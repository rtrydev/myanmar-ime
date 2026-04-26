import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-002: the `aw:` (heavy-tone) vowel rule was missing
/// both the asat (U+103A) and the heavy-tone marker (U+1038), making
/// every `<consonant>aw:` input compose to a malformed surface that is
/// neither the heavy-tone form nor any other legitimate spelling.
///
/// In standard Burmese orthography the three tones of an `-aw` final
/// syllable are:
///   - low (1):    `<C>aw`  → `<C>ော်` / `<C>ေါ်`     (1031 102C 103A)
///   - creaky (2): `<C>aw.` → `<C>ော့` / `<C>ေါ့`    (1031 102C 1037)
///   - heavy (3):  `<C>aw:` → `<C>ော်း` / `<C>ေါ်း`  (1031 102C 103A 1038)
///
/// The asat is preserved across base and heavy-tone forms; only creaky
/// tone replaces it. This suite asserts the full
/// `<aa-shape> <asat> <heavy-tone>` sequence is present on the rank-0
/// surface for the entire `-aw:` family — not just the example word
/// from the task. `correctAaShape` may swap U+102C ↔ U+102B for the
/// round-base consonants (`ပ`, `ဖ`, `ဝ`, `ဂ`, `ဒ`), so the assertion
/// accepts either aa-shape but requires both the asat and U+1038 to
/// be present in that order at the syllable's tail.
public enum HeavyToneAwSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    /// True when `surface` ends with the `<1031> <102C|102B> <103A> <1038>`
    /// heavy-tone-aw sequence (allowing aa-shape swap).
    private static func endsWithHeavyAw(_ surface: String) -> Bool {
        let scalars = surface.unicodeScalars.map(\.value)
        guard scalars.count >= 4 else { return false }
        let n = scalars.count
        let isAaShape = scalars[n - 3] == 0x102B || scalars[n - 3] == 0x102C
        return scalars[n - 1] == 0x1038
            && scalars[n - 2] == 0x103A
            && isAaShape
            && scalars[n - 4] == 0x1031
    }

    public static let suite = TestSuite(name: "HeavyToneAw", cases: [

        // Core bug class: every <C>aw: input must produce the full
        // heavy-tone-aw sequence (1031, aa-shape, 103A, 1038) at the
        // surface tail. These are the inputs that exercise the bugged
        // `aw:` rule directly.
        TestCase("heavyToneAw_consonantPlain") { ctx in
            let engine = emptyEngine()
            // Consonants spanning the major classes and including ones
            // that *don't* trigger the round-base aa-shape swap, so the
            // test exercises both `102C` and `102B` paths.
            let inputs = [
                "kyaw:", "naw:", "taw:", "saw:", "myaw:",
                "pyaw:", "thaw:",
                // Round-base consonants that DO trigger
                // `correctAaShape` (102C → 102B):
                "paw:", "baw:", "waw:", "gaw:", "daw:",
                // Cluster onsets:
                "khyaw:", "khwaw:", "kraw:",
            ]
            for input in inputs {
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    endsWithHeavyAw(top),
                    input,
                    detail: "top='\(top)' " +
                        "scalars=\(top.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " "))"
                )
            }
        },

        // The base form `aw` (low tone) and creaky `aw.` must NOT
        // grow a `1038` after this fix. Regression guard.
        TestCase("heavyToneAw_baseAndCreakyUnaffected") { ctx in
            let engine = emptyEngine()
            for input in ["kyaw", "naw", "kyaw.", "naw.", "paw", "paw."] {
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                let scalars = top.unicodeScalars.map(\.value)
                ctx.assertTrue(
                    !scalars.contains(0x1038),
                    input,
                    detail: "top='\(top)' should not have heavy-tone marker U+1038"
                )
            }
        },

        // Sibling heavy-tone rules must still work (regression guard
        // covering ar:, ay:, ai:, in:, on:, an: — none of these were
        // touched by the fix but the audit revealed they share the
        // tone-suffix pattern).
        TestCase("heavyToneAw_siblingTonesUnaffected") { ctx in
            let engine = emptyEngine()
            let cases: [(input: String, requiredScalar: UInt32)] = [
                ("thar:", 0x1038),
                ("kyar:", 0x1038),
                ("lay:",  0x1038),
                ("kyai:", 0x1038),
                ("min:",  0x1038),
                ("kan:",  0x1038),
                ("on:",   0x1038),
            ]
            for (input, required) in cases {
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                let scalars = top.unicodeScalars.map(\.value)
                ctx.assertTrue(
                    scalars.contains(required),
                    input,
                    detail: "top='\(top)' missing required scalar \(String(format: "%04X", required))"
                )
            }
        },

        // Heavy-tone aw embedded in a longer composable buffer (no
        // windowing) must still surface the full heavy-tone tail.
        TestCase("heavyToneAw_inLongerBuffer") { ctx in
            let engine = emptyEngine()
            for input in ["kyawkyaw:", "thakyaw:", "thakyawkyaw:"] {
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    endsWithHeavyAw(top),
                    input,
                    detail: "top='\(top)'"
                )
            }
        },

        // Round-trip through ReverseRomanizer: an aw: heavy-tone surface
        // must ReverseRomanizer.romanize to a string ending in `:` so the lexicon
        // builder records the right alias key. Uses the engine output as
        // the source of truth (post-aa-shape).
        TestCase("heavyToneAw_reverseRomanizes") { ctx in
            let engine = emptyEngine()
            _ = ()
            for input in ["kyaw:", "thaw:", "paw:", "naw:"] {
                let state = engine.update(buffer: input, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.assertTrue(false, input, detail: "no candidate")
                    continue
                }
                let romanized = ReverseRomanizer.romanize(top)
                ctx.assertTrue(
                    romanized.hasSuffix(":"),
                    input,
                    detail: "surface='\(top)' romanized='\(romanized)'"
                )
            }
        },
    ])
}
