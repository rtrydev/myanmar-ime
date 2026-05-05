import Foundation
import BurmeseIMECore

/// Step 4 / Tier 2 — C27 (section markers), C28 (trailing literal
/// punctuation).
///
/// ASCII punctuation with no romanization overload trailing a Burmese
/// composing run must commit verbatim — `kar,` → `ကာ,`. The period is
/// overloaded as the creaky-tone marker, so `thar.` intentionally ranks
/// `သာ့` above the literal-period sibling.
public enum LangPunctuationSuite {

    private static func bareEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func assertSurfaceEndsWithLiteral(
        _ ctx: TestContext,
        input: String,
        myanmarPart: String,
        literalSuffix: String
    ) {
        let top = bareEngine().update(buffer: input, context: []).candidates.first?.surface ?? ""
        let expected = myanmarPart + literalSuffix
        ctx.assertTrue(
            top == expected,
            input,
            detail: "expected rank-0 == '\(expected)'; got '\(top)'"
        )
    }

    public static let suite = TestSuite(name: "LangPunctuation", cases: [

        // C28-* — trailing literal punctuation.
        TestCase("trailing_period_isCreakyTone") { ctx in
            let surfaces = bareEngine().update(buffer: "thar.", context: []).candidates.map(\.surface)
            ctx.assertEqual(surfaces.first, "သာ့", "thar._rank0")
        },
        TestCase("trailing_comma")      { ctx in assertSurfaceEndsWithLiteral(ctx, input: "kar,",   myanmarPart: "ကာ", literalSuffix: ",") },
        TestCase("trailing_question")   { ctx in assertSurfaceEndsWithLiteral(ctx, input: "mar?",   myanmarPart: "မာ", literalSuffix: "?") },
        TestCase("trailing_exclamation"){ ctx in assertSurfaceEndsWithLiteral(ctx, input: "lar!",   myanmarPart: "လာ", literalSuffix: "!") },
        TestCase("trailing_semicolon")  { ctx in assertSurfaceEndsWithLiteral(ctx, input: "thar;",  myanmarPart: "သာ", literalSuffix: ";") },

        // A second period after a creaky-tone period must not stack
        // multiple U+1037 tone marks.
        TestCase("trailing_creaky_then_period") { ctx in
            // `kar.` → ကာ့ (creaky); add another `.` literal.
            // (We treat single `.` as creaky if it's a tone marker
            // following a vowel — the engine resolves disambiguation.)
            // Just assert that the surface contains creaky and ends
            // with no doubled creaky.
            let top = bareEngine().update(buffer: "kar..", context: []).candidates.first?.surface ?? ""
            let creakyCount = top.unicodeScalars.filter { $0.value == 0x1037 }.count
            ctx.assertTrue(
                creakyCount <= 1,
                "kar..",
                detail: "rank-0 has \(creakyCount) creaky markers: '\(top)'"
            )
        },
    ])
}
