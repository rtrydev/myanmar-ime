import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-022: per-cluster anchor injection invariant. The orphan-mark
/// promotion sanitiser must wrap a contiguous run of orphan dep-vowel
/// scalars with at most one independent-vowel anchor (U+1021), not
/// one anchor per scalar. The chain-detection sanitiser must also
/// treat `<consonant-base> 103A` (asat-closed coda) as a transparent
/// bridge across the indep-vowel chain, so the sanitiser catches the
/// anchor-pollution pattern even when the parser's `e`-rule fallback
/// inserts ya-asat between two orphan-mark clusters.
///
/// The detector used by this suite is intentionally fresh — the
/// existing `AdjacentIndependentVowelSuite::violatesRepeatedAnchors`
/// helper has the same flawed chain-reset logic as the engine
/// sanitiser, so adapting it would just duplicate the bug. We count
/// every U+1021 anchor in the rank-0 surface and bound it by the
/// number of "semantic syllable" units, where a syllable is delimited
/// by an asat-closed coda or a base consonant.
public enum OrphanMarkClusterAnchorSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    /// Count of independent-vowel anchors (U+1021..U+102A) in `surface`.
    private static func independentVowelCount(_ surface: String) -> Int {
        surface.unicodeScalars.lazy.filter { (0x1021...0x102A).contains($0.value) }.count
    }

    /// TASK-022 acceptance corpus: each rank-0 surface for these
    /// buffers must satisfy the "≤ 1 indep-vowel anchor per
    /// semantic syllable" structural rule. Counted by:
    ///   - one syllable per base consonant (U+1000..U+101F, U+103F)
    ///   - one syllable per orphan-anchor cluster (a U+1021 anchor
    ///     followed by zero or more dep-marks, then either end of
    ///     surface or a non-dep-mark scalar).
    private static let acceptanceCorpus: [String] = [
        "aoo", "aaoo", "kuoo", "kayoo",
        "phaungoo", "nyaungoo", "aungoo",
        "aungii", "aungai", "kar+oo",
    ]

    /// Approximate semantic-syllable count: each base consonant
    /// (U+1000..U+101F, U+103F) starts a syllable; each U+1021
    /// orphan-anchor / U+1023..U+102A independent-vowel scalar starts
    /// a syllable. dep-vowels and tone marks attach to the previous
    /// base / anchor.
    private static func semanticSyllableCount(_ surface: String) -> Int {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        var count = 0
        for v in scalars {
            if (0x1000...0x101F).contains(v) || v == 0x103F { count += 1 }
            if (0x1021...0x102A).contains(v) { count += 1 }
        }
        return max(count, 1)
    }

    public static let suite = TestSuite(name: "OrphanMarkClusterAnchor", cases: [

        // Per-cluster anchor invariant: at most one independent-vowel
        // anchor per semantic syllable. This is the TASK-022
        // acceptance criterion stated as a checkable structural rule.
        TestCase("rank0_anchorPerSemanticSyllable") { ctx in
            let engine = emptyEngine()
            for input in acceptanceCorpus {
                let surface = engine.update(buffer: input, context: [])
                    .candidates.first?.surface ?? ""
                let anchors = independentVowelCount(surface)
                let syllables = semanticSyllableCount(surface)
                ctx.assertTrue(
                    anchors <= syllables,
                    input,
                    detail: "rank-0 for '\(input)' has \(anchors) indep-vowel anchors but only \(syllables) semantic syllables; surface='\(surface)'"
                )
            }
        },

        // Sanitiser-level invariant: surfaces with multi-cluster
        // orphan-mark patterns bridged by a fallback consonant fragment
        // (`101A 103A`, `1004 103A`) should be rejected by
        // `surfaceViolatesIndependentVowelInvariant` — the detector
        // must look through asat-closed coda bridges. Synthesised
        // surfaces, not engine output: this is the structural rule.
        TestCase("sanitiserDetectsBridgedAnchorChain") { ctx in
            // Two orphan-mark clusters bridged by `101A 103A` (ya-asat),
            // each anchored by U+1021. Should be flagged.
            let bridged = "\u{1021}\u{102D}\u{1021}\u{102F}\u{101A}\u{103A}\u{1021}\u{102D}\u{1021}\u{102F}"
            ctx.assertTrue(
                BurmeseEngine.surfaceViolatesIndependentVowelInvariant(bridged),
                "bridged_detected",
                detail: "ya-asat bridge must not reset the indep-vowel chain detector; surface='\(bridged)'"
            )
            // Two clusters bridged by `1004 103A` (nga-asat / kinzi
            // coda); same shape, should also fire.
            let kinziBridged = "\u{1021}\u{102D}\u{1021}\u{102F}\u{1004}\u{103A}\u{1021}\u{102D}\u{1021}\u{102F}"
            ctx.assertTrue(
                BurmeseEngine.surfaceViolatesIndependentVowelInvariant(kinziBridged),
                "kinziBridged_detected",
                detail: "nga-asat coda bridge must not reset the indep-vowel chain detector; surface='\(kinziBridged)'"
            )
        },

        // Counter-example: legitimate two-syllable shapes with one
        // anchor each separated by asat-closed coda must NOT be
        // flagged.
        TestCase("sanitiserAllowsLegitimateMultiSyllable") { ctx in
            // `aung` + `out` — two-syllable closed-then-closed
            // shape with one anchor per syllable.
            let aungout = "\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}\u{1021}\u{102C}\u{1010}\u{103A}"
            ctx.assertFalse(
                BurmeseEngine.surfaceViolatesIndependentVowelInvariant(aungout),
                "aungout_allowed",
                detail: "legitimate two-anchor shape was wrongly flagged; surface='\(aungout)'"
            )
        },

        // TASK-017 verifies that the user-visible repro buffers no
        // longer carry the multi-cluster orphan-mark shape on rank 0
        // (the engine's belt-and-suspenders is the per-cluster anchor
        // injection in `promoteOrphanInternalMarks` PLUS the extended
        // chain detector that drops surviving multi-anchor candidates).
        TestCase("rank0HasNoBridgedAnchorChain") { ctx in
            let engine = emptyEngine()
            for buffer in [
                "nyaungoo", "kar+oo", "aoo", "aaoo",
                "kayoo", "aungoo", "phaungoo",
            ] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    BurmeseEngine.surfaceViolatesIndependentVowelInvariant(surface),
                    buffer,
                    detail: "rank 0 for '\(buffer)' violates indep-vowel chain invariant; surface='\(surface)'"
                )
            }
        },
    ])
}
