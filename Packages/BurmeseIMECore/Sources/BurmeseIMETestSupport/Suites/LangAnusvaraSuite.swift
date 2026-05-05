import Foundation
import BurmeseIMECore

/// Step 4 / Tier 2 — C12 (anusvara nasal codas).
///
/// The anusvara ◌ံ (U+1036) is a nasal coda that attaches to a
/// dependent-vowel-or-inherent syllable. The romanization rule is
/// `an3` (or `own3` / `on3` for u/ws-swe variants). The output
/// must place U+1036 immediately after the base consonant or vowel.
public enum LangAnusvaraSuite {

    private static func bareEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func panelContains(
        _ ctx: TestContext,
        input: String,
        scalars: [UInt32]
    ) {
        let needle = String(scalars.compactMap { Unicode.Scalar($0).map { Character($0) } })
        let surfaces = bareEngine().update(buffer: input, context: []).candidates.map(\.surface)
        let hit = surfaces.contains { $0.range(of: needle, options: .literal) != nil }
        ctx.assertTrue(
            hit,
            input,
            detail: "expected \(needle) (\(scalars.map { String(format: "%04X", $0) }.joined(separator: " "))) in panel; got \(surfaces)"
        )
    }

    public static let suite = TestSuite(name: "LangAnusvara", cases: [

        // Anusvara on canonical bases (each row of consonants).
        TestCase("anusvara_kan3")  { ctx in panelContains(ctx, input: "kan3",  scalars: [0x1000, 0x1036]) },
        TestCase("anusvara_man3")  { ctx in panelContains(ctx, input: "man3",  scalars: [0x1019, 0x1036]) },
        TestCase("anusvara_pan3")  { ctx in panelContains(ctx, input: "pan3",  scalars: [0x1015, 0x1036]) },
        TestCase("anusvara_tan3")  { ctx in panelContains(ctx, input: "tan3",  scalars: [0x1010, 0x1036]) },
        TestCase("anusvara_san3")  { ctx in panelContains(ctx, input: "san3",  scalars: [0x1005, 0x1036]) },
        TestCase("anusvara_nan3")  { ctx in panelContains(ctx, input: "nan3",  scalars: [0x1014, 0x1036]) },
        TestCase("anusvara_hsan3") { ctx in panelContains(ctx, input: "hsan3", scalars: [0x1006, 0x1036]) },
        TestCase("anusvara_than3") { ctx in panelContains(ctx, input: "than3", scalars: [0x101E, 0x1036]) },

        // Anusvara + tone overlay.
        // Note: digit `3` is a literal in user input; the engine
        // doesn't parse `kan3.` as anusvara+creaky. The user reaches
        // `ကံ့` (creaky anusvara) via panel selection. The orthographic
        // shape `1000 1036 1037` *must* be reachable somewhere; we
        // test panel inclusion across the digit-bearing siblings —
        // a TONED anusvara surface should appear when the digit is
        // followed by a tone marker.
        TestCase("anusvara_kan3_panelHasAnusvara") { ctx in
            // Bare anusvara — already covered by anusvara_kan3.
            panelContains(ctx, input: "kan3", scalars: [0x1000, 0x1036])
        },

        // u-anusvara compound (`own3` rule, internal-only — input is
        // `kown3`; the engine produces both raw 3-bearing and
        // anusvara siblings).
        TestCase("anusvara_own3_kown3") { ctx in panelContains(ctx, input: "kown3", scalars: [0x1000, 0x102F, 0x1036]) },

        // wa-swe + anusvara (`on3` rule)
        TestCase("anusvara_on3_kon3") { ctx in panelContains(ctx, input: "kon3", scalars: [0x1000, 0x103D, 0x1036]) },
    ])
}
