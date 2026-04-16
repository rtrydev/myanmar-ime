import Foundation
import SwiftUI
import BurmeseIMECore

/// SwiftUI-facing wrapper around `IMESettings`. Mirrors each value as
/// `@Published` so views re-render on change, and subscribes to the shared
/// notification so edits made inside the IMK extension (or any other process
/// holding the suite) flow back into the container app's UI.
@MainActor
final class IMESettingsViewModel: ObservableObject {
    let settings: IMESettings

    @Published var candidatePageSize: Int
    @Published var commitOnSpace: Bool
    @Published var clusterAliasesEnabled: Bool
    @Published var lmPruneMargin: Double
    @Published var anchorCommitThreshold: Int
    @Published var burmesePunctuationEnabled: Bool
    @Published var numberMeasureWordsEnabled: Bool
    @Published var learningEnabled: Bool

    private var observer: NSObjectProtocol?

    init(settings: IMESettings = IMESettings()) {
        self.settings = settings
        self.candidatePageSize = settings.candidatePageSize
        self.commitOnSpace = settings.commitOnSpace
        self.clusterAliasesEnabled = settings.clusterAliasesEnabled
        self.lmPruneMargin = settings.lmPruneMargin
        self.anchorCommitThreshold = settings.anchorCommitThreshold
        self.burmesePunctuationEnabled = settings.burmesePunctuationEnabled
        self.numberMeasureWordsEnabled = settings.numberMeasureWordsEnabled
        self.learningEnabled = settings.learningEnabled

        self.observer = NotificationCenter.default.addObserver(
            forName: IMESettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func reload() {
        // Re-read everything; guarded by equality checks so we don't
        // trigger redundant SwiftUI renders on unchanged values.
        if candidatePageSize != settings.candidatePageSize {
            candidatePageSize = settings.candidatePageSize
        }
        if commitOnSpace != settings.commitOnSpace {
            commitOnSpace = settings.commitOnSpace
        }
        if clusterAliasesEnabled != settings.clusterAliasesEnabled {
            clusterAliasesEnabled = settings.clusterAliasesEnabled
        }
        if lmPruneMargin != settings.lmPruneMargin {
            lmPruneMargin = settings.lmPruneMargin
        }
        if anchorCommitThreshold != settings.anchorCommitThreshold {
            anchorCommitThreshold = settings.anchorCommitThreshold
        }
        if burmesePunctuationEnabled != settings.burmesePunctuationEnabled {
            burmesePunctuationEnabled = settings.burmesePunctuationEnabled
        }
        if numberMeasureWordsEnabled != settings.numberMeasureWordsEnabled {
            numberMeasureWordsEnabled = settings.numberMeasureWordsEnabled
        }
        if learningEnabled != settings.learningEnabled {
            learningEnabled = settings.learningEnabled
        }
    }

    // MARK: - Bindings (write through to settings on set)

    var candidatePageSizeBinding: Binding<Int> {
        Binding(get: { self.candidatePageSize },
                set: { self.candidatePageSize = $0; self.settings.candidatePageSize = $0 })
    }
    var commitOnSpaceBinding: Binding<Bool> {
        Binding(get: { self.commitOnSpace },
                set: { self.commitOnSpace = $0; self.settings.commitOnSpace = $0 })
    }
    var clusterAliasesEnabledBinding: Binding<Bool> {
        Binding(get: { self.clusterAliasesEnabled },
                set: { self.clusterAliasesEnabled = $0; self.settings.clusterAliasesEnabled = $0 })
    }
    var lmPruneMarginBinding: Binding<Double> {
        Binding(get: { self.lmPruneMargin },
                set: { self.lmPruneMargin = $0; self.settings.lmPruneMargin = $0 })
    }
    var anchorCommitThresholdBinding: Binding<Double> {
        Binding(get: { Double(self.anchorCommitThreshold) },
                set: { let v = Int($0); self.anchorCommitThreshold = v; self.settings.anchorCommitThreshold = v })
    }
    var burmesePunctuationEnabledBinding: Binding<Bool> {
        Binding(get: { self.burmesePunctuationEnabled },
                set: { self.burmesePunctuationEnabled = $0; self.settings.burmesePunctuationEnabled = $0 })
    }
    var numberMeasureWordsEnabledBinding: Binding<Bool> {
        Binding(get: { self.numberMeasureWordsEnabled },
                set: { self.numberMeasureWordsEnabled = $0; self.settings.numberMeasureWordsEnabled = $0 })
    }
    var learningEnabledBinding: Binding<Bool> {
        Binding(get: { self.learningEnabled },
                set: { self.learningEnabled = $0; self.settings.learningEnabled = $0 })
    }

    // MARK: - Commands

    func restoreDefaults(_ section: IMESettings.Section) {
        settings.restoreDefaults(section: section)
    }

    func resetLearnedHistory() {
        UserHistoryStore.clearAll()
    }
}
