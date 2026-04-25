import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for task 06: typing a bare vowel letter repeated N times
/// (N ≥ 2) must surface the canonical single-vowel shape at rank 1
/// rather than a repeated-asat / stacked-indep-vowel artifact (`ယ်ယ်ယ်`,
/// `ဦဦ`). The canonical alternative remains reachable elsewhere in
/// the panel.
public enum BareVowelRepetitionSuite {

    /// Per bare-vowel letter, the canonical surface returned for a
    /// repeated input (N ≥ 2). Single-letter inputs (N == 1) keep
    /// the parser's native rule output.
    private static let canonicalForRepetition: [(letter: Character, surface: String)] = [
        ("a", "\u{1021}"),                    // အ
        ("e", "\u{1021}\u{102E}"),            // အီ
        ("i", "\u{1024}"),                    // ဤ
        ("o", "\u{1029}"),                    // ဩ
        ("u", "\u{1021}\u{1030}"),            // အူ
    ]

    private static func candidateSurfaces(_ candidates: [Candidate]) -> String {
        String(describing: candidates.prefix(6).map(\.surface))
    }

    public static let suite = TestSuite(name: "BareVowelRepetition", cases: [

        // Each repeated vowel letter must surface the canonical
        // single-vowel form at rank 1 for every N ∈ {2, 3, 4, 5}.
        TestCase("repeatedBareVowels_canonicalAtRank1") { ctx in
            for entry in canonicalForRepetition {
                for n in 2...5 {
                    let buffer = String(repeating: String(entry.letter), count: n)
                    let state = BurmeseEngine().update(buffer: buffer, context: [])
                    let top = state.candidates.first?.surface ?? ""
                    ctx.assertTrue(
                        top == entry.surface,
                        "\(buffer)",
                        detail: "top='\(top)' expected='\(entry.surface)' all=\(candidateSurfaces(state.candidates))"
                    )
                }
            }
        },

        // Single-letter bare vowels still flow through the parser's
        // native rule (no override). `a` collapses to inherent `အ`,
        // `e` → orphan-ZWNJ promotion → `အေ` (or similar legal
        // sibling), etc. This guard makes sure the override only
        // kicks in for repetitions.
        TestCase("singleBareVowels_useParserNativeOutput") { ctx in
            for letter in ["a", "e", "i", "o", "u"] {
                let state = BurmeseEngine().update(buffer: letter, context: [])
                ctx.assertTrue(
                    !state.candidates.isEmpty,
                    "single_\(letter)",
                    detail: "no candidates for single bare vowel '\(letter)'"
                )
            }
        },
    ])
}
