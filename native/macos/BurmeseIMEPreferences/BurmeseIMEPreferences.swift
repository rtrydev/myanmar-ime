import SwiftUI

@main
struct BurmeseIMEPreferencesApp: App {
    var body: some Scene {
        WindowGroup("Burmese IME") {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 640)

        Settings {
            PreferencesSettingsScene()
        }
    }
}

/// Host for the Settings scene (Cmd+,). Reuses the same PreferencesView that the
/// main WindowGroup embeds, but without the Header / Installation banner.
private struct PreferencesSettingsScene: View {
    var body: some View {
        ContentView()
            .frame(minWidth: 520, minHeight: 520)
    }
}
