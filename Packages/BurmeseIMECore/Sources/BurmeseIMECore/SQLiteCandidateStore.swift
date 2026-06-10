import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
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
    private var exactAliasStmt: OpaquePointer?
    private var exactComposeStmt: OpaquePointer?
    // Exact-match lookups are called many times per keystroke by the lattice
    // decoder — at every position × every prefix length. Most sub-readings
    // do not exist as lexicon entries, so a cheap per-engine-instance cache
    // collapses each repeat lookup to a dictionary hit.
    private var exactLookupCache: [String: [Candidate]] = [:]
    private var exactLookupCacheOrder: [String] = []
    private let exactLookupCacheLock = NSLock()
    private static let exactLookupCacheCapacity = 4096

    // The lattice decoder issues O(buffer² ) `lookupExactForLattice` calls
    // per `decode()` — one per (start, length) substring up to 24 chars.
    // Same shape of lookup as `lookupExact`, but needed separately because
    // the lattice keeps the raw `alias_penalty` instead of folding it into
    // `Candidate.score`. Without a cache here, incremental typing pays full
    // SQL bind + step + per-row String materialisation on every keystroke.
    private var latticeLookupCache: [String: [LatticeLookupRow]] = [:]
    private var latticeLookupCacheOrder: [String] = []
    private let latticeLookupCacheLock = NSLock()
    private static let latticeLookupCacheCapacity = 4096

    // The engine's `lookup(prefix:)` call is the slowest single SQL the IME
    // issues: for a short prefix (`a`, `t`, `k`) the WHERE clause selects
    // tens of thousands of rows, and the bundled lexicon's
    // `idx_reading_alias` is not covering for the `ORDER BY alias_penalty
    // ASC, rank_score DESC` clause, so SQLite walks the full range into a
    // temp B-tree before LIMIT 20 can apply. On macOS that's ~60 ms per
    // call, ~120 ms per keystroke (the engine calls `lookup(prefix:)`
    // twice per keystroke in the non-windowed path). Caching the result
    // turns every repeat keystroke for the same prefix into a dictionary
    // hit; the `previousSurface` parameter is ignored on the SQLite path,
    // so the cache key is the raw prefix string. Same drop-25%-on-overflow
    // eviction the other two caches use.
    private var prefixLookupCache: [String: [Candidate]] = [:]
    private var prefixLookupCacheOrder: [String] = []
    private let prefixLookupCacheLock = NSLock()
    private static let prefixLookupCacheCapacity = 4096

    // Eviction batch for both caches. On overflow we drop the oldest 25%
    // rather than clearing the whole map: a full wipe causes a hit-rate
    // cliff where every keystroke after the cache fills pays full SQL
    // cost again, which is exactly what these caches exist to avoid.
    private static let lookupCacheEvictBatch = 1024

    private struct LatticeLookupRow {
        let candidate: Candidate
        let aliasPenalty: Int
    }

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
        sqlite3_finalize(exactAliasStmt)
        sqlite3_finalize(exactComposeStmt)
        sqlite3_close(db)
    }

    // MARK: - CandidateStore

    public func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
        guard !prefix.isEmpty else { return [] }

        prefixLookupCacheLock.lock()
        if let hit = prefixLookupCache[prefix] {
            prefixLookupCacheLock.unlock()
            return hit
        }
        prefixLookupCacheLock.unlock()

        var candidates: [Candidate] = []
        // TASK-084: the range queries below order by `alias_penalty ASC,
        // rank_score DESC LIMIT 20` with no preference for exact-length
        // matches, so a penalty-1 exact row (`ahain` → `အိမ်`) can be
        // crowded out of the window by 20 penalty-0 completions of
        // longer readings sharing the prefix. Union the exact-equality
        // rows first — exact matches of the typed prefix are the
        // strongest hits this lookup can return and must never be lost
        // to same-prefix completions. The combined result is what the
        // prefix LRU caches, so the hot path pays the equality probes
        // only on a cache miss. Union rows are gated by
        // `isExactTrustworthyRow`: corpus rows whose reading silently
        // under-covers the surface (`၁ဝ` ← `wa`, `၃က` ← `ka`,
        // `သို႔` ← `tho`) used to hide behind the LIMIT window and
        // must not be rescued past it; the window rows themselves are
        // returned exactly as before.
        for variant in Romanization.lookupAliasReadings(for: prefix) {
            let upperBound = prefixUpperBound(variant.aliasReading)
            let exactRows = lookupExactAlias(reading: variant.aliasReading).filter {
                Romanization.isExactTrustworthyRow(surface: $0.surface, reading: $0.reading)
            }
            candidates += applyLookupPenalty(
                exactRows + lookupPrefix(prefix: variant.aliasReading, upperBound: upperBound),
                variant.extraPenalty
            )
        }
        for variant in Romanization.lookupComposeReadings(for: prefix) {
            let upperBound = prefixUpperBound(variant.composeReading)
            let exactRows = lookupExactCompose(reading: variant.composeReading).filter {
                Romanization.isExactTrustworthyRow(surface: $0.surface, reading: $0.reading)
            }
            candidates += applyLookupPenalty(
                exactRows + lookupComposePrefix(prefix: variant.composeReading, upperBound: upperBound),
                variant.extraPenalty
            )
        }
        let deduped = deduplicateCandidates(candidates)

        prefixLookupCacheLock.lock()
        if prefixLookupCache[prefix] == nil {
            if prefixLookupCache.count >= Self.prefixLookupCacheCapacity {
                let drop = min(Self.lookupCacheEvictBatch, prefixLookupCacheOrder.count)
                for key in prefixLookupCacheOrder.prefix(drop) {
                    prefixLookupCache.removeValue(forKey: key)
                }
                prefixLookupCacheOrder.removeFirst(drop)
            }
            prefixLookupCache[prefix] = deduped
            prefixLookupCacheOrder.append(prefix)
        }
        prefixLookupCacheLock.unlock()
        return deduped
    }

    public func lookupExactForLattice(reading: String) -> [(candidate: Candidate, aliasPenalty: Int)] {
        guard !reading.isEmpty else { return [] }

        latticeLookupCacheLock.lock()
        if let hit = latticeLookupCache[reading] {
            latticeLookupCacheLock.unlock()
            return hit.map { ($0.candidate, $0.aliasPenalty) }
        }
        latticeLookupCacheLock.unlock()

        var results: [(candidate: Candidate, aliasPenalty: Int)] = []
        for variant in Romanization.lookupAliasReadings(for: reading) {
            results += lookupExactAliasWithPenalty(reading: variant.aliasReading).map {
                ($0.candidate, $0.aliasPenalty + variant.extraPenalty)
            }
        }
        for variant in Romanization.lookupComposeReadings(for: reading) {
            results += lookupExactComposeWithPenalty(reading: variant.composeReading).map {
                ($0.candidate, $0.aliasPenalty + variant.extraPenalty)
            }
        }
        // Dedupe by surface, keeping the first (higher-ranked) entry.
        var seen: Set<String> = []
        var deduped: [(candidate: Candidate, aliasPenalty: Int)] = []
        deduped.reserveCapacity(results.count)
        for row in results where seen.insert(row.candidate.surface).inserted {
            deduped.append(row)
        }

        let cacheRows = deduped.map { LatticeLookupRow(candidate: $0.candidate, aliasPenalty: $0.aliasPenalty) }
        latticeLookupCacheLock.lock()
        if latticeLookupCache[reading] == nil {
            if latticeLookupCache.count >= Self.latticeLookupCacheCapacity {
                let drop = min(Self.lookupCacheEvictBatch, latticeLookupCacheOrder.count)
                for key in latticeLookupCacheOrder.prefix(drop) {
                    latticeLookupCache.removeValue(forKey: key)
                }
                latticeLookupCacheOrder.removeFirst(drop)
            }
            latticeLookupCache[reading] = cacheRows
            latticeLookupCacheOrder.append(reading)
        }
        latticeLookupCacheLock.unlock()
        return deduped
    }

    public func lookupAliasExact(aliasReading: String) -> [Candidate] {
        // TASK-084: direct equality probe on `reading_alias_index` —
        // verbatim matched-alias semantics, no compose fallback and no
        // variant expansion. Reuses the prepared exact statement
        // (indexed `alias_reading = ?` probe), so the cost is one
        // B-tree lookup per call; callers on the per-keystroke hot
        // path issue at most one of these per update.
        guard !aliasReading.isEmpty else { return [] }
        return deduplicateCandidates(lookupExactAlias(reading: aliasReading))
    }

    public func lookupExact(reading: String, previousSurface: String?) -> [Candidate] {
        guard !reading.isEmpty else { return [] }
        let aliasKey = Romanization.aliasReading(reading)
        let composeKey = Romanization.composeLookupKey(reading)
        let cacheKey = aliasKey + "\u{1F}" + composeKey

        exactLookupCacheLock.lock()
        if let hit = exactLookupCache[cacheKey] {
            exactLookupCacheLock.unlock()
            return hit
        }
        exactLookupCacheLock.unlock()

        var candidates: [Candidate] = []
        for variant in Romanization.lookupAliasReadings(for: reading) {
            candidates += applyLookupPenalty(
                lookupExactAlias(reading: variant.aliasReading),
                variant.extraPenalty
            )
        }
        for variant in Romanization.lookupComposeReadings(for: reading) {
            candidates += applyLookupPenalty(
                lookupExactCompose(reading: variant.composeReading),
                variant.extraPenalty
            )
        }
        let deduped = deduplicateCandidates(candidates)

        exactLookupCacheLock.lock()
        if exactLookupCache[cacheKey] == nil {
            if exactLookupCache.count >= Self.exactLookupCacheCapacity {
                let drop = min(Self.lookupCacheEvictBatch, exactLookupCacheOrder.count)
                for key in exactLookupCacheOrder.prefix(drop) {
                    exactLookupCache.removeValue(forKey: key)
                }
                exactLookupCacheOrder.removeFirst(drop)
            }
            exactLookupCache[cacheKey] = deduped
            exactLookupCacheOrder.append(cacheKey)
        }
        exactLookupCacheLock.unlock()
        return deduped
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

        // Exact-match variants for the lattice decoder. The alias equality
        // query hits `idx_reading_alias`; the compose equality query hits
        // `idx_reading_compose` when present, else falls back to a REPLACE
        // filter on `reading_alias_index` (mirrors the prefix fallback).
        let exactAliasSQL: String
        let exactComposeSQL: String
        if usesAliasIndex {
            exactAliasSQL = """
                SELECT e.surface, a.canonical_reading, a.rank_score, a.alias_penalty
                FROM reading_alias_index a
                JOIN entries e ON e.id = a.entry_id
                WHERE a.alias_reading = ?1
                ORDER BY a.alias_penalty ASC, a.rank_score DESC
                LIMIT 20
                """
            if usesComposeIndex {
                exactComposeSQL = """
                    SELECT e.surface, c.canonical_reading, c.rank_score, c.alias_penalty, c.separator_penalty
                    FROM reading_compose_index c
                    JOIN entries e ON e.id = c.entry_id
                    WHERE c.compose_reading = ?1
                    ORDER BY c.separator_penalty ASC, c.alias_penalty ASC, c.rank_score DESC
                    LIMIT 20
                    """
            } else {
                exactComposeSQL = """
                    SELECT e.surface, a.canonical_reading, a.rank_score, a.alias_penalty,
                           (LENGTH(a.alias_reading) - LENGTH(REPLACE(REPLACE(a.alias_reading, '+', ''), '''', ''))) AS separator_penalty
                    FROM reading_alias_index a
                    JOIN entries e ON e.id = a.entry_id
                    WHERE REPLACE(REPLACE(a.alias_reading, '+', ''), '''', '') = ?1
                    ORDER BY separator_penalty ASC, a.alias_penalty ASC, a.rank_score DESC
                    LIMIT 20
                    """
            }
        } else {
            exactAliasSQL = """
                SELECT e.surface, r.canonical_reading, r.rank_score,
                       (LENGTH(r.canonical_reading) - LENGTH(REPLACE(REPLACE(r.canonical_reading, '2', ''), '3', ''))) AS alias_penalty
                FROM reading_index r
                JOIN entries e ON e.id = r.entry_id
                WHERE REPLACE(REPLACE(r.canonical_reading, '2', ''), '3', '') = ?1
                ORDER BY alias_penalty ASC, r.rank_score DESC
                LIMIT 20
                """
            exactComposeSQL = """
                SELECT e.surface, r.canonical_reading, r.rank_score,
                       (LENGTH(r.canonical_reading) - LENGTH(REPLACE(REPLACE(r.canonical_reading, '2', ''), '3', ''))) AS alias_penalty,
                       (LENGTH(r.canonical_reading) - LENGTH(REPLACE(REPLACE(r.canonical_reading, '+', ''), '''', ''))) AS separator_penalty
                FROM reading_index r
                JOIN entries e ON e.id = r.entry_id
                WHERE REPLACE(REPLACE(REPLACE(REPLACE(r.canonical_reading, '+', ''), '''', ''), '2', ''), '3', '') = ?1
                ORDER BY separator_penalty ASC, alias_penalty ASC, r.rank_score DESC
                LIMIT 20
                """
        }

        if sqlite3_prepare_v2(db, exactAliasSQL, -1, &exactAliasStmt, nil) != SQLITE_OK {
            sqlite3_finalize(prefixStmt); prefixStmt = nil
            sqlite3_finalize(composePrefixStmt); composePrefixStmt = nil
            return false
        }
        if sqlite3_prepare_v2(db, exactComposeSQL, -1, &exactComposeStmt, nil) != SQLITE_OK {
            sqlite3_finalize(prefixStmt); prefixStmt = nil
            sqlite3_finalize(composePrefixStmt); composePrefixStmt = nil
            sqlite3_finalize(exactAliasStmt); exactAliasStmt = nil
            return false
        }

        return true
    }

    private func lookupExactAlias(reading: String) -> [Candidate] {
        guard !reading.isEmpty, let stmt = exactAliasStmt else { return [] }
        defer { sqlite3_reset(stmt) }

        sqlite3_bind_text(stmt, 1, reading, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var results: [Candidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let surface = String(cString: sqlite3_column_text(stmt, 0))
            let readingStr = String(cString: sqlite3_column_text(stmt, 1))
            let rankScore = sqlite3_column_double(stmt, 2)
            let aliasPenalty = Int(sqlite3_column_int(stmt, 3))
            results.append(Candidate(
                surface: surface,
                reading: readingStr,
                source: .lexicon,
                score: rankScore - Double(aliasPenalty) * 1000.0
            ))
        }
        return results
    }

    private func lookupExactAliasWithPenalty(reading: String) -> [(candidate: Candidate, aliasPenalty: Int)] {
        guard !reading.isEmpty, let stmt = exactAliasStmt else { return [] }
        defer { sqlite3_reset(stmt) }

        sqlite3_bind_text(stmt, 1, reading, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var results: [(candidate: Candidate, aliasPenalty: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let surface = String(cString: sqlite3_column_text(stmt, 0))
            let readingStr = String(cString: sqlite3_column_text(stmt, 1))
            let rankScore = sqlite3_column_double(stmt, 2)
            let aliasPenalty = Int(sqlite3_column_int(stmt, 3))
            results.append((
                Candidate(surface: surface, reading: readingStr, source: .lexicon, score: rankScore),
                aliasPenalty
            ))
        }
        return results
    }

    private func lookupExactComposeWithPenalty(reading: String) -> [(candidate: Candidate, aliasPenalty: Int)] {
        guard !reading.isEmpty, let stmt = exactComposeStmt else { return [] }
        defer { sqlite3_reset(stmt) }

        sqlite3_bind_text(stmt, 1, reading, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var results: [(candidate: Candidate, aliasPenalty: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let surface = String(cString: sqlite3_column_text(stmt, 0))
            let readingStr = String(cString: sqlite3_column_text(stmt, 1))
            let rankScore = sqlite3_column_double(stmt, 2)
            let aliasPenalty = Int(sqlite3_column_int(stmt, 3))
            // Column 4 is separator_penalty — intentionally ignored here;
            // separator count is a reading-shape concern that the
            // lattice's contiguous-arc traversal already handles.
            results.append((
                Candidate(surface: surface, reading: readingStr, source: .lexicon, score: rankScore),
                aliasPenalty
            ))
        }
        return results
    }

    private func lookupExactCompose(reading: String) -> [Candidate] {
        guard !reading.isEmpty, let stmt = exactComposeStmt else { return [] }
        defer { sqlite3_reset(stmt) }

        sqlite3_bind_text(stmt, 1, reading, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var results: [Candidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let surface = String(cString: sqlite3_column_text(stmt, 0))
            let readingStr = String(cString: sqlite3_column_text(stmt, 1))
            let rankScore = sqlite3_column_double(stmt, 2)
            let aliasPenalty = Int(sqlite3_column_int(stmt, 3))
            let separatorPenalty = Int(sqlite3_column_int(stmt, 4))
            results.append(Candidate(
                surface: surface,
                reading: readingStr,
                source: .lexicon,
                score: rankScore - Double(aliasPenalty) * 1000.0 - Double(separatorPenalty) * 250.0
            ))
        }
        return results
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

        // Mirror the LexiconBuilder's composite indexes — covering the
        // runtime `ORDER BY` clauses so short prefix lookups don't pay
        // the ~60 ms temp-B-tree sort cost (see LexiconBuilder comment).
        if createAliasIndex,
           !exec(
            "CREATE INDEX idx_reading_alias ON reading_alias_index (alias_reading, alias_penalty, rank_score DESC)",
            in: lookupDB
        ) {
            sqlite3_close(lookupDB)
            return nil
        }

        if createComposeIndex,
           !exec(
            "CREATE INDEX idx_reading_compose ON reading_compose_index (compose_reading, separator_penalty, alias_penalty, rank_score DESC)",
            in: lookupDB
        ) {
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

            if createAliasIndex, let insertAliasStmt {
                for variant in Romanization.indexedAliasReadings(for: reading) {
                    sqlite3_bind_text(insertAliasStmt, 1, variant.aliasReading, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(insertAliasStmt, 2, reading, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_int64(insertAliasStmt, 3, entryID)
                    sqlite3_bind_double(insertAliasStmt, 4, rankScore)
                    sqlite3_bind_int(insertAliasStmt, 5, Int32(variant.aliasPenalty))

                    guard sqlite3_step(insertAliasStmt) == SQLITE_DONE else {
                        return false
                    }
                    sqlite3_reset(insertAliasStmt)
                    sqlite3_clear_bindings(insertAliasStmt)
                }
            }

            if createComposeIndex, let insertComposeStmt {
                for variant in Romanization.indexedComposeReadings(for: reading) {
                    sqlite3_bind_text(insertComposeStmt, 1, variant.composeReading, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(insertComposeStmt, 2, reading, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_int64(insertComposeStmt, 3, entryID)
                    sqlite3_bind_double(insertComposeStmt, 4, rankScore)
                    sqlite3_bind_int(insertComposeStmt, 5, Int32(variant.aliasPenalty))
                    sqlite3_bind_int(insertComposeStmt, 6, Int32(variant.separatorPenalty))

                    guard sqlite3_step(insertComposeStmt) == SQLITE_DONE else {
                        return false
                    }
                    sqlite3_reset(insertComposeStmt)
                    sqlite3_clear_bindings(insertComposeStmt)
                }
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

    private func applyLookupPenalty(_ candidates: [Candidate], _ penalty: Int) -> [Candidate] {
        guard penalty > 0 else { return candidates }
        let scorePenalty = Double(penalty) * 1000.0
        return candidates.map {
            Candidate(
                surface: $0.surface,
                reading: $0.reading,
                source: $0.source,
                score: $0.score - scorePenalty
            )
        }
    }
}
