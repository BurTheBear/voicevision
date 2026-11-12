import UIKit

final class BoundingBoxOverlayView: UIView {

    struct Box {
        let rect: CGRect   // normalized [0,1] coords
        let label: String
        let confidence: Float
    }

    // The displayed video rectangle inside this view (accounting for aspect fill)
    // CameraVC will set this each layout pass from AVCaptureVideoPreviewLayer.videoRect.
    var videoRect: CGRect = .zero {
        didSet { setNeedsLayout() }
    }

    private var boxes: [Box] = []
    private var shapeLayers: [CAShapeLayer] = []
    private var textLayers: [CATextLayer] = []

    override class var layerClass: AnyClass { CALayer.self }

    func show(detections: [DetectedObject]) {
        boxes = detections.map { Box(rect: $0.bbox, label: $0.label, confidence: $0.confidence) }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        shapeLayers.removeAll()
        textLayers.removeAll()

        let drawRect = videoRect == .zero ? bounds : videoRect

        for b in boxes {
            // If boxes appear vertically flipped, uncomment the flippedY line and use flippedRect instead of b.rect.
            // let flippedY = 1.0 - (b.rect.origin.y + b.rect.height)
            // let flippedRect = CGRect(x: b.rect.origin.x, y: flippedY, width: b.rect.width, height: b.rect.height)
            let converted = rectInView(fromNormalized: b.rect, in: drawRect)

            let shape = CAShapeLayer()
            shape.frame = converted
            shape.path = UIBezierPath(rect: shape.bounds).cgPath
            shape.strokeColor = color(for: b.label).cgColor
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 2.0

            layer.addSublayer(shape)
            shapeLayers.append(shape)

            let text = CATextLayer()
            text.contentsScale = UIScreen.main.scale
            text.alignmentMode = .left
            text.foregroundColor = UIColor.white.cgColor
            text.backgroundColor = color(for: b.label).withAlphaComponent(0.85).cgColor
            text.cornerRadius = 4
            text.masksToBounds = true

            let label = "\(b.label) \(Int(b.confidence * 100))%"
            let font = UIFont.systemFont(ofSize: 12, weight: .semibold)
            let size = (label as NSString).size(withAttributes: [.font: font])
            let textWidth = size.width + 8
            let textHeight = size.height + 4

            text.frame = CGRect(x: converted.minX,
                                y: max(0, converted.minY - textHeight - 2),
                                width: min(textWidth, bounds.width - converted.minX),
                                height: textHeight)

            text.string = label
            layer.addSublayer(text)
            textLayers.append(text)
        }
    }

    private func rectInView(fromNormalized r: CGRect, in container: CGRect) -> CGRect {
        let x = container.origin.x + r.origin.x * container.width
        let y = container.origin.y + r.origin.y * container.height
        let w = r.size.width * container.width
        let h = r.size.height * container.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func color(for label: String) -> UIColor {
        switch label {
        case "person": return UIColor.systemRed
        case "chair", "couch", "bed": return UIColor.systemBlue
        case "tv", "laptop", "cell phone", "keyboard", "mouse": return UIColor.systemPurple
        case "bottle", "cup": return UIColor.systemTeal
        case "stairs", "staircase": return UIColor.systemOrange
        default: return UIColor.systemGreen
        }
    }
}
