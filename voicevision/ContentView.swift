import SwiftUI
import AVFoundation
import Vision
import Combine
import CoreHaptics
// ARKit removed from this file to avoid LiDAR usage

// MARK: - Main App View
struct ContentView: View {
    @ObservedObject var narrator = Narrator.shared
    @AppStorage("acceptedTOS") private var acceptedTOS: Bool = false
    @State private var showTOS = false
    @State private var showInstructions = false
    @State private var showSettings = false

    @State private var started = false
    @State private var authStatus = AVCaptureDevice.authorizationStatus(for: .video)

    // New: control whether we are on the intro page or the existing home
    @State private var showIntro: Bool = true
    // New: control selected tab (0 = Home, 1 = Technologies)
    @State private var selectedTab: Int = 0

    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        TabView(selection: $selectedTab) {
            // Home tab: shows Intro first, then your existing home flow
            ZStack {
                if showIntro {
                    IntroView {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showIntro = false
                        }
                    }
                } else {
                    ZStack {
                        if started {
                            if authStatus == .authorized {
                                CameraScreen(onExit: {
                                    Narrator.shared.stopSpeaking()
                                    started = false
                                }, onAppear: {
                                    authStatus = AVCaptureDevice.authorizationStatus(for: .video)
                                }, onShowSettings: {
                                    showSettings = true
                                })
                                .transition(.move(edge: .bottom))
                            } else {
                                PermissionGateView(
                                    status: $authStatus,
                                    onClose: {
                                        Narrator.shared.stopSpeaking()
                                        started = false
                                    }
                                )
                                .transition(.opacity)
                            }
                        } else {
                            StartScreen(
                                acceptedTOS: $acceptedTOS,
                                onStart: {
                                    if !acceptedTOS {
                                        showTOS = true
                                        return
                                    }
                                    authStatus = AVCaptureDevice.authorizationStatus(for: .video)
                                    started = true
                                },
                                onShowTOS: { showTOS = true },
                                onShowInstructions: { showInstructions = true },
                                onShowSettings: { showSettings = true }
                            )
                            .sheet(isPresented: $showTOS) {
                                TermsOfServiceView(accepted: $acceptedTOS) {
                                    Narrator.shared.stopSpeaking()
                                    showTOS = false
                                }
                            }
                            .sheet(isPresented: $showInstructions) {
                                InstructionsView {
                                    Narrator.shared.stopSpeaking()
                                    showInstructions = false
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .animation(.easeInOut(duration: 0.3), value: started)
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }
            .tag(0)

            // Technologies tab
            TechnologiesView()
                .tabItem {
                    Label("Technologies", systemImage: "bolt.horizontal.fill")
                }
                .tag(1)
        }
        .onChange(of: settings.speakLanguageCode) { _, newCode in
            Narrator.shared.setLanguage(code: newCode)
        }
        .onAppear {
            Narrator.shared.setLanguage(code: settings.speakLanguageCode)
            Narrator.shared.showSubtitles = settings.showSubtitles
        }
        .onChange(of: settings.showSubtitles) { _, newValue in
            Narrator.shared.showSubtitles = newValue
        }
    }
}

// MARK: - Intro Page
struct IntroView: View {
    let onGo: () -> Void

    private let gold = Color(red: 0.95, green: 0.76, blue: 0.2)
    private let nearBlack = Color(red: 0.06, green: 0.06, blue: 0.07)

    var body: some View {
        ZStack {
            nearBlack.ignoresSafeArea()
            VStack(spacing: 32) {
                Spacer()

                Text("VoiceVision")
                    .font(.system(size: 48, weight: .heavy, design: .rounded))
                    .foregroundColor(gold)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                Button(action: onGo) {
                    Text("GO")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .background(gold)
                        .cornerRadius(28)
                        .shadow(color: gold.opacity(0.35), radius: 12, x: 0, y: 8)
                        .padding(.horizontal, 24)
                }
                .accessibilityLabel("Go to Home")

                Spacer(minLength: 60)
            }
        }
    }
}

// MARK: - Start Screen
struct StartScreen: View {
    @Binding var acceptedTOS: Bool
    let onStart: () -> Void
    let onShowTOS: () -> Void
    let onShowInstructions: () -> Void
    let onShowSettings: () -> Void

    // Gold and black palette
    private let gold = Color(red: 0.95, green: 0.76, blue: 0.2) // approx #F2C233
    private let goldDim = Color(red: 0.75, green: 0.6, blue: 0.16)
    private let nearBlack = Color(red: 0.06, green: 0.06, blue: 0.07) // very dark gray/black
    private let softBlack = Color(red: 0.12, green: 0.12, blue: 0.14)

    var body: some View {
        ZStack {
            nearBlack
                .ignoresSafeArea()

            VStack(spacing: 28) {
                HStack {
                    Spacer()
                    Button(action: onShowSettings) {
                        Image(systemName: "gearshape")
                            .font(.title2)
                            .foregroundColor(gold)
                            .padding(10)
                            .background(softBlack.opacity(0.6), in: Circle())
                            .overlay(
                                Circle().stroke(gold.opacity(0.6), lineWidth: 1)
                            )
                    }
                    .accessibilityLabel("Settings")
                    .padding(.trailing)
                    .padding(.top)
                }

                VStack(spacing: 8) {
                    Text("🎙️ VoiceVision")
                        .font(.largeTitle)
                        .bold()
                        .foregroundColor(gold)
                    Text("Guiding vision beyond sight")
                        .font(.subheadline)
                        .foregroundColor(Color.white.opacity(0.7))
                }

                HStack(spacing: 12) {
                    Button(action: onStart) {
                        Text(acceptedTOS ? "Start Narration" : "Accept Terms to Start")
                            .fontWeight(.semibold)
                            .foregroundColor(Color.black)
                            .padding()
                            .frame(maxWidth: 220)
                            .background(acceptedTOS ? gold : goldDim.opacity(0.6))
                            .cornerRadius(25)
                            .shadow(color: gold.opacity(0.35), radius: 10, x: 0, y: 6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 25)
                                    .stroke(acceptedTOS ? gold.opacity(0.9) : goldDim.opacity(0.7), lineWidth: 1)
                            )
                    }
                    .disabled(!acceptedTOS)

                    Button(action: onShowInstructions) {
                        Image(systemName: "questionmark.circle")
                            .font(.title2)
                            .foregroundColor(gold)
                            .padding(10)
                            .background(softBlack.opacity(0.6), in: Circle())
                            .overlay(
                                Circle().stroke(gold.opacity(0.6), lineWidth: 1)
                            )
                    }
                    .accessibilityLabel("Instructions")
                }

                Button(action: onShowTOS) {
                    Text("View Terms of Service")
                        .font(.footnote)
                        .underline()
                        .foregroundColor(gold.opacity(0.9))
                }
                .padding(.top, 4)

                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Technologies Tab
struct TechnologiesView: View {
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    Group {
                        Text("YOLOv8")
                            .font(.title2).bold()
                        Text(
                            "YOLOv8 is a modern real-time object detector from Ultralytics. " +
                            "It balances accuracy and speed, using anchor-free head variants and improved training strategies. " +
                            "It’s well-suited for mobile-friendly deployment when quantized or distilled, " +
                            "and is commonly used for detecting people, everyday objects, and scene elements in a single forward pass."
                        )
                        .foregroundColor(.secondary)
                    }

                    Divider()

                    Group {
                        Text("FastViT")
                            .font(.title2).bold()
                        Text(
                            "FastViT is a family of hybrid Vision Transformers designed for speed and efficiency. " +
                            "By combining convolutional stems with lightweight transformer blocks, it achieves strong accuracy " +
                            "while maintaining low latency on-device. It works well for classification, feature extraction, " +
                            "and as a backbone for downstream tasks."
                        )
                        .foregroundColor(.secondary)
                    }

                    Divider()

                    Group {
                        Text("DepthAnythingV2")
                            .font(.title2).bold()
                        Text(
                            "DepthAnythingV2 is a state-of-the-art monocular depth estimation model that generalizes well across domains. " +
                            "It produces dense depth maps from a single RGB image, enabling downstream applications like obstacle proximity, " +
                            "layout understanding, and AR effects without a dedicated depth sensor."
                        )
                        .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Technologies")
        }
    }
}

// MARK: - Instructions
struct InstructionsView: View {
    let onClose: () -> Void

    private var spokenInstructions: String {
        [
            "How to use VoiceVision.",
            "1. Hold the phone upright. Point the rear camera at what you want described and keep your hand steady.",
            "2. Boxes and labels. Colored boxes show detected objects: red for people, blue for furniture, purple for electronics, and green for other objects.",
            "3. Haptics and proximity. Continuous strong vibration means an obstacle is very close, about one foot. Short pulses mean something is approaching. Soft ticks mean it’s moving away.",
            "4. Navigation tips. If you hear Obstacle ahead, it may tell you to turn left or right. If you hear Stop, an obstacle is within one foot.",
            "5. Safety. This is not a safety device. Always move carefully, especially near stairs, traffic, or uneven ground."
        ].joined(separator: "\n")
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("How to Use VoiceVision")
                        .font(.title).bold()

                    Group {
                        Text("1. Hold the phone upright").font(.headline)
                        Text("Point the rear camera at what you want described. Keep your hand steady for best results.")
                    }

                    Group {
                        Text("2. Boxes and labels").font(.headline)
                        Text("Colored boxes show detected objects. Red highlights people, blue shows furniture, purple shows electronics, and green other objects.")
                    }

                    Group {
                        Text("3. Haptics and proximity").font(.headline)
                        Text("Continuous strong vibration signals a very close obstacle (about one foot). Short pulses mean something is approaching; soft ticks mean it’s receding.")
                    }

                    Group {
                        Text("4. Navigation tips").font(.headline)
                        Text("If you hear ‘Obstacle ahead’, it may tell you to turn left or right. If you hear ‘Stop’, an obstacle is within one foot.")
                    }

                    Group {
                        Text("5. Safety").font(.headline)
                        Text("This is not a safety device. Always move carefully, especially near stairs, traffic, or uneven ground.")
                    }
                }
                .padding()
            }
            .navigationBarItems(
                leading: Button("Close") {
                    Narrator.shared.stopSpeaking()
                    onClose()
                }
            )
        }
        .onAppear {
            Narrator.shared.speak(spokenInstructions)
        }
        .onDisappear {
            Narrator.shared.stopSpeaking()
        }
    }
}

// MARK: - Terms of Service
struct TermsOfServiceView: View {
    @Binding var accepted: Bool
    let onClose: () -> Void

    private var spokenTOS: String {
        [
            "Terms of Service.",
            "1. Acceptance of Terms. By using VoiceVision, you agree to these terms. Continued use means you accept any updates.",
            "2. No Safety Guarantees. VoiceVision may be inaccurate or delayed and is not a safety device. Always remain aware of your surroundings.",
            "3. No Medical or Professional Advice. Information is general and not professional advice.",
            "4. Assumption of Risk. You assume all risks associated with using the app, including misinterpretation or missed obstacles.",
            "5. Limitation of Liability. To the maximum extent permitted by law, developers are not liable for injuries, damages, or losses related to use of the app.",
            "6. Privacy. Camera input may be processed on-device. The app does not transmit your video to external services without your explicit consent.",
            "7. Appropriate Use. Do not use while operating vehicles or in situations where distraction could cause harm.",
            "8. Termination. Access may be suspended or terminated for violations or misuse.",
            "9. Contact. For questions, use the support channels listed with the app.",
            "To accept, enable the toggle, then press Accept."
        ].joined(separator: "\n")
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Terms of Service")
                        .font(.title)
                        .bold()

                    Group {
                        Text("1. Acceptance of Terms")
                            .font(.headline)
                        Text("By using VoiceVision, you agree to these Terms of Service. If you do not agree, do not use the app. These terms may be updated occasionally; continued use means you accept any changes.")
                    }

                    Group {
                        Text("2. No Safety Guarantees")
                            .font(.headline)
                        Text("VoiceVision provides descriptive audio and haptic feedback to assist with awareness. However, it is not a safety device and may be inaccurate or delayed. You must remain aware of your surroundings and use your own judgment at all times.")
                    }

                    Group {
                        Text("3. No Medical or Professional Advice")
                            .font(.headline)
                        Text("Information provided is for general informational purposes only and should not be considered medical, legal, or professional advice.")
                    }

                    Group {
                        Text("4. Assumption of Risk")
                            .font(.headline)
                        Text("You understand and agree that using VoiceVision involves inherent risks. You assume all risks associated with using the app, including but not limited to misinterpretation of descriptions, missed obstacles, or delays in feedback.")
                    }

                    Group {
                        Text("5. Limitation of Liability")
                            .font(.headline)
                        Text("To the maximum extent permitted by law, the developers and affiliates of VoiceVision are not liable for any injuries, accidents, damages, or losses arising from or related to your use of the app. You agree to hold the developers harmless from any claims or demands.")
                    }

                    Group {
                        Text("6. Privacy")
                            .font(.headline)
                        Text("VoiceVision may process camera input on-device to provide descriptions and feedback. The app does not transmit your video to external services without your explicit consent. Refer to our Privacy Policy for more details.")
                    }

                    Group {
                        Text("7. Appropriate Use")
                            .font(.headline)
                        Text("Do not use VoiceVision while operating vehicles or in any situation where distraction could cause harm. The app is intended to supplement awareness, not replace it.")
                    }

                    Group {
                        Text("8. Termination")
                            .font(.headline)
                        Text("We reserve the right to suspend or terminate access if you violate these terms or misuse the app.")
                    }

                    Group {
                        Text("9. Contact")
                            .font(.headline)
                        Text("If you have questions about these terms, contact the developer/support through the channels provided in the app listing.")
                    }

                    Toggle("I have read and agree to the Terms of Service", isOn: $accepted)
                        .padding(.top, 12)
                }
                .padding()
            }
            .navigationBarItems(
                leading: Button("Close") {
                    Narrator.shared.stopSpeaking()
                    onClose()
                },
                trailing: Button("Accept") {
                    accepted = true
                    Narrator.shared.stopSpeaking()
                    onClose()
                }.disabled(!accepted)
            )
        }
        .onAppear {
            Narrator.shared.speak(spokenTOS)
        }
        .onDisappear {
            Narrator.shared.stopSpeaking()
        }
    }
}

// MARK: - Permission Gate
struct PermissionGateView: View {
    @Binding var status: AVAuthorizationStatus
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.title2)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top)

            Spacer()

            switch status {
            case .notDetermined:
                VStack(spacing: 12) {
                    Text("Allow Camera Access")
                        .font(.title2).bold()
                    Text("VoiceVision needs the camera to narrate what it sees.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    Button {
                        requestCamera()
                    } label: {
                        Text("Continue")
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding()
                            .frame(width: 220)
                            .background(Color.gray.opacity(0.9))
                            .cornerRadius(25)
                    }
                }

            case .denied, .restricted:
                VStack(spacing: 12) {
                    Text("Camera Access Needed")
                        .font(.title2).bold()
                    Text("Enable camera access in Settings → Privacy → Camera.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    Button {
                        openSettings()
                    } label: {
                        Label("Open Settings", systemImage: "gear")
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding()
                            .frame(width: 220)
                            .background(Color.gray.opacity(0.9))
                            .cornerRadius(25)
                    }
                }

            case .authorized:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting camera…")
                        .foregroundColor(.secondary)
                }

            @unknown default:
                Text("Camera not available.")
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .background(Color(.systemGray6).ignoresSafeArea())
    }

    private func requestCamera() {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async {
                status = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Camera Screen
struct CameraScreen: View {
    @ObservedObject var narrator = Narrator.shared
    let onExit: () -> Void
    var onAppear: () -> Void = {}
    var onShowSettings: () -> Void = {}

    @State private var controllerRef = CameraControllerRef()
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        ZStack {
            CameraView(controllerRef: $controllerRef)
                .ignoresSafeArea()
                .onAppear {
                    onAppear()
                    controllerRef.controller?.start()
                }
                .onDisappear {
                    controllerRef.controller?.stop()
                    Narrator.shared.stopSpeaking()
                }

            VStack {
                HStack(spacing: 12) {
                    Button(action: {
                        Narrator.shared.stopSpeaking()
                        onExit()
                    }) {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(.leading)

                    Button(action: onShowSettings) {
                        Image(systemName: "gearshape")
                            .font(.title2)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Settings")

                    Spacer()
                }
                .padding(.top)

                Spacer()
                if settings.showSubtitles {
                    Text(narrator.lastTranslatedPhrase.isEmpty ? narrator.lastPhrase : narrator.lastTranslatedPhrase)
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundColor(.white)
                        .padding(.bottom, 24)
                        .multilineTextAlignment(.center)
                        .accessibilityLabel("Subtitle")
                }
            }
        }
    }
}

// Helper to hold a weak reference to CameraVC
final class CameraControllerRef {
    weak var controller: CameraVC?
}

// MARK: - Narrator with male voice and strict pacing + language support
final class Narrator: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Narrator()

    private let synth = AVSpeechSynthesizer()
    @Published var lastPhrase: String = "Point the camera at something…"
    @Published var lastTranslatedPhrase: String = "" // for subtitles

    // Strict pacing controls
    private var isSpeaking = false
    private var lastFinishTime = Date.distantPast

    // Keep only the most recent pending phrase with timestamp
    private var pendingPhrase: String?
    private var pendingTimestamp: Date?

    // Tunable pacing
    private let cooldownAfterFinish: TimeInterval = 0.875
    private let maxPendingAge: TimeInterval = 5.0

    // Language/voice
    private var currentLanguageCode: String = "en-US"
    var showSubtitles: Bool = true

    override init() {
        super.init()
        synth.delegate = self
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            print("[Audio] AVAudioSession setup error: \(error)")
        }
    }

    func setLanguage(code: String) {
        currentLanguageCode = code
    }

    // Public API: speak in selected language with lightweight inline translations for ES/FR
    func speak(_ text: String) {
        speakInternal(text, interrupt: false)
    }

    func speakUrgent(_ text: String) {
        speakInternal(text, interrupt: true)
    }

    private func speakInternal(_ text: String, interrupt: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let now = Date()

        let sinceFinish = now.timeIntervalSince(lastFinishTime)
        if (isSpeaking || sinceFinish < cooldownAfterFinish), !interrupt {
            pendingPhrase = trimmed
            pendingTimestamp = now
            return
        }

        if interrupt, synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
            isSpeaking = false
        }
        pendingPhrase = nil
        pendingTimestamp = nil

        translateAndSpeak(trimmed)
    }

    // Minimal inline dictionary for Spanish/French/Hindi; fallback to original
    private func inlineTranslate(_ text: String, to languageCode: String) -> String {
        let key = text.lowercased()
        if languageCode.hasPrefix("es") {
            let dict: [String: String] = [
                "stop. obstacle within one foot.": "Alto. Obstáculo a menos de un pie.",
                "wall ahead. turn around or go back.": "Pared adelante. Da la vuelta o regresa.",
                "wall ahead. stop.": "Pared adelante. Detente.",
                "obstacle ahead. turn left.": "Obstáculo adelante. Gira a la izquierda.",
                "obstacle ahead. turn right.": "Obstáculo adelante. Gira a la derecha.",
                "obstacle ahead. slow down.": "Obstáculo adelante. Reduce la velocidad.",
                "path is clear.": "El camino está despejado.",
                "there is a person ahead.": "Hay una persona adelante.",
                "there is a staircase ahead.": "Hay una escalera adelante.",
                "stairs": "escalera",
                "staircase": "escalera",
                "there is a": "Hay un",
                "feet ahead.": "pies adelante.",
                "ahead": "adelante",
                "to the left": "a la izquierda",
                "to the right": "a la derecha",
                "this appears to be a": "Parece ser un"
            ]
            if let mapped = dict[key] { return mapped }
            if key.hasPrefix("there is a ") && key.hasSuffix(" feet ahead.") {
                let body = String(key.dropFirst("there is a ".count).dropLast(" feet ahead.".count))
                return "Hay un \(body) pies adelante."
            }
            if key.hasPrefix("there is a ") && (key.hasSuffix(" ahead.") || key.contains(" to the ")) {
                let body = String(key.dropFirst("there is a ".count))
                return "Hay un \(body)"
                    .replacingOccurrences(of: "to the left", with: "a la izquierda")
                    .replacingOccurrences(of: "to the right", with: "a la derecha")
                    .replacingOccurrences(of: "ahead", with: "adelante")
                
            }
            return text
        } else if languageCode.hasPrefix("fr") {
            let dict: [String: String] = [
                "stop. obstacle within one foot.": "Arrêtez-vous. Obstacle à moins de trente centimètres.",
                "wall ahead. turn around or go back.": "Mur devant. Faites demi-tour ou revenez.",
                "wall ahead. stop.": "Mur devant. Arrêtez-vous.",
                "obstacle ahead. turn left.": "Obstacle devant. Tournez à gauche.",
                "obstacle ahead. turn right.": "Obstacle devant. Tournez à droite.",
                "obstacle ahead. slow down.": "Obstacle devant. Ralentissez.",
                "path is clear.": "La voie est libre.",
                "there is a person ahead.": "Il y a une personne devant.",
                "there is a staircase ahead.": "Il y a un escalier devant.",
                "stairs": "escalier",
                "staircase": "escalier",
                "there is a": "Il y a un",
                "feet ahead.": "pieds devant.",
                "ahead": "devant",
                "to the left": "à gauche",
                "to the right": "à droite",
                "this appears to be a": "Cela semble être un"
            ]
            if let mapped = dict[key] { return mapped }
            if key.hasPrefix("there is a ") && key.hasSuffix(" feet ahead.") {
                let body = String(key.dropFirst("there is a ".count).dropLast(" feet ahead.".count))
                return "Il y a un \(body) pieds devant."
            }
            if key.hasPrefix("there is a ") && (key.hasSuffix(" ahead.") || key.contains(" to the ")) {
                let body = String(key.dropFirst("there is a ".count))
                return "Il y a un \(body)"
                    .replacingOccurrences(of: "to the left", with: "à gauche")
                    .replacingOccurrences(of: "to the right", with: "à droite")
                    .replacingOccurrences(of: "ahead", with: "devant")
                
            }
            return text
        } else if languageCode.hasPrefix("hi") {
            let dict: [String: String] = [
                "stop. obstacle within one foot.": "रुकिए। एक फुट के अंदर बाधा है।",
                "wall ahead. turn around or go back.": "दीवार आगे है। वापस मुड़ें या लौट जाएं।",
                "wall ahead. stop.": "दीवार आगे है। रुकिए।",
                "obstacle ahead. turn left.": "आगे बाधा है। बाएं मुड़ें।",
                "obstacle ahead. turn right.": "आगे बाधा है। दाएं मुड़ें।",
                "obstacle ahead. slow down.": "आगे बाधा है। धीरे चलें।",
                "path is clear.": "रास्ता साफ है।",
                "there is a person ahead.": "आगे एक व्यक्ति है।",
                "there is a staircase ahead.": "आगे सीढ़ियाँ हैं।",
                "stairs": "सीढ़ियाँ",
                "staircase": "सीढ़ियाँ",
                "there is a": "यह है",
                "feet ahead.": "फुट आगे।",
                "ahead": "आगे",
                "to the left": "बाएं",
                "to the right": "दाएं",
                "this appears to be a": "यह एक ... प्रतीत होता है"
            ]
            if let mapped = dict[key] { return mapped }
            if key.hasPrefix("there is a ") && key.hasSuffix(" feet ahead.") {
                let body = String(key.dropFirst("there is a ".count).dropLast(" feet ahead.".count))
                return "यह \(body) फुट आगे।"
            }
            if key.hasPrefix("there is a ") && (key.hasSuffix(" ahead.") || key.contains(" to the ")) {
                let body = String(key.dropFirst("there is a ".count))
                return "यह \(body)"
                    .replacingOccurrences(of: "to the left", with: "बाएं")
                    .replacingOccurrences(of: "to the right", with: "दाएं")
                    .replacingOccurrences(of: "ahead", with: "आगे")
            }
            return text
        } else {
            return text // English or other
        }
    }

    private func translateAndSpeak(_ text: String) {
        let target = currentLanguageCode
        let translated = inlineTranslate(text, to: target)
        lastPhrase = text
        lastTranslatedPhrase = translated

        startSpeaking(translated, languageCode: target)
    }

    private func startSpeaking(_ text: String, languageCode: String) {
        let utterance = AVSpeechUtterance(string: text)

        // Prefer a voice that matches the selected language
        if let voice = AVSpeechSynthesisVoice(language: languageCode) {
            utterance.voice = voice
        } else {
            // Fallback: try any voice whose language has same primary code
            let primary = languageCode.split(separator: "-").first.map(String.init) ?? "en"
            if let any = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix(primary) }) {
                utterance.voice = any
            } else {
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            }
        }

        // Keep your pacing tone
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.8
        utterance.pitchMultiplier = 0.95
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.0
        utterance.postUtteranceDelay = 0.0

        isSpeaking = true
        synth.speak(utterance)
    }

    func stopSpeaking() {
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
        pendingPhrase = nil
        pendingTimestamp = nil
        lastFinishTime = Date()
    }

    // AVSpeechSynthesizerDelegate
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
        lastFinishTime = Date()
        scheduleNextIfNeeded()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
        lastFinishTime = Date()
        scheduleNextIfNeeded()
    }

    private func scheduleNextIfNeeded() {
        guard let next = pendingPhrase, let timestamp = pendingTimestamp else { return }
        let capturedTimestamp = timestamp

        DispatchQueue.main.asyncAfter(deadline: .now() + cooldownAfterFinish) { [weak self] in
            guard let self else { return }
            if self.isSpeaking { return }
            guard self.pendingPhrase == next, self.pendingTimestamp == capturedTimestamp else { return }
            if Date().timeIntervalSince(capturedTimestamp) > self.maxPendingAge {
                self.pendingPhrase = nil
                self.pendingTimestamp = nil
                self.lastFinishTime = Date()
                return
            }
            self.pendingPhrase = nil
            self.pendingTimestamp = nil
            self.translateAndSpeak(next)
        }
    }
}

// MARK: - Scene Describer: bias to "what's happening"
final class SceneDescriber {
    private var lastLabels: [String] = []
    private let minLabelConfidence: Float = 0.55
    private let maxLabels = 3

    func makeSummary(labels: [VNClassificationObservation],
                     peopleCount: Int,
                     facesCount: Int,
                     rectsCount: Int,
                     text: String?) -> String {

        let filtered = labels.filter { $0.confidence >= minLabelConfidence }
            .sorted(by: { $0.confidence > $1.confidence })
        let top = filtered.prefix(maxLabels).map { $0.identifier }

        let stableLabels = top.isEmpty ? lastLabels : top
        lastLabels = stableLabels

        var clauses: [String] = []

        if peopleCount > 0 || facesCount > 0 {
            if peopleCount > 1 {
                clauses.append("there are several people in the room")
            } else if peopleCount == 1 {
                clauses.append("there is one person in the room")
            } else if facesCount > 0 {
                clauses.append(facesCount > 1 ? "multiple faces are visible" : "a face is visible")
            }
        }

        if rectsCount > 0 {
            clauses.append(rectsCount > 1 ? "signs or rectangular objects are present" : "a sign or rectangular object is present")
        }

        if let t = text, !t.isEmpty {
            clauses.append("I can read “\(t)”")
        }

        if !stableLabels.isEmpty {
            let activityPhrase = self.activityPhrase(from: stableLabels)
            // If any label is stairs or staircase, add a clause for it separately
            var stairsClauseAdded = false
            for label in stableLabels {
                let lower = label.lowercased()
                if lower == "stairs" || lower == "staircase" {
                    clauses.append("there is a staircase ahead")
                    stairsClauseAdded = true
                    break
                }
            }
            if stairsClauseAdded {
                // Remove stairs/staircase related phrase from activityPhrase if present,
                // as we've added a specific clause.
                // Or just do not insert activityPhrase if it is only stairs.
                // But since activityPhrase may contain other things, just insert it.
                // To avoid duplication, let's insert activityPhrase excluding stairs.
                // So we filter out stairs/staircase from activity phrase components:
                let filteredLabels = stableLabels.filter {
                    let l = $0.lowercased()
                    return l != "stairs" && l != "staircase"
                }
                if !filteredLabels.isEmpty {
                    let filteredActivityPhrase = self.activityPhrase(from: filteredLabels)
                    if !filteredActivityPhrase.isEmpty {
                        clauses.insert(filteredActivityPhrase, at: 0)
                    }
                }
            } else {
                clauses.insert(activityPhrase, at: 0)
            }
        }

        if clauses.isEmpty {
            return "I’m looking around the room."
        }
        return joinClauses(clauses)
    }

    private func activityPhrase(from labels: [String]) -> String {
        let mapped = labels.map { mapToActivity($0) }.filter { !$0.isEmpty }
        if mapped.isEmpty { return "this appears to be an indoor scene" }
        switch mapped.count {
        case 1: return mapped[0]
        case 2: return mapped[0] + " and " + mapped[1]
        default: return mapped[0] + ", " + mapped[1] + ", and " + mapped[2]
        }
    }

    private func mapToActivity(_ label: String) -> String {
        let l = label.lowercased()
        switch l {
        case "living room": return "this appears to be a living room"
        case "kitchen": return "this appears to be a kitchen"
        case "bedroom": return "this appears to be a bedroom"
        case "office": return "this appears to be an office"
        case "classroom": return "this appears to be a classroom"
        case "library": return "this appears to be a library"
        case "restaurant": return "this appears to be a restaurant"
        case "store", "supermarket": return "this appears to be a store"
        case "gymnasium": return "this appears to be a gym"
        case "workshop", "wood shop", "carpentry shop": return "this appears to be a workshop"
        case "corridor", "hallway": return "this appears to be a hallway"
        case "stairs", "staircase": return "this appears to be a staircase"
        default: return ""
        }
    }

    private func joinClauses(_ clauses: [String]) -> String {
        if clauses.count == 1 { return clauses[0] + "." }
        if clauses.count == 2 { return clauses[0].capitalized + " and " + clauses[1] + "." }
        let body = clauses.dropLast().joined(separator: ", ")
        return body.capitalized + ", and " + (clauses.last ?? "") + "."
    }
}

// MARK: - Camera + Vision + Haptics + YOLO Fusion
struct CameraView: UIViewControllerRepresentable {
    @Binding var controllerRef: CameraControllerRef

    func makeCoordinator() -> Coordinator {
        Coordinator(controllerRef: controllerRef)
    }

    func makeUIViewController(context: Context) -> CameraVC {
        let vc = CameraVC()
        context.coordinator.attach(vc)
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraVC, context: Context) { }

    final class Coordinator {
        private let controllerRef: CameraControllerRef
        init(controllerRef: CameraControllerRef) {
            self.controllerRef = controllerRef
        }
        func attach(_ vc: CameraVC) {
            controllerRef.controller = vc
        }
    }
}

final class CameraVC: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate, VisionFusionPipelineDelegate {

    // Capture
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    private var isStopping = false

    // Dedicated capture callback queue (never block this)
    private let captureQueue = DispatchQueue(label: "camera.capture.queue", qos: .userInitiated)

    // Vision fusion
    private let fusion = VisionFusionPipeline()

    // Overlay
    private let overlayView = BoundingBoxOverlayView()

    // Proximity sensor
    private var proximityObserver: NSObjectProtocol?
    private var proximityNear = false

    // Haptics
    private var hapticEngine: CHHapticEngine?
    private var supportsHaptics = false
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    private var lastContinuousIntensity: Float = -1
    private var lastPulseTime = Date.distantPast
    private var lastTickTime = Date.distantPast

    private let messageLabel: UILabel = {
        let l = UILabel()
        l.text = "Requesting camera permission…"
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGray6
        view.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20)
        ])

        // Overlay setup
        overlayView.frame = view.bounds
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayView.isUserInteractionEnabled = false
        view.addSubview(overlayView)

        fusion.delegate = self

        setupHaptics()
        setupProximityMonitoring(true)
        // Warm up ML/Vision to avoid first-frame stalls
        fusion.warmUp()
        requestAndStart()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        if let preview = previewLayer {
            if preview.superlayer !== view.layer {
                view.layer.insertSublayer(preview, below: overlayView.layer)
            }
            overlayView.videoRect = videoRect(for: preview)
        } else {
            overlayView.videoRect = view.bounds
        }
    }

    deinit {
        stop()
        setupProximityMonitoring(false)
        stopContinuous()
        hapticEngine?.stop(completionHandler: nil)
    }

    // MARK: - Public controls
    func start() {
        isStopping = false
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            if !isConfigured {
                setupSessionAndRun()
            } else {
                startSessionIfNeeded()
            }
        case .notDetermined:
            requestAndStart()
        case .denied, .restricted:
            showDeniedMessage()
        @unknown default:
            showUnavailableMessage()
        }
    }

    func stop() {
        isStopping = true
        if session.isRunning {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.session.isRunning {
                    self.session.stopRunning()
                    print("[CameraVC] Session stopped.")
                }
            }
        }
        stopContinuous()
    }

    // MARK: - VisionFusionPipelineDelegate
    func fusionPipeline(_ pipeline: VisionFusionPipeline, didUpdateDetections detections: [DetectedObject]) {
        DispatchQueue.main.async { [weak self] in
            self?.overlayView.show(detections: detections)
        }
    }

    func fusionPipeline(_ pipeline: VisionFusionPipeline, didUpdateHaptics intent: HapticIntent) {
        // Haptics are handled in captureOutput using current intent + proximity
    }

    // MARK: - Proximity
    private func setupProximityMonitoring(_ enable: Bool) {
        let device = UIDevice.current
        device.isProximityMonitoringEnabled = enable
        if enable {
            proximityObserver = NotificationCenter.default.addObserver(forName: UIDevice.proximityStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.proximityNear = device.proximityState
                if self.proximityNear {
                    self.startContinuous(intensity: 0.95)
                } else {
                    self.stopContinuous()
                }
            }
        } else if let obs = proximityObserver {
            NotificationCenter.default.removeObserver(obs)
            proximityObserver = nil
            device.isProximityMonitoringEnabled = false
        }
    }

    // MARK: - Haptics setup
    private func setupHaptics() {
        guard UserDefaults.standard.bool(forKey: "hapticsEnabled") != false else {
            supportsHaptics = false
            return
        }
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        guard supportsHaptics else { return }
        do {
            hapticEngine = try CHHapticEngine()
            try hapticEngine?.start()
        } catch {
            print("[Haptics] Engine error: \(error)")
            supportsHaptics = false
        }
    }

    private func startContinuous(intensity: Float) {
        guard UserDefaults.standard.bool(forKey: "hapticsEnabled") != false else { return }

        guard supportsHaptics else {
            let gen = UIImpactFeedbackGenerator(style: .medium)
            gen.impactOccurred()
            return
        }
        let clamped = max(0.05, min(1.0, intensity))
        if abs(clamped - lastContinuousIntensity) < 0.08, continuousPlayer != nil {
            return
        }
        lastContinuousIntensity = clamped
        do {
            if let player = continuousPlayer {
                try player.stop(atTime: 0)
                continuousPlayer = nil
            }
            let intensityParam = CHHapticEventParameter(parameterID: .hapticIntensity, value: clamped)
            let sharpParam = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25)
            let event = CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [intensityParam, sharpParam],
                                      relativeTime: 0,
                                      duration: 1.0)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            continuousPlayer = try hapticEngine?.makeAdvancedPlayer(with: pattern)
            continuousPlayer?.loopEnabled = true
            try hapticEngine?.start()
            try continuousPlayer?.start(atTime: 0)
        } catch {
            print("[Haptics] Continuous start error: \(error)")
        }
    }

    private func stopContinuous() {
        lastContinuousIntensity = -1
        guard supportsHaptics, let player = continuousPlayer else { return }
        do {
            try player.stop(atTime: 0)
            continuousPlayer = nil
        } catch {
            print("[Haptics] Continuous stop error: \(error)")
        }
    }

    private func pulseHard() {
        guard UserDefaults.standard.bool(forKey: "hapticsEnabled") != false else { return }

        let now = Date()
        guard now.timeIntervalSince(lastPulseTime) > 0.25 else { return }
        lastPulseTime = now

        guard supportsHaptics else {
            let gen = UIImpactFeedbackGenerator(style: .heavy)
            gen.impactOccurred(intensity: 1.0)
            return
        }
        do {
            let sharp = CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
            let strong = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [sharp, strong], relativeTime: 0)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try hapticEngine?.makePlayer(with: pattern)
            try hapticEngine?.start()
            try player?.start(atTime: 0)
        } catch {
            print("[Haptics] Pulse error: \(error)")
        }
    }

    private func tickSoft() {
        guard UserDefaults.standard.bool(forKey: "hapticsEnabled") != false else { return }

        let now = Date()
        guard now.timeIntervalSince(lastTickTime) > 0.35 else { return }
        lastTickTime = now

        guard supportsHaptics else {
            let gen = UIImpactFeedbackGenerator(style: .light)
            gen.impactOccurred()
            return
        }
        do {
            let sharp = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)
            let weak = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.3)
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [sharp, weak], relativeTime: 0)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try hapticEngine?.makePlayer(with: pattern)
            try hapticEngine?.start()
            try player?.start(atTime: 0)
        } catch {
            print("[Haptics] Tick error: \(error)")
        }
    }

    // MARK: - UI messages
    private func showDeniedMessage() {
        messageLabel.text = "Camera access denied. Enable it in Settings → Privacy → Camera."
        messageLabel.isHidden = false
    }

    private func showUnavailableMessage() {
        messageLabel.text = "Camera not available."
        messageLabel.isHidden = false
    }

    // MARK: - Permissions and session
    private func requestAndStart() {
        #if targetEnvironment(simulator)
        messageLabel.text = "Camera not available in the simulator. Please run on a real device."
        print("[CameraVC] Running in Simulator: no camera available.")
        #else
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            setupSessionAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.setupSessionAndRun()
                    } else {
                        self.showDeniedMessage()
                        print("[CameraVC] Camera access denied by user.")
                    }
                }
            }
        case .denied, .restricted:
            showDeniedMessage()
            print("[CameraVC] Authorization status: \(status).")
        @unknown default:
            showUnavailableMessage()
            print("[CameraVC] Unknown auth status.")
        }
        #endif
    }

    private func setupSessionAndRun() {
        guard !isConfigured else {
            startSessionIfNeeded()
            return
        }

        messageLabel.text = "Starting camera…"
        messageLabel.isHidden = false

        let session = self.session
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            session.commitConfiguration()
            showUnavailableMessage()
            print("[CameraVC] No camera device.")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                messageLabel.text = "Cannot add camera input."
                print("[CameraVC] Cannot add input.")
                return
            }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            messageLabel.text = "Failed to open camera: \(error.localizedDescription)"
            print("[CameraVC] Device input error: \(error)")
            return
        }

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            messageLabel.text = "Cannot add video output."
            print("[CameraVC] Cannot add output.")
            return
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(0) {
                    connection.videoRotationAngle = 0
                }
            } else {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }
        }

        session.commitConfiguration()
        isConfigured = true

        if previewLayer == nil {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.insertSublayer(layer, below: overlayView.layer)
            previewLayer = layer
        } else {
            previewLayer?.session = session
        }
        previewLayer?.frame = view.bounds

        if let preview = previewLayer {
            overlayView.videoRect = videoRect(for: preview)
        } else {
            overlayView.videoRect = view.bounds
        }

        startSessionIfNeeded()
    }

    private func startSessionIfNeeded() {
        guard isConfigured else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.session.isRunning, !self.isStopping else { return }
            self.session.startRunning()
            self.messageLabel.isHidden = true
            print("[CameraVC] Session started.")
        }
    }

    // MARK: - Vision + YOLO fusion
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Immediately hand off; do not block captureQueue.
        fusion.enqueue(frame: buffer, orientation: .up)

        // Drive haptics from fusion.hapticIntent plus proximity sensor
        switch fusion.hapticIntent {
        case .none:
            if !proximityNear { stopContinuous() }
        case .close(let intensity):
            startContinuous(intensity: max(intensity, proximityNear ? 0.95 : intensity))
        case .approaching:
            pulseHard()
        case .receding:
            tickSoft()
        }
    }

    // MARK: - Compute displayed video rect for aspect-fill mapping
    private func videoRect(for layer: AVCaptureVideoPreviewLayer) -> CGRect {
        guard let connection = layer.connection,
              let inputPort = connection.inputPorts.first,
              let formatDescription = inputPort.formatDescription else {
            return layer.bounds
        }

        let cleanAperture = CMVideoFormatDescriptionGetCleanAperture(formatDescription, originIsAtTopLeft: false)
        let videoSize = cleanAperture.size
        let viewSize = layer.bounds.size

        guard videoSize.width > 0, videoSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return layer.bounds
        }

        let videoAspect = videoSize.width / videoSize.height
        let viewAspect = viewSize.width / viewSize.height

        var size = CGSize.zero

        if videoAspect > viewAspect {
            let scale = viewSize.height / videoSize.height
            size = CGSize(width: videoSize.width * scale, height: viewSize.height)
        } else {
            let scale = viewSize.width / videoSize.width
            size = CGSize(width: viewSize.width, height: videoSize.height * scale)
        }

        let origin = CGPoint(x: (viewSize.width - size.width) * 0.5,
                             y: (viewSize.height - size.height) * 0.5)
        return CGRect(origin: origin, size: size)
    }
}

// MARK: - Helpers
private extension CGRect {
    var area: CGFloat { width * height }
}

// Small helper to read speaking state safely from CameraVC
private extension Narrator {
    static var sharedIsSpeaking: Bool { shared._isSpeaking() }
    func _isSpeaking() -> Bool { synth.isSpeaking || isSpeaking }
}

