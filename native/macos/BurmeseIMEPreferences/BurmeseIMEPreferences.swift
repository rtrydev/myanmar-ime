import SwiftUI
import AppKit

@main
struct BurmeseIMEPreferencesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
