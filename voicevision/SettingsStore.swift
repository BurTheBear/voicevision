import SwiftUI
import Combine

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark:  return "Dark"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {

    // We wrap @AppStorage in computed properties to ensure ObservableObject updates fire reliably.
    @AppStorage("appAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage("hapticsEnabled") private var hapticsEnabledRaw: Bool = true
    @AppStorage("guidanceOnlyMode") private var guidanceOnlyModeRaw: Bool = false

    // New settings
    @AppStorage("speakLanguageCode") private var speakLanguageCodeRaw: String = "en-US"
    @AppStorage("showSubtitles") private var showSubtitlesRaw: Bool = true

    // Exposed properties with manual objectWillChange triggering
    var appAppearance: AppAppearance {
        get { AppAppearance(rawValue: appAppearanceRaw) ?? .system }
        set {
            if newValue.rawValue != appAppearanceRaw {
                objectWillChange.send()
                appAppearanceRaw = newValue.rawValue
            }
        }
    }

    var hapticsEnabled: Bool {
        get { hapticsEnabledRaw }
        set {
            if newValue != hapticsEnabledRaw {
                objectWillChange.send()
                hapticsEnabledRaw = newValue
            }
        }
    }

    var guidanceOnlyMode: Bool {
        get { guidanceOnlyModeRaw }
        set {
            if newValue != guidanceOnlyModeRaw {
                objectWillChange.send()
                guidanceOnlyModeRaw = newValue
            }
        }
    }

    // Language to speak/subtitle in (BCP-47)
    var speakLanguageCode: String {
        get { speakLanguageCodeRaw }
        set {
            if newValue != speakLanguageCodeRaw {
                objectWillChange.send()
                speakLanguageCodeRaw = newValue
            }
        }
    }

    // Subtitle visibility
    var showSubtitles: Bool {
        get { showSubtitlesRaw }
        set {
            if newValue != showSubtitlesRaw {
                objectWillChange.send()
                showSubtitlesRaw = newValue
            }
        }
    }
}

extension View {
    @ViewBuilder
    func applyAppearanceOverride(_ appearance: AppAppearance) -> some View {
        switch appearance {
        case .system:
            self
        case .light:
            self.preferredColorScheme(.light)
        case .dark:
            self.preferredColorScheme(.dark)
        }
    }
}

