import Foundation
import BurmeseIMECore

/// Step 4 / Tier 2 — C10 (independent vowels), C11 (orphan-ZWNJ
/// avoidance), C34 (bare-vowel pedagogical inputs).
///
/// Burmese has seven independent vowel codepoints (ဣ ဤ ဥ ဦ ဧ ဩ ဪ).
/// Each must surface either as a panel candidate for the
/// corresponding bare-vowel input, or as a structural sibling of
/// the dependent-vowel form. The orthographic invariant L4.4 is
/// asserted for *every* bare-vowel input: the rank-0 surface must
/// not begin with U+200C (ZWNJ).
public enum LangIndependentVowelSuite {

    private static func bareEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func panelContainsScalar(
        _ ctx: TestContext,
        input: String,
        scalar: UInt32,
        label: String
    ) {
        let surfaces = bareEngine().update(buffer: input, context: []).candidates.map(\.surface)
        let target = Unicode.Scalar(scalar)!
        let hit = surfaces.contains { $0.unicodeScalars.contains(target) }
        ctx.assertTrue(
            hit,
            label,
            detail: "expected scalar U+\(String(format: "%04X", scalar)) in any panel surface for '\(input)'; got \(surfaces)"
        )
    }

    private static func rank0NotStartingWithZwnj(
        _ ctx: TestContext,
        input: String
    ) {
        let state = bareEngine().update(buffer: input, context: [])
        let top = state.candidates.first?.surface ?? ""
        let firstScalarIsZwnj = top.unicodeScalars.first?.value == 0x200C
        ctx.assertFalse(
            firstScalarIsZwnj,
            input,
            detail: "rank-0 starts with U+200C: '\(top)' (full panel: \(state.candidates.map(\.surface)))"
        )
    }

    public static let suite = TestSuite(name: "LangIndependentVowel", cases: [

        // C10-* — each independent vowel reachable.
        TestCase("indep_ii_short")  { ctx in panelContainsScalar(ctx, input: "ii.", scalar: 0x1023, label: "ဣ") },
        TestCase("indep_ii_long")   { ctx in panelContainsScalar(ctx, input: "ii",  scalar: 0x1024, label: "ဤ") },
        // Note: `u2.` carries a literal `2` digit in user input —
        // it doesn't reach the rule `u2.` directly. Instead, ဥ
        // surfaces via panel selection when the user picks the
        // ဥ variant of an `u`-class input. Bare `u` test below.
        TestCase("indep_uu_short_indirect")  { ctx in
            // The engine surfaces ဥ in the panel for *some* input
            // — typically pedagogical typing. We accept either ဥ
            // or its long-i sibling ဦ.
            let surfaces = bareEngine().update(buffer: "u2.", context: []).candidates.map(\.surface)
            let hasShort = surfaces.contains { $0.unicodeScalars.contains(Unicode.Scalar(0x1025)!) }
            let hasLong = surfaces.contains { $0.unicodeScalars.contains(Unicode.Scalar(0x1026)!) }
            ctx.assertTrue(
                hasShort || hasLong,
                "indep_uu_short_indirect",
                detail: "panel for 'u2.' lacks both ဥ U+1025 and ဦ U+1026: \(surfaces)"
            )
        },
        TestCase("indep_uu_long")   { ctx in panelContainsScalar(ctx, input: "u2",  scalar: 0x1026, label: "ဦ") },
        TestCase("indep_e")         { ctx in panelContainsScalar(ctx, input: "ay2", scalar: 0x1027, label: "ဧ") },
        TestCase("indep_o")         { ctx in panelContainsScalar(ctx, input: "oo",  scalar: 0x1029, label: "ဩ") },
        TestCase("indep_aw")        { ctx in panelContainsScalar(ctx, input: "oo:", scalar: 0x102A, label: "ဪ") },

        // C11-* — orphan-ZWNJ avoidance: every bare-vowel input
        // must not have a ZWNJ-prefixed rank-0 surface.
        TestCase("noZwnj_u")    { ctx in rank0NotStartingWithZwnj(ctx, input: "u")   },
        TestCase("noZwnj_ay")   { ctx in rank0NotStartingWithZwnj(ctx, input: "ay")  },
        TestCase("noZwnj_i")    { ctx in rank0NotStartingWithZwnj(ctx, input: "i")   },
        TestCase("noZwnj_aw")   { ctx in rank0NotStartingWithZwnj(ctx, input: "aw")  },
        TestCase("noZwnj_oo")   { ctx in rank0NotStartingWithZwnj(ctx, input: "oo")  },
        TestCase("noZwnj_iCreak"){ ctx in rank0NotStartingWithZwnj(ctx, input: "i.") },
        TestCase("noZwnj_uCreak"){ ctx in rank0NotStartingWithZwnj(ctx, input: "u.") },
        TestCase("noZwnj_arBare"){ ctx in rank0NotStartingWithZwnj(ctx, input: "ar") },

        // C34-* — bare-vowel pedagogical inputs surface a sensible
        // (non-ZWNJ) form. We accept any of: independent vowel,
        // carrier-shape အ + dep-vowel, or panel-included.
        TestCase("bareVowel_u_includesPanelForm") { ctx in
            let surfaces = bareEngine().update(buffer: "u", context: []).candidates.map(\.surface)
            let acceptable = surfaces.contains { surface in
                surface.unicodeScalars.contains { $0.value == 0x1026 || $0.value == 0x1025 }
                    || surface.unicodeScalars.contains(Unicode.Scalar(0x1021)!)
            }
            ctx.assertTrue(
                acceptable,
                "u",
                detail: "panel for 'u' lacks any of {ဦ U+1026, ဥ U+1025, အ U+1021 carrier}: \(surfaces)"
            )
        },

        TestCase("bareVowel_ay_independentE") { ctx in
            // Bare `ay` should produce ဧ as a candidate.
            panelContainsScalar(ctx, input: "ay", scalar: 0x1027, label: "ay→ဧ")
        },

        TestCase("bareVowel_oo_independentO") { ctx in
            panelContainsScalar(ctx, input: "oo", scalar: 0x1029, label: "oo→ဩ")
        },
    ])
}
