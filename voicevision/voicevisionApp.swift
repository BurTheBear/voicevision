import SwiftUI

@main
struct YourAppNameApp: App {
    @StateObject private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .applyAppearanceOverride(settings.appAppearance)
        }
    }
}
