import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for task 01: when the right-shrink probe drops trailing
/// ASCII letters that cannot compose into Myanmar (`c`, `f`, `q`,
/// `v`, `x`, `z`, plus surplus letters past a complete syllable), the
/// engine must keep at least one candidate so the user can commit
/// what they have so far.
///
/// Updated invariant (TASK-043, 2026-05-03): the panel is **never
/// empty** for any non-empty composable buffer. Buffers with a
/// Myanmar-bearing composable prefix (`abc` → `အဘ` + `c`, `aungc`
/// → `အောင်` + `c`, `kar:bc` → `ကား` + `:bc`) keep their Myanmar
/// candidate at rank 0; buffers with no acceptable Myanmar parse
/// (`fox`, `xyz`, `ccc`, `c`, `comp`, `facebook`) get a synthesized
/// literal candidate equal to the raw buffer so the user can commit
/// what they typed.
public enum UnparseableTailFallbackSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func surfacesContainMyanmar(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value >= 0x1000 && $0.value <= 0x109F }
    }

    private static func describe(_ candidates: [Candidate]) -> String {
        String(describing: candidates.prefix(5).map(\.surface))
    }

    public static let suite = TestSuite(name: "UnparseableTailFallback", cases: [

        // Buffers whose composable prefix produces at least one
        // Myanmar scalar but whose tail ends in unparseable ASCII
        // must surface a candidate combining the Myanmar prefix and
        // the literal tail. The exact tail rendering is allowed to
        // differ (mapped vs raw) but the candidate must exist.
        TestCase("partialComposition_keepsMyanmarPlusLiteralTail") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, mustContain: Character)] = [
                ("abc", "c"),
                ("kac", "c"),
                ("aungc", "c"),
                ("kar:bc", "c"),
            ]
            for entry in cases {
                let state = engine.update(buffer: entry.buffer, context: [])
                ctx.assertFalse(
                    state.candidates.isEmpty,
                    entry.buffer,
                    detail: "panel empty for partial-composition buffer"
                )
                let hasMyanmarSurface = state.candidates.contains {
                    surfacesContainMyanmar($0.surface)
                }
                ctx.assertTrue(
                    hasMyanmarSurface,
                    entry.buffer,
                    detail: "no Myanmar-bearing candidate; got \(describe(state.candidates))"
                )
            }
        },

        // Whenever the buffer's first letter alone composes to at
        // least one Myanmar scalar, appending an unparseable letter
        // must not empty the panel — the right-shrink probe should
        // back off to the composable prefix and surface it with the
        // dropped letter as a literal tail.
        TestCase("composablePrefixPlusUnparseableTail_neverEmpty") { ctx in
            let engine = emptyEngine()
            let composable: [Character] = [
                "a", "b", "d", "e", "g", "h", "i", "j",
                "k", "l", "m", "n", "o", "p", "r", "s",
                "t", "u", "w", "y",
            ]
            let unparseable: [Character] = ["c", "f", "q", "v", "x", "z"]
            for first in composable {
                guard !engine.update(buffer: String(first), context: []).candidates.isEmpty
                else { continue }
                for second in unparseable {
                    let buffer = String([first, second])
                    let state = engine.update(buffer: buffer, context: [])
                    ctx.assertFalse(
                        state.candidates.isEmpty,
                        "buf_\(buffer)",
                        detail: "panel empty for composable+unparseable buffer"
                    )
                }
            }
        },

        // Spot-check the regression cases listed in the task: the
        // top candidate for each must keep both the Myanmar prefix
        // and a literal tail bearing the dropped ASCII letter(s).
        TestCase("regressionTable_topSurfaceShape") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, prefixHex: [UInt32])] = [
                ("abc", [0x1021, 0x1018]),         // အဘ + c
                ("aungc", [0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
                ("kac", [0x1000]),
            ]
            for entry in cases {
                let state = engine.update(buffer: entry.buffer, context: [])
                let myanmarTops = state.candidates.filter {
                    surfacesContainMyanmar($0.surface)
                }
                ctx.assertFalse(
                    myanmarTops.isEmpty,
                    entry.buffer,
                    detail: "no Myanmar-bearing candidate at all"
                )
                let prefix = String(String.UnicodeScalarView(
                    entry.prefixHex.compactMap(Unicode.Scalar.init)
                ))
                let withMatchingPrefix = myanmarTops.contains {
                    $0.surface.hasPrefix(prefix) && $0.surface.contains("c")
                }
                ctx.assertTrue(
                    withMatchingPrefix,
                    entry.buffer,
                    detail: "no candidate '\(prefix)…c' found; got \(describe(state.candidates))"
                )
            }
        },

        // Sibling regression: composable tails still compose cleanly
        // to pure-Myanmar surfaces — the fix must not change the
        // well-behaved path.
        //
        // TASK-068: `ace` and `acer` (lone `c` between `a` and the
        // following vowel rule) were previously in this regression
        // set and asserted the literal-`c`-dropped Myanmar surface
        // `အယ်` / `အယ်ရ` — pinning the silent-absorption bug. With
        // the new `class_E_unsupportedLetterMidBuffer` promotion
        // path, the literal raw buffer correctly takes rank 0 for
        // these lone-`c` buffers. They have been removed from this
        // composable-tail regression; the `ab` case (no
        // unsupported letter) remains as the regression baseline.
        TestCase("composableTailRegression") { ctx in
            let engine = emptyEngine()
            for (buffer, expected) in [("ab", "\u{1021}\u{1018}")] {
                let top = engine.update(buffer: buffer, context: []).candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top == expected,
                    buffer,
                    detail: "top='\(top)' expected='\(expected)'"
                )
            }
        },
    ])
}
