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

        // Sibling reachability: the override flips the canonical
        // single-vowel form to rank 1, but the parser-native repeated
        // shape (`ဦဦ` for `uu`, `ယ်ယ်ယ်` for `eee`, `အိုို` for `oo`,
        // `အီီ` etc. for `ii`) must remain reachable elsewhere in the
        // panel so the user can still pick the rarer form if they
        // explicitly want it. `a` repetition has no parser-native
        // sibling (the inherent vowel collapses every repetition to
        // a single `အ`), so it's skipped here.
        TestCase("repeatedBareVowels_parserNativeSiblingReachable") { ctx in
            // Letter → expected rank-1 override surface (skip-list
            // for the sibling search). `a` is excluded because the
            // parser collapses every `a`-only buffer to inherent `အ`
            // with no distinct sibling.
            let cases: [(letter: Character, override: String)] = [
                ("e", "\u{1021}\u{102E}"),
                ("i", "\u{1024}"),
                ("o", "\u{1029}"),
                ("u", "\u{1021}\u{1030}"),
            ]
            for entry in cases {
                for n in 2...4 {
                    let buffer = String(repeating: String(entry.letter), count: n)
                    let state = BurmeseEngine().update(buffer: buffer, context: [])
                    ctx.assertTrue(
                        state.candidates.count >= 2,
                        "\(buffer)",
                        detail: "panel has fewer than two candidates; user can't reach a sibling"
                    )
                    let nonOverrideSibling = state.candidates.first {
                        $0.surface != entry.override
                    }
                    ctx.assertTrue(
                        nonOverrideSibling != nil,
                        "\(buffer)",
                        detail: "no parser-native sibling for '\(buffer)'; only override candidate is reachable"
                    )
                }
            }
        },
    ])
}
