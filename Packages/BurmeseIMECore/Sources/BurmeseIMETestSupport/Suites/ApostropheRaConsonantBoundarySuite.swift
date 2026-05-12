import Foundation
import BurmeseIMECore

/// TASK-071: the doubled-mid-buffer apostrophe suite locked in
/// `thar'mar` → `သာမာ` as a single-apostrophe stability invariant.
/// The 2026-05-11 corpus rebuild shifted lexicon/LM scores enough
/// that the lattice composite now floats the 3-syllable
/// `tha + ra + mar` parse (= `သရမာ`) above the 2-syllable
/// `thar + mar` parse (= `သာမာ`) at rank 0, because `ra → ရ` is
/// the highest-frequency single-letter particle in the corpus.
///
/// The pattern is broader than the specific failing buffer: for any
/// `<C>ar'<X>` input, the parser produces BOTH the `<C>aa + <X>` and
/// the `<C> + ra + <X>` parses. The user's typed `r'` boundary signals
/// that `r` is the `aa`-vowel coda of `<C>`, not a fresh `ra`-consonant
/// syllable. The fix targets the engine's grammar comparator so the
/// dep-vowel sibling wins when the only difference between the two
/// candidates is a `<consonant base, no following dep-mark>` vs
/// `<aa-family dep-vowel>` substitution at the same scalar index.
public enum ApostropheRaConsonantBoundarySuite {

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

        // The minimal failing case from
        // `DoubledMidBufferApostropheSuite.singleApostrophe_topSurfaceUnchanged`.
        cases.append(TestCase("regression_thar_apos_mar_topIsSaaMar") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "thar'mar", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertEqual(
                top, "\u{101E}\u{102C}\u{1019}\u{102C}",
                "thar'mar_top_\(hex(top))"
            )
        })

        // Class predicate: `<C>ar'<X>` must rank the `<C>aa + <X>`
        // parse above the `<C> + ra + <X>` parse. We pick consonants
        // for which both parses are realisable.
        let classCases: [(buffer: String, expectedTop: String, gloss: String)] = [
            ("thar'mar",   "\u{101E}\u{102C}\u{1019}\u{102C}",   "thar+mar (saa-maa)"),
            ("kar'mar",    "\u{1000}\u{102C}\u{1019}\u{102C}",   "kar+mar (kaa-maa)"),
            ("nar'mar",    "\u{1014}\u{102C}\u{1019}\u{102C}",   "nar+mar (naa-maa)"),
            ("phar'mar",   "\u{1016}\u{102C}\u{1019}\u{102C}",   "phar+mar (phaa-maa)"),
        ]
        for c in classCases {
            cases.append(TestCase("classPredicate_\(c.buffer)") { ctx in
                guard let engine = bundledEngine(ctx) else { return }
                let state = engine.update(buffer: c.buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top, c.expectedTop,
                    "\(c.buffer)_top_\(hex(top))_(\(c.gloss))"
                )
            })
        }

        // Control: `tharmar` (no apostrophe) must STILL rank
        // `သာမာ` at top — the apostrophe-fix should not regress the
        // no-apostrophe baseline.
        cases.append(TestCase("control_tharmar_noApostropheTopUnchanged") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "tharmar", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertEqual(
                top, "\u{101E}\u{102C}\u{1019}\u{102C}",
                "tharmar_topUnchanged_\(hex(top))"
            )
        })

        // Control: `thar` alone must rank `သာ` at top —
        // the apostrophe-fix should not regress the buffer-leading
        // baseline (which already worked).
        cases.append(TestCase("control_thar_topUnchanged") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "thar", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertEqual(
                top, "\u{101E}\u{102C}",
                "thar_topUnchanged_\(hex(top))"
            )
        })

        // Control: legitimate `Cra` clusters must still be reachable.
        // `kraa` typings explicitly type `kr` cluster, not `kar`.
        // (`kr` has an aliasCost-10 cluster entry, but the `Cra`
        // shape with `r` as second consonant is the natural reading
        // for the buffer `kra`/`kraa`/etc.)
        cases.append(TestCase("control_legitCraReading_panelStillReachable") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            // For `kra`, the user's intent is the kra cluster. Top-1
            // doesn't have to be `Cra` — only require the panel to
            // contain at least one Myanmar candidate so the buffer
            // doesn't fall through to the literal.
            let state = engine.update(buffer: "kra", context: [])
            let myanmarPresent = state.candidates.contains { c in
                c.surface.unicodeScalars.contains { $0.value >= 0x1000 && $0.value < 0x10A0 }
            }
            ctx.assertTrue(
                myanmarPresent,
                "kra_panelHasMyanmar",
                detail: "panel=\(state.candidates.prefix(8).map(\.surface))"
            )
        })

        return TestSuite(name: "ApostropheRaConsonantBoundary", cases: cases)
    }()
}
