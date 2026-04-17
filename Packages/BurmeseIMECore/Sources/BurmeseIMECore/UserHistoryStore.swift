import Foundation

/// Persistent record of previously-committed candidate selections. The lookup
/// method mirrors `CandidateStore` so the engine can merge history hits into
/// ranking; `record` is the write-through called from the commit path.
public protocol UserHistoryStore: Sendable {
    /// Returns history candidates whose stored reading is a prefix of `prefix`
    /// or matches exactly. Score is the recency/frequency weighted value
    /// computed by the store (see `SQLiteUserHistoryStore`).
    func lookup(prefix: String, previousSurface: String?) -> [Candidate]

    /// Increment the `(reading, surface)` row and bump `last_picked_at`.
    /// Implementations may dispatch the write asynchronously.
    func record(reading: String, surface: String)

    /// Remove every stored selection.
    func clearAll()
}

/// A no-op history store. Used in tests and as the fallback when the on-disk
/// database cannot be opened.
public struct EmptyUserHistoryStore: UserHistoryStore {
    public init() {}
    public func lookup(prefix: String, previousSurface: String?) -> [Candidate] { [] }
    public func record(reading: String, surface: String) {}
    public func clearAll() {}
}

/// Helpers for the canonical on-disk history location. The Preferences app
/// uses `clearAll()` to wipe the table without holding a long-lived store
/// instance.
public enum UserHistoryStoreDefault {
    public static let filename = "UserHistory.sqlite"

    /// `~/Library/Application Support/BurmeseIME/UserHistory.sqlite`.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("BurmeseIME", isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// Ensure the parent directory exists. Returns true on success.
    @discardableResult
    public static func ensureContainer() -> Bool {
        let dir = defaultURL().deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// Open the default store and delete every row. If the database is missing
    /// this is a no-op — nothing to clear.
    public static func clearAll() {
        let url = defaultURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let store = SQLiteUserHistoryStore(path: url.path) else {
            return
        }
        store.clearAll()
    }
}
