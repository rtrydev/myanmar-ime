import Foundation
import BurmeseIMECore

/// Step 4 / Tier 1 — C1 (bare consonant + inherent vowel).
///
/// For each of the 33 standard Burmese consonants plus the great-sa
/// ligature, asserting that the canonical bare-letter input produces
/// the right consonant on the panel. Inherent /a/ means: no dependent
/// vowel sign attached.
public enum LangBasicConsonantInventorySuite {

    private static func bareEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func assertSurfaceContains(
        _ ctx: TestContext,
        input: String,
        expected: Character,
        label: String? = nil
    ) {
        let state = bareEngine().update(buffer: input, context: [])
        let surfaces = state.candidates.map(\.surface)
        let hit = surfaces.contains { $0.contains(expected) }
        ctx.assertTrue(
            hit,
            label ?? input,
            detail: "expected '\(expected)' in any panel surface for '\(input)'; got \(surfaces)"
        )
    }

    public static let suite = TestSuite(name: "LangBasicConsonantInventory", cases: [

        // C1-01..C1-25: each base consonant with `a` inherent.
        TestCase("velar_ka")      { ctx in assertSurfaceContains(ctx, input: "ka",  expected: Myanmar.ka) },
        TestCase("velar_kha")     { ctx in assertSurfaceContains(ctx, input: "kha", expected: Myanmar.kha) },
        TestCase("velar_ga")      { ctx in assertSurfaceContains(ctx, input: "ga",  expected: Myanmar.ga) },
        TestCase("velar_gha")     { ctx in assertSurfaceContains(ctx, input: "gha", expected: Myanmar.gha) },
        TestCase("velar_nga")     { ctx in assertSurfaceContains(ctx, input: "nga", expected: Myanmar.nga) },

        TestCase("palatal_sa")    { ctx in assertSurfaceContains(ctx, input: "sa",  expected: Myanmar.ca) },
        TestCase("palatal_hsa")   { ctx in assertSurfaceContains(ctx, input: "hsa", expected: Myanmar.cha) },
        TestCase("palatal_za")    { ctx in assertSurfaceContains(ctx, input: "za",  expected: Myanmar.ja) },
        TestCase("palatal_nya")   { ctx in assertSurfaceContains(ctx, input: "nya", expected: Myanmar.nnya) },

        TestCase("dental_ta")     { ctx in assertSurfaceContains(ctx, input: "ta",  expected: Myanmar.ta) },
        TestCase("dental_hta")    { ctx in assertSurfaceContains(ctx, input: "hta", expected: Myanmar.tha) },
        TestCase("dental_da")     { ctx in assertSurfaceContains(ctx, input: "da",  expected: Myanmar.da) },
        TestCase("dental_dha")    { ctx in assertSurfaceContains(ctx, input: "dha", expected: Myanmar.dha) },
        TestCase("dental_na")     { ctx in assertSurfaceContains(ctx, input: "na",  expected: Myanmar.na) },

        TestCase("labial_pa")     { ctx in assertSurfaceContains(ctx, input: "pa",  expected: Myanmar.pa) },
        TestCase("labial_pha")    { ctx in assertSurfaceContains(ctx, input: "pha", expected: Myanmar.pha) },
        TestCase("labial_va")     { ctx in assertSurfaceContains(ctx, input: "va",  expected: Myanmar.ba) },
        TestCase("labial_ba")     { ctx in assertSurfaceContains(ctx, input: "ba",  expected: Myanmar.bha) },
        TestCase("labial_ma")     { ctx in assertSurfaceContains(ctx, input: "ma",  expected: Myanmar.ma) },

        TestCase("sonorant_ya")   { ctx in assertSurfaceContains(ctx, input: "ya",  expected: Myanmar.ya) },
        TestCase("sonorant_ra")   { ctx in assertSurfaceContains(ctx, input: "ra",  expected: Myanmar.ra) },
        TestCase("sonorant_la")   { ctx in assertSurfaceContains(ctx, input: "la",  expected: Myanmar.la) },
        TestCase("sonorant_wa")   { ctx in assertSurfaceContains(ctx, input: "wa",  expected: Myanmar.wa) },
        TestCase("sonorant_tha")  { ctx in assertSurfaceContains(ctx, input: "tha", expected: Myanmar.sa) },

        TestCase("other_ha")      { ctx in assertSurfaceContains(ctx, input: "ha",  expected: Myanmar.ha) },
        TestCase("other_aha")     { ctx in assertSurfaceContains(ctx, input: "aha", expected: Myanmar.ah) },

        // C1-26..C1-30: the seven Pali-only retroflex / "rare" consonants.
        // Their inputs use the `2`-disambiguated keys.
        TestCase("pali_zza")      { ctx in assertSurfaceContains(ctx, input: "zza",  expected: Myanmar.jha) },
        TestCase("pali_t2a")      { ctx in assertSurfaceContains(ctx, input: "t2a",  expected: Myanmar.tta) },
        TestCase("pali_ht2a")     { ctx in assertSurfaceContains(ctx, input: "ht2a", expected: Myanmar.ttha) },
        TestCase("pali_d2a")      { ctx in assertSurfaceContains(ctx, input: "d2a",  expected: Myanmar.dda) },
        TestCase("pali_dh2a")     { ctx in assertSurfaceContains(ctx, input: "dh2a", expected: Myanmar.ddha) },
        TestCase("pali_n2a")      { ctx in assertSurfaceContains(ctx, input: "n2a",  expected: Myanmar.nna) },
        TestCase("pali_l2a")      { ctx in assertSurfaceContains(ctx, input: "l2a",  expected: Myanmar.lla) },

        // C1-Special: Great Sa (ဿ) and the second nya (ဉ).
        TestCase("special_greatSa") { ctx in assertSurfaceContains(ctx, input: "ssa", expected: Myanmar.greatSa) },
        TestCase("special_flatNya") { ctx in assertSurfaceContains(ctx, input: "ny2a", expected: Myanmar.nya) },

        // Rule: a bare-consonant input must not introduce ZWNJ at the
        // start of the rank-0 surface — orphan-ZWNJ is parser
        // sentinel for "no onset", but with onset we must never see
        // U+200C in front of the consonant glyph.
        TestCase("noLeadingZwnjOnBareConsonant") { ctx in
            for input in ["ka", "ma", "tha", "pa"] {
                let state = bareEngine().update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    !top.unicodeScalars.starts(with: [Unicode.Scalar(0x200C)!]),
                    input,
                    detail: "rank-0 starts with U+200C: \(top)"
                )
            }
        },
    ])
}
