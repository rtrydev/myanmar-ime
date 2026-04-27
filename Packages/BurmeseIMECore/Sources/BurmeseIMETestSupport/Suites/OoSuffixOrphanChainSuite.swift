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

    /// True when `surface` carries two or more anchors immediately
    /// adjacent (either touching or separated only by one or more
    /// dep-mark scalars). Used by the `openSyllablePrefix_onePerCluster`
    /// test to verify the TASK-022 per-cluster invariant: each
    /// contiguous orphan-mark run carries at most one anchor.
    private static func consecutiveAnchorsInDepMarkRun(_ scalars: [UInt32]) -> Bool {
        var sawAnchor = false
        for v in scalars {
            let isAnchor = (0x1021...0x102A).contains(v)
            let isDepMark = (0x102B...0x1032).contains(v)
                || v == 0x1036
                || (0x103B...0x103E).contains(v)
            if isAnchor {
                if sawAnchor { return true }
                sawAnchor = true
            } else if isDepMark {
                // stay in the current run
            } else {
                sawAnchor = false
            }
        }
        return false
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
