import Foundation
import BurmeseIMECore

/// TASK-073 + TASK-074 share the same comparator pathology: a curated
/// lexicon alias (`u.` → `ဥ`, `an:` → `အံး`) with a very high stored
/// score (~745 / ~850) absorbed into a grammar candidate loses to a
/// parser-emitted sibling at rank 0 because the engine's merge order
/// prioritises pure-lexicon `exactAliasLexicon` candidates ahead of
/// grammar candidates regardless of composite score. The parser-
/// emitted sibling has a lower stored score but a stronger LM signal
/// (the curated alias surface is intentionally OOV in the LM vocab —
/// it is preserved by `CuratedLexicon.oovAllowedSurfaces` — so its
/// LM falls to the `<unk>` floor and the composite tilt favours the
/// parser-emitted form).
///
/// The acceptance criterion is the same for both tasks: the curated
/// alias's surface must reach rank 0 when the user types the alias
/// key. The parser-emitted sibling stays in the panel below it.
public enum CuratedAliasRankZeroSuite {

    private static func bundledEngine(_ ctx: TestContext) -> BurmeseEngine? {
        guard let lexPath = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lexPath),
              let lmPath = BundledArtifacts.trigramLMPath,
              let lm = try? TrigramLanguageModel(path: lmPath) else {
            ctx.assertTrue(true, "skipped_noBundledArtifacts")
            return nil
        }
        return BurmeseEngine(candidateStore: store, languageModel: lm)
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    public static let suite: TestSuite = {
        var cases: [TestCase] = []

        // TASK-073: `u.` (creaky-tone independent vowel `ဥ`).
        cases.append(TestCase("uDot_ranks_independent_u_curatedAlias") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "u.", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertEqual(top, "\u{1025}", "u._top_\(hex(top))")
        })

        // TASK-074: `an:` (anusvara `အံး`).
        cases.append(TestCase("anColon_ranks_anusvara_form_curatedAlias") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "an:", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertEqual(top, "\u{1021}\u{1036}\u{1038}", "an:_top_\(hex(top))")
        })

        // Controls — already-passing cases that must NOT regress.
        let controls: [(buffer: String, expected: String, label: String)] = [
            ("u",   "\u{1025}",          "u_topUnchanged"),       // TASK-073 baseline
            ("u2",  "\u{1025}\u{1042}",  "u2_topUnchanged"),      // TASK-073 baseline
            ("an",  "\u{1021}\u{1036}",  "an_topUnchanged"),      // TASK-074 baseline (already fixed)
            ("an.", "\u{1021}\u{1036}\u{1037}", "an._topUnchanged"), // TASK-074 baseline (already fixed)
        ]
        for c in controls {
            cases.append(TestCase("control_\(c.label)") { ctx in
                guard let engine = bundledEngine(ctx) else { return }
                let state = engine.update(buffer: c.buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertEqual(top, c.expected, "\(c.label)_got_\(hex(top))")
            })
        }

        // Predicate: the parser-emitted sibling stays REACHABLE in
        // the panel for the failing inputs — the curated-alias
        // promotion shouldn't drop it.
        let reachability: [(buffer: String, sibling: String, label: String)] = [
            ("u.",  "\u{1021}\u{1030}\u{1037}",   "uDot_siblingAUcreaky_reachable"),
            ("an:", "\u{1021}\u{1014}\u{103A}\u{1038}", "anColon_siblingNAsat_reachable"),
        ]
        for r in reachability {
            cases.append(TestCase("\(r.label)") { ctx in
                guard let engine = bundledEngine(ctx) else { return }
                let state = engine.update(buffer: r.buffer, context: [])
                let top8 = state.candidates.prefix(8).map(\.surface)
                ctx.assertTrue(
                    top8.contains(r.sibling),
                    r.label,
                    detail: "expected sibling '\(r.sibling)' (\(hex(r.sibling))) in top8=\(top8)"
                )
            })
        }

        return TestSuite(name: "CuratedAliasRankZero", cases: cases)
    }()
}
