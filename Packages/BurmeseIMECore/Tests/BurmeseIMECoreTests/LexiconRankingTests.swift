import XCTest
@testable import BurmeseIMECore
#if canImport(SQLite3)
import SQLite3
#endif

/// Tests for lexicon-based frequency ranking of conversion candidates.
///
/// Covers three layers:
/// - In-engine ordering between lexicon candidates (match quality, alias
///   penalty, lexicon frequency).
/// - Merge-slot priority between lexicon and grammar candidates in
///   `BurmeseEngine.update`.
/// - Score formulas and dedup behavior in `SQLiteCandidateStore`.
final class LexiconRankingTests: XCTestCase {

    // MARK: - Fixtures

    private struct FixedCandidateStore: CandidateStore {
        var byPrefix: [String: [Candidate]] = [:]
        var byBigram: [String: [String: [Candidate]]] = [:]

        func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
            var results: [Candidate] = []
            if let prev = previousSurface, let bigramHits = byBigram[prev]?[prefix] {
                results += bigramHits
            }
            if let hits = byPrefix[prefix] {
                results += hits
            }
            return results
        }
    }

    // MARK: - A. Ordering among lexicon candidates

    func testLexiconOrdering_higherFrequencyFirst() {
        // Both readings have aliasPenalty 0 and aliasReading == aliasPrefix
        // (match quality 2), so only score breaks the tie.
        let store = FixedCandidateStore(byPrefix: [
            "kyar": [
                Candidate(surface: "ကျား", reading: "kyar", source: .lexicon, score: 400),
                Candidate(surface: "ကြား", reading: "kyar", source: .lexicon, score: 900),
            ]
        ])
        let engine = BurmeseEngine(candidateStore: store)
        let state = engine.update(buffer: "kyar", context: [])

        let lexicon = state.candidates.filter { $0.source == .lexicon }
        guard lexicon.count >= 2 else {
            XCTFail("Expected both lexicon candidates in panel, got \(lexicon)")
            return
        }
        let first = lexicon.firstIndex(where: { $0.surface == "ကြား" })
        let second = lexicon.firstIndex(where: { $0.surface == "ကျား" })
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertLessThan(first!, second!, "Higher-frequency lexicon candidate must come first")
    }

    func testLexiconOrdering_aliasPenaltyBeatsFrequency() {
        // Buffer "kyar:" → aliasPrefix "kyar:". Both candidates have
        // aliasReading == "kyar:" (match quality 2), so the tiebreak falls
        // through to aliasPenalty (preferred lower) before score. Surfaces
        // are chosen to not collide with grammar output so the
        // lexicon-specific sort path is exercised.
        struct AnyPrefixStore: CandidateStore {
            let results: [Candidate]
            func lookup(prefix: String, previousSurface: String?) -> [Candidate] { results }
        }
        let store = AnyPrefixStore(results: [
            Candidate(surface: "HIGH", reading: "ky2ar:", source: .lexicon, score: 1500),
            Candidate(surface: "LOW", reading: "kyar:", source: .lexicon, score: 800),
        ])
        let engine = BurmeseEngine(candidateStore: store)
        let state = engine.update(buffer: "kyar:", context: [])

        let lexicon = state.candidates.filter { $0.source == .lexicon }
        XCTAssertEqual(lexicon.first?.surface, "LOW",
            "Zero-alias-penalty candidate must outrank higher-frequency penalized candidate")
    }

    func testLexiconOrdering_exactAliasBeatsComposeMatchQuality() {
        // Buffer "min+galarpar" makes aliasPrefix = "min+galarpar" and
        // composePrefix = "mingalarpar". Two fixture entries:
        //   A: alias_reading == aliasPrefix (match quality 2)
        //   B: alias_reading != aliasPrefix, compose_reading == composePrefix (quality 1)
        // A must come first regardless of score.
        let store = FixedCandidateStore(byPrefix: [
            "min+galarpar": [
                Candidate(surface: "Bmin", reading: "mingalarpar2", source: .lexicon, score: 2000),
                Candidate(surface: "Amin", reading: "min+galarpar2", source: .lexicon, score: 600),
            ]
        ])
        let engine = BurmeseEngine(candidateStore: store)
        let state = engine.update(buffer: "min+galarpar", context: [])

        let lexicon = state.candidates.filter { $0.source == .lexicon }
        guard lexicon.count >= 2 else {
            XCTFail("Expected both lexicon candidates; got \(lexicon)")
            return
        }
        XCTAssertEqual(lexicon.first?.surface, "Amin",
            "Exact-alias match must outrank exact-compose match regardless of score")
    }

    // MARK: - B. Merge-slot priority

    func testMerge_exactAliasLexiconFillsSlotsZeroAndOne() {
        // Both readings alias to "min+galarpar" (exact-alias match, quality 2),
        // so both qualify for the prioritized lexicon slots 0 and 1.
        let store = FixedCandidateStore(byPrefix: [
            "min+galarpar": [
                Candidate(surface: "AA", reading: "min+galarpar2", source: .lexicon, score: 1000),
                Candidate(surface: "BB", reading: "min+galarpar3", source: .lexicon, score: 900),
            ]
        ])
        let engine = BurmeseEngine(candidateStore: store)
        let state = engine.update(buffer: "min+galarpar", context: [])

        XCTAssertGreaterThanOrEqual(state.candidates.count, 3)
        XCTAssertEqual(state.candidates[0].source, .lexicon)
        XCTAssertEqual(state.candidates[1].source, .lexicon)
        XCTAssertEqual(state.candidates[0].surface, "AA")
        XCTAssertEqual(state.candidates[1].surface, "BB")
    }

    func testMerge_onlyExactComposeWhenNoExactAlias() {
        // Buffer "mingalarpar" has aliasPrefix == composePrefix == "mingalarpar".
        // Entry's alias_reading is "min+galarpar2" → aliasReading becomes
        // "min+galarpar" (digits stripped) which does NOT equal the prefix
        // (the prefix has no '+'). composeReading strips separators and
        // matches. So this is a compose-only match.
        let store = FixedCandidateStore(byPrefix: [
            "mingalarpar": [
                Candidate(surface: "မင်္ဂလာပါ", reading: "min+galarpar2", source: .lexicon, score: 1000),
            ]
        ])
        let engine = BurmeseEngine(candidateStore: store)
        let state = engine.update(buffer: "mingalarpar", context: [])

        XCTAssertEqual(state.candidates.first?.surface, "မင်္ဂလာပါ")
        XCTAssertEqual(state.candidates.first?.source, .lexicon)
    }

    func testMerge_trailingLexiconDoesNotDisplacePrimaryGrammar() {
        // A lexicon candidate with neither exact-alias nor exact-compose
        // match (surface distinct from any grammar output) must come after
        // the top-3 grammar candidates, not before them.
        let store = FixedCandidateStore(byPrefix: [
            "thar": [
                Candidate(surface: "FakeLexicon", reading: "tharx", source: .lexicon, score: 999),
            ]
        ])
        let engine = BurmeseEngine(candidateStore: store)
        let state = engine.update(buffer: "thar", context: [])

        guard let lexIndex = state.candidates.firstIndex(where: { $0.surface == "FakeLexicon" }) else {
            // Acceptable: page was filled by grammar and the trailing
            // lexicon didn't make the cut.
            return
        }
        let firstGrammarIndex = state.candidates.firstIndex(where: { $0.source == .grammar })
        XCTAssertNotNil(firstGrammarIndex)
        XCTAssertLessThan(firstGrammarIndex!, lexIndex,
            "Non-exact lexicon must not displace primary grammar candidates")
    }

    func testMerge_lexiconSurfaceMatchingGrammarIsMergedNotDuplicated() {
        // "thar" parses to သာ. Lexicon returns the same surface; engine must
        // merge (not emit a duplicate and not expose a .lexicon entry with
        // that surface).
        let store = FixedCandidateStore(byPrefix: [
            "thar": [
                Candidate(surface: "သာ", reading: "thar", source: .lexicon, score: 750),
            ]
        ])
        let engine = BurmeseEngine(candidateStore: store)
        let state = engine.update(buffer: "thar", context: [])

        let matches = state.candidates.filter { $0.surface == "သာ" }
        XCTAssertEqual(matches.count, 1, "Grammar+lexicon surface match must not duplicate")
        XCTAssertEqual(matches.first?.source, .grammar,
            "Merged candidate keeps grammar source")
    }

    func testMerge_pageSizeNeverExceedsLimit() {
        let store = FixedCandidateStore(byPrefix: [
            "kyar": [
                Candidate(surface: "ကြား", reading: "kyar:", source: .lexicon, score: 900),
                Candidate(surface: "ကျား", reading: "ky2ar:", source: .lexicon, score: 800),
                Candidate(surface: "ExtraA", reading: "kyarx1", source: .lexicon, score: 700),
                Candidate(surface: "ExtraB", reading: "kyarx2", source: .lexicon, score: 600),
                Candidate(surface: "ExtraC", reading: "kyarx3", source: .lexicon, score: 500),
            ]
        ])
        let engine = BurmeseEngine(candidateStore: store)
        let state = engine.update(buffer: "kyar", context: [])

        XCTAssertLessThanOrEqual(state.candidates.count, BurmeseEngine.candidatePageSize)
    }

    // MARK: - C. SQLite score formula verification

    private struct LexiconRow {
        var id: Int64
        var surface: String
        var canonicalReading: String
        var unigramScore: Double
    }

    private func makeInMemoryStore(
        entries: [LexiconRow],
        bigrams: [(prev: String, entryID: Int64, score: Double)] = []
    ) throws -> (url: URL, store: SQLiteCandidateStore) {
        #if canImport(SQLite3)
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            throw NSError(domain: "LexiconRankingTests", code: 1)
        }
        defer { sqlite3_close(db) }

        let schema = """
            CREATE TABLE entries (
                id INTEGER PRIMARY KEY,
                surface TEXT NOT NULL,
                canonical_reading TEXT NOT NULL,
                unigram_score REAL NOT NULL
            );
            CREATE TABLE reading_index (
                canonical_reading TEXT NOT NULL,
                entry_id INTEGER NOT NULL REFERENCES entries(id),
                rank_score REAL NOT NULL
            );
            CREATE TABLE bigram_context (
                prev_surface TEXT NOT NULL,
                next_entry_id INTEGER NOT NULL REFERENCES entries(id),
                score REAL NOT NULL
            );
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "LexiconRankingTests", code: 2)
        }

        for row in entries {
            let sql = """
                INSERT INTO entries (id, surface, canonical_reading, unigram_score)
                VALUES (\(row.id), '\(row.surface)', '\(row.canonicalReading)', \(row.unigramScore));
                INSERT INTO reading_index (canonical_reading, entry_id, rank_score)
                VALUES ('\(row.canonicalReading)', \(row.id), \(row.unigramScore));
                """
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "LexiconRankingTests", code: 3)
            }
        }

        for bigram in bigrams {
            let sql = """
                INSERT INTO bigram_context (prev_surface, next_entry_id, score)
                VALUES ('\(bigram.prev)', \(bigram.entryID), \(bigram.score));
                """
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "LexiconRankingTests", code: 4)
            }
        }

        guard let store = SQLiteCandidateStore(path: dbURL.path) else {
            throw NSError(domain: "LexiconRankingTests", code: 5)
        }
        return (dbURL, store)
        #else
        throw XCTSkip("SQLite3 is unavailable in this environment")
        #endif
    }

    func testScore_aliasPenaltyApplied() throws {
        // canonical_reading "kyar:" contains no '2'/'3' digits so alias
        // penalty is 0. Use "ky2ar:" (one digit) to get penalty 1 → −1000.
        let (url, store) = try makeInMemoryStore(entries: [
            LexiconRow(id: 1, surface: "ကျား", canonicalReading: "ky2ar:", unigramScore: 500.0)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let result = store.lookup(prefix: "kyar:", previousSurface: nil)
        guard let hit = result.first(where: { $0.surface == "ကျား" }) else {
            XCTFail("Expected lookup hit; got \(result)")
            return
        }
        XCTAssertEqual(hit.score, 500.0 - 1000.0, accuracy: 0.001,
            "rank_score - aliasPenalty * 1000")
    }

    func testScore_separatorPenaltyAppliedOnComposeMatch() throws {
        // canonical_reading "min+galarpar2" has 1 separator ('+') and 1 digit
        // ('2'). Looking up compose key "mingalarpar" (no separators, no
        // digits) should yield: rank_score − 1·1000 − 1·250.
        let (url, store) = try makeInMemoryStore(entries: [
            LexiconRow(id: 1, surface: "မင်္ဂလာပါ", canonicalReading: "min+galarpar2", unigramScore: 1000.0)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let result = store.lookup(prefix: "mingalarpar", previousSurface: nil)
        guard let hit = result.first(where: { $0.surface == "မင်္ဂလာပါ" }) else {
            XCTFail("Expected compose-path hit; got \(result)")
            return
        }
        XCTAssertEqual(hit.score, 1000.0 - 1000.0 - 250.0, accuracy: 0.001)
    }

    func testScore_bigramBonusApplied() throws {
        let (url, store) = try makeInMemoryStore(
            entries: [
                LexiconRow(id: 1, surface: "ကျား", canonicalReading: "kyar:", unigramScore: 500.0)
            ],
            bigrams: [(prev: "ကြီး", entryID: 1, score: 500.0)]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let withContext = store.lookup(prefix: "kyar:", previousSurface: "ကြီး")
        guard let bigramHit = withContext.first else {
            XCTFail("Expected at least one candidate with bigram context")
            return
        }
        // Bigram: rank_score (500) + 500 − aliasPenalty(0)·1000 = 1000.
        // (Dedup keeps the first — the bigram row — because it's queried first.)
        XCTAssertEqual(bigramHit.score, 500.0 + 500.0, accuracy: 0.001,
            "Bigram bonus +500 must be applied")
    }

    func testDedup_bigramHitWinsOverPlainPrefixHit() throws {
        // Same entry matched by both bigram and plain prefix queries. The
        // deduplicator keeps whichever is first; SQLiteCandidateStore runs
        // the bigram query first, so the higher-scoring bigram candidate
        // must survive dedup.
        let (url, store) = try makeInMemoryStore(
            entries: [
                LexiconRow(id: 1, surface: "ကျား", canonicalReading: "kyar:", unigramScore: 400.0)
            ],
            bigrams: [(prev: "ကြီး", entryID: 1, score: 400.0)]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let results = store.lookup(prefix: "kyar:", previousSurface: "ကြီး")
        let matches = results.filter { $0.surface == "ကျား" }
        XCTAssertEqual(matches.count, 1, "Duplicate entries must be deduped")
        // Must be the bigram-bonused score, not the plain prefix score.
        XCTAssertEqual(matches.first?.score, 400.0 + 500.0, accuracy: 0.001,
            "Dedup must retain the higher-scoring bigram candidate, not the plain prefix hit")
    }

    // MARK: - D. Real-lexicon sanity

    private func bundledLexiconURL() -> URL? {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dbURL = repoRoot.appendingPathComponent("native/macos/Data/BurmeseLexicon.sqlite")
        return FileManager.default.fileExists(atPath: dbURL.path) ? dbURL : nil
    }

    func testRealLexicon_commonGreetingSurfacesAtTop() throws {
        guard let url = bundledLexiconURL() else {
            throw XCTSkip("Bundled lexicon unavailable")
        }
        guard let store = SQLiteCandidateStore(path: url.path) else {
            XCTFail("Expected lexicon to open")
            return
        }
        let engine = BurmeseEngine(candidateStore: store)
        let state = engine.update(buffer: "mingalarpar", context: [])

        let top2 = Array(state.candidates.prefix(2))
        XCTAssertTrue(
            top2.contains(where: { $0.surface == "မင်္ဂလာပါ" }),
            "Expected မင်္ဂလာပါ in top 2; got \(state.candidates.map(\.surface))"
        )
    }

    /// Common high-frequency words that should appear in the top of the
    /// candidate panel when their typed form is composed. The typed form is
    /// derived by stripping digit disambiguators and syllable separators
    /// from the canonical reading (i.e. the compose-lookup key), which is
    /// what a casual user is most likely to type.
    private static let commonWordCases: [(surface: String, frequency: Int)] = [
        ("မင်္ဂလာပါ", 10000),
        ("သို့", 9444),
        ("ပါ", 9200),
        ("မင်္ဂလာ", 9000),
        ("မြန်မာ", 9000),
        ("သာ", 9000),
        ("သည်", 8729),
        ("ကို", 8522),
        ("ကောင်း", 8500),
        ("လူ", 8460),
        ("နှင့်", 8380),
    ]

    func testRealLexicon_commonWordsRankInTopCandidates() throws {
        guard let url = bundledLexiconURL() else {
            throw XCTSkip("Bundled lexicon unavailable")
        }
        guard let store = SQLiteCandidateStore(path: url.path) else {
            XCTFail("Expected lexicon to open")
            return
        }
        let engine = BurmeseEngine(candidateStore: store)

        for testCase in Self.commonWordCases {
            let canonical = ReverseRomanizer.romanize(testCase.surface)
            let typed = Romanization.composeLookupKey(canonical)
            guard !typed.isEmpty else {
                XCTFail("Empty typed key for \(testCase.surface)")
                continue
            }
            let state = engine.update(buffer: typed, context: [])
            let top3 = Array(state.candidates.prefix(3)).map(\.surface)
            XCTAssertTrue(
                top3.contains(testCase.surface),
                "Expected \(testCase.surface) (freq \(testCase.frequency)) in top 3 for typed '\(typed)'; got \(top3)"
            )
        }
    }

    func testRealLexicon_higherFrequencyOutranksLowerForSharedReading() throws {
        guard let url = bundledLexiconURL() else {
            throw XCTSkip("Bundled lexicon unavailable")
        }
        guard let store = SQLiteCandidateStore(path: url.path) else {
            XCTFail("Expected lexicon to open")
            return
        }
        // Pairs of (higher-frequency, lower-frequency) surfaces that share
        // a typed prefix. The higher-frequency entry must appear at an
        // earlier index in the raw store lookup than the lower-frequency one.
        let typedPrefix = "mingalarpar"
        let rawResults = store.lookup(prefix: typedPrefix, previousSurface: nil)
        let surfaces = rawResults.map(\.surface)
        guard
            let commonIdx = surfaces.firstIndex(of: "မင်္ဂလာပါ")
        else {
            XCTFail("Expected မင်္ဂလာပါ in lookup results for '\(typedPrefix)'")
            return
        }
        // Any "မင်္ဂလာပါ…" continuation must appear at or after the base
        // (its frequency can't exceed 10000).
        for (i, surface) in surfaces.enumerated() where surface != "မင်္ဂလာပါ" && surface.hasPrefix("မင်္ဂလာပါ") {
            XCTAssertGreaterThanOrEqual(i, commonIdx,
                "High-frequency base word မင်္ဂလာပါ must not be outranked by its longer continuation \(surface)")
        }
    }

    func testRealLexicon_singleSyllableCommonWordReachable() throws {
        // "ပါ" is a very common particle (freq 9200). Typing just "par"
        // must expose it somewhere in the panel — not necessarily at the
        // top (grammar takes slot 0 for a single-syllable parse), but it
        // must be present.
        guard let url = bundledLexiconURL() else {
            throw XCTSkip("Bundled lexicon unavailable")
        }
        guard let store = SQLiteCandidateStore(path: url.path) else {
            XCTFail("Expected lexicon to open")
            return
        }
        let engine = BurmeseEngine(candidateStore: store)
        let state = engine.update(buffer: "par", context: [])
        let surfaces = state.candidates.map(\.surface)
        XCTAssertTrue(surfaces.contains("ပါ"),
            "Expected ပါ in panel for 'par'; got \(surfaces)")
    }

    func testRealLexicon_higherFrequencyWinsAmongLexiconHits() throws {
        guard let url = bundledLexiconURL() else {
            throw XCTSkip("Bundled lexicon unavailable")
        }
        guard let store = SQLiteCandidateStore(path: url.path) else {
            XCTFail("Expected lexicon to open")
            return
        }
        // Raw lookup: among lexicon candidates for a common prefix, the
        // ordering must be monotonic non-increasing by score after the
        // engine applies its match-quality/alias-penalty layers. Here we
        // verify the store's own output is already score-sorted within each
        // (match quality, alias penalty) bucket.
        let results = store.lookup(prefix: "thar", previousSurface: nil)
        XCTAssertFalse(results.isEmpty, "Expected lexicon hits for 'thar'")
        // Scores within the first-returned bucket should be non-increasing.
        // (The store emits prefix results sorted by alias_penalty ASC,
        // rank_score DESC.)
        var lastScore = Double.infinity
        var lastPenalty = -1
        for candidate in results {
            let penalty = Romanization.aliasPenaltyCount(for: candidate.reading)
            if penalty != lastPenalty {
                lastPenalty = penalty
                lastScore = Double.infinity
                continue
            }
            XCTAssertLessThanOrEqual(candidate.score, lastScore + 0.001,
                "Within an alias-penalty bucket, scores must be non-increasing")
            lastScore = candidate.score
        }
    }
}
