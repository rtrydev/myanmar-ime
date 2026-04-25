import Foundation
@_spi(Testing) import BurmeseIMECore

/// Regression suite for mid-buffer ASCII digits landing inside inferred
/// virama / kinzi clusters.
///
/// When the user places a digit between two syllables (e.g. `min2galar`,
/// `tin2gar`) the digit is a hard syllable break — the stack / kinzi
/// inference must not fire across it. The digit should appear in the
/// candidate surface as a Myanmar numeral (or ASCII) between two cleanly-
/// rendered syllables, never inside a virama or kinzi grapheme cluster.
///
/// See `tasks/01-mid-buffer-digit-splices-into-stack-cluster.md`.
public enum MidBufferDigitStackSplitSuite {

    private static let viramaScalar: UInt32 = 0x1039

    private static func hasVirama(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value == viramaScalar }
    }

    private static func hasDigitScalar(_ surface: String) -> Bool {
        for s in surface.unicodeScalars {
            let v = s.value
            if (v >= 0x30 && v <= 0x39) || (v >= 0x1040 && v <= 0x1049) { return true }
        }
        return false
    }

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func topSurface(_ engine: BurmeseEngine, _ input: String) -> String {
        engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
    }

    public static let suite = TestSuite(name: "MidBufferDigitStackSplit", cases: [

        // ── Kinzi site interrupted by digit — no virama allowed ───────────
        // The digit acts as a hard syllable break; inference must not fire
        // across the digit boundary.
        TestCase("kinziSite_singleDigit_noVirama") { ctx in
            let engine = emptyEngine()
            for input in ["min2galar", "tin2gar", "khin2gar"] {
                let top = topSurface(engine, input)
                ctx.assertFalse(
                    hasVirama(top),
                    input,
                    detail: "top '\(top)' contains virama; digit must break the stack site"
                )
            }
        },

        TestCase("kinziSite_leadingZeroDigit_noVirama") { ctx in
            let engine = emptyEngine()
            let top = topSurface(engine, "min0galar")
            ctx.assertFalse(
                hasVirama(top),
                "min0galar",
                detail: "top '\(top)' contains virama"
            )
        },

        TestCase("kinziSite_multiDigit_noVirama") { ctx in
            let engine = emptyEngine()
            let top = topSurface(engine, "min12345galar")
            ctx.assertFalse(
                hasVirama(top),
                "min12345galar",
                detail: "top '\(top)' contains virama"
            )
        },

        // ── Pali stack site interrupted by digit ──────────────────────────
        TestCase("paliStack_singleDigit_noVirama") { ctx in
            let engine = emptyEngine()
            for input in ["at2ta", "at2t2a"] {
                let top = topSurface(engine, input)
                ctx.assertFalse(
                    hasVirama(top),
                    input,
                    detail: "top '\(top)' contains virama"
                )
            }
        },

        // ── Diphthong-coda site interrupted by digit ──────────────────────
        // `aing` diphthong already has a built-in nga-asat coda. A digit
        // between the diphthong and a following consonant must suppress any
        // virama inference (task 01 generalisation of task 04).
        TestCase("diphthongCoda_digitBreak_noVirama") { ctx in
            let engine = emptyEngine()
            for input in ["kaing2ga", "maing2ga", "maung2ga"] {
                let top = topSurface(engine, input)
                ctx.assertFalse(
                    hasVirama(top),
                    input,
                    detail: "top '\(top)' contains virama"
                )
            }
        },

        // ── Digit must appear in the candidate surface ────────────────────
        // After the digit-break fix the digit itself should be re-injected
        // into the surface as a Myanmar numeral (1040–1049) or ASCII digit.
        TestCase("digitPreservedInSurface") { ctx in
            let engine = emptyEngine()
            for input in ["min2galar", "tin2gar", "at2ta"] {
                let top = topSurface(engine, input)
                ctx.assertTrue(
                    hasDigitScalar(top),
                    input,
                    detail: "top '\(top)' contains no digit scalar; digit was lost"
                )
            }
        },

        // ── Non-stack digit positions must not regress ────────────────────
        TestCase("nonStack_khin2khin_noVirama") { ctx in
            // 'n' before 'k' is not a valid Pali stack upper — inference
            // would not fire here even before the fix. Guard against regression.
            let engine = emptyEngine()
            let top = topSurface(engine, "khin2khin")
            ctx.assertFalse(
                hasVirama(top),
                "khin2khin",
                detail: "top '\(top)' unexpectedly contains virama"
            )
        },

        TestCase("noDigit_inference_unchanged") { ctx in
            // `mingalar` (no digit) must still produce kinzi as usual.
            let engine = emptyEngine()
            let top = topSurface(engine, "mingalar")
            ctx.assertTrue(
                hasVirama(top),
                "mingalar",
                detail: "top '\(top)' lost virama; inference regressed for digit-free input"
            )
        },

        TestCase("digitAtBoundary_min23_noVirama") { ctx in
            // Trailing digits — should not produce virama regardless.
            let engine = emptyEngine()
            let top = topSurface(engine, "min23")
            ctx.assertFalse(
                hasVirama(top),
                "min23",
                detail: "top '\(top)' contains virama"
            )
        },
    ])
}
