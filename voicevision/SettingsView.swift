import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    private struct LanguageOption: Identifiable, Hashable {
        let id: String
        let title: String
    }

    private let languageOptions: [LanguageOption] = [
        .init(id: "en-US", title: "English"),
        .init(id: "es-ES", title: "Spanish"),
        .init(id: "fr-FR", title: "French"),
        .init(id: "hi-IN", title: "Hindi")
    ]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Appearance")) {
                    Picker("App Appearance", selection: Binding(
                        get: { settings.appAppearance },
                        set: { settings.appAppearance = $0 }
                    )) {
                        ForEach(AppAppearance.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }

                Section(header: Text("Language")) {
                    Picker("Speak & Subtitles", selection: Binding(
                        get: { settings.speakLanguageCode },
                        set: { settings.speakLanguageCode = $0 }
                    )) {
                        ForEach(languageOptions) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    Toggle("Show Subtitles", isOn: Binding(
                        get: { settings.showSubtitles },
                        set: { settings.showSubtitles = $0 }
                    ))
                }

                Section(header: Text("Haptics")) {
                    Toggle("Enable Haptics", isOn: Binding(
                        get: { settings.hapticsEnabled },
                        set: { settings.hapticsEnabled = $0 }
                    ))
                }

                Section(header: Text("Guidance")) {
                    Toggle("Guidance-Only Mode", isOn: Binding(
                        get: { settings.guidanceOnlyMode },
                        set: { settings.guidanceOnlyMode = $0 }
                    ))
                    Text("When enabled, narration is limited to navigation guidance: “Path is clear”, “Stop”, “Turn left/right”, or “Turn around or go back”.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

