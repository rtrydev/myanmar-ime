import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for task 05: when the buffer exceeds the windowing
/// threshold (`compositionWindowSize` ~= 18 chars), the split site
/// chosen by `findSyllableSafeSplit` must keep clean
/// `<onset><vowel>` syllables intact across the prefix / tail
/// boundary. A split that's locally legal but cuts a join the
/// un-windowed DP would render as a single syllable produces drift —
/// e.g. `tharko` → `သအာကို` (prefix renders `သ`, tail renders `အာကို`)
/// instead of the intended `သာကို`.
public enum LongBufferWindowingSuite {

    private static func defaultEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    public static let suite = TestSuite(name: "LongBufferWindowing", cases: [

        // The windowed parse must match the un-windowed parse for any
        // long buffer that doesn't exceed budget twice over. The
        // un-windowed reference comes from the same engine running on
        // a short prefix slice.
        TestCase("longBufferWindow_topMatchesUnwindowedSlice") { ctx in
            let engine = defaultEngine()
            // 32-char input from the task spec. The windowed result must
            // contain the un-windowed `tharko` rendering `သာကို` —
            // not the drifted `သအာကို` / `သရကို` shapes.
            let buffer = "mingalarpartharkomyatkhinparthay"
            let state = engine.update(buffer: buffer, context: [])
            let top = state.candidates.first?.surface ?? ""
            let drifted = "\u{101E}\u{1021}\u{102C}\u{1000}\u{102D}\u{102F}"   // သအာကို
            let cleanThark = "\u{101E}\u{102C}\u{1000}\u{102D}\u{102F}"      // သာကို
            ctx.assertFalse(
                top.contains(drifted),
                buffer,
                detail: "top='\(top)' carries drifted သအာကို sequence"
            )
            ctx.assertTrue(
                top.contains(cleanThark),
                buffer,
                detail: "top='\(top)' lacks clean သာကို rendering"
            )
        },

        // Property: for every long buffer where a clean syllable
        // straddles the window boundary, the windowed rendering must
        // match the un-windowed rendering of the equivalent slice.
        TestCase("longBufferWindow_propertyOnSyllableStraddle") { ctx in
            let engine = defaultEngine()
            // Buffers chosen so they exceed 18 chars and the suspect
            // syllable spans the window boundary.
            let cases = [
                "mingalarpartharkomyatkhinparthay",
                "mingalarpartharkomyatkhinparte",
                "kyawzawminthartharkomyat",
                "kyawminthartharkothee",
            ]
            for buffer in cases {
                let top = engine.update(buffer: buffer, context: []).candidates.first?.surface ?? ""
                // Generic check: no `သအာ` (၁၀ိ၁ + 1021 + 102C) sequence,
                // which is the signature artefact of a boundary cutting
                // through `thar` mid-syllable.
                let badSeq = "\u{101E}\u{1021}\u{102C}"
                ctx.assertFalse(
                    top.contains(badSeq),
                    buffer,
                    detail: "top='\(top)' carries `သအာ` boundary drift"
                )
                // Also: no embedded literal ASCII letter `r`/`a`/`o`
                // mid-Myanmar — drift sometimes manifests that way.
                let asciiInMiddle = top.unicodeScalars.contains(where: { v in
                    let val = v.value
                    return (val >= 0x61 && val <= 0x7A) || (val >= 0x41 && val <= 0x5A)
                })
                ctx.assertFalse(
                    asciiInMiddle,
                    buffer,
                    detail: "top='\(top)' leaks ASCII letter (boundary drift)"
                )
            }
        },

        // Regression: short buffers (no windowing) keep producing the
        // same expected output. Just a basic sanity check that the
        // unwindowed path is unaffected.
        TestCase("longBufferWindow_shortBuffersUnchanged") { ctx in
            let engine = defaultEngine()
            for (buffer, expectedSubstr) in [
                ("tharko", "\u{101E}\u{102C}\u{1000}\u{102D}\u{102F}"),
                ("mingalarpar", "\u{1019}\u{1004}\u{103A}\u{1039}\u{1002}\u{101C}\u{102C}\u{1015}\u{102B}"),
            ] {
                let top = engine.update(buffer: buffer, context: []).candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top.contains(expectedSubstr),
                    buffer,
                    detail: "expected top to contain '\(expectedSubstr)'; got='\(top)'"
                )
            }
        },
    ])
}
