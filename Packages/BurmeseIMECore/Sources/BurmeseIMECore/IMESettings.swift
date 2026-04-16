import Foundation

/// Shared, process-crossing preferences for the IME. Backed by a
/// `UserDefaults` suite so the container app and the IMK extension observe
/// the same values. Foundation-only — no Combine/SwiftUI — so this compiles
/// on any Swift toolchain.
public final class IMESettings: @unchecked Sendable {

    public static let didChangeNotification = Notification.Name("BurmeseIMESettingsDidChange")
    public static let changedKeyUserInfoKey = "key"

    public enum Section: String, CaseIterable, Sendable {
        case inputBehavior
        case candidateRanking
        case textOutput
        case learning
        case diagnostics
    }

    public enum Key: String, CaseIterable, Sendable {
        case candidatePageSize         = "ime.candidatePageSize"
        case commitOnSpace             = "ime.commitOnSpace"
        case clusterAliasesEnabled     = "ime.clusterAliasesEnabled"
        case lmPruneMargin             = "ime.lmPruneMargin"
        case anchorCommitThreshold     = "ime.anchorCommitThreshold"
        case burmesePunctuationEnabled = "ime.burmesePunctuationEnabled"
        case numberMeasureWordsEnabled = "ime.numberMeasureWordsEnabled"
        case learningEnabled           = "ime.learningEnabled"

        public var section: Section {
            switch self {
            case .candidatePageSize, .commitOnSpace, .clusterAliasesEnabled:
                return .inputBehavior
            case .lmPruneMargin, .anchorCommitThreshold:
                return .candidateRanking
            case .burmesePunctuationEnabled, .numberMeasureWordsEnabled:
                return .textOutput
            case .learningEnabled:
                return .learning
            }
        }
    }

    public enum DefaultValue: Sendable {
        case int(Int)
        case bool(Bool)
        case double(Double)
    }

    public static let defaultValues: [Key: DefaultValue] = [
        .candidatePageSize:         .int(9),
        .commitOnSpace:             .bool(false),
        .clusterAliasesEnabled:     .bool(true),
        .lmPruneMargin:             .double(8.0),
        .anchorCommitThreshold:     .int(8),
        .burmesePunctuationEnabled: .bool(false),
        .numberMeasureWordsEnabled: .bool(false),
        .learningEnabled:           .bool(true),
    ]

    /// Default suite name used by the production app + extension. Both
    /// targets must carry a matching App Group entitlement for the suite
    /// to bridge across processes.
    public static let defaultSuiteName = "group.com.myangler.inputmethod.burmese"

    public let store: UserDefaults
    public let suiteName: String?

    /// - Parameter suiteName: pass `nil` to use `.standard` (tests / fallback).
    public init(suiteName: String? = IMESettings.defaultSuiteName) {
        self.suiteName = suiteName
        if let name = suiteName, let suite = UserDefaults(suiteName: name) {
            self.store = suite
        } else {
            self.store = .standard
        }
        seedMissingDefaults()
    }

    private func seedMissingDefaults() {
        for (key, value) in Self.defaultValues where store.object(forKey: key.rawValue) == nil {
            switch value {
            case .int(let v):    store.set(v, forKey: key.rawValue)
            case .bool(let v):   store.set(v, forKey: key.rawValue)
            case .double(let v): store.set(v, forKey: key.rawValue)
            }
        }
    }

    // MARK: - Typed accessors

    public var candidatePageSize: Int {
        get { store.integer(forKey: Key.candidatePageSize.rawValue) }
        set { write(.candidatePageSize, newValue) }
    }

    public var commitOnSpace: Bool {
        get { store.bool(forKey: Key.commitOnSpace.rawValue) }
        set { write(.commitOnSpace, newValue) }
    }

    public var clusterAliasesEnabled: Bool {
        get { store.bool(forKey: Key.clusterAliasesEnabled.rawValue) }
        set { write(.clusterAliasesEnabled, newValue) }
    }

    public var lmPruneMargin: Double {
        get { store.double(forKey: Key.lmPruneMargin.rawValue) }
        set { write(.lmPruneMargin, newValue) }
    }

    public var anchorCommitThreshold: Int {
        get { store.integer(forKey: Key.anchorCommitThreshold.rawValue) }
        set { write(.anchorCommitThreshold, newValue) }
    }

    public var burmesePunctuationEnabled: Bool {
        get { store.bool(forKey: Key.burmesePunctuationEnabled.rawValue) }
        set { write(.burmesePunctuationEnabled, newValue) }
    }

    public var numberMeasureWordsEnabled: Bool {
        get { store.bool(forKey: Key.numberMeasureWordsEnabled.rawValue) }
        set { write(.numberMeasureWordsEnabled, newValue) }
    }

    public var learningEnabled: Bool {
        get { store.bool(forKey: Key.learningEnabled.rawValue) }
        set { write(.learningEnabled, newValue) }
    }

    // MARK: - Bulk operations

    /// Reset every key in `section` to its compiled-in default. Posts one
    /// change notification per key so observers can react uniformly.
    public func restoreDefaults(section: Section) {
        for key in Key.allCases where key.section == section {
            guard let value = Self.defaultValues[key] else { continue }
            switch value {
            case .int(let v):    store.set(v, forKey: key.rawValue)
            case .bool(let v):   store.set(v, forKey: key.rawValue)
            case .double(let v): store.set(v, forKey: key.rawValue)
            }
            postChange(key: key)
        }
    }

    // MARK: - Internal helpers

    private func write<T>(_ key: Key, _ value: T) {
        store.set(value, forKey: key.rawValue)
        postChange(key: key)
    }

    private func postChange(key: Key) {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.changedKeyUserInfoKey: key.rawValue]
        )
    }
}
