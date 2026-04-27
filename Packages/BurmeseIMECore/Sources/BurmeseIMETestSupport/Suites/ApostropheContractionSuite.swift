import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-021: letter-flanked apostrophes that match common English
/// contraction shapes (`don't`, `can't`, `it's`, `we're`, …) must
/// surface as a literal candidate so the user can commit the typed
/// English text. Burmese-style null-vowel separator usage
/// (`nya'n`, `kya'aung`, `a'a`) keeps the existing connector behaviour
/// at the top rank.
public enum ApostropheContractionSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static let englishContractions: [String] = [
        "don't", "can't", "won't", "it's",
        "we're", "you're", "isn't",
    ]

    /// Burmese-side null-vowel-separator inputs. The connector-rule top
    /// rank must remain the Myanmar-only parsed form; no behavioural
    /// regression for users who explicitly typed `'` between Burmese-
    /// readable letters.
    private static let burmeseConnectorInputs: [String] = [
        "a'a", "nya'n", "ka'la", "kya'aung",
    ]

    public static let suite = TestSuite(name: "ApostropheContraction", cases: [

        TestCase("englishContractions_panelNonEmpty") { ctx in
            let engine = emptyEngine()
            for input in englishContractions {
                let state = engine.update(buffer: input, context: [])
                ctx.assertFalse(
                    state.candidates.isEmpty,
                    input,
                    detail: "panel must be non-empty for '\(input)'"
                )
            }
        },

        TestCase("englishContractions_literalCandidatePresent") { ctx in
            let engine = emptyEngine()
            for input in englishContractions {
                let state = engine.update(buffer: input, context: [])
                let surfaces = state.candidates.map(\.surface)
                ctx.assertTrue(
                    surfaces.contains(input),
                    input,
                    detail: "panel must contain literal candidate '\(input)'; got \(surfaces)"
                )
            }
        },

        TestCase("englishContractions_literalAtRankZero") { ctx in
            let engine = emptyEngine()
            for input in englishContractions {
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top,
                    input,
                    "literalRank0_\(input)"
                )
            }
        },

        TestCase("burmeseConnector_topUnchanged") { ctx in
            let engine = emptyEngine()
            // Each entry: input + expected rank-0 prefix character set.
            // We verify that the rank-0 surface is purely Myanmar-or-zero-
            // width (no apostrophe leaks at the top), preserving the
            // existing connector-rule behaviour.
            for input in burmeseConnectorInputs {
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                let isMyanmarOnly = top.unicodeScalars.allSatisfy { scalar in
                    (scalar.value >= 0x1000 && scalar.value <= 0x109F)
                        || scalar.value == 0x200B
                        || scalar.value == 0x200C
                }
                ctx.assertFalse(
                    top.isEmpty,
                    "burmeseConnector_nonEmpty_\(input)",
                    detail: "rank 0 must be non-empty for '\(input)'"
                )
                ctx.assertTrue(
                    isMyanmarOnly,
                    "burmeseConnector_myanmarOnly_\(input)",
                    detail: "rank 0 for '\(input)' must remain Myanmar-only; got '\(top)'"
                )
            }
        },
    ])
}
