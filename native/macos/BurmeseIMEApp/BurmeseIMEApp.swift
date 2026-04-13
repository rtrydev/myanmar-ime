import SwiftUI
import Carbon
import InputMethodKit

private enum RegistrationHelper {
    private static let registerArgument = "--register-input-source"
    private static let bundleIdentifierArgument = "--bundle-identifier"

    static func runIfRequested(arguments: [String]) -> Bool {
        guard let registerIndex = arguments.firstIndex(of: registerArgument),
              arguments.indices.contains(registerIndex + 1)
        else {
            return false
        }

        let bundlePath = arguments[registerIndex + 1]
        let bundleIdentifier = bundleIdentifier(from: arguments)
        run(bundleURL: URL(fileURLWithPath: bundlePath), bundleIdentifier: bundleIdentifier)
        return true
    }

    private static func bundleIdentifier(from arguments: [String]) -> String? {
        guard let identifierIndex = arguments.firstIndex(of: bundleIdentifierArgument),
              arguments.indices.contains(identifierIndex + 1)
        else {
            return nil
        }

        return arguments[identifierIndex + 1]
    }

    private static func run(bundleURL: URL, bundleIdentifier: String?) {
        let launchServicesStatus = LSRegisterURL(bundleURL as CFURL, true)
        if launchServicesStatus != noErr {
            NSLog(
                "Burmese IME helper LaunchServices registration failed for %@ with status %d",
                bundleURL.path,
                launchServicesStatus
            )
        }

        let registrationStatus = TISRegisterInputSource(bundleURL as CFURL)
        if registrationStatus != noErr {
            NSLog(
                "Burmese IME helper TIS registration failed for %@ with status %d",
                bundleURL.path,
                registrationStatus
            )
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 5))

        if let bundleIdentifier {
            let count = registeredInputSourceCount(for: bundleIdentifier)
            NSLog("Burmese IME helper sees %d registered sources for %@", count, bundleIdentifier)
        }
    }

    private static func registeredInputSourceCount(for bundleIdentifier: String) -> Int {
        let properties = [kTISPropertyBundleID as String: bundleIdentifier] as CFDictionary
        let inputSources = TISCreateInputSourceList(properties, true)?.takeRetainedValue() as? [TISInputSource]
        return inputSources?.count ?? 0
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?
    private var registrationHelperProcess: Process?
    private var wasExplicitlyOpened = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Intercept the "open application" Apple Event. macOS sends this ONLY when the
        // user explicitly opens the app (Finder, Launchpad, Spotlight). It is NOT sent
        // when macOS silently launches the process as an IME server in response to an
        // input source selection — letting us suppress the window in that case.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenApplicationEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenApplication)
        )
    }

    @objc private func handleOpenApplicationEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent: NSAppleEventDescriptor
    ) {
        wasExplicitlyOpened = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startInputMethodServer()
        registerInstalledInputMethodBundle()

        // Defer the window-visibility decision until after the run loop has processed
        // any pending Apple Events (including kAEOpenApplication). If the app was
        // launched as a background IME server rather than by the user, hide the window.
        DispatchQueue.main.async { [weak self] in
            guard self?.wasExplicitlyOpened == false else { return }
            NSApp.windows.forEach { $0.orderOut(nil) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // User activated the running app (e.g. double-clicked in Finder) — show the window.
            NSApp.windows.forEach { $0.makeKeyAndOrderFront(self) }
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    private func startInputMethodServer() {
        guard let info = Bundle.main.infoDictionary,
              let connectionName = info["InputMethodConnectionName"] as? String,
              let bundleIdentifier = Bundle.main.bundleIdentifier
        else {
            NSLog("Burmese IME server configuration is missing from the app bundle")
            return
        }

        server = IMKServer(name: connectionName, bundleIdentifier: bundleIdentifier)
        guard server != nil else {
            NSLog("Burmese IME failed to create IMKServer for %@", connectionName)
            return
        }

        sharedCandidatesPanel = IMKCandidates(
            server: server!,
            panelType: kIMKSingleRowSteppingCandidatePanel
        )
    }

    private func registerInstalledInputMethodBundle() {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let installDirectory = bundleURL.deletingLastPathComponent().path
        let userInstallDirectory = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Input Methods")
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            NSLog("Burmese IME is missing a bundle identifier")
            return
        }

        guard installDirectory == userInstallDirectory || installDirectory == "/Library/Input Methods" else {
            return
        }

        registerWithLaunchServices(bundleURL)
        attemptTISRegistration(for: bundleURL, bundleIdentifier: bundleIdentifier, remainingAttempts: 5)
        launchRegistrationHelperIfNeeded(bundleURL: bundleURL, bundleIdentifier: bundleIdentifier)
    }

    private func registerWithLaunchServices(_ url: URL) {
        let status = LSRegisterURL(url as CFURL, true)
        guard status != noErr else { return }
        NSLog("LaunchServices registration failed for %@ with status %d", url.path, status)
    }

    private func attemptTISRegistration(for url: URL, bundleIdentifier: String, remainingAttempts: Int) {
        let status = TISRegisterInputSource(url as CFURL)
        guard status == noErr else {
            NSLog("Burmese IME registration failed for %@ with status %d", url.path, status)
            return
        }

        guard registeredInputSourceCount(for: bundleIdentifier) == 0, remainingAttempts > 1 else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.attemptTISRegistration(
                for: url,
                bundleIdentifier: bundleIdentifier,
                remainingAttempts: remainingAttempts - 1
            )
        }
    }

    private func registeredInputSourceCount(for bundleIdentifier: String) -> Int {
        let properties = [kTISPropertyBundleID as String: bundleIdentifier] as CFDictionary
        let inputSources = TISCreateInputSourceList(properties, true)?.takeRetainedValue() as? [TISInputSource]
        return inputSources?.count ?? 0
    }

    private func launchRegistrationHelperIfNeeded(bundleURL: URL, bundleIdentifier: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            guard self.registrationHelperProcess?.isRunning != true else { return }
            guard let executableURL = Bundle.main.executableURL else {
                NSLog("Burmese IME helper registration launch failed: missing executable URL")
                return
            }

            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = [
                "--register-input-source",
                bundleURL.path,
                "--bundle-identifier",
                bundleIdentifier,
            ]
            process.standardError = outputPipe
            process.standardOutput = outputPipe
            process.terminationHandler = { [weak self] helper in
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                    NSLog("Burmese IME helper output: %@", output.trimmingCharacters(in: .whitespacesAndNewlines))
                }

                if helper.terminationStatus != 0 {
                    NSLog("Burmese IME helper exited with status %d", helper.terminationStatus)
                }

                self?.registrationHelperProcess = nil
            }

            do {
                self.registrationHelperProcess = process
                NSLog("Burmese IME launching helper via %@", executableURL.path)
                try process.run()
            } catch {
                self.registrationHelperProcess = nil
                NSLog("Burmese IME helper registration launch failed: %@", error.localizedDescription)
            }
        }
    }
}

struct BurmeseIMEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 360)
    }
}

@main
enum BurmeseIMEEntryPoint {
    static func main() {
        guard !RegistrationHelper.runIfRequested(arguments: CommandLine.arguments) else {
            return
        }

        BurmeseIMEApp.main()
    }
}
