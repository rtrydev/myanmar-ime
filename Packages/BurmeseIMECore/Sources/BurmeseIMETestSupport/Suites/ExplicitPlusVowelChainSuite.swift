import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-054: An explicit user-typed `+` between two vowel-rule arcs
/// must be honoured as a hard syllable break. Buffers shaped
/// `<C><vowel-rule> + <vowel-rule>` previously merged both vowel
/// rules onto the same base (the parser's DP emitted the soft-
/// boundary `+` as a `1039` virama between two dep-vowels and the
/// engine's `sanitizeIndepVowelVirama` then stripped it, hiding the
/// illegal placement).
///
/// Acceptance: rank-0 surface must NOT carry both vowel rules on a
/// single anchor. Either the engine produces a multi-anchor sibling
/// (`<C><vowel-1> <fresh-anchor><vowel-2>`) or the literal-fallback
/// candidate occupies rank 0.
public enum ExplicitPlusVowelChainSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// Detect any base anchor (consonant or independent vowel) that
    /// carries both an `1031` (e-kar) AND another non-aa dep-vowel
    /// scalar — or `102C` aa AND another non-aa dep-vowel — within the
    /// same cluster. Mirrors the TASK-053 surface invariant but is
    /// scoped to the specific shapes TASK-054 produces from a
    /// `<C><vowel> + <vowel>` buffer.
    private static func surfaceMergesTwoVowelsOnOneAnchor(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        var i = 0
        while i < scalars.count {
            let v = scalars[i]
            let isAnchor = (v >= 0x1000 && v <= 0x102A) || v == 0x103F
            if !isAnchor { i += 1; continue }
            var depVowels: [UInt32] = []
            var j = i + 1
            walk: while j < scalars.count {
                let w = scalars[j]
                if w >= 0x102B && w <= 0x1032 {
                    depVowels.append(w)
                    j += 1
                } else if (w >= 0x1036 && w <= 0x1038) || (w >= 0x103B && w <= 0x103E) {
                    j += 1
                } else {
                    break walk
                }
            }
            if depVowels.count >= 2 {
                // Allow the two canonical multi-scalar shapes:
                // `102D 102F` (`o` cluster) and `1031 102B/102C`
                // (`aw` family). Reject everything else.
                let isOCluster = depVowels == [0x102D, 0x102F]
                let isAungOrder = depVowels.count == 2
                    && depVowels[0] == 0x1031
                    && (depVowels[1] == 0x102B || depVowels[1] == 0x102C)
                if !(isOCluster || isAungOrder) {
                    return true
                }
            }
            i = j
        }
        return false
    }

    public static let suite = TestSuite(name: "ExplicitPlusVowelChain", cases: [

        // Bug-class buffers: `<C><vowel> + <vowel>` must NOT merge
        // both vowels on a single anchor.
        TestCase("plusVowelChain_doesNotMergeOnSingleAnchor") { ctx in
            let engine = emptyEngine()
            let buffers = [
                "ka+ay+o", "ka+ay+oo", "ka+ay+i", "ka+ay+u",
                "ka+ar+i", "ka+ar+oo",
            ]
            for buffer in buffers {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    surfaceMergesTwoVowelsOnOneAnchor(surface),
                    buffer,
                    detail: "rank-0 merges two vowel rules on a single anchor: '\(hex(surface))'"
                )
            }
        },

        // Forbidden adjacencies: rank-0 surface must not contain any
        // of the specific TASK-054 illegal dep-vowel-on-dep-vowel
        // substrings — these are exactly the shapes the bug
        // produced (the `+` was dropped and both vowels chained on
        // the same base).
        TestCase("plusVowelChain_forbidsEkarThenOtherSubstring") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, forbid: [UInt32])] = [
                ("ka+ay+o",  [0x1031, 0x102D, 0x102F]),
                ("ka+ay+oo", [0x1031, 0x102D, 0x102F]),
                ("ka+ay+i",  [0x1031, 0x102E]),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars).map(\.value)
                var found = false
                if scalars.count >= c.forbid.count {
                    for i in 0...(scalars.count - c.forbid.count) {
                        if Array(scalars[i..<(i + c.forbid.count)]) == c.forbid {
                            found = true
                            break
                        }
                    }
                }
                ctx.assertFalse(
                    found,
                    c.buffer,
                    detail: "rank-0 contains forbidden adjacency '\(c.forbid.map { String(format: "%04X", $0) })' surface='\(hex(surface))'"
                )
            }
        },

        // Regression guards: legal `+` shapes must keep working.
        // - `ka+e+o` is the multi-anchor sibling reference (`e` rule
        //   emits a coda asat that legally closes the syllable).
        // - `ka+u` was originally a single-syllable expectation
        //   (`ku`) on the assumption that `+` before a single-char
        //   vowel rule is a no-op; TASK-047 reclassifies the
        //   `<C>(a|ar|ay)+<vowel-rule>` shape as a hard syllable
        //   break. The test now checks for the two-syllable form
        //   (anchor injection between LHS and the bare vowel),
        //   matching the TASK-047 acceptance criterion.
        // - `k+k+k+k` is the kinzi-stack regression guard.
        TestCase("plusVowelChain_regressionGuards") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, mustContain: [UInt32])] = [
                ("ka+e+o",   [0x101A, 0x103A, 0x1021, 0x102D, 0x102F]),  // e-coda + indep-o
                ("ka+u",     [0x1000, 0x1021, 0x1030]),                  // TASK-047 two-syllable
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars).map(\.value)
                var found = false
                if scalars.count >= c.mustContain.count {
                    for i in 0...(scalars.count - c.mustContain.count) {
                        if Array(scalars[i..<(i + c.mustContain.count)]) == c.mustContain {
                            found = true
                            break
                        }
                    }
                }
                ctx.assertTrue(
                    found,
                    c.buffer,
                    detail: "rank-0 lost expected shape '\(c.mustContain.map { String(format: "%04X", $0) })' surface='\(hex(surface))'"
                )
            }
            // Kinzi-stack regression guard (verbatim from
            // ExplicitPlusVowelSuite). `k+k+k+k` must produce a
            // virama-stacked surface, not a pure-vowel
            // collapse.
            let kkkk = engine.update(buffer: "k+k+k+k", context: [])
                .candidates.first?.surface ?? ""
            ctx.assertTrue(
                kkkk.unicodeScalars.contains { $0.value == 0x1039 },
                "k+k+k+k",
                detail: "kinzi-stack regression — expected virama scalar in '\(kkkk)' \(hex(kkkk))"
            )
            // `ka+ay+aa` regression guard: the user typed `+` so the
            // second segment must be on its own anchor — i.e. the
            // surface must NOT carry both vowel rules merged onto a
            // single base. (The exact shape is determined by the rule
            // set: `aa` is two inherent-`a` arcs, not the `aw` vowel
            // rule, so the surface lands on a fresh `1021` anchor.)
            let kayaa = engine.update(buffer: "ka+ay+aa", context: [])
                .candidates.first?.surface ?? ""
            ctx.assertFalse(
                surfaceMergesTwoVowelsOnOneAnchor(kayaa),
                "ka+ay+aa",
                detail: "rank-0 merged two vowel rules on a single anchor: '\(hex(kayaa))'"
            )
        },
    ])
}
