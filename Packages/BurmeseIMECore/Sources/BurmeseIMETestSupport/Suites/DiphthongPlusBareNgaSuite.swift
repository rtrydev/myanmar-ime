import Foundation
@_spi(Testing) import BurmeseIMECore

/// Regression suite for stack inference over-firing on ai/aung diphthong
/// buffers where the user types a bare `ng` that is already provided by the
/// diphthong's built-in nga-asat coda.
///
/// The `ai` rule emits `102D 102F 1004 103A` (ိုင်) — nga already present.
/// A following user-typed `ng` is redundant. Allowing regular inference to
/// fire at the `n+g` boundary produces a doubled-nga kinzi surface that
/// looks wrong to a typist. The buffer-leading `aing` fast-path in
/// `inferImplicitStackMarkers` already collapses this correctly; this suite
/// guards the generalised fix for onset-leading buffers (`mainga`, etc.).
///
/// See `tasks/04-stack-inference-fires-without-trailing-stackable.md`.
public enum DiphthongPlusBareNgaSuite {

    private static let kinziScalars: [UInt32] = [0x1004, 0x103A, 0x1039]
    private static let doubledNgaVirama: [UInt32] = [0x1004, 0x103A, 0x1039, 0x1004]

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

    private static func containsSubsequence(_ scalars: [UInt32], _ sub: [UInt32]) -> Bool {
        guard scalars.count >= sub.count else { return false }
        for i in 0...(scalars.count - sub.count) {
            if Array(scalars[i..<i + sub.count]) == sub { return true }
        }
        return false
    }

    private static func containsKinzi(_ surface: String) -> Bool {
        containsSubsequence(surface.unicodeScalars.map(\.value), kinziScalars)
    }

    private static func containsDoubledNga(_ surface: String) -> Bool {
        containsSubsequence(surface.unicodeScalars.map(\.value), doubledNgaVirama)
    }

    private static func topCandidate(
        _ engine: BurmeseEngine,
        _ input: String
    ) -> String {
        engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
    }

    public static let suite = TestSuite(name: "DiphthongPlusBareNga", cases: [

        // ── ai-diphthong, open form must win ──────────────────────────────
        // Onset + ai + ng + nothing (or bare vowel): the user's `ng` is just
        // the open-form nga onset. No kinzi should appear at rank 0.
        TestCase("ai_openFormWins_bareNga") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for input in ["mainga", "kainga", "tainga", "nainga", "sainga", "thainga"] {
                let top = topCandidate(engine, input)
                ctx.assertFalse(
                    containsKinzi(top),
                    input,
                    detail: "top '\(top)' has kinzi; expected open form"
                )
            }
        },

        // maingga: lower consonant is present but has only inherent 'a',
        // so the open form is still preferred over kinzi.
        TestCase("ai_openFormWins_maingga") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let top = topCandidate(engine, "maingga")
            ctx.assertFalse(
                containsKinzi(top),
                "maingga",
                detail: "top '\(top)' has kinzi; expected open form"
            )
        },

        // The doubled-nga surface (1004 103A 1039 1004) must never appear
        // at rank 0 for any of these inputs — it is always wrong.
        TestCase("ai_noDoubledNgaAtTop") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for input in ["mainga", "kainga", "tainga", "maingga", "nainga"] {
                let top = topCandidate(engine, input)
                ctx.assertFalse(
                    containsDoubledNga(top),
                    input,
                    detail: "top '\(top)' has doubled-nga (1004 103A 1039 1004)"
                )
            }
        },

        // Kinzi sibling must still be reachable (rank ≥ 1) for panel access.
        TestCase("ai_kinziSiblingReachable") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for input in ["mainga", "kainga"] {
                let state = engine.update(buffer: input, context: [])
                let hasKinziCandidate = state.candidates.dropFirst().contains {
                    containsKinzi($0.surface)
                }
                ctx.assertTrue(
                    hasKinziCandidate,
                    "\(input).kinziReachable",
                    detail: "kinzi form not in panel at rank ≥ 1; cands=\(state.candidates.prefix(4).map(\.surface))"
                )
            }
        },

        // ── ai-diphthong, kinzi-with-stacked-lower must be correct ────────
        // When the user types a GENUINE lower consonant with an explicit
        // vowel after the `ng`, the kinzi form should win. The `ng` collapses
        // into the diphthong's existing nga-asat coda and `+` is inserted
        // before the stackable lower.
        TestCase("ai_kinziWithStackedGar") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for input in ["mainggar", "kainggar"] {
                let top = topCandidate(engine, input)
                // Must have kinzi (nga+asat+virama) but NOT the doubled-nga
                // pattern (nga+asat+virama+nga) that the old wrong inference
                // produced.
                ctx.assertTrue(
                    containsKinzi(top),
                    "\(input).hasKinzi",
                    detail: "top '\(top)' missing kinzi"
                )
                ctx.assertFalse(
                    containsDoubledNga(top),
                    "\(input).noDoubledNga",
                    detail: "top '\(top)' has doubled-nga (wrong inference)"
                )
            }
        },

        TestCase("ai_kinziWithStackedGi") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for input in ["mainggi", "kainggi"] {
                let top = topCandidate(engine, input)
                ctx.assertTrue(
                    containsKinzi(top),
                    "\(input).hasKinzi",
                    detail: "top '\(top)' missing kinzi"
                )
                ctx.assertFalse(
                    containsDoubledNga(top),
                    "\(input).noDoubledNga",
                    detail: "top '\(top)' has doubled-nga"
                )
            }
        },

        TestCase("ai_kinziWithStackedKha") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            // `maingkha` removed — `မိုင်ခ` is a real lexicon entry
            // (Myanmar acronym, freq 48), so once the lexicon dropped
            // its ASCII-suffixed sibling rows the lexicon-validated
            // non-kinzi form correctly wins over the grammar-only
            // kinzi-stack interpretation. `kaingkha` has no
            // `ကိုင်ခ` lexicon entry and continues to surface the
            // kinzi form at top.
            for input in ["kaingkha"] {
                let top = topCandidate(engine, input)
                ctx.assertTrue(
                    containsKinzi(top),
                    "\(input).hasKinzi",
                    detail: "top '\(top)' missing kinzi"
                )
                ctx.assertFalse(
                    containsDoubledNga(top),
                    "\(input).noDoubledNga",
                    detail: "top '\(top)' has doubled-nga"
                )
            }
        },

        // ── aung-diphthong: already correct, must not regress ─────────────
        // The `aung` rule also ends with a nga-asat coda. These cases are
        // already handled (nil inference) and must remain correct.
        TestCase("aung_openFormStaysCorrect") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for input in ["maunga", "kaunga", "taunga", "naunga"] {
                let top = topCandidate(engine, input)
                ctx.assertFalse(
                    containsKinzi(top),
                    input,
                    detail: "top '\(top)' has kinzi; expected open form"
                )
            }
        },

        // ── buffer-leading fast-path non-regression ───────────────────────
        // The buffer-leading ai+ng fast-path that already existed must not
        // be disturbed by the mid-buffer generalisation.
        TestCase("bufferLeading_ainga_openForm") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let top = topCandidate(engine, "ainga")
            ctx.assertFalse(
                containsKinzi(top),
                "ainga",
                detail: "top '\(top)' has kinzi; expected open form"
            )
        },

        TestCase("bufferLeading_ainggar_kinzi") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let top = topCandidate(engine, "ainggar")
            ctx.assertTrue(
                containsKinzi(top),
                "ainggar.hasKinzi",
                detail: "top '\(top)' missing kinzi"
            )
            ctx.assertFalse(
                containsDoubledNga(top),
                "ainggar.noDoubledNga",
                detail: "top '\(top)' has doubled-nga"
            )
        },

        // ── Inference-level check (no bundled engine required) ────────────
        // Verify that inferImplicitStackMarkers itself returns the right
        // collapsed or nil result — independent of engine ranking.
        // Bare-onset `ng` (no consonant lower at stackStart) → liberal
        // inference so the kinzi form is reachable in the panel but
        // the rarity bump keeps the open form at rank 0.
        TestCase("infer_midBufferAiNg_bareOnset_liberalInference") { ctx in
            let cases: [(input: String, expected: String)] = [
                ("mainga", "mai+nga"),
                ("kainga", "kai+nga"),
                ("tainga", "tai+nga"),
            ]
            for (input, expected) in cases {
                let result = BurmeseEngine.inferImplicitStackMarkers(input)
                ctx.assertTrue(
                    result?.liberalInsertions == 1,
                    "\(input).isLiberal",
                    detail: "expected liberalInsertions=1 but got \(result?.liberalInsertions ?? -1)"
                )
                ctx.assertTrue(
                    result?.input == expected,
                    "\(input).collapsedForm",
                    detail: "expected '\(expected)' but got '\(result?.input ?? "nil")'"
                )
            }
        },

        // Consonant-lower that cannot stack with nga → blocked (nil), so
        // the open form wins naturally without kinzi in panel.
        TestCase("infer_midBufferAiNg_invalidStack_returnsNil") { ctx in
            for input in ["maingga"] {
                let result = BurmeseEngine.inferImplicitStackMarkers(input)
                ctx.assertTrue(
                    result == nil,
                    input,
                    detail: "expected nil but got inferred='\(result?.input ?? "?")'"
                )
            }
        },

        TestCase("infer_midBufferAiNg_withStackable_collapsed") { ctx in
            let cases: [(input: String, expected: String)] = [
                ("mainggar", "mai+gar"),
                ("kainggar", "kai+gar"),
                ("mainggi",  "mai+gi"),
                ("kainggi",  "kai+gi"),
                ("maingkha", "mai+kha"),
                ("kaingkha", "kai+kha"),
            ]
            for (input, expected) in cases {
                let result = BurmeseEngine.inferImplicitStackMarkers(input)
                ctx.assertTrue(
                    result?.input == expected,
                    input,
                    detail: "expected '\(expected)' but got '\(result?.input ?? "nil")'"
                )
            }
        },

        TestCase("infer_bufferLeading_unchanged") { ctx in
            // ainga: fast-path falls through, regular loop produces ai+nga
            let ainga = BurmeseEngine.inferImplicitStackMarkers("ainga")
            ctx.assertTrue(
                ainga?.input == "ai+nga",
                "ainga",
                detail: "expected 'ai+nga' got '\(ainga?.input ?? "nil")'"
            )
            // ainggar: fast-path collapses to ai+gar
            let ainggar = BurmeseEngine.inferImplicitStackMarkers("ainggar")
            ctx.assertTrue(
                ainggar?.input == "ai+gar",
                "ainggar",
                detail: "expected 'ai+gar' got '\(ainggar?.input ?? "nil")'"
            )
        },
    ])
}
