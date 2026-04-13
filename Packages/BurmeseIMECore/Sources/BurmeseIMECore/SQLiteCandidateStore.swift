import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// A read-only candidate store backed by a SQLite lexicon database.
///
/// Database schema (created by LexiconBuilder):
///   entries(id INTEGER PRIMARY KEY, surface TEXT, canonical_reading TEXT, unigram_score REAL)
///   reading_index(canonical_reading TEXT, entry_id INTEGER, rank_score REAL)
///   bigram_context(prev_surface TEXT, next_entry_id INTEGER, score REAL)
public final class SQLiteCandidateStore: CandidateStore, @unchecked Sendable {

    private var db: OpaquePointer?
    private var prefixStmt: OpaquePointer?
    private var bigramStmt: OpaquePointer?

    /// Open a lexicon database at the given path.
    /// Returns nil if the database cannot be opened.
    public init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }

        // Prepare the prefix lookup statement
        let prefixSQL = """
            SELECT e.surface, e.canonical_reading, e.unigram_score
            FROM entries e
            JOIN reading_index r ON r.entry_id = e.id
            WHERE r.canonical_reading >= ?1 AND r.canonical_reading < ?2
            ORDER BY r.rank_score DESC
            LIMIT 20
            """
        if sqlite3_prepare_v2(db, prefixSQL, -1, &prefixStmt, nil) != SQLITE_OK {
            sqlite3_close(db)
            return nil
        }

        // Prepare the bigram context lookup statement
        let bigramSQL = """
            SELECT e.surface, e.canonical_reading, b.score
            FROM bigram_context b
            JOIN entries e ON e.id = b.next_entry_id
            WHERE b.prev_surface = ?1
            AND e.canonical_reading >= ?2 AND e.canonical_reading < ?3
            ORDER BY b.score DESC
            LIMIT 10
            """
        if sqlite3_prepare_v2(db, bigramSQL, -1, &bigramStmt, nil) != SQLITE_OK {
            sqlite3_finalize(prefixStmt)
            sqlite3_close(db)
            return nil
        }
    }

    deinit {
        sqlite3_finalize(prefixStmt)
        sqlite3_finalize(bigramStmt)
        sqlite3_close(db)
    }

    // MARK: - CandidateStore

    public func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
        guard !prefix.isEmpty else { return [] }

        var candidates: [Candidate] = []

        // Compute the exclusive upper bound for prefix range query
        let upperBound = prefixUpperBound(prefix)

        // 1. Bigram context candidates (if we have previous context)
        if let prev = previousSurface {
            candidates += lookupBigram(prev: prev, prefix: prefix, upperBound: upperBound)
        }

        // 2. Unigram prefix candidates
        candidates += lookupPrefix(prefix: prefix, upperBound: upperBound)

        return candidates
    }

    // MARK: - Internal Queries

    private func lookupPrefix(prefix: String, upperBound: String) -> [Candidate] {
        guard let stmt = prefixStmt else { return [] }
        defer { sqlite3_reset(stmt) }

        sqlite3_bind_text(stmt, 1, prefix, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, upperBound, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var results: [Candidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let surface = String(cString: sqlite3_column_text(stmt, 0))
            let reading = String(cString: sqlite3_column_text(stmt, 1))
            let score = sqlite3_column_double(stmt, 2)

            results.append(Candidate(
                surface: surface,
                reading: reading,
                source: .lexicon,
                score: score
            ))
        }
        return results
    }

    private func lookupBigram(prev: String, prefix: String, upperBound: String) -> [Candidate] {
        guard let stmt = bigramStmt else { return [] }
        defer { sqlite3_reset(stmt) }

        sqlite3_bind_text(stmt, 1, prev, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, prefix, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, upperBound, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var results: [Candidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let surface = String(cString: sqlite3_column_text(stmt, 0))
            let reading = String(cString: sqlite3_column_text(stmt, 1))
            let score = sqlite3_column_double(stmt, 2)

            results.append(Candidate(
                surface: surface,
                reading: reading,
                source: .lexicon,
                score: score + 500.0  // bigram boost
            ))
        }
        return results
    }

    /// Compute the exclusive upper bound for a prefix range query.
    /// "min" → "mio" (increment last character).
    private func prefixUpperBound(_ prefix: String) -> String {
        guard !prefix.isEmpty else { return "" }
        var chars = Array(prefix)
        if let last = chars.last {
            chars[chars.count - 1] = Character(UnicodeScalar(last.asciiValue! + 1))
        }
        return String(chars)
    }
}
