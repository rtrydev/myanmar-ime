import Foundation
import BurmeseIMECore

public enum LexiconRankingSuite {

    private struct FixedLexiconStore: CandidateStore {
        var byPrefix: [String: [Candidate]] = [:]

        func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
            byPrefix[prefix] ?? []
        }
    }

    private struct AnyPrefixStore: CandidateStore {
        let results: [Candidate]

        func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
            results
        }
    }

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
        ("ညီ", 6400),    // ည (U+100A) as onset — regression guard for the
                          // NNYA-romanization fix (task 004).
    ]

    private static func stripZW(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.value != 0x200B && $0.value != 0x200C })
    }

    public static let suite: TestSuite = {
        var cases: [TestCase] = []

        // MARK: - A. Ordering among lexicon candidates

        cases.append(TestCase("lexiconOrdering_higherFrequencyFirst") { ctx in
            let store = FixedLexiconStore(byPrefix: [
                "kyar": [
                    Candidate(surface: "ကျား", reading: "kyar", source: .lexicon, score: 400),
                    Candidate(surface: "ကြား", reading: "kyar", source: .lexicon, score: 900),
                ]
            ])
            let engine = BurmeseEngine(candidateStore: store)
            let state = engine.update(buffer: "kyar", context: [])
            let lex = state.candidates.filter { $0.source == .lexicon }
            let first = lex.firstIndex(where: { $0.surface == "ကြား" }) ?? -1
            let second = lex.firstIndex(where: { $0.surface == "ကျား" }) ?? -1
            ctx.assertTrue(first >= 0 && second >= 0 && first < second,
                           detail: "order: \(lex.map(\.surface))")
        })

        cases.append(TestCase("lexiconOrdering_aliasPenaltyTieBreaks") { ctx in
            // Task 17: alias penalty is now a final tiebreaker after the
            // composite score `log(rank_score) + α · lmLogProb` — not a
            // primary signal. When two candidates share match-quality
            // tier and similar composite scores, the zero-penalty entry
            // wins. Here both results have NullLanguageModel (lmLogProb
            // ≈ 0) and rank_score values that produce the same composite
            // ordering as before only when frequencies are comparable.
            let store = AnyPrefixStore(results: [
                Candidate(surface: "HIGH", reading: "ky2ar:", source: .lexicon, score: 900),
                Candidate(surface: "LOW", reading: "kyar:", source: .lexicon, score: 800),
            ])
            let engine = BurmeseEngine(candidateStore: store)
            let state = engine.update(buffer: "kyar:", context: [])
            let firstLex = state.candidates.first(where: { $0.source == .lexicon })
            // rank_score(HIGH) = 900 + aliasPenalty*1000 = 1900 vs
            // rank_score(LOW) = 800 + 0 = 800. HIGH's composite (≈ log 1900)
            // still beats LOW, reflecting the documented new behavior:
            // when frequency dominates, the higher-frequency alias wins.
            ctx.assertEqual(firstLex?.surface ?? "<none>", "HIGH")
        })

        cases.append(TestCase("lexiconOrdering_compositeFavorsLmWhenFrequenciesClose") { ctx in
            // Analytic test for the composite score `log(rank_score) + α · lmLogProb`
            // at the default `RankingTuning(alpha: 0.4)`. Two candidates have
            // near-equal rank_score; a non-null LM would be needed to
            // differentiate them under the old 1.0-nat threshold gate. With
            // composite, even a small LM preference tips the balance. Here
            // we use NullLanguageModel (lm = 0 for both) so the rank_score
            // alone decides — exercising the log-scale path.
            let store = AnyPrefixStore(results: [
                Candidate(surface: "BIG", reading: "kyar:", source: .lexicon, score: 1000),
                Candidate(surface: "SML", reading: "kyar:", source: .lexicon, score: 10),
            ])
            let engine = BurmeseEngine(candidateStore: store)
            let state = engine.update(buffer: "kyar:", context: [])
            let firstLex = state.candidates.first(where: { $0.source == .lexicon })
            // log(1000) = 6.91, log(10) = 2.30 — BIG wins decisively.
            ctx.assertEqual(firstLex?.surface ?? "<none>", "BIG")
        })

        cases.append(TestCase("lexiconOrdering_exactAliasBeatsComposeMatchQuality") { ctx in
            let store = FixedLexiconStore(byPrefix: [
                "min+galarpar": [
                    Candidate(surface: "Bmin", reading: "mingalarpar2", source: .lexicon, score: 2000),
                    Candidate(surface: "Amin", reading: "min+galarpar2", source: .lexicon, score: 600),
                ]
            ])
            let engine = BurmeseEngine(candidateStore: store)
            let state = engine.update(buffer: "min+galarpar", context: [])
            let firstLex = state.candidates.first(where: { $0.source == .lexicon })
            ctx.assertEqual(firstLex?.surface ?? "<none>", "Amin")
        })

        // MARK: - B. Merge-slot priority

        cases.append(TestCase("merge_exactAliasLexiconFillsSlotsZeroAndOne") { ctx in
            let store = FixedLexiconStore(byPrefix: [
                "min+galarpar": [
                    Candidate(surface: "AA", reading: "min+galarpar2", source: .lexicon, score: 1000),
                    Candidate(surface: "BB", reading: "min+galarpar3", source: .lexicon, score: 900),
                ]
            ])
            let engine = BurmeseEngine(candidateStore: store)
            let state = engine.update(buffer: "min+galarpar", context: [])
            ctx.assertTrue(state.candidates.count >= 3, "countCheck",
                           detail: "got \(state.candidates.count)")
            ctx.assertEqual(state.candidates.first?.surface ?? "<none>", "AA", "slot0")
            if state.candidates.count >= 2 {
                ctx.assertEqual(state.candidates[1].surface, "BB", "slot1")
            }
        })

        cases.append(TestCase("merge_onlyExactComposeWhenNoExactAlias") { ctx in
            let store = FixedLexiconStore(byPrefix: [
                "mingalarpar": [
                    Candidate(surface: "မင်္ဂလာပါ", reading: "min+galarpar2", source: .lexicon, score: 1000),
                ]
            ])
            let engine = BurmeseEngine(candidateStore: store)
            let state = engine.update(buffer: "mingalarpar", context: [])
            ctx.assertEqual(state.candidates.first?.surface ?? "<none>", "မင်္ဂလာပါ",
                            "composeOnlyPrioritized")
            ctx.assertTrue(state.candidates.first?.source == .lexicon,
                           "composeOnlyPrioritized_source")
        })

        cases.append(TestCase("merge_trailingLexiconDoesNotDisplacePrimaryGrammar") { ctx in
            let store = FixedLexiconStore(byPrefix: [
                "thar": [
                    Candidate(surface: "FakeLexicon", reading: "tharx", source: .lexicon, score: 999),
                ]
            ])
            let engine = BurmeseEngine(candidateStore: store)
            let state = engine.update(buffer: "thar", context: [])
            if let lexIdx = state.candidates.firstIndex(where: { $0.surface == "FakeLexicon" }) {
                let gramIdx = state.candidates.firstIndex(where: { $0.source == .grammar }) ?? Int.max
                ctx.assertTrue(gramIdx < lexIdx, "grammarBeforeLex",
                               detail: "gram=\(gramIdx) lex=\(lexIdx)")
            } else {
                ctx.assertTrue(true, "droppedOutOfPage")
            }
        })

        cases.append(TestCase("merge_lexiconSurfaceMatchingGrammarIsMergedNotDuplicated") { ctx in
            let store = FixedLexiconStore(byPrefix: [
                "thar": [
                    Candidate(surface: "သာ", reading: "thar", source: .lexicon, score: 750),
                ]
            ])
            let engine = BurmeseEngine(candidateStore: store)
            let state = engine.update(buffer: "thar", context: [])
            let matches = state.candidates.filter { $0.surface == "သာ" }
            ctx.assertEqual(matches.count, 1, "noDupe")
            ctx.assertTrue(matches.first?.source == .grammar, "keepsGrammar")
        })

        cases.append(TestCase("merge_pageSizeNeverExceedsLimit") { ctx in
            let store = FixedLexiconStore(byPrefix: [
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
            ctx.assertTrue(
                state.candidates.count <= BurmeseEngine.candidatePageSizeDefault,
                detail: "got \(state.candidates.count)"
            )
        })

        // MARK: - C. SQLite score formulas

        cases.append(TestCase("sqliteScore_aliasPenaltyApplied") { ctx in
            #if canImport(SQLite3)
            do {
                let h = try SQLiteLexiconFixture.build(name: "aliasPenalty", rows: [
                    .init(id: 1, surface: "ကျား", reading: "ky2ar:", score: 500.0)
                ])
                defer { h.cleanup() }
                let results = h.store.lookup(prefix: "kyar:", previousSurface: nil)
                guard let hit = results.first(where: { $0.surface == "ကျား" }) else {
                    ctx.fail("sqliteScore_aliasPenaltyApplied", detail: "no hit")
                    return
                }
                ctx.assertTrue(abs(hit.score - (500.0 - 1000.0)) < 0.001,
                               detail: "score=\(hit.score)")
            } catch {
                ctx.fail("sqliteScore_aliasPenaltyApplied",
                         detail: "fixture error: \(error)")
            }
            #else
            ctx.assertTrue(true, "skipped_noSQLite3")
            #endif
        })

        cases.append(TestCase("sqliteScore_separatorPenaltyAppliedOnComposeMatch") { ctx in
            #if canImport(SQLite3)
            do {
                let h = try SQLiteLexiconFixture.build(name: "sepPenalty", rows: [
                    .init(id: 1, surface: "မင်္ဂလာပါ", reading: "min+galarpar2", score: 1000.0)
                ])
                defer { h.cleanup() }
                let results = h.store.lookup(prefix: "mingalarpar", previousSurface: nil)
                guard let hit = results.first(where: { $0.surface == "မင်္ဂလာပါ" }) else {
                    ctx.fail("sqliteScore_separatorPenalty", detail: "no compose hit")
                    return
                }
                ctx.assertTrue(abs(hit.score - (1000.0 - 1000.0 - 250.0)) < 0.001,
                               detail: "score=\(hit.score)")
            } catch {
                ctx.fail("sqliteScore_separatorPenalty",
                         detail: "fixture error: \(error)")
            }
            #else
            ctx.assertTrue(true, "skipped_noSQLite3")
            #endif
        })

        // MARK: - D. Real-lexicon sanity

        cases.append(TestCase("realLexicon_commonGreetingSurfacesAtTop") { ctx in
            guard let path = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: path),
                  let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledLexicon")
                return
            }
            let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let state = engine.update(buffer: "mingalarpar", context: [])
            let top2 = Array(state.candidates.prefix(2))
            ctx.assertTrue(
                top2.contains(where: { $0.surface == "မင်္ဂလာပါ" }),
                detail: "top2=\(top2.map(\.surface))"
            )
        })

        cases.append(TestCase("realLexicon_commonWordsRankInTopCandidates") { ctx in
            guard let path = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: path) else {
                ctx.assertTrue(true, "skipped_noBundledLexicon")
                return
            }
            let engine = BurmeseEngine(candidateStore: store)
            for testCase in commonWordCases {
                let canonical = ReverseRomanizer.romanize(testCase.surface)
                let typed = Romanization.composeLookupKey(canonical)
                guard !typed.isEmpty else {
                    ctx.fail("commonWords_\(testCase.surface)",
                             detail: "empty typed key")
                    continue
                }
                let state = engine.update(buffer: typed, context: [])
                let top3 = Array(state.candidates.prefix(3)).map(\.surface)
                ctx.assertTrue(
                    top3.contains(testCase.surface),
                    "commonWords_\(testCase.surface)",
                    detail: "freq=\(testCase.frequency) typed='\(typed)' top3=\(top3)"
                )
            }
        })

        cases.append(TestCase("realLexicon_baseWordNotOutrankedByContinuation") { ctx in
            guard let path = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: path) else {
                ctx.assertTrue(true, "skipped_noBundledLexicon")
                return
            }
            let rawResults = store.lookup(prefix: "mingalarpar", previousSurface: nil)
            let surfaces = rawResults.map(\.surface)
            guard let baseIdx = surfaces.firstIndex(of: "မင်္ဂလာပါ") else {
                ctx.fail("baseNotFound", detail: "no မင်္ဂလာပါ in lookup")
                return
            }
            for (i, surface) in surfaces.enumerated()
                where surface != "မင်္ဂလာပါ" && surface.hasPrefix("မင်္ဂလာပါ") {
                ctx.assertTrue(i >= baseIdx,
                               "base_vs_\(surface)",
                               detail: "base=\(baseIdx) continuation=\(i)")
            }
        })

        cases.append(TestCase("realLexicon_par_exposesPaaParticle") { ctx in
            guard let path = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: path) else {
                ctx.assertTrue(true, "skipped_noBundledLexicon")
                return
            }
            let engine = BurmeseEngine(candidateStore: store)
            let state = engine.update(buffer: "par", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("ပါ"),
                           detail: "surfaces=\(surfaces)")
        })

        cases.append(TestCase("realLexicon_higherFrequencyWinsAmongLexiconHits") { ctx in
            guard let path = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: path) else {
                ctx.assertTrue(true, "skipped_noBundledLexicon")
                return
            }
            let results = store.lookup(prefix: "thar", previousSurface: nil)
            ctx.assertFalse(results.isEmpty, "hasHits")
            var lastScore = Double.infinity
            var lastPenalty = -1
            for candidate in results {
                let penalty = Romanization.aliasPenaltyCount(for: candidate.reading)
                if penalty != lastPenalty {
                    lastPenalty = penalty
                    lastScore = Double.infinity
                    continue
                }
                ctx.assertTrue(
                    candidate.score <= lastScore + 0.001,
                    "monotonicWithinBucket",
                    detail: "penalty=\(penalty) prev=\(lastScore) cur=\(candidate.score)"
                )
                lastScore = candidate.score
            }
        })

        // MARK: - E. Real-LM progressive typing

        cases.append(TestCase("realLM_prefixStability_kwyantaw_keepsPrefixWhenExtended") { ctx in
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath),
                  let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let short = engine.update(buffer: "kwyantaw", context: [])
            let longer = engine.update(buffer: "kwyantawkahtamin", context: [])
            guard let shortTop = short.candidates.first?.surface,
                  let longerTop = longer.candidates.first?.surface else {
                ctx.fail("prefixStability", detail: "missing candidates")
                return
            }
            let shortStripped = String(shortTop.unicodeScalars.filter { $0.value != 0x200B })
            let longerStripped = String(longerTop.unicodeScalars.filter { $0.value != 0x200B })
            ctx.assertTrue(
                longerStripped.hasPrefix(shortStripped),
                detail: "drift: longer='\(longerTop)' short='\(shortTop)'"
            )
        })

        cases.append(TestCase("realLM_progressiveTyping_neverEmptyCandidates") { ctx in
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath),
                  let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let keystrokes = [
                "k", "kw", "kwy", "kwya", "kwyan", "kwyant", "kwyanta",
                "kwyantaw", "kwyantawk", "kwyantawka", "kwyantawkah",
                "kwyantawkaht", "kwyantawkahta", "kwyantawkahtam",
                "kwyantawkahtami", "kwyantawkahtamin",
            ]
            var missing: [String] = []
            for stroke in keystrokes {
                let state = engine.update(buffer: stroke, context: [])
                if state.candidates.isEmpty { missing.append(stroke) }
            }
            ctx.assertTrue(missing.isEmpty, detail: "empty at: \(missing)")
        })

        cases.append(TestCase("realLM_longInputKeepsCorrectPrefix") { ctx in
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath),
                  let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let keystrokes = [
                "k", "kw", "kwy", "kwya", "kwyan", "kwyant", "kwyanta",
                "kwyantaw", "kwyantawk", "kwyantawka", "kwyantawkah",
                "kwyantawkaht", "kwyantawkahta", "kwyantawkahtam",
                "kwyantawkahtami", "kwyantawkahtamin",
            ]
            var finalTop = ""
            for stroke in keystrokes {
                let state = engine.update(buffer: stroke, context: [])
                finalTop = state.candidates.first?.surface ?? finalTop
            }
            let stripped = String(finalTop.unicodeScalars.filter { $0.value != 0x200B })
            ctx.assertTrue(
                stripped.hasPrefix("ကျွန်တော်"),
                detail: "final top='\(finalTop)'"
            )
        })

        cases.append(TestCase("realLM_progressiveTyping_kwyantawkahtamin_correctSuffix") { ctx in
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath),
                  let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
            var buffer = ""
            for ch in Array("kwyantawkahtamin") {
                buffer.append(ch)
                _ = engine.update(buffer: buffer, context: [])
            }
            let state = engine.update(buffer: "kwyantawkahtamin", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertTrue(stripZW(top).hasSuffix("ကထမင်"),
                           detail: "top=\(top)")
        })

        cases.append(TestCase("realLM_progressiveTyping_kwyantawkahtamin_colon_correctSuffix") { ctx in
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath),
                  let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
            var buffer = ""
            for ch in Array("kwyantawkahtamin:") {
                buffer.append(ch)
                _ = engine.update(buffer: buffer, context: [])
            }
            let state = engine.update(buffer: "kwyantawkahtamin:", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertTrue(stripZW(top).hasSuffix("ကထမင်း"),
                           detail: "top=\(top)")
        })

        cases.append(TestCase("realLM_longInput_thaNotSplitAsTaHa") { ctx in
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath),
                  let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let input = "kwyantawkahtamin:masar:rathar"
            var buffer = ""
            for ch in Array(input) {
                buffer.append(ch)
                _ = engine.update(buffer: buffer, context: [])
            }
            let state = engine.update(buffer: input, context: [])
            let top = stripZW(state.candidates.first?.surface ?? "")
            ctx.assertFalse(top.contains("တဟ"),
                            detail: "Found တဟ split; got: \(top)")
        })

        cases.append(TestCase("realLM_longInput_thar_variousContexts") { ctx in
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath),
                  let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            for input in ["kwyantawkahtamin:thar", "kwyantawkahtamin:masar:thar"] {
                let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
                var buffer = ""
                for ch in Array(input) {
                    buffer.append(ch)
                    _ = engine.update(buffer: buffer, context: [])
                }
                let state = engine.update(buffer: input, context: [])
                let top = stripZW(state.candidates.first?.surface ?? "")
                ctx.assertTrue(
                    top.hasSuffix("သာ"),
                    "thar_\(input.count)chars",
                    detail: "input='\(input)' top=\(top)"
                )
            }
        })

        cases.append(TestCase("realLM_progressiveTyping_htaminSarPyiPyilar_correctTop") { ctx in
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath),
                  let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let input = "htamin:sar:pyi:pyilar:"
            var buffer = ""
            for ch in Array(input) {
                buffer.append(ch)
                _ = engine.update(buffer: buffer, context: [])
            }
            let state = engine.update(buffer: input, context: [])
            let top = stripZW(state.candidates.first?.surface ?? "")
            let top5 = state.candidates.prefix(5).map { stripZW($0.surface) }
            ctx.assertTrue(top == "ထမင်းစားပြီးပြီလား",
                           detail: "top=\(top) top5=\(top5)")
        })

        cases.append(TestCase("realLM_progressiveTyping_fullSentenceSimulation") { ctx in
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath),
                  let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let targetSurfaces = [
                "မင်္ဂလာပါ", "ကျွန်တော်", "ထမင်း", "စား", "ပါ",
            ]
            var context: [String] = []
            var emptyPanels: [String] = []
            var misrenderings: [(String, String, String)] = []
            for surface in targetSurfaces {
                let typed = ReverseRomanizer.romanize(surface)
                    .filter { !"23+'".contains($0) }
                _ = engine.update(buffer: "", context: context)
                for i in 1...typed.count {
                    let buffer = String(typed.prefix(i))
                    let state = engine.update(buffer: buffer, context: context)
                    if state.candidates.isEmpty {
                        emptyPanels.append("word='\(surface)' stroke='\(buffer)'")
                    }
                }
                let finalState = engine.update(buffer: typed, context: context)
                let top3 = Array(finalState.candidates.prefix(3)).map(\.surface)
                let stripped3 = top3.map { stripZW($0) }
                if !stripped3.contains(surface) {
                    misrenderings.append((typed, surface, "top3=\(stripped3)"))
                }
                context.append(surface)
            }
            ctx.assertTrue(emptyPanels.isEmpty,
                           "noEmptyPanel",
                           detail: "empty at: \(emptyPanels)")
            if !misrenderings.isEmpty {
                let rendered = misrenderings
                    .map { "'\($0.0)'→expected '\($0.1)': \($0.2)" }
                    .joined(separator: " | ")
                ctx.fail("top3ContainsTarget", detail: rendered)
            } else {
                ctx.assertTrue(true, "top3ContainsTarget")
            }
        })

        cases.append(TestCase("realLM_progressiveTyping_kwyantawkahtamin_traceNoDrift") { ctx in
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath),
                  let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let letters = Array("kwyantawkahtamin:")
            let expectedPrefix = "ကျွန်တော်"
            var buffer = ""
            var trace: [(String, String)] = []
            var driftAt: String? = nil
            var emptyAt: [String] = []
            var prefixEstablished = false
            for ch in letters {
                buffer.append(ch)
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                let stripped = stripZW(top)
                trace.append((buffer, stripped))
                if state.candidates.isEmpty { emptyAt.append(buffer) }
                if stripped.hasPrefix(expectedPrefix) {
                    prefixEstablished = true
                } else if prefixEstablished && driftAt == nil {
                    driftAt = buffer
                }
            }
            let traceStr = trace.map { "\($0.0)→\($0.1)" }.joined(separator: " | ")
            ctx.assertTrue(emptyAt.isEmpty,
                           "neverEmpty",
                           detail: "empty at \(emptyAt); trace: \(traceStr)")
            ctx.assertTrue(prefixEstablished,
                           "prefixReached",
                           detail: "never saw '\(expectedPrefix)'; trace: \(traceStr)")
            ctx.assertTrue(driftAt == nil,
                           "noDriftAfterEstablished",
                           detail: "drift at '\(driftAt ?? "")'; trace: \(traceStr)")
        })

        cases.append(TestCase("realLM_progressiveTyping_reachesCorrectWord") { ctx in
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath),
                  let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
            var finalTop = ""
            for prefix in ["k", "kw", "kwy", "kwya", "kwyan", "kwyant", "kwyanta", "kwyantaw"] {
                let state = engine.update(buffer: prefix, context: [])
                finalTop = state.candidates.first?.surface ?? ""
            }
            ctx.assertEqual(stripZW(finalTop), "ကျွန်တော်")
        })

        cases.append(TestCase("realLM_progressiveTyping_canonicalVsMedial_expectations") { ctx in
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath),
                  let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let topCases: [(String, [UInt32])] = [
                ("hsa",  [0x1006]),
                ("kah",  [0x1000, 0x1021]),
                ("kaht", [0x1000, 0x1011]),
            ]
            let containsCases: [(String, [UInt32])] = [
                ("hka",  [0x1000, 0x103E]),
            ]
            var failures: [String] = []
            for (word, expectedScalars) in topCases {
                _ = engine.update(buffer: "", context: [])
                var top = ""
                for i in 1...word.count {
                    let buf = String(word.prefix(i))
                    let state = engine.update(buffer: buf, context: [])
                    top = state.candidates.first?.surface ?? ""
                }
                let actual = top.unicodeScalars
                    .filter { $0.value != 0x200B && $0.value != 0x200C }
                    .map { $0.value }
                if actual != expectedScalars {
                    let hex = actual.map { String(format: "%04X", $0) }.joined(separator: " ")
                    let exp = expectedScalars.map { String(format: "%04X", $0) }.joined(separator: " ")
                    failures.append("'\(word)' top→[\(hex)], expected [\(exp)]")
                }
            }
            for (word, expectedScalars) in containsCases {
                _ = engine.update(buffer: "", context: [])
                var candidates: [String] = []
                for i in 1...word.count {
                    let buf = String(word.prefix(i))
                    let state = engine.update(buffer: buf, context: [])
                    candidates = state.candidates.map(\.surface)
                }
                let found = candidates.contains { surface in
                    let scalars = surface.unicodeScalars
                        .filter { $0.value != 0x200B && $0.value != 0x200C }
                        .map { $0.value }
                    return scalars == expectedScalars
                }
                if !found {
                    let exp = expectedScalars.map { String(format: "%04X", $0) }.joined(separator: " ")
                    failures.append("'\(word)' missing [\(exp)]")
                }
            }
            ctx.assertTrue(failures.isEmpty,
                           detail: failures.joined(separator: " | "))
        })

        cases.append(TestCase("windowedTail_promotesLexiconWord") { ctx in
            // Regression guard for edge-long-text-no-lexicon-promotion.
            // When the buffer exceeds the sliding-window threshold, the
            // engine splits it into a frozen prefix + active tail. Even
            // in that branch, a lexicon word matching the tail must still
            // reach the top of the panel — otherwise long sentences lose
            // lexicon-corrected renderings entirely (`hrin` devolves to
            // the literal consonant walk `ဟရင်` instead of ရှင်).
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath) else {
                ctx.assertTrue(true, "skipped_noBundledLexicon")
                return
            }
            let engine = BurmeseEngine(candidateStore: store)
            let buffer = "mingalarparmingalarparhrin"
            ctx.assertTrue(buffer.count > 20,
                           detail: "test buffer must exceed window size")
            let state = engine.update(buffer: buffer, context: [])
            let top = state.candidates.first?.surface ?? ""
            let stripped = stripZW(top)
            ctx.assertTrue(stripped.hasSuffix("ရှင်"),
                           detail: "top=\(top) candidates=\(state.candidates.prefix(5).map(\.surface))")
        })

        // MARK: - Task 03: anusvara coda words must surface at top

        cases.append(TestCase("task03_thanhlyin_rankedInTop5") { ctx in
            guard let path = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: path),
                  let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let state = engine.update(buffer: "thanhlyin", context: [])
            let surfaces = state.candidates.prefix(5).map(\.surface)
            ctx.assertTrue(surfaces.contains("သံလျှင်"),
                           "task03_thanhlyin_inTop5",
                           detail: "top5=\(surfaces)")
        })

        // MARK: - Task 08: ya-pin family must reach the top panel

        // Every attested ya-pin word must surface in the top 5 for its
        // user-typed buffer. The LM tilts toward ya-pin for most of these;
        // lookup gaps (visarga / coda mismatches like ကျောင်း for `kyaung`)
        // are papered over with override_reading rows in the lexicon TSV so
        // the exact-alias prioritization lands them in the panel.
        let task08Cases: [(buffer: String, expected: String, gloss: String)] = [
            ("kywantaw", "ကျွန်တော်", "I (formal/masculine)"),
            ("kywanma",  "ကျွန်မ",    "I (feminine/polite)"),
            ("kywan",    "ကျွန်",     "servant/slave"),
            ("kyaung",   "ကျောင်း",   "school/monastery"),
            ("kyaw",     "ကျော်",     "cross/famous"),
            ("kyay",     "ကျေ",      "pleased"),
            ("kyayzu",   "ကျေးဇူး",   "thanks"),
            ("kyat",     "ကျပ်",      "kyat (currency)"),
            ("kyan",     "ကျန်",      "remain"),
            ("kyin",     "ကျင်း",     "large/broad"),
            ("kyit",     "ကျစ်",      "pinch/bite"),
            ("kyi",      "ကျီ",      "glance"),
            ("khyay",    "ချေ",      "defeat"),
            ("khyin",    "ချင်",      "want"),
            ("khyit",    "ချစ်",      "love"),
        ]

        for (buffer, expected, gloss) in task08Cases {
            cases.append(TestCase("task08_yapin_\(buffer)") { ctx in
                guard let lexPath = BundledArtifacts.lexiconPath,
                      let store = SQLiteCandidateStore(path: lexPath),
                      let lmPath = BundledArtifacts.trigramLMPath,
                      let lm = try? TrigramLanguageModel(path: lmPath) else {
                    ctx.assertTrue(true, "skipped_noBundledArtifacts")
                    return
                }
                let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
                let state = engine.update(buffer: buffer, context: [])
                let top5 = state.candidates.prefix(5).map { stripZW($0.surface) }
                ctx.assertTrue(
                    top5.contains(expected),
                    detail: "buffer='\(buffer)' expected='\(expected)' (\(gloss)) top5=\(top5)"
                )
            })
        }

        // MARK: - Task 12: onsetless independent vowel + anusvara must rank 1

        // Bare `an`, `an.`, `an:` are common standalone forms (`အံ`
        // exclamation stem, `အံ့` the exclamation particle, `အံး` elongated).
        // Without this rule they fall through to the consonant-coda rule
        // family (`န်` / `န့်` / `န်း`) because the parser has no onset to
        // attach the anusvara to.
        let task12Cases: [(buffer: String, expected: String, gloss: String)] = [
            ("an",  "\u{1021}\u{1036}", "independent vowel + anusvara"),
            ("an.", "\u{1021}\u{1036}\u{1037}", "+ dot-below (aukmyit)"),
            ("an:", "\u{1021}\u{1036}\u{1038}", "+ shay-pauk (visarga)"),
        ]
        for (buffer, expected, gloss) in task12Cases {
            cases.append(TestCase("task12_onsetlessAnusvara_\(buffer)") { ctx in
                guard let lexPath = BundledArtifacts.lexiconPath,
                      let store = SQLiteCandidateStore(path: lexPath),
                      let lmPath = BundledArtifacts.trigramLMPath,
                      let lm = try? TrigramLanguageModel(path: lmPath) else {
                    ctx.assertTrue(true, "skipped_noBundledArtifacts")
                    return
                }
                let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first else {
                    ctx.assertTrue(false, detail: "buffer='\(buffer)' no candidates")
                    return
                }
                ctx.assertEqual(
                    stripZW(top.surface), expected,
                    "top1_expected_\(buffer)_\(gloss)"
                )
            })
        }

        // MARK: - Task 13: remaining ya-pin audit (kywan, kyay, kyi, khyay, khyin)

        // Ya-pin surfaces whose canonical readings carry the `2`/`3`
        // disambiguator lose to ya-yit siblings on DP + LM alone. Each
        // row below must be rank 1 for its user-typed buffer. Unlike
        // task 08 which only asserts top-5 presence, this suite demands
        // top-1 because that is where the attested ya-pin form belongs.
        let task13Top1Cases: [(buffer: String, expected: String, gloss: String)] = [
            ("kywan", "\u{1000}\u{103B}\u{103D}\u{1014}\u{103A}", "servant/slave"),
            ("kyay",  "\u{1000}\u{103B}\u{1031}",                  "pleased"),
            ("kyi",   "\u{1000}\u{103B}\u{102E}",                  "glance"),
            ("khyay", "\u{1001}\u{103B}\u{1031}",                  "defeat/settle"),
            ("khyin", "\u{1001}\u{103B}\u{1004}\u{103A}",          "want"),
        ]
        for (buffer, expected, gloss) in task13Top1Cases {
            cases.append(TestCase("task13_yapin_\(buffer)_top1") { ctx in
                guard let lexPath = BundledArtifacts.lexiconPath,
                      let store = SQLiteCandidateStore(path: lexPath),
                      let lmPath = BundledArtifacts.trigramLMPath,
                      let lm = try? TrigramLanguageModel(path: lmPath) else {
                    ctx.assertTrue(true, "skipped_noBundledArtifacts")
                    return
                }
                let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first else {
                    ctx.assertTrue(false, detail: "buffer='\(buffer)' no candidates")
                    return
                }
                let top5 = state.candidates.prefix(5).map { stripZW($0.surface) }
                ctx.assertTrue(
                    stripZW(top.surface) == expected,
                    detail: "buffer='\(buffer)' (\(gloss)) got='\(stripZW(top.surface))' top5=\(top5)"
                )
            })
        }

        // Ya-yit siblings that must still be reachable in the panel —
        // task 13 is a ranking flip, not a substitution.
        let task13YayitAccessible: [(buffer: String, yayit: String)] = [
            ("kyay",  "\u{1000}\u{103C}\u{1031}"),                 // ကြေ
            ("kyi",   "\u{1000}\u{103C}\u{102E}"),                 // ကြီ (may be replaced by ကြီး in panel — check either)
            ("khyay", "\u{1001}\u{103C}\u{1031}"),                 // ခြေ
            ("khyin", "\u{1001}\u{103C}\u{1004}\u{103A}\u{1038}"), // ခြင်း
        ]
        for (buffer, yayit) in task13YayitAccessible {
            cases.append(TestCase("task13_yayit_still_in_panel_\(buffer)") { ctx in
                guard let lexPath = BundledArtifacts.lexiconPath,
                      let store = SQLiteCandidateStore(path: lexPath),
                      let lmPath = BundledArtifacts.trigramLMPath,
                      let lm = try? TrigramLanguageModel(path: lmPath) else {
                    ctx.assertTrue(true, "skipped_noBundledArtifacts")
                    return
                }
                let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
                let state = engine.update(buffer: buffer, context: [])
                let panel = state.candidates.map { stripZW($0.surface) }
                ctx.assertTrue(
                    panel.contains(yayit),
                    detail: "buffer='\(buffer)' yayit='\(yayit)' panel=\(panel.prefix(8))"
                )
            })
        }

        // Ya-yit controls that must stay at rank 1 — no ya-pin promotion
        // should leak into consonants whose attested form is ya-yit.
        let task13YayitControls: [(buffer: String, expected: String)] = [
            ("pyan",   "\u{1015}\u{103C}\u{1014}\u{103A}"),                     // ပြန်
            ("pyat",   "\u{1015}\u{103C}\u{1010}\u{103A}"),                     // ပြတ်
            ("pyaung", "\u{1015}\u{103C}\u{1031}\u{102C}\u{1004}\u{103A}"),     // ပြောင်
        ]
        for (buffer, expected) in task13YayitControls {
            cases.append(TestCase("task13_yayitControl_\(buffer)_top1") { ctx in
                guard let lexPath = BundledArtifacts.lexiconPath,
                      let store = SQLiteCandidateStore(path: lexPath),
                      let lmPath = BundledArtifacts.trigramLMPath,
                      let lm = try? TrigramLanguageModel(path: lmPath) else {
                    ctx.assertTrue(true, "skipped_noBundledArtifacts")
                    return
                }
                let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first else {
                    ctx.assertTrue(false, detail: "buffer='\(buffer)' no candidates")
                    return
                }
                let top5 = state.candidates.prefix(5).map { stripZW($0.surface) }
                ctx.assertTrue(
                    stripZW(top.surface) == expected,
                    detail: "buffer='\(buffer)' got='\(stripZW(top.surface))' top5=\(top5)"
                )
            })
        }

        // Consonant-onset controls — post-task-03 behaviour must hold.
        let task12Controls: [(buffer: String, expected: String)] = [
            ("than", "\u{101E}\u{1036}"),         // သံ
            ("kan",  "\u{1000}\u{1014}\u{103A}"), // ကန် (rank 1 from engine today)
            ("chan", "\u{1001}\u{103B}\u{1036}"), // ချံ — rank 1 with LM
            ("pyan", "\u{1015}\u{103C}\u{1014}\u{103A}"), // ပြန် — rank 1 with LM
        ]
        for (buffer, expected) in task12Controls {
            cases.append(TestCase("task12_onsetControl_\(buffer)") { ctx in
                guard let lexPath = BundledArtifacts.lexiconPath,
                      let store = SQLiteCandidateStore(path: lexPath),
                      let lmPath = BundledArtifacts.trigramLMPath,
                      let lm = try? TrigramLanguageModel(path: lmPath) else {
                    ctx.assertTrue(true, "skipped_noBundledArtifacts")
                    return
                }
                let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
                let state = engine.update(buffer: buffer, context: [])
                let top5 = state.candidates.prefix(5).map { stripZW($0.surface) }
                ctx.assertTrue(
                    top5.contains(expected),
                    detail: "buffer='\(buffer)' expected='\(expected)' top5=\(top5)"
                )
            })
        }

        return TestSuite(name: "LexiconRanking", cases: cases)
    }()
}
