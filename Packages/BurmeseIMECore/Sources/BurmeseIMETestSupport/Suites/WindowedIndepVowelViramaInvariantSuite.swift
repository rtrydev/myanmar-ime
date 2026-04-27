import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-012: a candidate surface must never contain an
/// independent-vowel scalar (U+1021..U+102A) immediately followed by
/// virama (U+1039). That pattern is structurally illegal in modern
/// Burmese — independent vowels cannot serve as the upper of a
/// virama stack — and was reaching the candidate panel through the
/// windowed-prefix / active-tail seam in long `+`-chains.
public enum WindowedIndepVowelViramaInvariantSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    /// True when `surface` contains an independent-vowel scalar
    /// (U+1021..U+102A) immediately followed by virama (U+1039).
    private static func surfaceHasIndepVowelVirama(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 2 else { return false }
        for i in 0..<(scalars.count - 1) {
            let v = scalars[i]
            if v >= 0x1021 && v <= 0x102A && scalars[i + 1] == 0x1039 {
                return true
            }
        }
        return false
    }

    /// Build the `+`-chain of N segments — `prefix + plus + prefix +
    /// plus + …`.
    private static func plusChain(_ segment: String, count: Int) -> String {
        Array(repeating: segment, count: count).joined(separator: "+")
    }

    public static let suite = TestSuite(name: "WindowedIndepVowelViramaInvariant", cases: [

        // Headline reproduction table from TASK-012. Lengths 17, 20,
        // 23, 26 (the `ka+ka+...` chain adds 3 chars per segment).
        // Length 17 stays under the windowing threshold; 20+ crosses
        // it. Every candidate at every rank must be free of
        // `[1021..102A] 1039` adjacency.
        TestCase("plusChain_kaSegments_noIllegalSeam") { ctx in
            let engine = emptyEngine()
            for n in 6...10 {
                let buffer = plusChain("ka", count: n)
                let state = engine.update(buffer: buffer, context: [])
                for (idx, candidate) in state.candidates.enumerated() {
                    ctx.assertFalse(
                        surfaceHasIndepVowelVirama(candidate.surface),
                        "\(buffer)_rank\(idx)",
                        detail: "illegal `[1021..102A] 1039` in '\(buffer)' rank \(idx) surface='\(candidate.surface)'"
                    )
                }
            }
        },

        // General invariant: extend across multiple segment shapes
        // and lengths to catch the same seam bug for non-`ka` chains.
        TestCase("plusChain_variousSegments_noIllegalSeam") { ctx in
            let engine = emptyEngine()
            let segments = ["ka", "ta", "pa", "na", "ma", "sa"]
            for seg in segments {
                for n in 7...10 {
                    let buffer = plusChain(seg, count: n)
                    let state = engine.update(buffer: buffer, context: [])
                    for (idx, candidate) in state.candidates.enumerated() {
                        ctx.assertFalse(
                            surfaceHasIndepVowelVirama(candidate.surface),
                            "\(buffer)_rank\(idx)",
                            detail: "illegal seam in '\(buffer)' rank \(idx) surface='\(candidate.surface)'"
                        )
                    }
                }
            }
        },

        // Mixed cross-class chain — also stresses the seam.
        TestCase("plusChain_mixedSegments_noIllegalSeam") { ctx in
            let engine = emptyEngine()
            let buffers = [
                "na+ta+na+ta+na+ta+na+ta",         // dental + dental
                "na+da+na+da+na+da+na+da",         // dental cross
                "ka+ta+pa+ka+ta+pa+ka+ta+pa",       // velar/dental/labial
            ]
            for buffer in buffers {
                let state = engine.update(buffer: buffer, context: [])
                for (idx, candidate) in state.candidates.enumerated() {
                    ctx.assertFalse(
                        surfaceHasIndepVowelVirama(candidate.surface),
                        "\(buffer)_rank\(idx)",
                        detail: "illegal seam in '\(buffer)' rank \(idx) surface='\(candidate.surface)'"
                    )
                }
            }
        },

        // Short chains that don't cross the windowing threshold must
        // continue to render unchanged (no false-positive filter).
        TestCase("plusChain_shortChains_underThreshold") { ctx in
            let engine = emptyEngine()
            // Up to 6 segments × 2 chars + 5 separators = 17 chars
            // (still under the 18-char windowing threshold).
            for n in 1...6 {
                let buffer = plusChain("ka", count: n)
                let state = engine.update(buffer: buffer, context: [])
                ctx.assertTrue(
                    !state.candidates.isEmpty,
                    buffer,
                    detail: "no candidates for short chain '\(buffer)'"
                )
                for (idx, candidate) in state.candidates.enumerated() {
                    ctx.assertFalse(
                        surfaceHasIndepVowelVirama(candidate.surface),
                        "\(buffer)_rank\(idx)",
                        detail: "illegal seam in short chain '\(buffer)' rank \(idx) surface='\(candidate.surface)'"
                    )
                }
            }
        },
    ])
}
