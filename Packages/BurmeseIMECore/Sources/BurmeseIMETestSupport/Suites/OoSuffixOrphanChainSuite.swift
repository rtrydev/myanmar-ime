import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-017: typing `o` / `oo` (or other standalone-rule chars
/// `ee`, `ii`, `uu`, `ay`) after any non-seed predecessor must not
/// produce a multi-anchor orphan chain. The rank-0 surface for
/// `<closed-syllable>(o|oo|ee|ii|uu|ay)` patterns must have at
/// most ONE independent-vowel scalar (U+1021..U+102A) past the
/// asat coda — either the precomposed independent-vowel form
/// (`ဩ` for `oo`, `ဦ` for `uu`) at rank 0, or the trailing chain
/// dropped into the literal tail and rendered as a single
/// independent vowel by `composeLetterRunsInTail`.
public enum OoSuffixOrphanChainSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    /// True when `surface` contains an independent-vowel anchor
    /// (`1021..102A`) that splits a single orthographic cluster
    /// mid-stream — i.e. an anchor that lands BETWEEN dep-vowel
    /// scalars that would otherwise form a contiguous valid Burmese
    /// cluster on the prior anchor. Used by the
    /// `openSyllablePrefix_onePerCluster` test to verify the TASK-022
    /// per-cluster invariant: each cluster's `1021` injection lands
    /// at a cluster boundary, never in the middle of an in-progress
    /// cluster.
    ///
    /// A "valid Burmese cluster" is the contiguous dep-vowel/medial/
    /// tone-mark run that follows an anchor. A cluster ends at:
    ///   * a same-category dep-vowel repeat (`102D ... 102D`).
    ///   * an asat (`103A`) — closes the syllable.
    ///   * the next anchor.
    ///
    /// `1021 102D 102F 1021 102D 102F` is the legitimate "two
    /// complete `o`-clusters back-to-back" shape produced by
    /// per-cluster anchor injection — each `1021 102D 102F` is one
    /// `o`-cluster (`အို`). The cross-category cluster-completion
    /// shapes recognised here are the same canonical legal multi-
    /// scalar shapes as `Parser/Finalization::scanOutputLegality`:
    /// `o`-cluster (`102D 102F`, cats {2,3}) and aung-order
    /// (`1031 102B/102C`, cats {4,1}). Any other cross-category
    /// chain after an anchor is incomplete — a follow-on anchor
    /// would be mid-cluster.
    private static func consecutiveAnchorsInDepMarkRun(_ scalars: [UInt32]) -> Bool {
        var sawAnchor = false
        var seenDepCategoriesInCluster: Set<Int> = []
        for v in scalars {
            let isAnchor = (0x1021...0x102A).contains(v)
            let isDepMark = (0x102B...0x1032).contains(v)
                || v == 0x1036
                || (0x103B...0x103E).contains(v)
            let depCategory = depVowelCategory(v)
            if isAnchor {
                if sawAnchor {
                    // The prior cluster is complete iff it is empty
                    // (anchor with no dep-marks of its own — the
                    // anchor IS the cluster) or a canonical multi-
                    // scalar shape.
                    let isComplete = seenDepCategoriesInCluster.isEmpty
                        || seenDepCategoriesInCluster == [2, 3]      // o-cluster
                        || seenDepCategoriesInCluster == [4, 1]      // aung-order
                        || seenDepCategoriesInCluster == [4]         // standalone e-kar
                        || seenDepCategoriesInCluster == [1]         // standalone aa
                        || seenDepCategoriesInCluster == [2]         // standalone i
                        || seenDepCategoriesInCluster == [3]         // standalone u
                        || seenDepCategoriesInCluster == [5]         // standalone ai
                    if !isComplete {
                        return true
                    }
                }
                sawAnchor = true
                seenDepCategoriesInCluster.removeAll()
            } else if isDepMark {
                if depCategory != 0,
                   seenDepCategoriesInCluster.contains(depCategory) {
                    // Same-category dep-vowel repeat opens a new
                    // cluster — mirror the engine's per-cluster split.
                    sawAnchor = false
                    seenDepCategoriesInCluster.removeAll()
                }
                if depCategory != 0 {
                    seenDepCategoriesInCluster.insert(depCategory)
                }
            } else {
                sawAnchor = false
                seenDepCategoriesInCluster.removeAll()
            }
        }
        return false
    }

    /// Categorise dep-vowel scalars for cluster-split detection.
    /// Mirrors `Engine/SurfaceSanitizers.swift::depVowelCategory`.
    @inline(__always)
    private static func depVowelCategory(_ v: UInt32) -> Int {
        switch v {
        case 0x102B, 0x102C: return 1
        case 0x102D, 0x102E: return 2
        case 0x102F, 0x1030: return 3
        case 0x1031:        return 4
        case 0x1032:        return 5
        default:            return 0
        }
    }

    /// Count independent-vowel scalars (U+1021..U+102A) appearing
    /// AFTER the last asat scalar (U+103A) in `surface`. The
    /// pre-asat anchors (e.g. the leading-A from `aung`) are
    /// allowed; the count budget applies only to the trailing
    /// portion.
    private static func independentVowelsAfterLastAsat(_ surface: String) -> Int {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        var lastAsat = -1
        for i in 0..<scalars.count where scalars[i] == 0x103A {
            lastAsat = i
        }
        if lastAsat < 0 { return 0 }
        var count = 0
        for i in (lastAsat + 1)..<scalars.count
        where (0x1021...0x102A).contains(scalars[i]) {
            count += 1
        }
        return count
    }

    public static let suite = TestSuite(name: "OoSuffixOrphanChain", cases: [

        // The acceptance corpus: `<closed-syllable>(o|oo|...)` must
        // have at most one anchor past the asat coda.
        TestCase("rank0_singleAnchorPastAsatCoda") { ctx in
            let engine = emptyEngine()
            for buffer in [
                "aungoo", "nyaungoo", "phaungoo",
                "aungii", "aungai",
            ] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let count = independentVowelsAfterLastAsat(surface)
                ctx.assertTrue(
                    count <= 1,
                    buffer,
                    detail: "rank-0 for '\(buffer)' has \(count) indep-vowel anchors past the last asat coda; surface='\(surface)'"
                )
            }
        },

        // Open-syllable prefixes followed by trailing vowel rules
        // are documented in TASK-017 but the right-shrink rejection
        // path requires an asat-closed coda to fire cleanly (see
        // `surfaceHasOrphanAnchorPastAsatCoda` in InputNormalization).
        // Without a coda the engine still produces multiple anchored
        // syllables (one per `o`-rule firing); the TASK-022
        // per-cluster anchor injection caps the damage at "one
        // anchor per orphan-mark cluster" but the inputs render as
        // `အို + အို` rather than the desired `ဩ` precomposed form.
        // Verify the per-cluster invariant via a fresh detector that
        // counts adjacent-by-dep-marks-only anchor pairs.
        // Documented as a partial fix — full coverage of the no-coda
        // case requires the TASK-017 desired-state #2 (firing the
        // standalone rule mid-buffer), which is out of scope for
        // this iteration.
        TestCase("rank0_openSyllablePrefixAtMostOneAnchorPerCluster") { ctx in
            let engine = emptyEngine()
            for buffer in ["kayoo", "kar+oo"] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars).map(\.value)
                let consecutiveSameClusterPattern = consecutiveAnchorsInDepMarkRun(scalars)
                ctx.assertFalse(
                    consecutiveSameClusterPattern,
                    buffer,
                    detail: "rank-0 for '\(buffer)' has multiple anchors in a single dep-mark cluster; surface='\(surface)'"
                )
            }
        },
    ])
}
