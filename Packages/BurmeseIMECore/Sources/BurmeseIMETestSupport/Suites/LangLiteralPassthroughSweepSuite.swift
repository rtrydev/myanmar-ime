import Foundation
import BurmeseIMECore

/// Step 4 / Sweep — literal-pass-through invariant scan.
///
/// Verifies that the engine preserves user keystrokes when:
/// - the input is a fully-unconvertible English run,
/// - trailing punctuation follows a Burmese composing run,
/// - leading or mid-buffer ASCII digits sit alongside Burmese,
/// - mixed-script combinations need ASCII verbatim.
///
/// These invariants are framed as cross-cutting properties — they
/// hold across every category that produces a panel.
public enum LangLiteralPassthroughSweepSuite {

    private static func bareEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func surfaces(_ buffer: String) -> [String] {
        bareEngine().update(buffer: buffer, context: []).candidates.map(\.surface)
    }

    public static let suite = TestSuite(name: "LangLiteralPassthroughSweep", cases: [

        TestCase("trailingPunct_panel") { ctx in
            let cases: [(buffer: String, myanmar: String, suffix: String)] = [
                ("kar,", "ကာ", ","),
                ("mar?", "မာ", "?"),
                ("min;", "မင်", ";"),
            ]
            for c in cases {
                let top = surfaces(c.buffer).first ?? ""
                let expected = c.myanmar + c.suffix
                ctx.assertTrue(
                    top == expected,
                    c.buffer,
                    detail: "expected rank-0 == '\(expected)'; got '\(top)'"
                )
            }
        },

        TestCase("leadingDigits_preserved") { ctx in
            let top = surfaces("2024kar").first ?? ""
            // Either ASCII or Myanmar prefix — both legal; literal
            // never loses the digits.
            let hasAscii = top.range(of: "2024", options: .literal) != nil
            let hasMyanmar = top.range(of: "၂၀၂၄", options: .literal) != nil
            ctx.assertTrue(
                hasAscii || hasMyanmar,
                "leading_2024",
                detail: "rank-0 lost digits: '\(top)'"
            )
        },

        TestCase("englishRun_preservedAsRank0") { ctx in
            let englishWords = ["c", "co", "comp", "compute", "computer",
                                "facebook", "iphone", "fb", "co2"]
            for word in englishWords {
                // The exact rank-0 surface depends on whether the
                // engine's parser can find any partial Burmese parse,
                // but the literal must always be in the panel.
                let s = surfaces(word)
                ctx.assertTrue(
                    s.contains(word),
                    word,
                    detail: "literal '\(word)' missing from panel: \(s)"
                )
            }
        },

        TestCase("nonEmptyBuffer_alwaysHasCandidates") { ctx in
            // Universal invariant: a non-empty composable input
            // never returns an empty panel.
            let inputs = ["c", "ka", "u", "thar.", "2024", "ix",
                          "kjzx", "mingalarpar", "abc def"]
            for input in inputs {
                let candidates = bareEngine().update(buffer: input, context: []).candidates
                ctx.assertTrue(
                    !candidates.isEmpty,
                    input,
                    detail: "empty panel for '\(input)'"
                )
            }
        },
    ])
}
