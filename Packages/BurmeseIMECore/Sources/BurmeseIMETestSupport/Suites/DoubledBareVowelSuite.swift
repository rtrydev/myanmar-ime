import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-026: a doubled bare-vowel letter (`ii`, `uu`,
/// `ee`, `oo`) typed after a consonant must NOT materialize as
/// malformed multi-anchor or doubled coda-asat surfaces. The rank-0
/// candidate must be either the long-vowel form (`<C>` + long-vowel
/// sign) or a clean two-syllable recovery (`<C>` + short-vowel +
/// independent-vowel anchor for the dropped letter).
///
/// This is a strict generalization of TASK-016, which fixed the
/// parallel `<C>aa` case via the chained-inherent-`a` DP guard.
public enum DoubledBareVowelSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// Forbidden subsequences (any of these inside the rank-0 surface
    /// constitutes the bug class). Each tuple is the buffer and a list
    /// of forbidden scalar subsequences that must not appear in the
    /// rank-0 surface.
    ///
    /// `kii`  → forbid `100A 103A` (nya-asat coda)
    /// `kuu`  → forbid `1026` (independent ဦ adjacent to dep ူ)
    /// `kee`  → forbid two adjacent `101A 103A` clusters
    /// `koo`  → forbid `<o-pair> <o-pair>` chain where 0x1021 anchor
    ///          gets injected
    private static func containsSubsequence(_ scalars: [UInt32], sub: [UInt32]) -> Bool {
        guard !sub.isEmpty, scalars.count >= sub.count else { return false }
        for i in 0...(scalars.count - sub.count) {
            if Array(scalars[i..<(i + sub.count)]) == sub { return true }
        }
        return false
    }

    private static func countSubsequence(_ scalars: [UInt32], sub: [UInt32]) -> Int {
        guard !sub.isEmpty, scalars.count >= sub.count else { return 0 }
        var count = 0
        var i = 0
        while i <= scalars.count - sub.count {
            if Array(scalars[i..<(i + sub.count)]) == sub {
                count += 1
                i += sub.count
            } else {
                i += 1
            }
        }
        return count
    }

    public static let suite = TestSuite(name: "DoubledBareVowel", cases: [

        // `kii` family — must not produce nya-asat coda fallback
        // (`100A 103A`) at the doubled-vowel position.
        TestCase("doubledI_noNyaAsatCoda") { ctx in
            let engine = emptyEngine()
            for buffer in ["kii", "khii", "thii", "kiii", "kakii"] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars.map(\.value))
                ctx.assertFalse(
                    containsSubsequence(scalars, sub: [0x100A, 0x103A]),
                    buffer,
                    detail: "rank-0 contains nya-asat coda fallback: '\(hex(surface))'"
                )
            }
        },

        // `kuu` family — must not produce `1026` (ဦ as second anchor).
        TestCase("doubledU_noIndependentVowel1026") { ctx in
            let engine = emptyEngine()
            for buffer in ["kuu", "khuu", "thuu", "kuuu", "kakuu"] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars.map(\.value))
                ctx.assertFalse(
                    scalars.contains(0x1026),
                    buffer,
                    detail: "rank-0 contains stray independent ဦ (1026): '\(hex(surface))'"
                )
            }
        },

        // `kee` family — must not produce two adjacent `101A 103A`
        // clusters (the doubled ya-asat fallback that yields the
        // structurally-illegal `<C>ယ်ယ်`).
        TestCase("doubledE_noDoubledYaAsat") { ctx in
            let engine = emptyEngine()
            for buffer in ["kee", "khee", "thee", "keee", "kakee"] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    countSubsequence(scalars, sub: [0x101A, 0x103A]) <= 1,
                    buffer,
                    detail: "rank-0 has multiple ya-asat clusters: '\(hex(surface))'"
                )
            }
        },

        // `koo` family — must not produce a multi-anchor chain where
        // a `1021` independent-A is sandwiched between two `o`-rule
        // pairs.
        TestCase("doubledO_noDoubleAnchorChain") { ctx in
            let engine = emptyEngine()
            for buffer in ["koo", "khoo", "thoo", "kooo", "kakoo", "myoo"] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars.map(\.value))
                // `o`-rule emits `102D 102F` (short i + short u). A
                // multi-anchor chain looks like `… 102D 102F 1021 102D 102F`
                // (two repetitions surrounding an independent-A).
                ctx.assertFalse(
                    containsSubsequence(scalars, sub: [0x102D, 0x102F, 0x1021]),
                    buffer,
                    detail: "rank-0 has o-pair + 1021 anchor chain: '\(hex(surface))'"
                )
                // And the o-pair must not appear twice in a row.
                ctx.assertTrue(
                    countSubsequence(scalars, sub: [0x102D, 0x102F]) <= 1,
                    "\(buffer)_singleOpair",
                    detail: "rank-0 has multiple o-pair clusters: '\(hex(surface))'"
                )
            }
        },

        // `kaa` must continue to render `ကအ` — baseline locked in.
        TestCase("doubledA_unchanged_under_repetition") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                ("kaa",   [0x1000, 0x1021]),
                ("kaaa",  [0x1000, 0x1021]),
                ("kaaka", [0x1000, 0x1000]),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    actual == c.expected,
                    c.buffer,
                    detail: "regression on TASK-016 baseline: expected scalars=\(c.expected.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
            }
        },

        // Bare doubled vowel inputs (no preceding consonant) keep
        // their TASK-006 / `bareVowelOverrideSurface` shapes.
        TestCase("bareDoubledVowels_unchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                ("ii", [0x1024]),                  // ဤ
                ("uu", [0x1021, 0x1030]),          // အူ
                ("ee", [0x1021, 0x102E]),          // အီ
                ("oo", [0x1029]),                  // ဩ
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    actual == c.expected,
                    c.buffer,
                    detail: "regression: bare doubled vowel '\(c.buffer)' expected scalars=\(c.expected.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
            }
        },

        // TASK-026 follow-up: when the doubled bare-vowel pattern is
        // followed by a tone marker (`.` / `:`) the pre-pass must
        // still strip the duplicate vowel BEFORE the parser sees the
        // tone-attached buffer. Without the fix, the trailing tone
        // consumes the tail position and the right-shrink probe never
        // peels the duplicate vowel into `droppedTail`, so
        // `trimChainedBareVowelTail` cannot fire and the malformed
        // double-anchor surfaces (`ကယ်ယ့်`, `ကီည့်`, `ကိုအို့`,
        // `ကူဥ`) re-emerge.
        //
        // Forbidden subsequences mirror the no-tone bug-class checks:
        // - `kee.` / `kee:` → forbid two adjacent `101A 103A` clusters
        //                     (doubled ya-asat).
        // - `kii.` / `kii:` → forbid `100A 103A` (nya-asat coda
        //                     fallback).
        // - `koo.` / `koo:` → forbid `102D 102F 1021` (multi-anchor
        //                     chain via injected `1021`).
        // - `kuu.` / `kuu:` → forbid `1026` (independent ဦ as second
        //                     anchor).
        TestCase("doubledE_withTone_noDoubledYaAsat") { ctx in
            let engine = emptyEngine()
            for buffer in ["kee.", "kee:", "khee.", "khee:", "thee.", "thee:",
                           "keee.", "keee:", "kakee.", "kakee:"] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    countSubsequence(scalars, sub: [0x101A, 0x103A]) <= 1,
                    buffer,
                    detail: "rank-0 has multiple ya-asat clusters with trailing tone: '\(hex(surface))'"
                )
            }
        },

        TestCase("doubledI_withTone_noNyaAsatCoda") { ctx in
            let engine = emptyEngine()
            for buffer in ["kii.", "kii:", "khii.", "khii:", "thii.", "thii:",
                           "kiii.", "kiii:", "kakii.", "kakii:"] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars.map(\.value))
                ctx.assertFalse(
                    containsSubsequence(scalars, sub: [0x100A, 0x103A]),
                    buffer,
                    detail: "rank-0 contains nya-asat coda fallback with trailing tone: '\(hex(surface))'"
                )
            }
        },

        TestCase("doubledO_withTone_noDoubleAnchorChain") { ctx in
            let engine = emptyEngine()
            for buffer in ["koo.", "koo:", "khoo.", "khoo:", "thoo.", "thoo:",
                           "kooo.", "kooo:", "kakoo.", "kakoo:", "myoo.", "myoo:"] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars.map(\.value))
                // `o`-rule emits `102D 102F`. A multi-anchor chain
                // looks like `… 102D 102F 1021 102D 102F`. Forbid both
                // the injected `1021` between two o-pairs and a
                // second o-pair appearing in a row.
                ctx.assertFalse(
                    containsSubsequence(scalars, sub: [0x102D, 0x102F, 0x1021]),
                    buffer,
                    detail: "rank-0 has o-pair + 1021 anchor chain with trailing tone: '\(hex(surface))'"
                )
                ctx.assertTrue(
                    countSubsequence(scalars, sub: [0x102D, 0x102F]) <= 1,
                    "\(buffer)_singleOpair",
                    detail: "rank-0 has multiple o-pair clusters with trailing tone: '\(hex(surface))'"
                )
            }
        },

        TestCase("doubledU_withTone_noIndependentVowel1026") { ctx in
            let engine = emptyEngine()
            // `kuu.` collapses to `ku.` whose top parse is `ကု`
            // (`102F`, short u) — `1026` (ဦ) must not appear. `kuu:`
            // collapses to `ku:` whose top parse is `ကူး`
            // (`1030 1038`) — same `1026` ban.
            for buffer in ["kuu.", "kuu:", "khuu.", "khuu:", "thuu.", "thuu:",
                           "kuuu.", "kuuu:", "kakuu.", "kakuu:"] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars.map(\.value))
                ctx.assertFalse(
                    scalars.contains(0x1026),
                    buffer,
                    detail: "rank-0 contains stray independent ဦ (1026) with trailing tone: '\(hex(surface))'"
                )
            }
        },

        // Spot-check the expected toned surfaces for the canonical
        // cases. The doubled bare-vowel + tone is collapsed to the
        // single bare-vowel + tone form, then the parser applies its
        // existing `<vowel><tone>` rule. For `i`/`u` the parser's
        // rule scheme treats `.` as the short-vowel switch rather
        // than as a creaky-tone marker, so `kii.` resolves to the
        // short-i form (`ကိ`); this matches `ki.` exactly and
        // is structurally clean (no spurious double anchor).
        TestCase("doubledVowelWithTone_expectedSurfaces") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                ("kee.", [0x1000, 0x101A, 0x1037, 0x103A]),     // ကယ့်
                ("kee:", [0x1000, 0x1032]),                       // ကဲ
                ("kii.", [0x1000, 0x102D]),                       // ကိ
                ("kii:", [0x1000, 0x102E, 0x1038]),               // ကီး
                ("koo.", [0x1000, 0x102D, 0x102F, 0x1037]),       // ကို့
                ("koo:", [0x1000, 0x102D, 0x102F, 0x1038]),       // ကိုး
                ("kuu.", [0x1000, 0x102F]),                       // ကု
                ("kuu:", [0x1000, 0x1030, 0x1038]),               // ကူး
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    actual == c.expected,
                    c.buffer,
                    detail: "expected scalars=\(c.expected.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
            }
        },
    ])
}
