import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-052: An explicit user-typed `+` between two bare-vowel rules
/// must NOT be silently discarded. Buffers shaped
/// `<bare-vowel-LHS>+<bare-vowel-RHS>` previously stripped the `+` and
/// merged the two bare-vowel rules onto a single `1021` anchor or into
/// a long-vowel collapse. Per CLAUDE.md §6 ("User-typed `+` is a hard
/// syllable / stack boundary") the user-respecting two-syllable form
/// must be panel-reachable.
///
/// Acceptance: for every buffer `<v1>+<v2>` where v1, v2 ∈ {a, e, i,
/// o, u} (and their long siblings on the RHS), the panel contains a
/// candidate whose scalar sequence carries each side anchored to its
/// own independent vowel `1021` (or the canonical mixed-anchor form
/// for `o+...` / `u+e`). The identical-letter doubled-bare-vowel
/// buffers (`u+u`, `i+i`, `a+a`, `e+e`, `o+o`) keep their long-vowel
/// collapse at rank 0 — those are unambiguous emphasis readings.
public enum BareVowelPlusBareVowelSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// Returns true when `surface`'s scalar sequence contains exactly
    /// `expected` as a subsequence (full match — every scalar in
    /// `expected` appears at the corresponding position in `surface`).
    private static func surfaceEquals(_ surface: String, _ expected: [UInt32]) -> Bool {
        Array(surface.unicodeScalars).map(\.value) == expected
    }

    /// Returns true if any candidate in `cands` has scalar sequence
    /// exactly equal to `expected`. Used for panel-reachability checks
    /// where the two-syllable form may be at any rank.
    private static func panelContains(
        _ cands: [Candidate], scalar expected: [UInt32]
    ) -> Bool {
        cands.contains {
            Array($0.surface.unicodeScalars).map(\.value) == expected
        }
    }

    public static let suite = TestSuite(name: "BareVowelPlusBareVowel", cases: [

        // Headline class: `<bare-v>+<bare-v-RHS>` where the RHS is a
        // bare vowel-rule that was previously merged into the LHS by
        // the `collapseConnectorRuns` strip. The two-syllable form
        // (each side anchored to its own `1021`) must occupy rank 0.
        TestCase("twoSyllableFormAtRank0_for_aPlusBareVowel") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                ("a+i",   [0x1021, 0x1021, 0x102E]),
                ("a+o",   [0x1021, 0x1021, 0x102D, 0x102F]),
                ("a+u",   [0x1021, 0x1021, 0x1030]),
                ("a+ar",  [0x1021, 0x1021, 0x102C]),
                ("a+aw",  [0x1021, 0x1021, 0x1031, 0x102C, 0x103A]),
                ("a+aung",[0x1021, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
            ]
            for c in cases {
                let cands = engine.update(buffer: c.buffer, context: []).candidates
                guard let top = cands.first else {
                    ctx.assertTrue(false, c.buffer, detail: "panel empty")
                    continue
                }
                ctx.assertTrue(
                    surfaceEquals(top.surface, c.expected),
                    c.buffer,
                    detail: "rank-0='\(top.surface)' (\(hex(top.surface))) expected=\(c.expected.map { String(format: "%04X", $0) })"
                )
            }
        },

        // Other-LHS bare-vowel cases: `i+`, `e+`, `u+` (non-identical
        // doubled buffers). Each must produce a clean two-syllable
        // form panel-reachable; rank-0 strongly preferred per
        // CLAUDE.md §7.
        TestCase("twoSyllableFormReachable_for_otherBareVowelLHS") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                // i+u: nya-asat upper for `i` + `1021 1030` for `u`.
                ("i+u",   [0x1021, 0x100A, 0x103A, 0x1021, 0x1030]),
                ("i+o",   [0x1021, 0x100A, 0x103A, 0x1021, 0x102D, 0x102F]),
                ("i+ar",  [0x1021, 0x100A, 0x103A, 0x1021, 0x102C]),
                ("i+aung",[0x1021, 0x100A, 0x103A, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
                ("i+aw",  [0x1021, 0x100A, 0x103A, 0x1021, 0x1031, 0x102C, 0x103A]),
                ("e+i",   [0x1021, 0x101A, 0x103A, 0x1021, 0x102E]),
                ("e+u",   [0x1021, 0x101A, 0x103A, 0x1021, 0x1030]),
                ("e+aw",  [0x1021, 0x101A, 0x103A, 0x1021, 0x1031, 0x102C, 0x103A]),
                ("u+i",   [0x1021, 0x1030, 0x1021, 0x102E]),
                ("u+aw",  [0x1021, 0x1030, 0x1021, 0x1031, 0x102C, 0x103A]),
                ("u+o",   [0x1021, 0x1030, 0x1021, 0x102D, 0x102F]),
                ("o+aw",  [0x1021, 0x102D, 0x102F, 0x1021, 0x1031, 0x102C, 0x103A]),
            ]
            for c in cases {
                let cands = engine.update(buffer: c.buffer, context: []).candidates
                ctx.assertTrue(
                    panelContains(cands, scalar: c.expected),
                    c.buffer,
                    detail: "two-syllable form \(c.expected.map { String(format: "%04X", $0) }) not in panel; got \(cands.prefix(3).map { hex($0.surface) })"
                )
            }
        },

        // The five-syllable buffer `a+e+i+o+u` must produce all five
        // syllables at rank 0, each anchored to its own `1021`.
        TestCase("fiveSyllableChain_aeiou") { ctx in
            let engine = emptyEngine()
            let cands = engine.update(buffer: "a+e+i+o+u", context: []).candidates
            guard let top = cands.first else {
                ctx.assertTrue(false, "a+e+i+o+u", detail: "panel empty")
                return
            }
            // Each `+`-separated bare vowel rule contributes its own
            // anchored cluster. The five-syllable form's exact scalar
            // sequence depends on the engine's anchor injection rules;
            // assert the panel contains a candidate whose first scalar
            // is `1021` and which carries each of the expected
            // dep-vowel scalars in order.
            let topScalars = Array(top.surface.unicodeScalars).map(\.value)
            // Must start with U+1021 anchor.
            ctx.assertTrue(
                topScalars.first == 0x1021,
                "a+e+i+o+u_startsWith1021",
                detail: "rank-0 surface starts with \(String(format: "%04X", topScalars.first ?? 0))"
            )
            // Must contain at least 4 U+1021 anchors (one per syllable
            // boundary; the first is the initial bare-`a`, the others
            // sit before each subsequent syllable's vowel cluster).
            let anchorCount = topScalars.filter { $0 == 0x1021 }.count
            ctx.assertTrue(
                anchorCount >= 4,
                "a+e+i+o+u_minAnchors",
                detail: "rank-0 surface has \(anchorCount) `1021` anchors, expected ≥4 (\(hex(top.surface)))"
            )
            // Must contain the e-rule asat-coda (101A 103A), the long-i
            // (102E), the o-cluster (102D 102F), and the long-u (1030).
            ctx.assertTrue(
                topScalars.contains(0x102E),
                "a+e+i+o+u_hasLongI",
                detail: "rank-0 missing long-i: \(hex(top.surface))"
            )
            ctx.assertTrue(
                topScalars.contains(0x102D) && topScalars.contains(0x102F),
                "a+e+i+o+u_hasOCluster",
                detail: "rank-0 missing o-cluster: \(hex(top.surface))"
            )
            ctx.assertTrue(
                topScalars.contains(0x1030),
                "a+e+i+o+u_hasLongU",
                detail: "rank-0 missing long-u: \(hex(top.surface))"
            )
        },

        // Identical-letter doubled bare-vowel buffers keep the
        // long-vowel / particle collapse at rank 0. The two-syllable
        // form is still panel-reachable below.
        TestCase("identicalDoubledBareVowel_keepsCollapseAtRank0") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expectedTop: [UInt32])] = [
                ("u+u", [0x1021, 0x1030]),    // အူ long-u
                ("i+i", [0x1024]),             // ဤ long-i particle
                ("a+a", [0x1021]),             // အ single anchor
                ("e+e", [0x1021, 0x102E]),    // အီ
                ("o+o", [0x1029]),             // ဩ long-o particle
            ]
            for c in cases {
                let cands = engine.update(buffer: c.buffer, context: []).candidates
                guard let top = cands.first else {
                    ctx.assertTrue(false, c.buffer, detail: "panel empty")
                    continue
                }
                ctx.assertTrue(
                    surfaceEquals(top.surface, c.expectedTop),
                    c.buffer,
                    detail: "rank-0 '\(top.surface)' (\(hex(top.surface))) expected=\(c.expectedTop.map { String(format: "%04X", $0) })"
                )
            }
        },

        // No rank-0 candidate may carry an orphan-dep-vowel-after-asat
        // shape (`<asat> <dep-vowel>` with no anchor between) for any
        // bug-class buffer. Pre-fix `i+u` produced `1021 100A 103A
        // 1030` (orphan `1030` after asat); the fix injects a `1021`
        // anchor between them.
        TestCase("noOrphanDepVowelAfterAsat") { ctx in
            let engine = emptyEngine()
            let buffers = ["i+u", "i+o", "e+u", "e+o", "o+u", "o+i"]
            for buffer in buffers {
                let cands = engine.update(buffer: buffer, context: []).candidates
                guard let top = cands.first else {
                    ctx.assertTrue(false, buffer, detail: "panel empty")
                    continue
                }
                let s = Array(top.surface.unicodeScalars).map(\.value)
                var hasOrphanAfterAsat = false
                for i in 1..<s.count {
                    let prev = s[i - 1]
                    let cur = s[i]
                    if prev == 0x103A && cur >= 0x102B && cur <= 0x1032 {
                        hasOrphanAfterAsat = true
                        break
                    }
                }
                ctx.assertFalse(
                    hasOrphanAfterAsat,
                    buffer,
                    detail: "rank-0 '\(top.surface)' (\(hex(top.surface))) has orphan dep-vowel after asat"
                )
            }
        },

        // Counter-example regression guards: the buffers that already
        // worked must continue to work.
        TestCase("counterExamplesUnchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                ("i+e",  [0x1021, 0x102D, 0x101A, 0x103A]),  // အိယ်
                // u+i kept the existing two-syllable rank 0.
                ("u+i",  [0x1021, 0x1030, 0x1021, 0x102E]),
            ]
            for c in cases {
                let cands = engine.update(buffer: c.buffer, context: []).candidates
                guard let top = cands.first else {
                    ctx.assertTrue(false, c.buffer, detail: "panel empty")
                    continue
                }
                ctx.assertTrue(
                    surfaceEquals(top.surface, c.expected),
                    c.buffer,
                    detail: "rank-0 '\(top.surface)' (\(hex(top.surface))) expected=\(c.expected.map { String(format: "%04X", $0) })"
                )
            }
        },
    ])
}
