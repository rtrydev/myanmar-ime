import SwiftUI
import BurmeseIMECore

/// Settings and onboarding UI for the Burmese IME.
/// This app is not the typing surface — the IME lives at
/// ~/Library/Input Methods/BurmeseIME.app. This window explains how to
/// enable it, exposes preferences, and surfaces diagnostics.
struct ContentView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderView()
                Divider()
                InstallationGuideView()
                Divider()
                PreferencesView()
            }
            .padding(24)
        }
        .frame(minWidth: 520, minHeight: 520)
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
            Text("Getting started")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                step(1, "Open System Settings → Keyboard → Text Input → Edit.")
                step(2, "Click + and search for Burmese, then add it.")
                step(3, "Switch modes using the input menu in the menu bar:")
                HStack(spacing: 16) {
                    badge("က", label: "Compose")
                    badge("ABC", label: "Roman passthrough")
                }
                .padding(.leading, 20)
                step(4, "Open these preferences any time from the input menu → Preferences…, or Cmd+, while this window is active.")
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
    @StateObject private var vm = IMESettingsViewModel()
    @State private var showingResetConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preferences")
                .font(.headline)
            Form {
                inputBehaviorSection
                candidateRankingSection
                textOutputSection
                learningSection
                historySection
                diagnosticsSection
            }
            .formStyle(.grouped)
        }
        .onAppear { vm.refreshHistory() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            vm.refreshHistory()
        }
    }

    private var inputBehaviorSection: some View {
        Section("Input behavior") {
            Picker("Candidate panel size", selection: vm.candidatePageSizeBinding) {
                ForEach([3, 5, 9, 12], id: \.self) { Text("\($0)").tag($0) }
            }
            Toggle("Commit on space", isOn: vm.commitOnSpaceBinding)
            Toggle("Enable cluster-sound shortcuts (j, ch, gy, sh, …)",
                   isOn: vm.clusterAliasesEnabledBinding)
            restoreButton(.inputBehavior)
        }
    }

    private var candidateRankingSection: some View {
        Section("Candidate ranking") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("LM prune margin")
                    Spacer()
                    Text(String(format: "%.1f", vm.lmPruneMargin))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: vm.lmPruneMarginBinding, in: 0.0...16.0, step: 0.5)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Anchor commit threshold")
                    Spacer()
                    Text("\(vm.anchorCommitThreshold)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: vm.anchorCommitThresholdBinding, in: 4.0...16.0, step: 1.0)
            }
            restoreButton(.candidateRanking)
        }
    }

    private var textOutputSection: some View {
        Section("Text output") {
            Toggle("Burmese punctuation auto-mapping",
                   isOn: vm.burmesePunctuationEnabledBinding)
                .help("Replaces trailing ASCII . , ! ? ; with Myanmar ။ ၊ after Burmese text.")
            Toggle("Suggest measure words after numbers",
                   isOn: vm.numberMeasureWordsEnabledBinding)
                .help("Adds candidates like ၂၀၂၄ ခုနှစ် or ၁၀၀၀ ကျပ် beside plain digit output.")
            Text("Committed text is ZWSP-free.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var learningSection: some View {
        Section("Learning") {
            Toggle("Enable learning (remember selected candidates)",
                   isOn: vm.learningEnabledBinding)
            Button("Reset learned history…", role: .destructive) {
                showingResetConfirm = true
            }
            .buttonStyle(.borderless)
            .confirmationDialog(
                "Reset learned history?",
                isPresented: $showingResetConfirm
            ) {
                Button("Reset", role: .destructive) { vm.resetLearnedHistory() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears all remembered candidate selections. This cannot be undone.")
            }
        }
    }

    private var historySection: some View {
        Section("Typing history") {
            Text("Remove individual entries the IME has learned. Removing one stops it from being ranked above other candidates for that input.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if vm.historyEntries.isEmpty {
                Text("No learned entries yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.historyEntries, id: \.self) { entry in
                            HistoryRow(entry: entry) {
                                vm.removeHistoryEntry(reading: entry.reading, surface: entry.surface)
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            DiagnosticsView()
        }
    }

    private func restoreButton(_ section: IMESettings.Section) -> some View {
        Button("Restore defaults") { vm.restoreDefaults(section) }
            .buttonStyle(.borderless)
            .font(.callout)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.surface)
                    .font(.body)
                Text(entry.reading)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            Spacer()
            Text("×\(entry.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove this entry from learned history")
        }
        .padding(.vertical, 4)
    }
}

private struct DiagnosticsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            resourceRow(label: "Lexicon", name: "BurmeseLexicon", ext: "sqlite")
            resourceRow(label: "Language model", name: "BurmeseLM", ext: "bin")
            HStack {
                Text("Version")
                Spacer()
                Text(version)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("Open logs") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
    }

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    @ViewBuilder
    private func resourceRow(label: String, name: String, ext: String) -> some View {
        let url = IMEResources.locate(name: name, ext: ext, bundles: searchBundles)
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            if let url {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .monospaced()
                    if let size = fileSize(url) {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("not found")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    // The Preferences app doesn't ship the lexicon / LM itself — those
    // resources live in the IME bundle. Locate it via LaunchServices so
    // the diagnostic rows show real paths and sizes from the installed
    // ~/Library/Input Methods/BurmeseIME.app.
    private var searchBundles: [Bundle] {
        var bundles: [Bundle] = [.main]
        if let imeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.myangler.inputmethod.burmese"),
           let imeBundle = Bundle(url: imeURL) {
            bundles.append(imeBundle)
        }
        return bundles
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
    }
}

#Preview {
    ContentView()
}
