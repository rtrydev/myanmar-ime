import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// A read-only candidate store backed by a SQLite lexicon database.
///
/// Database schema (created by LexiconBuilder):
///   entries(id INTEGER PRIMARY KEY, surface TEXT, canonical_reading TEXT, unigram_score REAL)
///   reading_index(canonical_reading TEXT, entry_id INTEGER, rank_score REAL)
///   reading_alias_index(alias_reading TEXT, canonical_reading TEXT, entry_id INTEGER, rank_score REAL, alias_penalty INTEGER)
///   reading_compose_index(compose_reading TEXT, canonical_reading TEXT, entry_id INTEGER, rank_score REAL, alias_penalty INTEGER, separator_penalty INTEGER)
///
/// Context-aware re-ranking (the former `bigram_context` table) now lives in
/// the `LanguageModel` injected into `BurmeseEngine`.
public final class SQLiteCandidateStore: CandidateStore, @unchecked Sendable {

    private var db: OpaquePointer?
    private var prefixStmt: OpaquePointer?
    private var composePrefixStmt: OpaquePointer?

    /// Open a lexicon database at the given path.
    /// Returns nil if the database cannot be opened.
    public init?(path: String) {
        var sourceDB: OpaquePointer?
        guard sqlite3_open_v2(path, &sourceDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }

        let usesAliasIndex = Self.tableExists("reading_alias_index", in: sourceDB)
        let usesComposeIndex = Self.tableExists("reading_compose_index", in: sourceDB)

        if usesAliasIndex && usesComposeIndex {
            db = sourceDB
        } else {
            guard let materializedDB = Self.materializeLookupDatabase(
                from: sourceDB,
                createAliasIndex: !usesAliasIndex,
                createComposeIndex: !usesComposeIndex
            ) else {
                sqlite3_close(sourceDB)
                return nil
            }
            sqlite3_close(sourceDB)
            db = materializedDB
        }

        guard prepareStatements(usesAliasIndex: true, usesComposeIndex: true) else {
            sqlite3_close(db)
            db = nil
            return nil
        }
    }

    deinit {
        sqlite3_finalize(prefixStmt)
        sqlite3_finalize(composePrefixStmt)
        sqlite3_close(db)
    }

    // MARK: - CandidateStore

    public func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
        guard !prefix.isEmpty else { return [] }

        let aliasPrefix = Romanization.aliasReading(prefix)
        let composePrefix = Romanization.composeLookupKey(prefix)
        let upperBound = prefixUpperBound(aliasPrefix)
        let composeUpperBound = prefixUpperBound(composePrefix)

        var candidates: [Candidate] = []
        candidates += lookupPrefix(prefix: aliasPrefix, upperBound: upperBound)
        candidates += lookupComposePrefix(prefix: composePrefix, upperBound: composeUpperBound)
        return deduplicateCandidates(candidates)
    }

    // MARK: - Internal Queries

    private func prepareStatements(usesAliasIndex: Bool, usesComposeIndex: Bool) -> Bool {
        let prefixSQL: String
        let composePrefixSQL: String

        if usesAliasIndex {
            prefixSQL = """
                SELECT e.surface, a.canonical_reading, a.rank_score, a.alias_penalty
                FROM reading_alias_index a
                JOIN entries e ON e.id = a.entry_id
                WHERE a.alias_reading >= ?1 AND a.alias_reading < ?2
                ORDER BY a.alias_penalty ASC, a.rank_score DESC
                LIMIT 20
                """

            if usesComposeIndex {
                composePrefixSQL = """
                    SELECT e.surface, c.canonical_reading, c.rank_score, c.alias_penalty, c.separator_penalty
                    FROM reading_compose_index c
                    JOIN entries e ON e.id = c.entry_id
                    WHERE c.compose_reading >= ?1 AND c.compose_reading < ?2
                    ORDER BY c.separator_penalty ASC, c.alias_penalty ASC, c.rank_score DESC
                    LIMIT 20
                    """
            } else {
                composePrefixSQL = """
                    SELECT e.surface, a.canonical_reading, a.rank_score, a.alias_penalty,
                           (LENGTH(a.alias_reading) - LENGTH(REPLACE(REPLACE(a.alias_reading, '+', ''), '''', ''))) AS separator_penalty
                    FROM reading_alias_index a
                    JOIN entries e ON e.id = a.entry_id
                    WHERE REPLACE(REPLACE(a.alias_reading, '+', ''), '''', '') >= ?1
                    AND REPLACE(REPLACE(a.alias_reading, '+', ''), '''', '') < ?2
                    ORDER BY separator_penalty ASC, a.alias_penalty ASC, a.rank_score DESC
                    LIMIT 20
                    """
            }
        } else {
            prefixSQL = """
                SELECT e.surface, r.canonical_reading, r.rank_score,
                       (LENGTH(r.canonical_reading) - LENGTH(REPLACE(REPLACE(r.canonical_reading, '2', ''), '3', ''))) AS alias_penalty
                FROM reading_index r
                JOIN entries e ON e.id = r.entry_id
                WHERE REPLACE(REPLACE(r.canonical_reading, '2', ''), '3', '') >= ?1
                AND REPLACE(REPLACE(r.canonical_reading, '2', ''), '3', '') < ?2
                ORDER BY alias_penalty ASC, r.rank_score DESC
                LIMIT 20
                """

            composePrefixSQL = """
                SELECT e.surface, r.canonical_reading, r.rank_score,
                       (LENGTH(r.canonical_reading) - LENGTH(REPLACE(REPLACE(r.canonical_reading, '2', ''), '3', ''))) AS alias_penalty,
                       (LENGTH(r.canonical_reading) - LENGTH(REPLACE(REPLACE(r.canonical_reading, '+', ''), '''', ''))) AS separator_penalty
                FROM reading_index r
                JOIN entries e ON e.id = r.entry_id
                WHERE REPLACE(REPLACE(REPLACE(REPLACE(r.canonical_reading, '+', ''), '''', ''), '2', ''), '3', '') >= ?1
                AND REPLACE(REPLACE(REPLACE(REPLACE(r.canonical_reading, '+', ''), '''', ''), '2', ''), '3', '') < ?2
                ORDER BY separator_penalty ASC, alias_penalty ASC, r.rank_score DESC
                LIMIT 20
                """
        }

        if sqlite3_prepare_v2(db, prefixSQL, -1, &prefixStmt, nil) != SQLITE_OK {
            return false
        }

        if sqlite3_prepare_v2(db, composePrefixSQL, -1, &composePrefixStmt, nil) != SQLITE_OK {
            sqlite3_finalize(prefixStmt)
            prefixStmt = nil
            return false
        }

        return true
    }

    private func lookupPrefix(prefix: String, upperBound: String) -> [Candidate] {
        guard let stmt = prefixStmt else { return [] }
        defer { sqlite3_reset(stmt) }

        sqlite3_bind_text(stmt, 1, prefix, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, upperBound, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var results: [Candidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let surface = String(cString: sqlite3_column_text(stmt, 0))
            let reading = String(cString: sqlite3_column_text(stmt, 1))
            let rankScore = sqlite3_column_double(stmt, 2)
            let aliasPenalty = Int(sqlite3_column_int(stmt, 3))

            results.append(Candidate(
                surface: surface,
                reading: reading,
                source: .lexicon,
                score: rankScore - Double(aliasPenalty) * 1000.0
            ))
        }
        return results
    }

    private func lookupComposePrefix(prefix: String, upperBound: String) -> [Candidate] {
        guard !prefix.isEmpty, let stmt = composePrefixStmt else { return [] }
        defer { sqlite3_reset(stmt) }

        sqlite3_bind_text(stmt, 1, prefix, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, upperBound, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var results: [Candidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let surface = String(cString: sqlite3_column_text(stmt, 0))
            let reading = String(cString: sqlite3_column_text(stmt, 1))
            let rankScore = sqlite3_column_double(stmt, 2)
            let aliasPenalty = Int(sqlite3_column_int(stmt, 3))
            let separatorPenalty = Int(sqlite3_column_int(stmt, 4))

            results.append(Candidate(
                surface: surface,
                reading: reading,
                source: .lexicon,
                score: rankScore - Double(aliasPenalty) * 1000.0 - Double(separatorPenalty) * 250.0
            ))
        }
        return results
    }

    private static func tableExists(_ name: String, in db: OpaquePointer?) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1 LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }

        sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func materializeLookupDatabase(
        from sourceDB: OpaquePointer?,
        createAliasIndex: Bool,
        createComposeIndex: Bool
    ) -> OpaquePointer? {
        var lookupDB: OpaquePointer?
        guard sqlite3_open(":memory:", &lookupDB) == SQLITE_OK,
              let lookupDB else {
            sqlite3_close(lookupDB)
            return nil
        }

        guard backupDatabase(from: sourceDB, to: lookupDB) else {
            sqlite3_close(lookupDB)
            return nil
        }

        if createAliasIndex {
            guard exec(
                """
                CREATE TABLE reading_alias_index (
                    alias_reading TEXT NOT NULL,
                    canonical_reading TEXT NOT NULL,
                    entry_id INTEGER NOT NULL REFERENCES entries(id),
                    rank_score REAL NOT NULL,
                    alias_penalty INTEGER NOT NULL
                )
                """,
                in: lookupDB
            ) else {
                sqlite3_close(lookupDB)
                return nil
            }
        }

        if createComposeIndex {
            guard exec(
                """
                CREATE TABLE reading_compose_index (
                    compose_reading TEXT NOT NULL,
                    canonical_reading TEXT NOT NULL,
                    entry_id INTEGER NOT NULL REFERENCES entries(id),
                    rank_score REAL NOT NULL,
                    alias_penalty INTEGER NOT NULL,
                    separator_penalty INTEGER NOT NULL
                )
                """,
                in: lookupDB
            ) else {
                sqlite3_close(lookupDB)
                return nil
            }
        }

        guard populateDerivedIndexes(
            in: lookupDB,
            createAliasIndex: createAliasIndex,
            createComposeIndex: createComposeIndex
        ) else {
            sqlite3_close(lookupDB)
            return nil
        }

        if createAliasIndex,
           !exec("CREATE INDEX idx_reading_alias ON reading_alias_index (alias_reading)", in: lookupDB) {
            sqlite3_close(lookupDB)
            return nil
        }

        if createComposeIndex,
           !exec("CREATE INDEX idx_reading_compose ON reading_compose_index (compose_reading)", in: lookupDB) {
            sqlite3_close(lookupDB)
            return nil
        }

        return lookupDB
    }

    private static func backupDatabase(from sourceDB: OpaquePointer?, to destinationDB: OpaquePointer?) -> Bool {
        guard let backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") else {
            return false
        }
        defer { sqlite3_backup_finish(backup) }

        let result = sqlite3_backup_step(backup, -1)
        return result == SQLITE_DONE
    }

    private static func populateDerivedIndexes(
        in db: OpaquePointer?,
        createAliasIndex: Bool,
        createComposeIndex: Bool
    ) -> Bool {
        guard createAliasIndex || createComposeIndex else { return true }
        guard exec("BEGIN TRANSACTION", in: db) else { return false }

        var committed = false
        defer {
            if !committed {
                _ = exec("ROLLBACK", in: db)
            }
        }

        let selectSQL = """
            SELECT entry_id, canonical_reading, rank_score
            FROM reading_index
            """
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(selectStmt) }

        var insertAliasStmt: OpaquePointer?
        if createAliasIndex {
            let aliasSQL = """
                INSERT INTO reading_alias_index (
                    alias_reading,
                    canonical_reading,
                    entry_id,
                    rank_score,
                    alias_penalty
                ) VALUES (?1, ?2, ?3, ?4, ?5)
                """
            guard sqlite3_prepare_v2(db, aliasSQL, -1, &insertAliasStmt, nil) == SQLITE_OK else {
                return false
            }
        }
        defer { sqlite3_finalize(insertAliasStmt) }

        var insertComposeStmt: OpaquePointer?
        if createComposeIndex {
            let composeSQL = """
                INSERT INTO reading_compose_index (
                    compose_reading,
                    canonical_reading,
                    entry_id,
                    rank_score,
                    alias_penalty,
                    separator_penalty
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                """
            guard sqlite3_prepare_v2(db, composeSQL, -1, &insertComposeStmt, nil) == SQLITE_OK else {
                return false
            }
        }
        defer { sqlite3_finalize(insertComposeStmt) }

        while true {
            let stepResult = sqlite3_step(selectStmt)
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW,
                  let readingText = sqlite3_column_text(selectStmt, 1) else {
                return false
            }

            let entryID = sqlite3_column_int64(selectStmt, 0)
            let reading = String(cString: readingText)
            let rankScore = sqlite3_column_double(selectStmt, 2)
            let aliasPenalty = Romanization.aliasPenaltyCount(for: reading)

            if createAliasIndex, let insertAliasStmt {
                let aliasReading = Romanization.aliasReading(reading)
                sqlite3_bind_text(insertAliasStmt, 1, aliasReading, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(insertAliasStmt, 2, reading, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_int64(insertAliasStmt, 3, entryID)
                sqlite3_bind_double(insertAliasStmt, 4, rankScore)
                sqlite3_bind_int(insertAliasStmt, 5, Int32(aliasPenalty))

                guard sqlite3_step(insertAliasStmt) == SQLITE_DONE else {
                    return false
                }
                sqlite3_reset(insertAliasStmt)
                sqlite3_clear_bindings(insertAliasStmt)
            }

            if createComposeIndex, let insertComposeStmt {
                let composeReading = Romanization.composeLookupKey(reading)
                let separatorPenalty = Romanization.composeSeparatorPenaltyCount(for: reading)
                sqlite3_bind_text(insertComposeStmt, 1, composeReading, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(insertComposeStmt, 2, reading, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_int64(insertComposeStmt, 3, entryID)
                sqlite3_bind_double(insertComposeStmt, 4, rankScore)
                sqlite3_bind_int(insertComposeStmt, 5, Int32(aliasPenalty))
                sqlite3_bind_int(insertComposeStmt, 6, Int32(separatorPenalty))

                guard sqlite3_step(insertComposeStmt) == SQLITE_DONE else {
                    return false
                }
                sqlite3_reset(insertComposeStmt)
                sqlite3_clear_bindings(insertComposeStmt)
            }
        }

        guard exec("COMMIT", in: db) else { return false }
        committed = true
        return true
    }

    private static func exec(_ sql: String, in db: OpaquePointer?) -> Bool {
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(errorMessage) }

        return sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK
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

    private func deduplicateCandidates(_ candidates: [Candidate]) -> [Candidate] {
        var seen: Set<String> = []
        var unique: [Candidate] = []

        for candidate in candidates {
            let key = "\(candidate.surface)\u{0}\(candidate.reading)"
            if seen.insert(key).inserted {
                unique.append(candidate)
            }
        }

        return unique
    }
}
