import Foundation
@_spi(Testing) import BurmeseIMECore

/// Regression suite for the natural English-style romanization `aing`
/// of the diphthong `ိုင်`.
///
/// `Romanization.vowels` only stores the diphthong under the short
/// key `ai` (and its `ai.` / `ai:` tonal variants), but every published
/// Burmese romanization table teaches the syllable as **`aing`**: the
/// `ng` *is* the audible coda. When users type the natural form, the
/// parser greedily consumes `ai` as the vowel rule and the trailing
/// `ng` becomes a stranded bare nga consonant — surfacing as a doubled
/// `င + င` shape which is not legal Burmese.
///
/// The expected behaviour is for the romanization scheme to accept the
/// `aing` / `aing.` / `aing:` family as aliases of the corresponding
/// `ai*` rules. The parser then consumes the entire `aing<X>` substring
/// as one vowel rule, no double-nga is emitted, and any following onset
/// composes into its own syllable normally.
///
/// See `tasks/02-bare-aing-doubled-nga.md`.
public enum BareAingDiphthongSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func topSurface(_ engine: BurmeseEngine, _ input: String) -> String {
        engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
    }

    /// True when the surface contains two consecutive bare `င` (U+1004)
    /// scalars that aren't a kinzi marker (which would have a virama
    /// between them). The doubled-nga shape that this regression covers
    /// is `... 1004 103A 1004 ...` — diphthong's nga + asat, then the
    /// stranded bare nga.
    private static func surfaceHasDoubledNga(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 3 else { return false }
        for i in 0..<(scalars.count - 2) {
            // ... 1004 103A 1004 ...
            if scalars[i] == 0x1004,
               scalars[i + 1] == 0x103A,
               scalars[i + 2] == 0x1004 {
                return true
            }
        }
        return false
    }

    /// True when the surface starts with the `ိုင်` diphthong cluster
    /// (102D 102F 1004 ... 103A), allowing an optional leading `အ`
    /// U+1021 from the orphan-vowel promotion pass and an optional
    /// creaky-tone marker U+1037 between the nga and the asat (the
    /// `aing.` / `ai.` shape).
    private static func surfaceLeadsWithAiDiphthong(_ surface: String) -> Bool {
        let scalars = surface.unicodeScalars.map(\.value)
        var i = 0
        if i < scalars.count, scalars[i] == 0x1021 { i += 1 }
        guard i + 3 < scalars.count else { return false }
        guard scalars[i] == 0x102D else { return false }
        guard scalars[i + 1] == 0x102F else { return false }
        guard scalars[i + 2] == 0x1004 else { return false }
        // Allow optional creaky-tone (1037) between nga and asat.
        var afterNga = i + 3
        if scalars[afterNga] == 0x1037 {
            afterNga += 1
        }
        guard afterNga < scalars.count, scalars[afterNga] == 0x103A else {
            return false
        }
        return true
    }

    public static let suite = TestSuite(name: "BareAingDiphthong", cases: [

        // ── bare aing alone ─────────────────────────────────────────────────
        // Plain `aing` (4 chars) is the natural typing for `အိုင်`. The
        // current engine emits `အိုင်င` (doubled nga). After fix:
        // single diphthong, no second nga.
        TestCase("bareAingNoDoubledNga") { ctx in
            let engine = emptyEngine()
            for input in ["aing"] {
                let top = topSurface(engine, input)
                ctx.assertFalse(
                    surfaceHasDoubledNga(top),
                    input,
                    detail: "top '\(top)' contains stranded bare nga after diphthong"
                )
                ctx.assertTrue(
                    surfaceLeadsWithAiDiphthong(top),
                    input,
                    detail: "top '\(top)' does not lead with the diphthong cluster"
                )
            }
            // `ainga` (5 chars) and similar trailing-`a` shapes are
            // ambiguous between "diphthong + stray a" and "i +
            // anga"; either reading is acceptable provided the
            // surface stays orthographically clean (no doubled nga).
            for input in ["ainga"] {
                let top = topSurface(engine, input)
                ctx.assertFalse(
                    surfaceHasDoubledNga(top),
                    input,
                    detail: "top '\(top)' contains stranded bare nga after diphthong"
                )
            }
        },

        // ── aing<consonant> shapes (non-velar lower) ───────────────────────
        // The kinzi-collapse fast-path only fires when the lower forms
        // a same-class stack with nga (velar). For `aingthar`,
        // `aingar` and `aingtaung` (non-velar / vowel lower), the
        // current engine still emits the doubled-nga form. After fix:
        // diphthong + clean following syllable.
        TestCase("aingFollowedByNonVelar") { ctx in
            let engine = emptyEngine()
            for input in ["aingthar", "aingtaung", "aingthi"] {
                let top = topSurface(engine, input)
                ctx.assertFalse(
                    surfaceHasDoubledNga(top),
                    input,
                    detail: "top '\(top)' contains stranded bare nga after diphthong"
                )
                ctx.assertTrue(
                    surfaceLeadsWithAiDiphthong(top),
                    input,
                    detail: "top '\(top)' does not lead with the diphthong cluster"
                )
            }
        },

        // ── aing<vowel-extension> shapes ────────────────────────────────
        // `aingar` / `aingain` — the trailing onsetless syllable
        // forms its own segment (with implicit `အ`). The doubled-nga
        // shape must not surface. Anchoring on the `ai`-diphthong is
        // not required here because both readings (`aing + <next>`
        // vs `<onset>ain + <next>`) are plausible; we only insist on
        // a clean surface.
        TestCase("aingFollowedByVowelOpener") { ctx in
            let engine = emptyEngine()
            for input in ["aingar", "aingain"] {
                let top = topSurface(engine, input)
                ctx.assertFalse(
                    surfaceHasDoubledNga(top),
                    input,
                    detail: "top '\(top)' contains stranded bare nga after diphthong"
                )
            }
        },

        // ── kinzi fast-path remains intact ─────────────────────────────
        // `ainggar` (velar lower) must still produce the kinzi-anchored
        // `အိုင်္ဂါ` form via the existing inference path. The new
        // `aing` rule must not steal the kinzi by greedily consuming
        // `aing` and leaving `gar` as a separate syllable.
        TestCase("kinziCollapseStillFires_ainggar") { ctx in
            let engine = emptyEngine()
            let top = topSurface(engine, "ainggar")
            // Expected: 1021 102D 102F 1004 103A 1039 1002 102B (kinzi: ai + virama + ga + ar)
            let expected = "\u{1021}\u{102D}\u{102F}\u{1004}\u{103A}\u{1039}\u{1002}\u{102B}"
            ctx.assertTrue(
                top == expected,
                "ainggar",
                detail: "top '\(top)' is not the expected kinzi form '\(expected)'"
            )
        },

        // ── tonal variants: aing. / aing: ──────────────────────────────
        TestCase("aingTonalVariants") { ctx in
            let engine = emptyEngine()
            for (input, _expectedTrailingScalar) in [
                ("aing.", UInt32(0x1037)),
                ("aing:", UInt32(0x1038)),
            ] {
                let top = topSurface(engine, input)
                ctx.assertFalse(
                    surfaceHasDoubledNga(top),
                    input,
                    detail: "top '\(top)' contains stranded bare nga after diphthong"
                )
                ctx.assertTrue(
                    surfaceLeadsWithAiDiphthong(top),
                    input,
                    detail: "top '\(top)' does not lead with the diphthong cluster"
                )
            }
        },

        // ── onset + aing patterns ──────────────────────────────────────
        // `kaing`, `kainga`, `kaingar` etc. have an explicit onset
        // (`k`) so the parse should be a single syllable `ကိုင်` plus
        // any trailing material — never a doubled nga.
        TestCase("onsetPlusAing") { ctx in
            let engine = emptyEngine()
            for input in ["kaing", "kainga", "kaingar", "thaing", "maing"] {
                let top = topSurface(engine, input)
                ctx.assertFalse(
                    surfaceHasDoubledNga(top),
                    input,
                    detail: "top '\(top)' contains stranded bare nga after diphthong"
                )
            }
        },
    ])
}
