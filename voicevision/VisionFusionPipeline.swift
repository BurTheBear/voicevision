import Foundation
import CoreML
import Vision
import AVFoundation
import CoreVideo
import UIKit
import Accelerate

protocol VisionFusionPipelineDelegate: AnyObject {
    func fusionPipeline(_ pipeline: VisionFusionPipeline, didUpdateDetections detections: [DetectedObject])
    func fusionPipeline(_ pipeline: VisionFusionPipeline, didUpdateHaptics intent: HapticIntent)
}

enum HapticIntent: Equatable {
    case none
    case close(intensity: Float)
    case approaching(intensity: Float)
    case receding
}

struct DetectedObject {
    var label: String
    var confidence: Float
    var bbox: CGRect   // normalized [0,1] in model input space
}

final class VisionFusionPipeline {

    weak var delegate: VisionFusionPipelineDelegate?

    // MARK: - Models
    // Switched to yolov8l_2
    private lazy var yoloCoreML: yolov8l_2? = {
        do { return try yolov8l_2(configuration: MLModelConfiguration()) }
        catch { print("[Fusion] YOLO init error: \(error)"); return nil }
    }()

    private lazy var yoloVNModel: VNCoreMLModel? = {
        guard let model = yoloCoreML?.model else { return nil }
        do { return try VNCoreMLModel(for: model) }
        catch { print("[Fusion] YOLO VN model error: \(error)"); return nil }
    }()

    private lazy var fastVitModel: FastViTMA36F16? = {
        do { return try FastViTMA36F16(configuration: MLModelConfiguration()) }
        catch { print("[Fusion] FastViT init error: \(error)"); return nil }
    }()

    private lazy var fastVitVNModel: VNCoreMLModel? = {
        guard let model = fastVitModel?.model else { return nil }
        do { return try VNCoreMLModel(for: model) }
        catch { print("[Fusion] FastViT VN model error: \(error)"); return nil }
    }()

    private lazy var depthModel: DepthAnythingV2SmallF16? = {
        do { return try DepthAnythingV2SmallF16(configuration: MLModelConfiguration()) }
        catch { print("[Fusion] Depth init error: \(error)"); return nil }
    }()

    private lazy var depthVNModel: VNCoreMLModel? = {
        guard let model = depthModel?.model else { return nil }
        do { return try VNCoreMLModel(for: model) }
        catch { print("[Fusion] Depth VN model error: \(error)"); return nil }
    }()

    // MARK: - YOLO via Vision (VNRecognizedObjectObservation-only)
    private lazy var yoloRequest: VNCoreMLRequest? = {
        guard let m = yoloVNModel else { return nil }
        let req = VNCoreMLRequest(model: m) { [weak self] request, _ in
            guard let self else { return }
            if let objs = request.results as? [VNRecognizedObjectObservation], !objs.isEmpty {
                self.handleVNRecognizedObjects(objs)
            } else {
                // Clear detections if none
                self.handleVNRecognizedObjects([])
            }
        }
        // Preserve aspect ratio for YOLO-style letterboxing
        req.imageCropAndScaleOption = .scaleFit
        return req
    }()

    // MARK: - Depth via Vision
    private lazy var depthRequest: VNCoreMLRequest? = {
        guard let m = depthVNModel else { return nil }
        let req = VNCoreMLRequest(model: m) { [weak self] request, _ in
            guard let self else { return }
            if let pbObs = (request.results as? [VNPixelBufferObservation])?.first {
                self.ingestDepthPixelBuffer(pbObs.pixelBuffer)
            } else if let fvObs = (request.results as? [VNCoreMLFeatureValueObservation])?.first,
                      let arr = fvObs.featureValue.multiArrayValue {
                self.ingestDepthArray(arr)
            }
        }
        req.imageCropAndScaleOption = .scaleFit
        return req
    }()

    // MARK: - Scene via Vision
    private lazy var fastVitRequest: VNCoreMLRequest? = {
        guard let m = fastVitVNModel else { return nil }
        let req = VNCoreMLRequest(model: m) { [weak self] request, _ in
            guard let self else { return }
            if let results = request.results as? [VNClassificationObservation],
               let top = results.first {
                self.latestSceneLabel = top.identifier
                self.latestSceneConfidence = top.confidence
            }
        }
        req.imageCropAndScaleOption = .centerCrop
        return req
    }()

    // MARK: - Additional Apple Vision requests (fusion)
    private let humanReq = VNDetectHumanRectanglesRequest()
    private let faceReq = VNDetectFaceRectanglesRequest()
    private let rectReq: VNDetectRectanglesRequest = {
        let r = VNDetectRectanglesRequest()
        r.minimumConfidence = 0.6
        r.minimumAspectRatio = 0.2
        r.maximumObservations = 4
        return r
    }()

    // MARK: - State / cadence
    private let queue = DispatchQueue(label: "fusion.pipeline.queue")
    private var lastFastVitTime: CFTimeInterval = 0
    private var lastYoloTime: CFTimeInterval = 0
    private var lastDepthTime: CFTimeInterval = 0
    private var lastFusionVisionTime: CFTimeInterval = 0

    // Public outputs
    private(set) var hapticIntent: HapticIntent = .none
    private(set) var latestSceneLabel: String?
    private(set) var latestSceneConfidence: Float = 0

    // Depth tracking for approach velocity
    private var latestDepthMetric: Float?
    private var lastDepthMetric: Float?
    private var lastDepthMetricTime: CFTimeInterval = 0

    // Smoothing cache
    private var smoothedDetections: [DetectedObject] = []
    private var lastDetectionsTime: CFTimeInterval = 0

    // Dedupe narration
    private var lastSpoken: String = ""
    private var lastSpokenTime: CFTimeInterval = 0

    // Guidance cooldown and stability
    private var lastGuidanceTime: CFTimeInterval = 0
    private var centerBlockedFrames: Int = 0
    private var allBlockedFrames: Int = 0
    private var lastPathClearTime: CFTimeInterval = 0

    // Per-class thresholds tuned for yolov8l_2 (slightly higher to reduce false positives)
    private let baseConfThreshold: Float = 0.34
    private let classThresholds: [String: Float] = [
        "person": 0.30, "chair": 0.34, "couch": 0.34, "potted plant": 0.36, "tv": 0.36,
        "bottle": 0.36, "cup": 0.36, "backpack": 0.34, "handbag": 0.36,
        "stairs": 0.34, "staircase": 0.34
    ]

    // Narration thresholds (stricter than detection)
    private let narrationDefaultThreshold: Float = 0.75
    private let narrationHighRiskThreshold: Float = 0.75
    private lazy var narrationThresholds: [String: Float] = {
        var map: [String: Float] = [:]
        let highRisk: Set<String> = [
            "dog", "cat",
            "refrigerator", "fridge",
            "microwave", "oven", "toaster",
            "tv", "television",
            "cell phone", "laptop"
        ]
        for (cls, _) in classThresholds {
            map[cls] = highRisk.contains(cls) ? narrationHighRiskThreshold : narrationDefaultThreshold
        }
        map["stairs"] = narrationDefaultThreshold
        map["staircase"] = narrationDefaultThreshold
        return map
    }()

    // Temporal consistency for narration
    private var prevDetectionsForNarration: [DetectedObject] = []
    private let narrationIoUMin: Float = 0.30
    private let minNarrationArea: CGFloat = 0.03
    private let maxAspectSkew: CGFloat = 5.0

    // Friendly names
    private let friendlyNames: [String: [String]] = [
        "couch": ["couch", "sofa", "loveseat", "sectional", "beanbag"],
        "chair": ["chair", "armchair", "stool"],
        "dining table": ["table", "dining table", "desk", "counter"],
        "bed": ["bed", "bunk bed", "mattress"],
        "tv": ["TV", "television", "screen"],
        "potted plant": ["plant", "potted plant", "houseplant"],
        "cell phone": ["phone", "cell phone"],
        "laptop": ["laptop", "notebook"],
        "bottle": ["bottle", "water bottle"],
        "cup": ["cup", "mug", "glass"],
        "backpack": ["backpack", "bagpack"],
        "handbag": ["bag", "handbag", "purse"],
        "suitcase": ["suitcase", "luggage"],
        "refrigerator": ["fridge", "refrigerator"],
        "microwave": ["microwave"],
        "oven": ["oven", "stove"],
        "sink": ["sink"],
        "toaster": ["toaster"],
        "book": ["book"],
        "clock": ["clock"],
        "vase": ["vase"],
        "teddy bear": ["teddy bear", "stuffed toy", "plush toy"],
        "person": ["person"],
        "stairs": ["stairs", "staircase", "steps"],
        "staircase": ["stairs", "staircase", "steps"],
    ]

    // MARK: - One-foot hard-stop calibration
    private let oneFootMetricThreshold: Float = 0.95
    private var nearFramesInARow: Int = 0
    private let nearFramesRequired: Int = 2
    private var lastHardStopTime: CFTimeInterval = 0
    private let hardStopCooldown: CFTimeInterval = 10.0
    private let hardStopDebounceFramesRequired: Int = 3

    // Scene prefix cadence
    private var lastScenePrefixTime: CFTimeInterval = 0
    private let scenePrefixCooldown: CFTimeInterval = 15.0

    // MARK: - Settings lookups
    private var guidanceOnlyMode: Bool {
        return UserDefaults.standard.bool(forKey: "guidanceOnlyMode")
    }

    // MARK: - Depth buffer retention for distance sampling
    private var depthW: Int = 0
    private var depthH: Int = 0
    private var depthBuffer: [Float] = [] // larger value = nearer

    // For wall detection via depth coverage
    private var nearCoverageFrames: Int = 0
    private var fullScreenDetectionsFrames: Int = 0
    private var lastWallSpeakTime: CFTimeInterval = 0
    private let wallCooldown: CFTimeInterval = 6.0

    // MARK: - Public API
    func enqueue(frame: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) {
        queue.async { [weak self] in
            self?.process(frame: frame, orientation: orientation)
        }
    }

    func warmUp() {
        queue.async { [weak self] in
            guard let self else { return }
            let dummySize = CGSize(width: 16, height: 16)
            UIGraphicsBeginImageContext(dummySize)
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: dummySize))
            let img = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()

            guard let cg = img?.cgImage else { return }
            let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])

            var reqs: [VNRequest] = []
            if let r = self.yoloRequest { reqs.append(r) }
            if let r = self.depthRequest { reqs.append(r) }
            if let r = self.fastVitRequest { reqs.append(r) }
            reqs.append(contentsOf: [self.humanReq, self.faceReq, self.rectReq])

            do { try handler.perform(reqs) } catch { /* ignore warmup errors */ }
        }
    }

    func process(frame: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) {
        let now = CACurrentMediaTime()

        // Depth ~20 Hz
        if now - self.lastDepthTime > 0.05, let req = self.depthRequest {
            self.lastDepthTime = now
            let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: orientation)
            try? handler.perform([req])
        }

        // YOLO ~15 Hz
        if now - self.lastYoloTime > 0.066, let req = self.yoloRequest {
            self.lastYoloTime = now
            let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: orientation)
            try? handler.perform([req])
        }

        // Supplementary Vision ~8 Hz
        if now - self.lastFusionVisionTime > 0.12 {
            self.lastFusionVisionTime = now
            let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: orientation)
            try? handler.perform([self.humanReq, self.faceReq, self.rectReq])
            self.fuseAppleVisionSignals()
        }

        // Scene label infrequently
        if now - self.lastFastVitTime > 1.0, let req = self.fastVitRequest {
            self.lastFastVitTime = now
            let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: orientation)
            try? handler.perform([req])
        }

        if now - self.lastDetectionsTime < 0.4 {
            self.maybeSpeakGuidance()
            self.maybeDetectWallAndSpeak()
        }
    }

    func processLiDARDepth(depthMap: CVPixelBuffer,
                           orientation: CGImagePropertyOrientation = .up,
                           intrinsics: simd_float3x3? = nil) {
        ingestDepthPixelBuffer(depthMap)
    }

    // MARK: - YOLO handling
    private func handleVNRecognizedObjects(_ objs: [VNRecognizedObjectObservation]) {
        var dets: [DetectedObject] = []

        for o in objs {
            guard let best = o.labels.first else { continue }
            let label = best.identifier
            let conf = best.confidence
            let bb = o.boundingBox
            let th = classThresholds[label] ?? baseConfThreshold
            if conf >= th {
                dets.append(DetectedObject(label: label, confidence: conf, bbox: bb))
            }
        }

        // Temporal smoothing for tracking/overlay (slightly stronger)
        let now = CACurrentMediaTime()
        let smoothed = smoothDetections(previous: smoothedDetections, current: dets, alpha: 0.7)
        smoothedDetections = smoothed
        lastDetectionsTime = now

        // Notify delegate (BoundingBoxOverlayView uses these; unchanged)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.fusionPipeline(self, didUpdateDetections: smoothed)
        }

        // Narration with stricter filters (suppressed in guidance-only mode)
        if !guidanceOnlyMode,
           let candidate = pickStableNarrationCandidate(current: smoothed, previous: prevDetectionsForNarration) {

            let direction = directionForBox(candidate.bbox)
            let distanceFt = distanceFeet(for: candidate.bbox)

            let phrase: String
            if let ft = distanceFt {
                let rounded = max(1, min(30, Int(round(ft))))
                if direction == "ahead" {
                    phrase = "There is a \(pickFriendlyName(for: candidate.label)) \(rounded) feet ahead."
                } else {
                    phrase = "There is a \(pickFriendlyName(for: candidate.label)) \(rounded) feet ahead \(direction)."
                }
            } else {
                let proximityWord = proximityWordForBox(candidate.bbox)
                phrase = phraseForObject(label: candidate.label, direction: direction, proximity: proximityWord)
            }

            speakUrgentDedup(phrase)
        }

        prevDetectionsForNarration = smoothed
    }

    private func smoothDetections(previous: [DetectedObject], current: [DetectedObject], alpha: CGFloat) -> [DetectedObject] {
        guard !previous.isEmpty else { return current }
        var result: [DetectedObject] = []
        for cur in current {
            if let match = previous.max(by: { iou($0.bbox, cur.bbox) < iou($1.bbox, cur.bbox) }),
               iou(match.bbox, cur.bbox) > 0.2, match.label == cur.label {
                let blendedRect = blendRect(a: match.bbox, b: cur.bbox, alpha: alpha)
                let blendedConf = Float(alpha) * match.confidence + Float(1 - alpha) * cur.confidence
                result.append(DetectedObject(label: cur.label, confidence: blendedConf, bbox: blendedRect))
            } else {
                result.append(cur)
            }
        }
        return result
    }

    private func pickStableNarrationCandidate(current: [DetectedObject], previous: [DetectedObject]) -> DetectedObject? {
        let filteredByConf = current.filter { det in
            let th = narrationThresholds[det.label] ?? narrationDefaultThreshold
            return det.confidence >= th
        }

        guard !filteredByConf.isEmpty else { return nil }

        let filteredByGeom = filteredByConf.filter { det in
            let area = det.bbox.width * det.bbox.height
            guard area >= minNarrationArea else { return false }
            let w = det.bbox.width
            let h = det.bbox.height
            guard w > 0, h > 0 else { return false }
            let aspect = max(w / h, h / w)
            return aspect <= maxAspectSkew
        }

        guard !filteredByGeom.isEmpty else { return nil }

        var stable: [DetectedObject] = []
        for det in filteredByGeom {
            if let prev = previous
                .filter({ $0.label == det.label })
                .max(by: { iou($0.bbox, det.bbox) < iou($1.bbox, det.bbox) }) {
                if iou(prev.bbox, det.bbox) >= narrationIoUMin {
                    stable.append(det)
                }
            }
        }

        guard !stable.isEmpty else { return nil }

        let best = stable.max { a, b in
            if a.confidence == b.confidence {
                let areaA = a.bbox.width * a.bbox.height
                let areaB = b.bbox.width * b.bbox.height
                return areaA < areaB
            }
            return a.confidence < b.confidence
        }

        return best
    }

    private func blendRect(a: CGRect, b: CGRect, alpha: CGFloat) -> CGRect {
        let x = alpha * a.origin.x + (1 - alpha) * b.origin.x
        let y = alpha * a.origin.y + (1 - alpha) * b.origin.y
        let w = alpha * a.width + (1 - alpha) * b.width
        let h = alpha * a.height + (1 - alpha) * b.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Apple Vision fusion
    private func fuseAppleVisionSignals() {
        let faces = (faceReq.results as? [VNFaceObservation]) ?? []
        let humans = (humanReq.results as? [VNHumanObservation]) ?? []

        if !smoothedDetections.isEmpty {
            for i in 0..<smoothedDetections.count {
                if smoothedDetections[i].label == "person" {
                    let bb = smoothedDetections[i].bbox
                    let overlapsFace = faces.contains(where: { iou(bb, $0.boundingBox) > 0.1 })
                    let overlapsHuman = humans.contains(where: { iou(bb, $0.boundingBox) > 0.1 })
                    if overlapsFace || overlapsHuman {
                        smoothedDetections[i].confidence = min(1.0, smoothedDetections[i].confidence + 0.2)
                    }
                }
            }
        }
    }

    // MARK: - Navigation guidance
    private func maybeSpeakGuidance() {
        let bands: [ClosedRange<CGFloat>] = [0.0...0.33, 0.33...0.66, 0.66...1.0]
        var coverage: [CGFloat] = [0,0,0]

        for d in smoothedDetections {
            let area = d.bbox.width * d.bbox.height
            guard area > 0.03 else { continue }
            let mx = d.bbox.midX
            if bands[0].contains(mx) { coverage[0] += area }
            else if bands[1].contains(mx) { coverage[1] += area }
            else if bands[2].contains(mx) { coverage[2] += area }
        }

        // Slightly earlier triggers to make guidance feel responsive
        let centerBlockedNow = coverage[1] > 0.24
        let leftOpen = coverage[0] < 0.10
        let rightOpen = coverage[2] < 0.10
        let allBlockedNow = coverage[0] > 0.20 && coverage[1] > 0.24 && coverage[2] > 0.20

        centerBlockedFrames = centerBlockedNow ? min(centerBlockedFrames + 1, 10) : 0
        allBlockedFrames = allBlockedNow ? min(allBlockedFrames + 1, 10) : 0

        let centerBlocked = centerBlockedFrames >= 2
        let allBlocked = allBlockedFrames >= 2

        let now = CACurrentMediaTime()

        if case let .close(intensity) = hapticIntent, intensity > oneFootMetricThreshold {
            nearFramesInARow += 1
            if nearFramesInARow >= max(nearFramesRequired, hardStopDebounceFramesRequired),
               now - lastHardStopTime > hardStopCooldown {
                lastHardStopTime = now
                speakUrgentDedup("Stop. Obstacle within one foot.", priority: .critical)
                hapticIntent = .close(intensity: max(0.98, intensity))
                return
            }
        } else {
            nearFramesInARow = 0
        }

        // More responsive cadence
        let guidanceCooldown: CFTimeInterval = 1.4
        guard now - lastGuidanceTime > guidanceCooldown else { return }

        if case let .close(intensity) = hapticIntent, intensity > 0.9 {
            if allBlocked {
                lastGuidanceTime = now
                speakUrgentDedup("Wall ahead. Turn around or go back.")
                return
            }
            if centerBlocked {
                lastGuidanceTime = now
                speakUrgentDedup("Wall ahead. Stop.")
                return
            }
        }

        if centerBlocked {
            lastGuidanceTime = now
            if leftOpen && !rightOpen {
                speakUrgentDedup("Obstacle ahead. Turn left.")
                return
            } else if rightOpen && !leftOpen {
                speakUrgentDedup("Obstacle ahead. Turn right.")
                return
            } else {
                speakUrgentDedup("Obstacle ahead. Slow down.")
                return
            }
        }

        // Guidance-only: optionally confirm when path is clear so mode feels active
        if guidanceOnlyMode,
           hapticIntent == .none,
           !centerBlocked,
           coverage[1] < 0.08,
           coverage[0] < 0.08,
           coverage[2] < 0.08,
           now - lastPathClearTime > 6.0 {
            lastGuidanceTime = now
            lastPathClearTime = now
            speakUrgentDedup("Path is clear.")
            return
        }

        if let person = smoothedDetections
            .filter({ $0.label == "person" && $0.confidence >= 0.6 })
            .sorted(by: { $0.bbox.width * $0.bbox.height > $1.bbox.width * $1.bbox.height })
            .first {
            if person.bbox.midX > 0.33 && person.bbox.midX < 0.66 && (person.bbox.width * person.bbox.height) > 0.07 {
                lastGuidanceTime = now
                speakUrgentDedup("There is a person ahead.")
            }
        }
    }

    private func maybeSpeakScene() {
        if let scene = latestSceneLabel, latestSceneConfidence >= 0.6 {
            let now = CACurrentMediaTime()
            if now - lastSpokenTime > 6.0, lastSpoken != "scene:\(scene)" {
                lastSpoken = "scene:\(scene)"
                lastSpokenTime = now
                Narrator.shared.speak(scenePhrase(scene))
            }
        }
    }

    private func scenePhrase(_ scene: String) -> String {
        return "This appears to be a \(scene)."
    }

    private enum SpeechPriority { case normal, critical }

    private func scenePrefix() -> String {
        guard let label = latestSceneLabel, latestSceneConfidence >= 0.6 else { return "" }
        let l = label.lowercased()
        let indoorKeywords: Set<String> = [
            "indoor", "living room", "kitchen", "bedroom", "office", "classroom",
            "library", "restaurant", "store", "supermarket", "gymnasium",
            "workshop", "wood shop", "carpentry shop", "corridor", "hallway"
        ]
        let outdoorKeywords: Set<String> = [
            "outdoor", "street", "park", "forest", "beach", "mountain",
            "sidewalk", "road", "parking lot", "playground", "field", "yard", "garden"
        ]

        if indoorKeywords.contains(l) { return "Indoor. " }
        if outdoorKeywords.contains(l) { return "Outdoor. " }
        if l.contains("indoor") { return "Indoor. " }
        if l.contains("outdoor") { return "Outdoor. " }
        return ""
    }

    private let globalSpeakCooldown: CFTimeInterval = 1.0

    private func speakUrgentDedup(_ phrase: String, priority: SpeechPriority = .normal) {
        let now = CACurrentMediaTime()

        if now - lastSpokenTime < globalSpeakCooldown { return }
        if phrase == lastSpoken, now - lastSpokenTime < 4.0 { return }

        var toSpeak = phrase
        if now - lastScenePrefixTime >= scenePrefixCooldown {
            let prefix = scenePrefix()
            if !prefix.isEmpty && !phrase.hasPrefix("Indoor.") && !phrase.hasPrefix("Outdoor.") {
                toSpeak = prefix + phrase
                lastScenePrefixTime = now
            }
        }

        if priority == .critical {
            DispatchQueue.main.async {
                Narrator.shared.speakUrgent(toSpeak)
            }
            lastSpoken = toSpeak
            lastSpokenTime = now
            return
        }

        lastSpoken = toSpeak
        lastSpokenTime = now
        DispatchQueue.main.async {
            Narrator.shared.speak(toSpeak)
        }
    }

    // MARK: - Geometry helpers
    private func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let inter = a.intersection(b)
        if inter.isNull { return 0 }
        let interArea = Float(inter.width * inter.height)
        let union = Float(a.width * a.height + b.width * b.height) - interArea
        return union > 0 ? (interArea / union) : 0
    }

    private func directionForBox(_ bbox: CGRect) -> String {
        let x = bbox.midX
        if x < 0.33 { return "to the left" }
        if x > 0.66 { return "to the right" }
        return "ahead"
    }

    private func proximityWordForBox(_ bbox: CGRect) -> String {
        let area = bbox.width * bbox.height
        if area > 0.20 { return "in front" }
        return ""
    }

    private func pickFriendlyName(for label: String) -> String {
        if let options = friendlyNames[label], let choice = options.randomElement() {
            return choice
        }
        return label
    }

    private func phraseForObject(label: String, direction: String, proximity: String) -> String {
        let friendly = pickFriendlyName(for: label)
        if label == "person" {
            return proximity.isEmpty ? "There is a person \(direction)." : "There is a person \(proximity)."
        }
        return proximity.isEmpty ? "There is a \(friendly) \(direction)." : "There is a \(friendly) \(proximity)."
    }

    // MARK: - Depth ingestion and distance estimation

    // Tunable calibration
    private let kA: Float = 8.5
    private let kB: Float = 0.18
    private let kMinFeet: Float = 0.7
    private let kMaxFeet: Float = 30.0

    private func depthToFeet(_ v: Float) -> Float {
        let raw = kA / max(0.05, (v + kB))
        return min(kMaxFeet, max(kMinFeet, raw))
    }

    private func ingestDepthArray(_ arr: MLMultiArray) {
        let shape = arr.shape.map { Int(truncating: $0) }
        var flat: [Float] = []

        if shape.count == 3, shape[0] == 1 {
            let H = shape[1], W = shape[2]
            flat.reserveCapacity(H * W)
            for i in 0..<H {
                for j in 0..<W {
                    let v = Float(truncating: arr[[0, NSNumber(value: i), NSNumber(value: j)]])
                    flat.append(v.isFinite ? v : 0)
                }
            }
            storeDepthMap(flat, width: W, height: H)
        } else if shape.count == 2 {
            let H = shape[0], W = shape[1]
            flat.reserveCapacity(H * W)
            for i in 0..<H {
                for j in 0..<W {
                    let v = Float(truncating: arr[[NSNumber(value: i), NSNumber(value: j)]])
                    flat.append(v.isFinite ? v : 0)
                }
            }
            storeDepthMap(flat, width: W, height: H)
        } else {
            depthBuffer.removeAll()
            depthW = 0
            depthH = 0
        }

        let metric = computeProximityMetric(from: arr)
        updateHapticIntent(with: metric)
        latestDepthMetric = metric
    }

    private func ingestDepthPixelBuffer(_ pb: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent16Half else {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            let rowBytes = CVPixelBufferGetBytesPerRow(pb)
            var flat: [Float] = []
            flat.reserveCapacity(w*h)
            for i in 0..<h {
                let row = base.advanced(by: i * rowBytes)
                for j in 0..<w {
                    let v = Float(row.load(fromByteOffset: j, as: UInt8.self)) / 255.0
                    flat.append(v)
                }
            }
            storeDepthMap(flat, width: w, height: h)

            let metric = computeProximityMetric(fromDepthPixelBuffer: pb)
            updateHapticIntent(with: metric)
            latestDepthMetric = metric
            return
        }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let width = CVPixelBufferGetWidth(pb)
        let height = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }

        var srcBuffer = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
        let floatRowBytes = width * MemoryLayout<Float>.size
        guard let dstData = malloc(height * floatRowBytes) else { return }
        defer { free(dstData) }
        var dstBuffer = vImage_Buffer(data: dstData, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: floatRowBytes)

        let err = vImageConvert_Planar16FtoPlanarF(&srcBuffer, &dstBuffer, vImage_Flags(kvImageNoFlags))
        if err != kvImageNoError { return }

        var flat: [Float] = Array(repeating: 0, count: width * height)
        for i in 0..<height {
            let rowPtr = dstData.advanced(by: i * floatRowBytes).assumingMemoryBound(to: Float.self)
            for j in 0..<width {
                flat[i * width + j] = rowPtr[j]
            }
        }
        storeDepthMap(flat, width: width, height: height)

        let metric = computeProximityMetric(fromDepthPixelBuffer: pb)
        updateHapticIntent(with: metric)
        latestDepthMetric = metric
    }

    private func storeDepthMap(_ flat: [Float], width: Int, height: Int) {
        let target = 80
        guard width > 0, height > 0 else {
            depthBuffer.removeAll(); depthW = 0; depthH = 0; return
        }
        let sx = max(1, width / target)
        let sy = max(1, height / target)
        let dw = max(1, width / sx)
        let dh = max(1, height / sy)

        var out: [Float] = Array(repeating: 0, count: dw * dh)
        for y in 0..<dh {
            for x in 0..<dw {
                var acc: Float = 0
                var n: Int = 0
                let x0 = x * sx
                let y0 = y * sy
                let x1 = min(width, x0 + sx)
                let y1 = min(height, y0 + sy)
                for yy in y0..<y1 {
                    let base = yy * width
                    for xx in x0..<x1 {
                        let v = flat[base + xx]
                        if v.isFinite {
                            acc += v
                            n += 1
                        }
                    }
                }
                out[y * dw + x] = n > 0 ? (acc / Float(n)) : 0
            }
        }
        depthBuffer = out
        depthW = dw
        depthH = dh
    }

    private func sampleDepth(at normPoint: CGPoint) -> Float? {
        guard depthW > 0, depthH > 0, !depthBuffer.isEmpty else { return nil }
        let x = Int(clamp(normPoint.x, 0, 1) * CGFloat(depthW - 1))
        let y = Int(clamp(normPoint.y, 0, 1) * CGFloat(depthH - 1))

        var samples: [Float] = []
        samples.reserveCapacity(81)
        let r = 4
        for yy in max(0, y - r)...min(depthH - 1, y + r) {
            for xx in max(0, x - r)...min(depthW - 1, x + r) {
                let v = depthBuffer[yy * depthW + xx]
                if v.isFinite { samples.append(v) }
            }
        }
        guard samples.count >= 9 else { return nil }
        samples.sort()
        let trim = max(1, samples.count / 7)
        let trimmed = samples[trim..<(samples.count - trim)]
        let mean = trimmed.reduce(0, +) / Float(trimmed.count)
        return mean
    }

    // Apply 1/4 scaling (as requested)
    func distanceFeet(for bbox: CGRect) -> Float? {
        let center = CGPoint(x: bbox.midX, y: bbox.midY)
        guard let d = sampleDepth(at: center) else { return nil }
        let feet = depthToFeet(d) / 4.0
        return Float(Int(round(feet)))
    }

    // MARK: - Depth metric helpers
    private func computeProximityMetric(from arr: MLMultiArray) -> Float {
        let shape = arr.shape.map { Int(truncating: $0) }
        let count = arr.count
        var values: [Float] = []
        values.reserveCapacity(min(5000, count))

        if shape.count == 3, shape[0] == 1 {
            let H = shape[1], W = shape[2]
            let i0 = max(0, H/2 - H/6), i1 = min(H, H/2 + H/6)
            let j0 = max(0, W/2 - W/6), j1 = min(W, W/2 + W/6)
            for i in i0..<i1 {
                for j in j0..<j1 {
                    let v = Float(truncating: arr[[0, NSNumber(value: i), NSNumber(value: j)]])
                    if v.isFinite { values.append(v) }
                }
            }
        } else if shape.count == 2 {
            let H = shape[0], W = shape[1]
            let i0 = max(0, H/2 - H/6), i1 = min(H, H/2 + H/6)
            let j0 = max(0, W/2 - W/6), j1 = min(W, W/2 + W/6)
            for i in i0..<i1 {
                for j in j0..<j1 {
                    let v = Float(truncating: arr[[NSNumber(value: i), NSNumber(value: j)]])
                    if v.isFinite { values.append(v) }
                }
            }
        } else {
            let N = min(5000, count)
            for k in 0..<N {
                let v = Float(truncating: arr[k])
                if v.isFinite { values.append(v) }
            }
        }

        if values.isEmpty { return 0 }
        values.sort()
        let p10 = values[values.count / 10]
        let near = max(0, min(1, (5.0 - p10) / 4.8))
        return near
    }

    private func computeProximityMetric(fromDepthPixelBuffer pb: CVPixelBuffer) -> Float {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent16Half else {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            let rowBytes = CVPixelBufferGetBytesPerRow(pb)
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return 0 }
            var values: [Float] = []
            values.reserveCapacity(4000)
            let stepY = max(1, h / 24)
            let stepX = max(1, w / 24)
            for y in stride(from: h/3, to: 2*h/3, by: stepY) {
                let row = base.advanced(by: y * rowBytes)
                for x in stride(from: w/3, to: 2*w/3, by: stepX) {
                    let v = Float(row.load(fromByteOffset: x, as: UInt8.self)) / 255.0
                    if v.isFinite { values.append(v) }
                }
            }
            if values.isEmpty { return 0 }
            values.sort()
            let p10 = values[values.count / 10]
            let near = max(0, min(1, (1.0 - p10)))
            return near
        }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let width = CVPixelBufferGetWidth(pb)
        let height = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return 0 }

        var srcBuffer = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
        let floatRowBytes = width * MemoryLayout<Float>.size
        guard let dstData = malloc(height * floatRowBytes) else { return 0 }
        defer { free(dstData) }
        var dstBuffer = vImage_Buffer(data: dstData, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: floatRowBytes)

        let err = vImageConvert_Planar16FtoPlanarF(&srcBuffer, &dstBuffer, vImage_Flags(kvImageNoFlags))
        if err != kvImageNoError { return 0 }

        var values: [Float] = []
        values.reserveCapacity(5000)
        let i0 = max(0, height/2 - height/6)
        let i1 = min(height, height/2 + height/6)
        let j0 = max(0, width/2 - width/6)
        let j1 = min(width, width/2 + width/6)

        for i in i0..<i1 {
            let rowPtr = dstData.advanced(by: i * floatRowBytes).assumingMemoryBound(to: Float.self)
            for j in j0..<j1 {
                let v = rowPtr[j]
                if v.isFinite { values.append(v) }
            }
        }

        if values.isEmpty { return 0 }
        values.sort()
        let p10 = values[values.count / 10]
        let near = max(0, min(1, (5.0 - p10) / 4.8))
        return near
    }

    private func updateHapticIntent(with metric: Float) {
        let t = CACurrentMediaTime()
        var intent: HapticIntent = .none

        var velocity: Float = 0
        if let last = lastDepthMetric, lastDepthMetricTime > 0 {
            let dt = max(0.016, Float(t - lastDepthMetricTime))
            velocity = (metric - last) / dt
        }
        lastDepthMetric = metric
        lastDepthMetricTime = t

        if metric > 0.82 {
            intent = .close(intensity: min(1.0, metric))
        } else if velocity > 0.55 {
            intent = .approaching(intensity: max(0.2, min(0.9, metric)))
        } else if velocity < -0.35 {
            intent = .receding
        } else {
            intent = .none
        }

        self.hapticIntent = intent

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.fusionPipeline(self, didUpdateHaptics: intent)
        }
    }

    // MARK: - Wall detection improvements

    private func maybeDetectWallAndSpeak() {
        let now = CACurrentMediaTime()

        // Heuristic 1: Full-screen coverage by detections
        let totalArea = smoothedDetections.reduce(CGFloat(0)) { $0 + $1.bbox.width * $1.bbox.height }
        let maxArea = smoothedDetections.map { $0.bbox.width * $0.bbox.height }.max() ?? 0
        let fullScreenByBoxes = (totalArea > 0.85) || (maxArea > 0.80)

        if fullScreenByBoxes {
            fullScreenDetectionsFrames = min(fullScreenDetectionsFrames + 1, 10)
        } else {
            fullScreenDetectionsFrames = 0
        }

        // Heuristic 2: Depth near coverage across frame
        let nearCoverage = depthNearCoverage()
        let nearCoverageHigh = nearCoverage > 0.65
        if nearCoverageHigh {
            nearCoverageFrames = min(nearCoverageFrames + 1, 10)
        } else {
            nearCoverageFrames = 0
        }

        let wallLikely = (fullScreenDetectionsFrames >= 2) || (nearCoverageFrames >= 2)
        guard wallLikely else { return }
        guard now - lastWallSpeakTime > wallCooldown else { return }

        let centerBBox = CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10)
        let centerFeet = distanceFeet(for: centerBBox) ?? 3.0
        let rounded = max(1, Int(round(centerFeet)))
        lastWallSpeakTime = now
        speakUrgentDedup("Wall about \(rounded) feet ahead.")
    }

    private func depthNearCoverage() -> Float {
        guard depthW > 0, depthH > 0, !depthBuffer.isEmpty else { return 0 }
        let thresholdNear: Float = 1.2
        let sampleStep = max(1, min(depthW, depthH) / 40)
        var nearCount = 0
        var total = 0
        for y in stride(from: 0, to: depthH, by: sampleStep) {
            for x in stride(from: 0, to: depthW, by: sampleStep) {
                let v = depthBuffer[y * depthW + x]
                if v.isFinite {
                    total += 1
                    if v >= thresholdNear { nearCount += 1 }
                }
            }
        }
        if total == 0 { return 0 }
        return Float(nearCount) / Float(total)
    }

    // MARK: - Utils
    private func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
        return max(lo, min(hi, v))
    }
}

