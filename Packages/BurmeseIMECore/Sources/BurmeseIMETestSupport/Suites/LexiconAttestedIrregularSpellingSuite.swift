import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-081: a small, high-frequency class of Burmese
/// words is written with lexicalized irregular orthography that the
/// structural syllable model rejects — `ယောက်ျား` ("man/husband",
/// ya-pin medial AFTER the asat coda) and `ကျွန်ုပ်` ("I" formal,
/// u-vowel sign after the asat). Both are the standard dictionary
/// spellings and exist as penalty-0 alias rows in the shipped lexicon,
/// but `sanitizeMalformedMyanmarMarks` strips them whenever a
/// structurally "clean" sibling (a wrong word) exists, leaving the
/// intended word unreachable at any rank.
///
/// The rule encoded here: structural legality filtering must not
/// outvote curated lexicon data when the user typed the entry's exact
/// reading. The exemption is data-driven (lexicon-/history-sourced
/// candidates whose reading matches the typed buffer), never a
/// hardcoded surface list — parser-fabricated illegal surfaces keep
/// being filtered.
public enum LexiconAttestedIrregularSpellingSuite {

    private static func bundledStores(_ ctx: TestContext) -> (SQLiteCandidateStore, TrigramLanguageModel)? {
        guard let lexPath = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lexPath),
              let lmPath = BundledArtifacts.trigramLMPath,
              let lm = try? TrigramLanguageModel(path: lmPath) else {
            ctx.assertTrue(true, "skipped_noBundledArtifacts")
            return nil
        }
        return (store, lm)
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// The two canonical members of the irregular-spelling class with
    /// their exact digit-stripped aliases.
    private static let attestedCases: [(buffer: String, expected: String)] = [
        ("youtar:",  "ယောက်ျား"),
        ("kwyanote", "ကျွန်ုပ်"),
    ]

    public static let suite = TestSuite(name: "LexiconAttestedIrregularSpelling", cases: [

        // Exact-alias typing must surface the attested irregular
        // spelling — top-3 strongly preferred for penalty-0 exact
        // alias hits.
        TestCase("production_exactAliasSurfacesAttestedSpelling") { ctx in
            guard let (store, lm) = bundledStores(ctx) else { return }
            for c in attestedCases {
                let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
                let candidates = engine.update(buffer: c.buffer, context: []).candidates
                let rank = candidates.firstIndex { $0.surface == c.expected }
                ctx.assertTrue(
                    rank != nil && rank! < 3,
                    c.buffer,
                    detail: "expected '\(c.expected)' [\(hex(c.expected))] in top 3; got \(candidates.prefix(5).map(\.surface)) (rank=\(rank.map(String.init) ?? "absent"))"
                )
            }
        },

        // The regular sibling rows survive alongside: `ကျွနုပ်` is
        // itself a real lexicon row under the same alias (a corpus
        // artifact of the asat-less misspelling) and must remain
        // reachable — the exemption adds the attested surface, it
        // does not censor the sibling.
        TestCase("production_cleanSiblingRowsSurvive") { ctx in
            guard let (store, lm) = bundledStores(ctx) else { return }
            let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let candidates = engine.update(buffer: "kwyanote", context: []).candidates
            ctx.assertTrue(
                candidates.contains { $0.surface == "ကျွနုပ်" },
                "kwyanote_sibling",
                detail: "clean sibling 'ကျွနုပ်' missing; got \(candidates.prefix(6).map(\.surface))"
            )
        },

        // Without lexicon attestation the structural filter keeps
        // winning: the bare engine (no store) must not fabricate the
        // irregular shapes from the same readings — parser-generated
        // surfaces failing the legality scan are still dropped when
        // clean siblings exist.
        TestCase("bareEngine_structuralFilterStillApplies") { ctx in
            let engine = BurmeseEngine(
                candidateStore: EmptyCandidateStore(),
                languageModel: NullLanguageModel()
            )
            for c in attestedCases {
                let candidates = engine.update(buffer: c.buffer, context: []).candidates
                for cand in candidates {
                    ctx.assertTrue(
                        SyllableParser.scanOutputLegality(cand.surface)
                            || cand.surface == c.buffer,
                        "\(c.buffer)_noFabricatedIllegal",
                        detail: "bare engine emitted structurally illegal non-literal surface '\(cand.surface)' [\(hex(cand.surface))]"
                    )
                }
            }
        },

        // A committed selection of the irregular surface must survive
        // re-typing: history-sourced candidates whose reading matches
        // the typed buffer are attested by the user's own commit.
        TestCase("production_historyEntrySurvivesRetyping") { ctx in
            guard let (store, lm) = bundledStores(ctx) else { return }
            let tempPath = NSTemporaryDirectory() + "task081-history-\(UUID().uuidString).sqlite"
            defer { try? FileManager.default.removeItem(atPath: tempPath) }
            guard let history = SQLiteUserHistoryStore(path: tempPath) else {
                ctx.fail("setup", detail: "could not create temp history store")
                return
            }
            let engine = BurmeseEngine(
                candidateStore: store,
                historyStore: history,
                languageModel: lm
            )
            var state = engine.update(buffer: "youtar:", context: [])
            guard let idx = state.candidates.firstIndex(where: { $0.surface == "ယောက်ျား" }) else {
                ctx.fail(
                    "setup_candidatePresent",
                    detail: "'ယောက်ျား' not in panel; got \(state.candidates.prefix(5).map(\.surface))"
                )
                return
            }
            state.selectedCandidateIndex = idx
            engine.recordSelection(state: state)
            let retyped = engine.update(buffer: "youtar:", context: []).candidates
            let rank = retyped.firstIndex { $0.surface == "ယောက်ျား" }
            ctx.assertTrue(
                rank != nil,
                "historyPromotion",
                detail: "committed 'ယောက်ျား' absent after re-typing; got \(retyped.prefix(5).map(\.surface))"
            )
        },
    ])
}
