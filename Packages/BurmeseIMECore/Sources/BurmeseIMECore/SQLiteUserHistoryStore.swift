import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Persistent `(reading, surface)` selection counter backed by SQLite.
///
/// Schema:
///   selections(reading TEXT, surface TEXT, count INTEGER, last_picked_at REAL,
///              PRIMARY KEY (reading, surface))
///   INDEX idx_reading ON selections(reading)
///
/// Writes are serialized on a private queue so the IMK commit path isn't
/// blocked on fsync. `lookup` runs synchronously on the queue — the engine's
/// update path needs the result inline.
public final class SQLiteUserHistoryStore: UserHistoryStore, @unchecked Sendable {

    /// Recency half-life in days. A pick from 30 days ago contributes half
    /// the score of a same-count pick today.
    public static let recencyHalfLifeDays: Double = 30.0

    private let queue = DispatchQueue(
        label: "com.myangler.inputmethod.burmese.history",
        qos: .userInitiated
    )

    private var db: OpaquePointer?
    private var lookupStmt: OpaquePointer?
    private var upsertStmt: OpaquePointer?
    private var clearStmt: OpaquePointer?
    private var deleteStmt: OpaquePointer?
    private var listStmt: OpaquePointer?

    public init?(path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try? FileManager.default.createDirectory(
                atPath: parent, withIntermediateDirectories: true
            )
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        db = handle

        guard Self.migrate(db: db), prepareStatements() else {
            sqlite3_finalize(lookupStmt)
            sqlite3_finalize(upsertStmt)
            sqlite3_finalize(clearStmt)
            sqlite3_finalize(deleteStmt)
            sqlite3_finalize(listStmt)
            sqlite3_close(db)
            db = nil
            return nil
        }
    }

    deinit {
        sqlite3_finalize(lookupStmt)
        sqlite3_finalize(upsertStmt)
        sqlite3_finalize(clearStmt)
        sqlite3_finalize(deleteStmt)
        sqlite3_finalize(listStmt)
        sqlite3_close(db)
    }

    // MARK: - UserHistoryStore

    public func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
        guard !prefix.isEmpty else { return [] }
        return queue.sync { lookupLocked(prefix: prefix) }
    }

    public func record(reading: String, surface: String) {
        guard !reading.isEmpty, !surface.isEmpty else { return }
        queue.async { [weak self] in
            self?.recordLocked(reading: reading, surface: surface)
        }
    }

    public func remove(reading: String, surface: String) {
        guard !reading.isEmpty, !surface.isEmpty else { return }
        queue.sync { removeLocked(reading: reading, surface: surface) }
    }

    public func listAll() -> [HistoryEntry] {
        queue.sync { listAllLocked() }
    }

    public func clearAll() {
        queue.sync { clearLocked() }
    }

    // MARK: - Setup

    private static func migrate(db: OpaquePointer?) -> Bool {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS selections (
                reading TEXT NOT NULL,
                surface TEXT NOT NULL,
                count INTEGER NOT NULL DEFAULT 0,
                last_picked_at REAL NOT NULL,
                PRIMARY KEY (reading, surface)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_reading ON selections(reading)"
        ]
        for sql in statements {
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                return false
            }
        }
        return true
    }

    private func prepareStatements() -> Bool {
        let lookupSQL = """
            SELECT reading, surface, count, last_picked_at
            FROM selections
            WHERE reading >= ?1 AND reading < ?2
            LIMIT 64
            """
        let upsertSQL = """
            INSERT INTO selections (reading, surface, count, last_picked_at)
                VALUES (?1, ?2, 1, ?3)
            ON CONFLICT(reading, surface) DO UPDATE
                SET count = count + 1,
                    last_picked_at = excluded.last_picked_at
            """
        let clearSQL = "DELETE FROM selections"
        let deleteSQL = "DELETE FROM selections WHERE reading = ?1 AND surface = ?2"
        let listSQL = """
            SELECT reading, surface, count, last_picked_at
            FROM selections
            ORDER BY last_picked_at DESC
            LIMIT 2000
            """

        guard sqlite3_prepare_v2(db, lookupSQL, -1, &lookupStmt, nil) == SQLITE_OK else {
            return false
        }
        guard sqlite3_prepare_v2(db, upsertSQL, -1, &upsertStmt, nil) == SQLITE_OK else {
            return false
        }
        guard sqlite3_prepare_v2(db, clearSQL, -1, &clearStmt, nil) == SQLITE_OK else {
            return false
        }
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK else {
            return false
        }
        guard sqlite3_prepare_v2(db, listSQL, -1, &listStmt, nil) == SQLITE_OK else {
            return false
        }
        return true
    }

    // MARK: - Private queue operations

    private func lookupLocked(prefix: String) -> [Candidate] {
        guard let stmt = lookupStmt else { return [] }
        defer { sqlite3_reset(stmt) }

        let upper = Self.prefixUpperBound(prefix)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, prefix, -1, transient)
        sqlite3_bind_text(stmt, 2, upper, -1, transient)

        let now = Date().timeIntervalSince1970
        let prefixLen = prefix.count
        var results: [Candidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let reading = String(cString: sqlite3_column_text(stmt, 0))
            // Only surface history entries once the typed prefix covers at
            // least half of the stored reading. Without this, a two-char
            // prefix like "kw" would pop long entries like "kwyantaw" on
            // every keystroke.
            guard prefixLen * 2 >= reading.count else { continue }
            let surface = String(cString: sqlite3_column_text(stmt, 1))
            let count = Int(sqlite3_column_int64(stmt, 2))
            let lastPickedAt = sqlite3_column_double(stmt, 3)
            let score = Self.historyScore(count: count, lastPickedAt: lastPickedAt, now: now)
            results.append(Candidate(
                surface: surface,
                reading: reading,
                source: .history,
                score: score
            ))
        }
        results.sort { $0.score > $1.score }
        return results
    }

    private func recordLocked(reading: String, surface: String) {
        guard let stmt = upsertStmt else { return }
        defer { sqlite3_reset(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, reading, -1, transient)
        sqlite3_bind_text(stmt, 2, surface, -1, transient)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        _ = sqlite3_step(stmt)
    }

    private func clearLocked() {
        guard let stmt = clearStmt else { return }
        defer { sqlite3_reset(stmt) }
        _ = sqlite3_step(stmt)
    }

    private func removeLocked(reading: String, surface: String) {
        guard let stmt = deleteStmt else { return }
        defer { sqlite3_reset(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, reading, -1, transient)
        sqlite3_bind_text(stmt, 2, surface, -1, transient)
        _ = sqlite3_step(stmt)
    }

    private func listAllLocked() -> [HistoryEntry] {
        guard let stmt = listStmt else { return [] }
        defer { sqlite3_reset(stmt) }

        var results: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let reading = String(cString: sqlite3_column_text(stmt, 0))
            let surface = String(cString: sqlite3_column_text(stmt, 1))
            let count = Int(sqlite3_column_int64(stmt, 2))
            let lastPickedAt = sqlite3_column_double(stmt, 3)
            results.append(HistoryEntry(
                reading: reading,
                surface: surface,
                count: count,
                lastPickedAt: lastPickedAt
            ))
        }
        return results
    }

    // MARK: - Scoring

    /// `log(1 + count) * 0.5 ^ (days_since_last_pick / 30)`. Exposed for tests.
    public static func historyScore(count: Int, lastPickedAt: TimeInterval, now: TimeInterval) -> Double {
        let deltaSeconds = max(0, now - lastPickedAt)
        let deltaDays = deltaSeconds / 86_400.0
        let decay = pow(0.5, deltaDays / recencyHalfLifeDays)
        return log1p(Double(count)) * decay
    }

    // MARK: - Helpers

    /// Increment the final ASCII byte so the range query matches every string
    /// starting with `prefix`. Assumes the prefix is ASCII (alias readings are).
    private static func prefixUpperBound(_ prefix: String) -> String {
        guard !prefix.isEmpty else { return "" }
        var chars = Array(prefix)
        if let last = chars.last, let ascii = last.asciiValue {
            chars[chars.count - 1] = Character(UnicodeScalar(ascii + 1))
            return String(chars)
        }
        // Non-ASCII fallback: append a high-codepoint sentinel so the range
        // covers every prefix extension.
        return prefix + "\u{FFFF}"
    }

    /// Test hook: overwrite `last_picked_at` for a recorded row.
    #if DEBUG
    public func forceLastPickedAt(reading: String, surface: String, to timestamp: TimeInterval) {
        queue.sync {
            let sql = "UPDATE selections SET last_picked_at = ?3 WHERE reading = ?1 AND surface = ?2"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, reading, -1, transient)
            sqlite3_bind_text(stmt, 2, surface, -1, transient)
            sqlite3_bind_double(stmt, 3, timestamp)
            _ = sqlite3_step(stmt)
        }
    }
    #endif
}
