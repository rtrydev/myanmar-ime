import Foundation
import BurmeseIMECore

/// Step 4 / Tier 1 — C2 (consonant + each dependent vowel sign).
///
/// Each dependent vowel sign is exercised on a non-descender base
/// (`m` → မ) and on a descender base (`p` → ပ); the descender base
/// also gets the tall-aa coverage sister-cases. Every assertion
/// requires that at least one panel candidate carries the expected
/// vowel-sign codepoint adjacent to the base consonant.
public enum LangDependentVowelInventorySuite {

    private static func bareEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func panelHasSequence(
        _ ctx: TestContext,
        input: String,
        scalars: [UInt32],
        label: String? = nil
    ) {
        let state = bareEngine().update(buffer: input, context: [])
        let surfaces = state.candidates.map(\.surface)
        let needle = String(scalars.compactMap { Unicode.Scalar($0).map { Character($0) } })
        let hit = surfaces.contains { $0.range(of: needle, options: .literal) != nil }
        ctx.assertTrue(
            hit,
            label ?? input,
            detail: "expected \(needle) (\(scalars.map { String(format: "%04X", $0) }.joined(separator: " "))) in panel for '\(input)'; got \(surfaces)"
        )
    }

    public static let suite = TestSuite(name: "LangDependentVowelInventory", cases: [

        // Non-descender base (`m` / မ U+1019)
        TestCase("m_aa")     { ctx in panelHasSequence(ctx, input: "mar",  scalars: [0x1019, 0x102C]) },
        TestCase("m_i")      { ctx in panelHasSequence(ctx, input: "mi",   scalars: [0x1019, 0x102E]) },
        TestCase("m_iShort") { ctx in panelHasSequence(ctx, input: "mi.",  scalars: [0x1019, 0x102D]) },
        TestCase("m_u")      { ctx in panelHasSequence(ctx, input: "mu",   scalars: [0x1019, 0x1030]) },
        TestCase("m_uShort") { ctx in panelHasSequence(ctx, input: "mu.",  scalars: [0x1019, 0x102F]) },
        // Prescript ◌ေ (U+1031) is stored AFTER the consonant in
        // logical order even though it renders to the left visually.
        TestCase("m_ePresc") { ctx in panelHasSequence(ctx, input: "may",  scalars: [0x1019, 0x1031]) },
        TestCase("m_aiHeavy"){ ctx in panelHasSequence(ctx, input: "me:",  scalars: [0x1019, 0x1032]) },
        TestCase("m_yAsat")  { ctx in panelHasSequence(ctx, input: "me",   scalars: [0x1019, 0x101A, 0x103A]) },
        TestCase("m_aw")     { ctx in panelHasSequence(ctx, input: "maw",  scalars: [0x1019, 0x1031, 0x102C, 0x103A]) },
        TestCase("m_o")      { ctx in panelHasSequence(ctx, input: "mo",   scalars: [0x1019, 0x102D, 0x102F]) },

        // Descender base (`p` / ပ U+1015) — every aa-bearing surface
        // must use tall-aa U+102B, not round-aa U+102C.
        TestCase("p_tallAa") { ctx in panelHasSequence(ctx, input: "par",  scalars: [0x1015, 0x102B]) },
        TestCase("p_i")      { ctx in panelHasSequence(ctx, input: "pi",   scalars: [0x1015, 0x102E]) },
        TestCase("p_u")      { ctx in panelHasSequence(ctx, input: "pu",   scalars: [0x1015, 0x1030]) },
        TestCase("p_ePresc") { ctx in panelHasSequence(ctx, input: "pay",  scalars: [0x1015, 0x1031]) },
        TestCase("p_awTall") { ctx in panelHasSequence(ctx, input: "paw",  scalars: [0x1015, 0x1031, 0x102B, 0x103A]) },
        TestCase("p_o")      { ctx in panelHasSequence(ctx, input: "po",   scalars: [0x1015, 0x102D, 0x102F]) },
        TestCase("p_n")      { ctx in panelHasSequence(ctx, input: "pan",  scalars: [0x1015, 0x1014, 0x103A]) },
        TestCase("p_in")     { ctx in panelHasSequence(ctx, input: "pin",  scalars: [0x1015, 0x1004, 0x103A]) },
        TestCase("p_aungTall"){ ctx in panelHasSequence(ctx, input: "paung", scalars: [0x1015, 0x1031, 0x102B, 0x1004, 0x103A]) },

        // Negative invariant: descender base never produces round-aa
        TestCase("p_neverRoundAa") { ctx in
            let state = bareEngine().update(buffer: "par", context: [])
            let topSurface = state.candidates.first?.surface ?? ""
            ctx.assertFalse(
                topSurface.unicodeScalars.contains(Unicode.Scalar(0x102C)!),
                detail: "rank-0 'par' surface contains U+102C (round-aa): \(topSurface)"
            )
        },
    ])
}
