import Foundation
import BurmeseIMECore

/// Step 4 / Tier 3 — C35 (ya-pin / ya-yit alternation).
///
/// Several palatalised stop onsets have two legal orthographic
/// surfaces — ya-pin (◌ျ) and ya-yit (◌ြ). Both must be reachable
/// from the panel for the canonical romanisation. The IME's
/// medial-promotion rule may put ya-pin at rank 0 (per lexicon
/// dominance evidence) but ya-yit must still appear as an
/// alternative.
public enum LangYaPinYaYitAlternationSuite {

    private static func bareEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func panelHasBoth(
        _ ctx: TestContext,
        input: String,
        yaPinSurface: String,
        yaYitSurface: String
    ) {
        let surfaces = bareEngine().update(buffer: input, context: []).candidates.map(\.surface)
        ctx.assertTrue(
            surfaces.contains(yaPinSurface),
            input + "_yapin",
            detail: "expected '\(yaPinSurface)' in panel; got \(surfaces)"
        )
        ctx.assertTrue(
            surfaces.contains(yaYitSurface),
            input + "_yayit",
            detail: "expected '\(yaYitSurface)' in panel; got \(surfaces)"
        )
    }

    public static let suite = TestSuite(name: "LangYaPinYaYitAlternation", cases: [

        // Note: `ch` is itself a cluster alias for kha + ya-pin;
        // typing `cha` produces the bare cluster (no extra `y`).
        TestCase("alt_kya")  { ctx in panelHasBoth(ctx, input: "kya",  yaPinSurface: "ကျ", yaYitSurface: "ကြ") },
        TestCase("alt_cha")  { ctx in panelHasBoth(ctx, input: "cha",  yaPinSurface: "ချ", yaYitSurface: "ခြ") },
        TestCase("alt_gya")  { ctx in panelHasBoth(ctx, input: "gya",  yaPinSurface: "ဂျ", yaYitSurface: "ဂြ") },
        TestCase("alt_pya")  { ctx in panelHasBoth(ctx, input: "pya",  yaPinSurface: "ပျ", yaYitSurface: "ပြ") },
        TestCase("alt_mya")  { ctx in panelHasBoth(ctx, input: "mya",  yaPinSurface: "မျ", yaYitSurface: "မြ") },
    ])
}
