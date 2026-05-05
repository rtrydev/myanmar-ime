import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-060: Buffer-final non-standalone vowel rules (`u`, `i`, etc.)
/// attached after a prior cluster-bearing syllable must not surface
/// the engine-fabricated `<dep-vowel><U+1021><dep-vowel>` phantom-
/// anchor shape at rank 0.
public enum BufferFinalOrphanAnchorSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func surfaceHasPhantomMidAnchor(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 3 else { return false }
        for i in 1..<(scalars.count - 1) {
            guard scalars[i] == 0x1021 else { continue }
            let prev = scalars[i - 1]
            let next = scalars[i + 1]
            let prevIsDepMark = (prev >= 0x102B && prev <= 0x1032)
                || (prev >= 0x103B && prev <= 0x103E)
            let nextIsDepMark = (next >= 0x102B && next <= 0x1032)
                || (next >= 0x103B && next <= 0x103E)
            if prevIsDepMark && nextIsDepMark {
                return true
            }
        }
        return false
    }

    private static func surfaceContainsScalarSequence(
        _ surface: String,
        _ needle: [UInt32]
    ) -> Bool {
        let hay = Array(surface.unicodeScalars).map(\.value)
        guard needle.count <= hay.count else { return false }
        if needle.isEmpty { return true }
        outer: for i in 0...(hay.count - needle.count) {
            for j in needle.indices where hay[i + j] != needle[j] {
                continue outer
            }
            return true
        }
        return false
    }

    public static let suite = TestSuite(name: "BufferFinalOrphanAnchor", cases: [

        TestCase("rank0FreeOfPhantomMidAnchor") { ctx in
            let engine = emptyEngine()
            let buffers = [
                "kou", "you", "thou", "chingyou",
                "kayou", "khoyou", "kywou", "khywou", "phywou",
                "tipou", "phou", "khou",
                "kou+", "kou2",
            ]
            for buffer in buffers {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    surfaceHasPhantomMidAnchor(surface),
                    buffer,
                    detail: "rank-0 carries phantom <dep-vowel><U+1021><dep-vowel> for '\(buffer)' surface='\(surface)'"
                )
            }
        },

        TestCase("cleanYaAsatU1026FormReachableInPanel") { ctx in
            let engine = emptyEngine()
            let cases: [(String, [UInt32])] = [
                ("kou",  [0x1000, 0x102D, 0x102F, 0x101A, 0x103A, 0x1026]),
                ("you",  [0x101A, 0x102D, 0x102F, 0x101A, 0x103A, 0x1026]),
                ("thou", [0x101E, 0x102D, 0x102F, 0x101A, 0x103A, 0x1026]),
                ("phou", [0x1016, 0x102D, 0x102F, 0x101A, 0x103A, 0x1026]),
                ("khou", [0x1001, 0x102D, 0x102F, 0x101A, 0x103A, 0x1026]),
                ("kayou", [0x1000, 0x101A, 0x102D, 0x102F, 0x101A, 0x103A, 0x1026]),
                ("tipou", [0x1010, 0x102E, 0x1015, 0x102D, 0x102F, 0x101A, 0x103A, 0x1026]),
            ]
            for (buffer, expectedScalars) in cases {
                let candidates = engine.update(buffer: buffer, context: []).candidates
                let found = candidates.contains { c in
                    surfaceContainsScalarSequence(c.surface, expectedScalars)
                }
                ctx.assertTrue(
                    found,
                    buffer,
                    detail: "clean ya-asat + U+1026 form not present in any candidate for '\(buffer)'; surfaces=\(candidates.map(\.surface))"
                )
            }
        },

        TestCase("bufferExtendedRank0Unchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(String, [UInt32])] = [
                ("kou.",   [0x1000, 0x102D, 0x102F, 0x101A, 0x103A, 0x1026, 0x002E]),
                ("kou:",   [0x1000, 0x102D, 0x102F, 0x101A, 0x103A, 0x1026, 0x003A]),
                ("kouka",  [0x1000, 0x102D, 0x102F, 0x101A, 0x103A, 0x1026, 0x1000]),
            ]
            for (buffer, expectedScalars) in cases {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars).map(\.value)
                ctx.assertEqual(
                    actual,
                    expectedScalars,
                    buffer,
                    file: #file,
                    line: #line
                )
            }
        },

        TestCase("bareVowelInputsKeepIndependentVowelForm") { ctx in
            let engine = emptyEngine()
            let cases: [(String, [[UInt32]])] = [
                ("u",  [[0x1026], [0x1021, 0x1030]]),
                ("u2", [[0x1026, 0x1042], [0x1021, 0x1030, 0x1042]]),
                ("oo", [[0x1029], [0x1026]]),
                ("i",  [[0x1021, 0x102D], [0x1021, 0x102E]]),
            ]
            for (buffer, allowedScalars) in cases {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars).map(\.value)
                let matches = allowedScalars.contains { actual == $0 }
                ctx.assertTrue(
                    matches,
                    buffer,
                    detail: "rank-0 for bare-vowel '\(buffer)' is not one of the expected indep-vowel shapes; got \(actual)"
                )
            }
        },

        TestCase("doubledBareVowelKaaUnchanged") { ctx in
            let engine = emptyEngine()
            let candidates = engine.update(buffer: "kaa", context: []).candidates
            let expectedScalars: [UInt32] = [0x1000, 0x1021]
            let found = candidates.contains { c in
                Array(c.surface.unicodeScalars).map(\.value) == expectedScalars
            }
            ctx.assertTrue(
                found,
                "kaa",
                detail: "TASK-016 fixture surface 1000 1021 missing for 'kaa'; surfaces=\(candidates.map(\.surface))"
            )
        },

        TestCase("iClusterPlusIRuleNoPhantomMidAnchor") { ctx in
            let engine = emptyEngine()
            let buffers = ["kii", "tii", "phii"]
            for buffer in buffers {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    surfaceHasPhantomMidAnchor(surface),
                    buffer,
                    detail: "rank-0 carries phantom <dep-vowel><U+1021><dep-vowel> for '\(buffer)' surface='\(surface)'"
                )
            }
        },

        TestCase("noCandidateInPanelHasPhantomMidAnchor") { ctx in
            let engine = emptyEngine()
            let buffers = [
                "kou", "you", "thou", "kayou",
                "kywou", "phywou", "tipou", "phou", "khou",
            ]
            for buffer in buffers {
                let candidates = engine.update(buffer: buffer, context: []).candidates
                for (rank, c) in candidates.enumerated() {
                    ctx.assertFalse(
                        surfaceHasPhantomMidAnchor(c.surface),
                        buffer,
                        detail: "rank-\(rank) candidate '\(c.surface)' carries phantom <dep-vowel><U+1021><dep-vowel> for '\(buffer)'"
                    )
                }
            }
        },
    ])
}
