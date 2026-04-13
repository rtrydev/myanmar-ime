import SwiftUI

/// Settings and onboarding UI for the Burmese IME container app.
/// This app is not the typing surface — it explains installation,
/// shows extension status, and exposes preference controls.
struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HeaderView()
            Divider()
            InstallationGuideView()
            Divider()
            PreferencesView()
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 440, minHeight: 320)
    }
}

private struct HeaderView: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("က")
                .font(.system(size: 40))
            VStack(alignment: .leading, spacing: 2) {
                Text("Burmese IME")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Hybrid Burmese romanization for macOS")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct InstallationGuideView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Installation")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                step(1, "Install this app in ~/Library/Input Methods, then launch it once to register the embedded input method extension.")
                step(2, "Open System Settings → Keyboard → Text Input → Edit.")
                step(3, "Click + and search for Burmese, then add it.")
                step(4, "Switch modes using the input menu in the menu bar:")
                HStack(spacing: 16) {
                    badge("က", label: "Compose")
                    badge("ABC", label: "Roman passthrough")
                }
                .padding(.leading, 20)
            }
            .font(.callout)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(n).")
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .leading)
            Text(text)
        }
    }

    private func badge(_ label: String, label desc: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(desc)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }
}

private struct PreferencesView: View {
    @AppStorage("learningEnabled") private var learningEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preferences")
                .font(.headline)
            Toggle("Enable learning (remember selected candidates)", isOn: $learningEnabled)
                .font(.callout)
            Button("Reset learned history…") {
                // TODO: clear UserHistory.sqlite via shared app group
            }
            .font(.callout)
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }
    }
}

#Preview {
    ContentView()
}
