import Foundation
@_spi(Testing) import BurmeseIMECore

/// Regression suite for the ASCII apostrophe (`'`, U+0027) surfacing
/// literally instead of being silently consumed as a null-vowel connector.
///
/// `'` is a composing character that doubles as a null-vowel separator
/// inside Myanmar romanisation. When used as a quote mark or English
/// contraction apostrophe it must appear verbatim on the candidate
/// surface so the user gets the character they typed.
///
/// See `tasks/03-apostrophe-silently-consumed.md`.
public enum ApostropheLiteralSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func topSurface(_ engine: BurmeseEngine, _ input: String) -> String {
        engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
    }

    public static let suite = TestSuite(name: "ApostropheLiteral", cases: [

        // ── quoted Burmese words — both apostrophes ──────────────────────
        TestCase("quotedBurmese_both") { ctx in
            let engine = emptyEngine()
            for input in ["'thar'", "'aung'", "'kywantaw'"] {
                let top = topSurface(engine, input)
                ctx.assertTrue(
                    top.contains("'"),
                    input,
                    detail: "top '\(top)' lacks apostrophe; quotes are being consumed"
                )
            }
        },

        // ── leading apostrophe only ──────────────────────────────────────
        TestCase("quotedBurmese_leading") { ctx in
            let engine = emptyEngine()
            for input in ["'thar", "'aung", "'mingalar"] {
                let top = topSurface(engine, input)
                ctx.assertTrue(
                    top.hasPrefix("'"),
                    input,
                    detail: "top '\(top)' does not start with apostrophe"
                )
            }
        },

        // ── trailing apostrophe only ─────────────────────────────────────
        TestCase("quotedBurmese_trailing") { ctx in
            let engine = emptyEngine()
            for input in ["thar'", "aung'", "mingalar'"] {
                let top = topSurface(engine, input)
                ctx.assertTrue(
                    top.hasSuffix("'"),
                    input,
                    detail: "top '\(top)' does not end with apostrophe"
                )
            }
        },

        // ── negative: apostrophe-free buffers unchanged ──────────────────
        TestCase("noApostrophe_unchanged") { ctx in
            let engine = emptyEngine()
            for input in ["thar", "mingalar", "aung"] {
                let top = topSurface(engine, input)
                ctx.assertFalse(
                    top.contains("'"),
                    input,
                    detail: "top '\(top)' unexpectedly gained an apostrophe"
                )
            }
        },
    ])
}
