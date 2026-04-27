import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-018: long inherent-A chains followed by more letters past
/// the 6-character dropped-tail gate must not leak raw ASCII into
/// the rank-0 candidate surface. The right-shrink probe peels the
/// trailing letters into the literal tail; without this fix
/// `composeLetterRunsInTail` is gated off and the user sees raw
/// ASCII (`ကaaaakaa` for `kaaaaakaa`) instead of clean Myanmar.
///
/// The acceptance invariant: for any buffer whose composable run
/// is purely ASCII letters (no digits, no literal punctuation, no
/// spaces), the rank-0 surface contains no raw ASCII letters past
/// any Myanmar scalar.
public enum InherentAChainOverflowSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    /// True when `surface` contains an ASCII letter (U+0041..U+005A
    /// or U+0061..U+007A). The TASK-018 invariant rejects any rank-0
    /// surface where this is true and the input was a pure-ASCII
    /// Roman composing buffer.
    private static func surfaceHasAsciiLetter(_ surface: String) -> Bool {
        surface.unicodeScalars.contains {
            (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
        }
    }

    /// Onsets that should not collide with the inherent-A chain
    /// (excludes medial-bearing keys / cluster aliases / digit-bearing
    /// variants — those interact with the parser's other special
    /// paths).
    private static let onsets: [String] = [
        "k", "g", "n", "p", "h", "m", "y", "r", "l", "w", "s", "z",
        "th", "ny", "ng", "ph", "kh",
    ]

    public static let suite = TestSuite(name: "InherentAChainOverflow", cases: [

        // Specific reproductions documented in TASK-018.
        TestCase("repro_kaaaaakaa_isMyanmarOnly") { ctx in
            let engine = emptyEngine()
            let inputs = ["kaaaaakaa", "kaaaaaakaa", "kaaaaakaaa",
                          "naaaaakaa", "thaaaaakaa", "phaaaaakaa"]
            for buffer in inputs {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    surfaceHasAsciiLetter(surface),
                    buffer,
                    detail: "rank 0 leaked ASCII letters for '\(buffer)' surface='\(surface)'"
                )
                ctx.assertFalse(
                    surface.isEmpty,
                    "\(buffer)_nonEmpty",
                    detail: "rank 0 must not be empty for '\(buffer)'"
                )
            }
        },

        // Pathological auto-repeat: 16 trailing `a`s.
        TestCase("repro_extremeChain_isMyanmarOnly") { ctx in
            let engine = emptyEngine()
            let buffer = "kaaaaaaaaaaaaaaaaa"
            let surface = engine.update(buffer: buffer, context: [])
                .candidates.first?.surface ?? ""
            ctx.assertFalse(
                surfaceHasAsciiLetter(surface),
                buffer,
                detail: "rank 0 leaked ASCII letters for '\(buffer)' surface='\(surface)'"
            )
        },

        // Sweep across every plain consonant onset and chain length.
        TestCase("sweep_consonantsAndChainLengths_areMyanmarOnly") { ctx in
            let engine = emptyEngine()
            for onset in onsets {
                for chainLen in 5...10 {
                    let chain = String(repeating: "a", count: chainLen)
                    for tail in ["kaa", "ka", "kaaa"] {
                        let buffer = onset + chain + tail
                        let surface = engine.update(buffer: buffer, context: [])
                            .candidates.first?.surface ?? ""
                        ctx.assertFalse(
                            surfaceHasAsciiLetter(surface),
                            buffer,
                            detail: "rank 0 leaked ASCII letters for '\(buffer)' surface='\(surface)'"
                        )
                    }
                }
            }
        },

        // Counter-example: short chains continue to render cleanly.
        TestCase("counter_shortChain_unchanged") { ctx in
            let engine = emptyEngine()
            for buffer in ["kaakaa", "kaaakaa", "kaaaakaa"] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    surfaceHasAsciiLetter(surface),
                    buffer,
                    detail: "regressed short-chain behaviour for '\(buffer)' surface='\(surface)'"
                )
            }
        },
    ])
}
