import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-029: buffer-leading doubled bare-vowel + tone marker. When the
/// user types `ee.`, `ee:`, `ii:`, `oo.`, `uu.`, `uu:` (no preceding
/// consonant), the rank-0 surface must be a single-cluster shape — at
/// most one independent-vowel anchor (`1023`–`102A`) and at most one
/// inherent-A anchor (`1021`), no literal `.` / `:` (`002E` / `003A`)
/// in the surface, and none of the bug-class scalar patterns produced
/// by the un-peeled doubled-vowel + tone path.
///
/// `ii.` and `oo:` are dedicated rule-table entries in
/// `Romanization.vowelRules` and must NOT be perturbed by the peel —
/// they intentionally collapse to `ဣ` (1023) and `ဪ` (102A) and have
/// existing engine / ranking suite assertions.
///
/// Sister to `DoubledBareVowelSuite` which covers the consonant-anchored
/// `<C>VV<tone>` shape (TASK-026).
public enum BareDoubledVowelToneSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

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

    /// Independent-vowel anchors (U+1023..U+102A). The rank-0 surface
    /// for a single VV<tone> input must have at most one of these.
    private static func independentVowelAnchorCount(_ scalars: [UInt32]) -> Int {
        scalars.filter { (0x1023...0x102A).contains($0) }.count
    }

    /// Inherent-A anchors (U+1021). The rank-0 surface for a single
    /// VV<tone> input must have at most one of these (no
    /// `1021 ... 1021` chains).
    private static func inherentAAnchorCount(_ scalars: [UInt32]) -> Int {
        scalars.filter { $0 == 0x1021 }.count
    }

    /// In-scope buffers — six VV<tone> shapes with no dedicated rule
    /// entry. These are the buffers that exhibit the bug.
    private static let inScopeBuffers: [String] = [
        "ii:", "uu.", "uu:", "ee.", "ee:", "oo.",
    ]

    public static let suite = TestSuite(name: "BareDoubledVowelTone", cases: [

        // Bug-class invariant 1: at most one independent-vowel anchor
        // (1023-102A) in the surface. The current bug emits two
        // (e.g. `1021 1030 1025` for `uu.` has 1025; `1021 1030 1026 1038`
        // for `uu:` has 1026).
        TestCase("rank0_atMostOneIndependentVowelAnchor") { ctx in
            let engine = emptyEngine()
            for buffer in inScopeBuffers {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars).map(\.value)
                ctx.assertTrue(
                    independentVowelAnchorCount(scalars) <= 1,
                    buffer,
                    detail: "rank-0 has multiple independent-vowel anchors: '\(hex(surface))'"
                )
            }
        },

        // Bug-class invariant 2: at most one inherent-A anchor (1021).
        // The `oo.` bug emits two: `1021 102D 102F 1021 102D 102F 1037`.
        TestCase("rank0_atMostOneInherentAAnchor") { ctx in
            let engine = emptyEngine()
            for buffer in inScopeBuffers {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars).map(\.value)
                ctx.assertTrue(
                    inherentAAnchorCount(scalars) <= 1,
                    buffer,
                    detail: "rank-0 has multiple inherent-A anchors: '\(hex(surface))'"
                )
            }
        },

        // Bug-class invariant 3: the literal tone-marker punctuation
        // (`002E` `.` and `003A` `:`) must not appear in the rank-0
        // surface. The `ee:` bug leaks the colon as `1021 102E 003A`.
        TestCase("rank0_noLiteralToneMarker") { ctx in
            let engine = emptyEngine()
            for buffer in inScopeBuffers {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars).map(\.value)
                ctx.assertFalse(
                    scalars.contains(0x002E),
                    "\(buffer)_dot",
                    detail: "rank-0 contains literal '.' (002E): '\(hex(surface))'"
                )
                ctx.assertFalse(
                    scalars.contains(0x003A),
                    "\(buffer)_colon",
                    detail: "rank-0 contains literal ':' (003A): '\(hex(surface))'"
                )
            }
        },

        // Bug-class invariant 4: forbid the specific scalar patterns
        // produced by the un-peeled paths.
        // - `ee.` bug:  `101A 103A 101A` (doubled ya-asat in a row).
        // - `oo.` bug:  `102D 102F 1021 102D 102F` (anchor-injected
        //                o-cluster chain).
        // - `uu.` bug:  `1030 1025`  (1030 followed by 1025 ဥ).
        // - `uu:` bug:  `1030 1026`  (1030 followed by 1026 ဦ).
        // - `ii:` bug:  `100A 103A` (nya-asat coda fallback).
        TestCase("rank0_noKnownBugPatterns") { ctx in
            let engine = emptyEngine()
            let surfaceFor: (String) -> [UInt32] = { buf in
                let s = engine.update(buffer: buf, context: [])
                    .candidates.first?.surface ?? ""
                return Array(s.unicodeScalars).map(\.value)
            }
            // ya-asat duplication (the `ee.` shape).
            for buffer in ["ee.", "ee:"] {
                let scalars = surfaceFor(buffer)
                ctx.assertTrue(
                    countSubsequence(scalars, sub: [0x101A, 0x103A]) <= 1,
                    buffer,
                    detail: "rank-0 has duplicated ya-asat for '\(buffer)': scalars=\(scalars.map { String(format: "%04X", $0) })"
                )
            }
            // o-cluster injected anchor (the `oo.` shape).
            let ooScalars = surfaceFor("oo.")
            ctx.assertFalse(
                containsSubsequence(ooScalars, sub: [0x102D, 0x102F, 0x1021]),
                "oo.",
                detail: "rank-0 has o-pair + injected 1021 anchor: scalars=\(ooScalars.map { String(format: "%04X", $0) })"
            )
            ctx.assertTrue(
                countSubsequence(ooScalars, sub: [0x102D, 0x102F]) <= 1,
                "oo._singleOpair",
                detail: "rank-0 has multiple o-pair clusters for 'oo.': scalars=\(ooScalars.map { String(format: "%04X", $0) })"
            )
            // 1030 followed by independent ဥ / ဦ (the `uu.` / `uu:` shape).
            for buffer in ["uu.", "uu:"] {
                let scalars = surfaceFor(buffer)
                ctx.assertFalse(
                    containsSubsequence(scalars, sub: [0x1030, 0x1025]),
                    "\(buffer)_no_1030_1025",
                    detail: "rank-0 has 1030+1025 chain: scalars=\(scalars.map { String(format: "%04X", $0) })"
                )
                ctx.assertFalse(
                    containsSubsequence(scalars, sub: [0x1030, 0x1026]),
                    "\(buffer)_no_1030_1026",
                    detail: "rank-0 has 1030+1026 chain: scalars=\(scalars.map { String(format: "%04X", $0) })"
                )
            }
            // nya-asat coda fallback (the `ii:` shape).
            let iiColonScalars = surfaceFor("ii:")
            ctx.assertFalse(
                containsSubsequence(iiColonScalars, sub: [0x100A, 0x103A]),
                "ii:_no_nya_asat",
                detail: "rank-0 has nya-asat coda for 'ii:': scalars=\(iiColonScalars.map { String(format: "%04X", $0) })"
            )
        },

        // Regression guard: dedicated rule-table entries `ii.` → ဣ
        // (1023) and `oo:` → ဪ (102A) must not be perturbed.
        TestCase("rule_entries_ii_dot_and_oo_colon_unchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                ("ii.", [0x1023]),  // ဣ
                ("oo:", [0x102A]),  // ဪ
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars).map(\.value)
                ctx.assertTrue(
                    actual == c.expected,
                    c.buffer,
                    detail: "regression on rule-table entry: expected scalars=\(c.expected.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
            }
        },
    ])
}
