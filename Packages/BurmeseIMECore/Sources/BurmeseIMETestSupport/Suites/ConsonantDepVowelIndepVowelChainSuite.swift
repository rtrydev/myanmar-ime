import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-041: Inputs of the shape `<consonant><o-rule><u-rule><C>`
/// (`thoun`, `koun`, `myoun`, `thoung`, …) produce a rank-0 surface
/// where the consonant onset is followed by `<dep-vowel(s)><indep-
/// vowel><consonant>` in a single uninterrupted dep-mark run — two
/// distinct base anchors (the consonant + the indep-vowel) within
/// one syllable cluster. The pattern `<dep-vowel><indep-vowel>`
/// inside a single syllable is structurally illegal: the indep-
/// vowel is a fresh syllable anchor, but a syllable cluster cannot
/// open a new base before its U+103A asat closer.
///
/// The parser already rejects the symmetric forward shape
/// `<indep-vowel><dep-vowel>` (`scanOutputLegality` returns false
/// when an indep-vowel is followed by a dep-vowel). The TASK-041
/// gap is the backward shape: `<dep-vowel><indep-vowel>`. This
/// suite exercises the new check.
public enum ConsonantDepVowelIndepVowelChainSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func surfaceHasDepVowelThenIndepVowel(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 2 else { return false }
        for i in 1..<scalars.count {
            let prev = scalars[i - 1]
            let curr = scalars[i]
            // Dep-vowel range U+102B..U+1032, indep-vowel range
            // U+1023..U+102A.
            if (prev >= 0x102B && prev <= 0x1032)
                && (curr >= 0x1023 && curr <= 0x102A) {
                return true
            }
        }
        return false
    }

    public static let suite = TestSuite(name: "ConsonantDepVowelIndepVowelChain", cases: [

        // Parser-level: scanOutputLegality must reject every documented
        // illegal scalar sequence.
        TestCase("parser_legality_rejectsDepVowelIndepVowel") { ctx in
            let illegal: [(String, [UInt32])] = [
                ("thoun",  [0x101E, 0x102D, 0x102F, 0x1026, 0x1014]),
                ("koun",   [0x1000, 0x102D, 0x102F, 0x1026, 0x1014]),
                ("thoung", [0x101E, 0x102D, 0x102F, 0x1026, 0x1004]),
                ("myoun",  [0x1019, 0x103C, 0x102D, 0x102F, 0x1026, 0x1014]),
            ]
            for (label, scalars) in illegal {
                var s = ""
                s.unicodeScalars.append(contentsOf: scalars.compactMap { Unicode.Scalar($0) })
                ctx.assertFalse(
                    SyllableParser.scanOutputLegality(s),
                    label,
                    detail: "scanOutputLegality accepted illegal surface '\(s)'"
                )
            }
        },

        // Parser-level: legitimate `<consonant><dep-vowel><asat>
        // <indep-vowel>` two-syllable shapes are NOT flagged
        // (the asat closes the first cluster before the second
        // anchor appears).
        TestCase("parser_legality_acceptsClosedClusterThenIndepVowel") { ctx in
            // `aungout` two-cluster shape: each cluster has its
            // own base + e-kar + aa + nga-asat coda terminator.
            let aungout: [UInt32] = [
                0x1021, 0x1031, 0x102C, 0x1004, 0x103A,
                0x1021, 0x1031, 0x102C, 0x1000, 0x103A,
            ]
            // `rarthiu` three-syllable shape: the trailing
            // independent-vowel ဦ comes after a dep-vowel that
            // belongs to a different (already-closed) cluster.
            let rarthiu: [UInt32] = [
                0x101B, 0x102C, 0x101E, 0x102E, 0x1026,
            ]
            for (label, scalars) in [("aungout", aungout), ("rarthiu", rarthiu)] {
                var s = ""
                s.unicodeScalars.append(contentsOf: scalars.compactMap { Unicode.Scalar($0) })
                ctx.assertTrue(
                    SyllableParser.scanOutputLegality(s),
                    label,
                    detail: "scanOutputLegality regressed on legal surface '\(s)'"
                )
            }
        },

        // Engine: rank-0 surface for the documented `<C><o><u><C>`
        // family must not carry the dep-vowel→indep-vowel chain.
        TestCase("engine_rank0FreeOfDepVowelIndepVowelChain") { ctx in
            let buffers = ["thoun", "koun", "myoun", "thoung"]
            for buffer in buffers {
                let surface = emptyEngine()
                    .update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    surfaceHasDepVowelThenIndepVowel(surface),
                    buffer,
                    detail: "rank-0 carries dep-vowel→indep-vowel chain for '\(buffer)' surface='\(surface)'"
                )
            }
        },

        // Engine: when the multi-anchor parse is at rank 1+ in the
        // panel (e.g. `tuun`/`kuun`), it must be filtered when a
        // clean sibling exists.
        TestCase("engine_multiAnchorFilteredWhenSiblingExists") { ctx in
            let buffers = ["tuun", "kuun"]
            for buffer in buffers {
                let candidates = emptyEngine()
                    .update(buffer: buffer, context: [])
                    .candidates
                let cleanExists = candidates.contains {
                    !surfaceHasDepVowelThenIndepVowel($0.surface)
                }
                guard cleanExists else { continue }
                for (i, c) in candidates.enumerated() {
                    ctx.assertFalse(
                        surfaceHasDepVowelThenIndepVowel(c.surface),
                        buffer,
                        detail: "rank-\(i) of '\(buffer)' carries dep-vowel→indep-vowel chain: '\(c.surface)'"
                    )
                }
            }
        },

        // Regression: legitimate `<C>+<dep-vowel>+<asat-closed
        // syllable>+<indep-vowel particle>` shapes (`thiu`,
        // `rarthiu`) continue to surface unchanged at rank 0.
        TestCase("engine_legitimateIndepVowelParticleSurvives") { ctx in
            let cases: [(String, [UInt32])] = [
                ("thiu",    [0x101E, 0x102E, 0x1026]),
                ("rarthiu", [0x101B, 0x102C, 0x101E, 0x102E, 0x1026]),
            ]
            for (buffer, scalars) in cases {
                var expected = ""
                expected.unicodeScalars.append(
                    contentsOf: scalars.compactMap { Unicode.Scalar($0) }
                )
                let actual = emptyEngine()
                    .update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertEqual(
                    actual,
                    expected,
                    buffer,
                    file: #file,
                    line: #line
                )
            }
        },
    ])
}
