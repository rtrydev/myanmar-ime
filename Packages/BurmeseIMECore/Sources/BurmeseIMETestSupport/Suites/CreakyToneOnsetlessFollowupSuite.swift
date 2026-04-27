import Foundation
@_spi(Testing) import BurmeseIMECore

/// Regression suite for creaky-tone-modified open syllables followed by
/// an onset-less syllable (one whose romanization starts with a vowel letter).
///
/// When a vowel suffix whose romanization ends in `.` (e.g. `u.`, `i.`, `ar.`,
/// `in.`) is immediately followed by a vowel-starting suffix (`aung`, `ar`,
/// `aw`, `i`, …), the engine must inject a syllable boundary at the dot —
/// rendering each part independently — instead of passing the joined buffer
/// to the parser and producing a fused, malformed surface.
///
/// See `tasks/02-creaky-tone-modifier-then-onset-less-syllable.md`.
public enum CreakyToneOnsetlessFollowupSuite {

    private static let implicitAScalar: UInt32 = 0x1021  // U+1021 MYANMAR LETTER A

    private static func hasImplicitA(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value == implicitAScalar }
    }

    private static func implicitACount(_ surface: String) -> Int {
        surface.unicodeScalars.filter { $0.value == implicitAScalar }.count
    }

    /// Count of independent-vowel scalars in the surface (U+1021..U+102A,
    /// including the precomposed forms `1023`–`102A`). Used by the
    /// onset-less-split test in place of the literal `1021` count: both
    /// `အု` (1021 + 102F) and the precomposed `ဥ` (1025) are valid
    /// "split worked" surfaces — the engine's frozen-segment renderer
    /// may pick either depending on which sibling the parser ranks
    /// higher, so the assertion needs to accept both shapes.
    private static func independentVowelCount(_ surface: String) -> Int {
        surface.unicodeScalars.filter { (0x1021...0x102A).contains($0.value) }.count
    }

    private static func isLegal(_ surface: String) -> Bool {
        SyllableParser.scanOutputLegality(surface)
    }

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func topSurface(_ engine: BurmeseEngine, _ input: String) -> String {
        engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
    }

    public static let suite = TestSuite(name: "CreakyToneOnsetlessFollowup", cases: [

        // ── u-vowel dot + aung ──────────────────────────────────────────────
        // `u.` renders as ု; when followed by an onset-less suffix like `aung`
        // the engine must split at the dot so `aung` renders as `အောင်` (with
        // explicit U+1021 base) instead of fusing onto the preceding vowel.
        TestCase("uVowelCreaky_aung") { ctx in
            let engine = emptyEngine()
            for input in ["mu.aung", "ku.aung", "su.aung", "thu.aung"] {
                let top = topSurface(engine, input)
                ctx.assertTrue(
                    hasImplicitA(top),
                    input,
                    detail: "top '\(top)' lacks implicit-A (U+1021); aung suffix fused with preceding u-vowel"
                )
            }
        },

        // ── i-vowel dot + aung ──────────────────────────────────────────────
        TestCase("iVowelCreaky_aung") { ctx in
            let engine = emptyEngine()
            for input in ["mi.aung", "ki.aung", "si.aung"] {
                let top = topSurface(engine, input)
                ctx.assertTrue(
                    hasImplicitA(top),
                    input,
                    detail: "top '\(top)' lacks implicit-A; aung fused with preceding i-vowel"
                )
            }
        },

        // ── u-vowel dot + various onset-less suffixes ───────────────────────
        // `ar`, `aw`, and `i` all need an explicit U+1021 base after split.
        // `ay` maps to the standalone ဧ letter and already has no fusing issue,
        // so it only needs the legality gate.
        TestCase("uVowelCreaky_otherSyllables") { ctx in
            let engine = emptyEngine()
            for input in ["mu.ar", "mu.aw", "mu.i"] {
                let top = topSurface(engine, input)
                ctx.assertTrue(
                    hasImplicitA(top),
                    input,
                    detail: "top '\(top)' lacks implicit-A; suffix fused with preceding u-vowel"
                )
            }
            // mu.ay → ဧ is already a standalone letter; check legality only
            let topAy = topSurface(engine, "mu.ay")
            ctx.assertTrue(
                isLegal(topAy),
                "mu.ay",
                detail: "top '\(topAy)' fails scanOutputLegality"
            )
        },

        // ── ar-coda dot + aung ──────────────────────────────────────────────
        // `ar.` renders as `ာ့` (U+102C U+1037). A following `aung` must not
        // attach its e/aa-vowel marks to the creaky-tone marker — the surface
        // must be legal under `scanOutputLegality`.
        TestCase("arCodaCreaky_aung") { ctx in
            let engine = emptyEngine()
            for input in ["thar.aung", "mar.aung", "ngar.aung"] {
                let top = topSurface(engine, input)
                ctx.assertTrue(
                    isLegal(top),
                    input,
                    detail: "top '\(top)' fails scanOutputLegality; dependent-vowel attached to creaky-tone marker"
                )
                ctx.assertTrue(
                    hasImplicitA(top),
                    input,
                    detail: "top '\(top)' lacks implicit-A; aung part has no base consonant"
                )
            }
        },

        // ── ar-coda dot + other onset-less syllables ────────────────────────
        TestCase("arCodaCreaky_otherSyllables") { ctx in
            let engine = emptyEngine()
            for input in ["thar.aw", "thar.ar", "thar.i"] {
                let top = topSurface(engine, input)
                ctx.assertTrue(
                    isLegal(top),
                    input,
                    detail: "top '\(top)' fails scanOutputLegality"
                )
                ctx.assertTrue(
                    hasImplicitA(top),
                    input,
                    detail: "top '\(top)' lacks implicit-A; suffix fused with ar-coda vowel"
                )
            }
        },

        // ── onset-less open-vowel dot + aung ────────────────────────────────
        // `u.aung` and `i.aung` have no base consonant for the first syllable.
        // Both sides of the split need an independent-vowel anchor (one per
        // syllable). The first-syllable anchor may surface either as the
        // generic U+1021 + dependent vowel pair (`အု`) or as the precomposed
        // independent vowel (`ဥ` = U+1025). Count any independent-vowel
        // scalar (1021..102A) so both rendering shapes pass — the test
        // verifies that the split fired, not a particular spelling choice.
        TestCase("onsetlessVowelCreaky_aung") { ctx in
            let engine = emptyEngine()
            for input in ["u.aung", "i.aung"] {
                let top = topSurface(engine, input)
                let independentCount = independentVowelCount(top)
                ctx.assertTrue(
                    independentCount >= 2,
                    input,
                    detail: "top '\(top)' has only \(independentCount) independent-vowel scalar(s); expected ≥2 (one per split syllable)"
                )
            }
        },

        // ── negative: asat-coda creaky must retain correct shape ─────────────
        // `min.aung`, `khin.aung` already parse correctly via the DP structural
        // break after the asat coda; `kun.aung` uses the literal-dot path. None
        // of these should regress after the split fix is applied.
        TestCase("asatCodaCreaky_unchanged") { ctx in
            let engine = emptyEngine()
            for input in ["min.aung", "khin.aung"] {
                let top = topSurface(engine, input)
                ctx.assertTrue(
                    hasImplicitA(top),
                    input,
                    detail: "top '\(top)' lost implicit-A; regression in asat-coda creaky case"
                )
            }
        },

        // ── negative: literal-dot path must be unchanged ────────────────────
        TestCase("literalDot_unchanged") { ctx in
            let engine = emptyEngine()
            for input in ["kya.aung", "kun.aung"] {
                let top = topSurface(engine, input)
                ctx.assertTrue(
                    hasImplicitA(top),
                    input,
                    detail: "top '\(top)' lost implicit-A; literal-dot path regressed"
                )
            }
        },
    ])
}
