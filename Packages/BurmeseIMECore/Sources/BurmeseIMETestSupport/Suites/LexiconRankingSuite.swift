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

        cases.append(TestCase("lexiconOrdering_aliasPenaltyBeatsFrequency") { ctx in
            let store = AnyPrefixStore(results: [
                Candidate(surface: "HIGH", reading: "ky2ar:", source: .lexicon, score: 1500),
                Candidate(surface: "LOW", reading: "kyar:", source: .lexicon, score: 800),
            ])
            let engine = BurmeseEngine(candidateStore: store)
            let state = engine.update(buffer: "kyar:", context: [])
            let firstLex = state.candidates.first(where: { $0.source == .lexicon })
            ctx.assertEqual(firstLex?.surface ?? "<none>", "LOW")
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
                  let store = SQLiteCandidateStore(path: path) else {
                ctx.assertTrue(true, "skipped_noBundledLexicon")
                return
            }
            let engine = BurmeseEngine(candidateStore: store)
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

        return TestSuite(name: "LexiconRanking", cases: cases)
    }()
}
