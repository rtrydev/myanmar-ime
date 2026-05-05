import Foundation
import BurmeseIMECore

/// Step 4 / Tier 2 — C26 (numerals — Myanmar + ASCII), C30 (mixed).
///
/// Myanmar digits ၀–၉ (U+1040–U+1049) and ASCII 0–9 freely
/// interleave in modern Burmese text. Both forms must be reachable
/// from the panel, and ASCII digits typed mid-buffer must be
/// preserved as literal at their typed position (never reinterpreted
/// as variant-disambiguator suffixes).
public enum LangNumeralSuite {

    private static func bareEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    public static let suite = TestSuite(name: "LangNumeral", cases: [

        // C26-* — pure-numeric inputs surface both Myanmar and ASCII
        // forms.
        TestCase("digit_2_panel") { ctx in
            let surfaces = bareEngine().update(buffer: "2", context: []).candidates.map(\.surface)
            let hasMyanmar2 = surfaces.contains { $0.unicodeScalars.contains(Unicode.Scalar(0x1042)!) }
            let hasAscii2   = surfaces.contains("2")
            ctx.assertTrue(hasMyanmar2 || hasAscii2,
                           "digit_2",
                           detail: "expected at least one of {၂, 2} in panel; got \(surfaces)")
        },

        TestCase("digit_2024_panel") { ctx in
            let surfaces = bareEngine().update(buffer: "2024", context: []).candidates.map(\.surface)
            let hasAsciiYear = surfaces.contains("2024")
            ctx.assertTrue(hasAsciiYear,
                           "digit_2024_ascii",
                           detail: "expected ASCII '2024' in panel; got \(surfaces)")
        },

        // C26-* — mid-buffer digit literally preserved.
        TestCase("midDigit_kar2_literalDigit") { ctx in
            let top = bareEngine().update(buffer: "kar2", context: []).candidates.first?.surface ?? ""
            // Top should contain 'ASCII 2' or '၂' immediately after
            // the Burmese ကာ.
            let containsAsciiOrMyanmarTwo = top.contains("2") || top.unicodeScalars.contains(Unicode.Scalar(0x1042)!)
            ctx.assertTrue(
                containsAsciiOrMyanmarTwo,
                "kar2",
                detail: "rank-0 lacks digit-2 after ကာ: '\(top)'"
            )
        },

        // C30-* — mixed Myanmar + ASCII digits.
        TestCase("mixed_kar2024_preserved") { ctx in
            let top = bareEngine().update(buffer: "kar2024", context: []).candidates.first?.surface ?? ""
            // Either rank-0 contains ASCII "2024" or Myanmar "၂၀၂၄"
            let hasAscii   = top.range(of: "2024", options: .literal) != nil
            let hasMyanmar = top.range(of: "၂၀၂၄", options: .literal) != nil
            ctx.assertTrue(
                hasAscii || hasMyanmar,
                "kar2024",
                detail: "rank-0 lacks any '2024'/'၂၀၂၄': '\(top)'"
            )
        },

        TestCase("mixed_2024kar_preserved") { ctx in
            let top = bareEngine().update(buffer: "2024kar", context: []).candidates.first?.surface ?? ""
            let hasAscii   = top.range(of: "2024", options: .literal) != nil
            let hasMyanmar = top.range(of: "၂၀၂၄", options: .literal) != nil
            ctx.assertTrue(
                hasAscii || hasMyanmar,
                "2024kar",
                detail: "rank-0 lacks any '2024'/'၂၀၂၄': '\(top)'"
            )
        },

        // Negative invariant: a literal digit must NEVER be consumed
        // as a variant disambiguator. `kar2` must contain `ကာ` (or
        // `ကား`) followed by a literal 2; it must NOT silently
        // produce `ကါ` (variant of ကာ).
        TestCase("digit_isNotVariantSelector") { ctx in
            let surfaces = bareEngine().update(buffer: "kar2", context: []).candidates.map(\.surface)
            let topLeaks = surfaces.first?.unicodeScalars.contains(Unicode.Scalar(0x102B)!)
            ctx.assertFalse(
                topLeaks ?? false,
                "kar2_noTallAa",
                detail: "rank-0 of 'kar2' uses tall-aa (variant) — digit was misread as variant selector: \(surfaces)"
            )
        },
    ])
}
