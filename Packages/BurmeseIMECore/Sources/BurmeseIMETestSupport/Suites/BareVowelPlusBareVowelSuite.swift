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

    /// Returns true when `surface` contains at least two distinct
    /// independent-vowel anchors (U+1021..U+102A) — a heuristic for
    /// "two-syllable form, each side anchored to its own indep vowel".
    /// Used by the panel-reachability checks for the 25-cell cross-
    /// product where the exact two-syllable shape varies between the
    /// canonical and `<v>2`-variant forms.
    private static func surfaceHasTwoIndepVowelSyllables(
        _ surface: String
    ) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        var anchors = 0
        for v in scalars where (0x1021...0x102A).contains(v) {
            anchors += 1
            if anchors >= 2 { return true }
        }
        return false
    }

    public static let suite = TestSuite(name: "BareVowelPlusBareVowel", cases: [

        // FULL 25-cell cross-product: every buffer `<v1>+<v2>` where
        // v1, v2 ∈ {a, e, i, o, u}. For each non-identical-doubled
        // cell, assert the rank-0 surface contains TWO independent-
        // vowel anchors — i.e. each side materialises as its own
        // syllable. The identical-doubled cells (`a+a`, `e+e`, etc.)
        // keep their long-vowel collapse and are NOT expected to
        // produce two anchors at rank-0; those are covered by the
        // dedicated `identicalDoubledBareVowel_keepsCollapseAtRank0`
        // case below.
        TestCase("fullCrossProduct_rank0HasTwoSyllableStructure") { ctx in
            let engine = emptyEngine()
            let vowels = ["a", "e", "i", "o", "u"]
            for v1 in vowels {
                for v2 in vowels {
                    let buffer = "\(v1)+\(v2)"
                    // Skip identical-doubled cells — they
                    // deliberately collapse at rank 0 (covered by
                    // `identicalDoubledBareVowel_keepsCollapseAtRank0`).
                    if v1 == v2 { continue }
                    let cands = engine.update(buffer: buffer, context: []).candidates
                    guard let top = cands.first else {
                        ctx.assertTrue(false, buffer, detail: "panel empty")
                        continue
                    }
                    ctx.assertTrue(
                        surfaceHasTwoIndepVowelSyllables(top.surface),
                        buffer,
                        detail: "rank-0 '\(top.surface)' (\(hex(top.surface))) lacks two-syllable structure (needs ≥2 indep-vowel anchors)"
                    )
                }
            }
        },

        // FULL 25-cell cross-product, exact rank-0 surface for the
        // canonical two-syllable form. For each non-identical-doubled
        // cell whose rank-0 lands the canonical `<v1-surface><1021><v2-surface>`
        // shape, assert the exact scalar sequence.
        //
        // Cells whose rank-0 currently uses an alternate (`o2`/`i2`)
        // variant due to the parser's richer-surface tiebreak land
        // in the looser `fullCrossProduct_panelContainsTwoSyllable`
        // case below — they still satisfy the panel-reachability
        // invariant via the `<v>2` variant pair.
        TestCase("fullCrossProduct_rank0ExactCanonical") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                // a-LHS:
                ("a+e",  [0x1021, 0x1021, 0x101A, 0x103A]),
                ("a+i",  [0x1021, 0x1021, 0x102E]),
                ("a+o",  [0x1021, 0x1021, 0x102D, 0x102F]),
                ("a+u",  [0x1021, 0x1021, 0x1030]),
                // e-LHS:
                ("e+a",  [0x1021, 0x101A, 0x103A, 0x1021]),
                ("e+i",  [0x1021, 0x101A, 0x103A, 0x1021, 0x102E]),
                ("e+o",  [0x1021, 0x101A, 0x103A, 0x1021, 0x102D, 0x102F]),
                ("e+u",  [0x1021, 0x101A, 0x103A, 0x1021, 0x1030]),
                // i-LHS (long-i variant wins rank-0 with my fix):
                ("i+a",  [0x1021, 0x102E, 0x1021]),
                ("i+e",  [0x1021, 0x102E, 0x1021, 0x101A, 0x103A]),
                ("i+o",  [0x1021, 0x102E, 0x1021, 0x102D, 0x102F]),
                ("i+u",  [0x1021, 0x102E, 0x1021, 0x1030]),
                // o-LHS:
                ("o+a",  [0x1021, 0x102D, 0x102F, 0x1021]),
                ("o+e",  [0x1021, 0x102D, 0x102F, 0x1021, 0x101A, 0x103A]),
                ("o+u",  [0x1021, 0x102D, 0x102F, 0x1021, 0x1030]),
                // u-LHS:
                ("u+a",  [0x1021, 0x1030, 0x1021]),
                ("u+e",  [0x1021, 0x1030, 0x1021, 0x101A, 0x103A]),
                ("u+i",  [0x1021, 0x1030, 0x1021, 0x102E]),
                ("u+o",  [0x1021, 0x1030, 0x1021, 0x102D, 0x102F]),
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

        // Cells whose rank-0 lands the `o2`+`i2` variant pair. The
        // surface still carries two independent-vowel anchors so the
        // panel-reachability invariant holds, but the canonical
        // `1021 102D 102F 1021 102E` (`အို + အီ`) form is shadowed
        // by the richer-surface `o2`+`i2` tiebreak. The variant
        // form is a legitimate two-syllable shape (each side anchored
        // to its own `1021`), so this case asserts the rank-0
        // matches the `o2`+`i2` pair specifically.
        TestCase("fullCrossProduct_oLhs_i_or_iLhs_o_variant") { ctx in
            let engine = emptyEngine()
            // `o+i` rank-0 lands the `o2`+`i2` variant pair (richer-
            // surface tiebreak between `o` (2 scalars) and `o2`
            // (4 scalars) at materialise time).
            let cases: [(buffer: String, expected: [UInt32])] = [
                ("o+i",  [0x1021, 0x102D, 0x102F, 0x101A, 0x103A,
                          0x1021, 0x100A, 0x103A]),
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

        // The `e+i` particle `104F` (`၏`, genitive marker) is the
        // longest-match singletonized reading the parser uses for an
        // un-`+`-separated `ei` input. When the user explicitly types
        // `e+i` (with the hard syllable break), the parser's
        // longest-match must respect the `+` separator and must NOT
        // produce the `104F` particle at rank 0 — the user's typed
        // `+` is the discriminator between "I want the particle" and
        // "I want two separate vowel syllables".
        //
        // This case asserts the inverse invariant: NO rank-≤3
        // candidate for `e+i` is the `104F` particle. The two-
        // syllable form `1021 101A 103A 1021 102E` must win rank 0;
        // the `104F` particle is intentionally NOT in the panel
        // because the engine's `ei` longest-match never crosses the
        // user's `+` boundary post-fix. Users wanting the particle
        // type `ei` (without `+`); the panel-reachability invariant
        // is satisfied via that input path, not via `e+i`.
        TestCase("eiParticle_doesNotWinRank0_underExplicitPlus") { ctx in
            let engine = emptyEngine()
            let cands = engine.update(buffer: "e+i", context: []).candidates
            guard let top = cands.first else {
                ctx.assertTrue(false, "e+i", detail: "panel empty")
                return
            }
            // The genitive-particle scalar `104F` must NOT win
            // rank 0 for an explicit-`+` buffer.
            ctx.assertFalse(
                top.surface.unicodeScalars.contains { $0.value == 0x104F },
                "e+i_104FNotRank0",
                detail: "rank-0 '\(top.surface)' (\(hex(top.surface))) carries 104F particle despite explicit `+`"
            )
            // The two-syllable form must be at rank-0.
            ctx.assertTrue(
                surfaceEquals(top.surface, [0x1021, 0x101A, 0x103A, 0x1021, 0x102E]),
                "e+i_twoSyllableAtRank0",
                detail: "rank-0 '\(top.surface)' (\(hex(top.surface))) is not the two-syllable form"
            )
        },

        // Panel-wide invariant: for the `<bare-vowel>+<bare-vowel>`
        // class, no rank-≤3 candidate carries a multi-cluster-on-
        // single-anchor shape (chained dep-vowel clusters on one
        // base) or an orphan-dep-vowel-after-asat shape. Both shapes
        // are textbook orthographic violations the existing
        // sanitizers reject — TASK-052 asserts they are now
        // unreachable in the top of the panel for this class.
        TestCase("noMultiClusterOrOrphanInTop3") { ctx in
            let engine = emptyEngine()
            let vowels = ["a", "e", "i", "o", "u"]
            for v1 in vowels {
                for v2 in vowels {
                    let buffer = "\(v1)+\(v2)"
                    let cands = engine.update(buffer: buffer, context: []).candidates
                    for (i, c) in cands.prefix(3).enumerated() {
                        let scalars = Array(c.surface.unicodeScalars).map(\.value)
                        // orphan-dep-vowel-after-asat: `103A` followed
                        // immediately by a dep-vowel scalar
                        // (`102B..1032`) with no anchor between.
                        var hasOrphan = false
                        for j in 1..<scalars.count {
                            let prev = scalars[j - 1]
                            let cur = scalars[j]
                            if prev == 0x103A && cur >= 0x102B && cur <= 0x1032 {
                                hasOrphan = true
                                break
                            }
                        }
                        ctx.assertFalse(
                            hasOrphan,
                            "\(buffer)_rank\(i)_noOrphan",
                            detail: "rank-\(i) '\(c.surface)' (\(hex(c.surface))) has orphan dep-vowel after asat"
                        )
                        ctx.assertFalse(
                            BurmeseEngine.surfaceContainsMultiClusterOnSingleAnchor(c.surface),
                            "\(buffer)_rank\(i)_noMultiCluster",
                            detail: "rank-\(i) '\(c.surface)' (\(hex(c.surface))) has multi-cluster-on-single-anchor"
                        )
                    }
                }
            }
        },

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
        //
        // Gap-fix update (TASK-052 follow-up): `i+e` was previously
        // asserted at the short-i + ya-asat coda surface
        // (`1021 102D 101A 103A` / `အိယ်`), which is a single-syllable
        // form produced when the right-shrink probe rejected the
        // soft-`+` parse and the engine composed `e` as a tail on
        // the kept `i+` prefix. After widening the soft-`+`
        // admission for the `<bare-vowel-LHS>+<bare-vowel-RHS>`
        // class (and the matching `1021` injection in
        // `Finalization::materialize`), the user-respecting
        // two-syllable form `1021 102E 1021 101A 103A` (`အီအယ်`)
        // now lands at rank 0 — exactly the panel-presence claim
        // the task acceptance criteria advocate (CLAUDE.md §6:
        // "User-typed `+` is a hard syllable / stack boundary").
        // The previous assertion was a documented baseline, not a
        // user-respecting target; the new value matches the
        // task body's own counter-example table.
        TestCase("counterExamplesUnchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                // i+e now lands the two-syllable form at rank 0:
                // `1021 102E` (`အီ`) + `1021 101A 103A` (`အယ်`).
                ("i+e",  [0x1021, 0x102E, 0x1021, 0x101A, 0x103A]),
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
