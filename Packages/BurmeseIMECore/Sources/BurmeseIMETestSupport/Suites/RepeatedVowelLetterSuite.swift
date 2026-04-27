import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-016: a consonant followed by two or more
/// inherent-`a` letters (`kaa`, `kaaa`, `thaaa`) must not silently
/// collapse to the same surface as `<C>a` — the user's extra
/// keystrokes must remain visible somewhere in the panel.
public enum RepeatedVowelLetterSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    /// Consonants that don't carry a built-in medial extender. We
    /// skip `y`/`r`/`w`/`h` because they double as medials and the
    /// "consonant + multiple a" reading is ambiguous for them.
    private static let bareConsonants: [String] = [
        "k", "kh", "g", "gh", "ng", "s", "z", "t", "ht", "d", "dh",
        "n", "p", "ph", "v", "b", "m", "l", "th",
    ]

    public static let suite = TestSuite(name: "RepeatedVowelLetter", cases: [

        // For every bare consonant `<C>`, the panel for `<C>aa` must
        // contain a candidate whose surface differs from `<C>a`'s
        // rank-0 surface. The user's extra `a` cannot silently vanish.
        TestCase("repeatedA_panelHasNonCollapsingCandidate") { ctx in
            let engine = emptyEngine()
            for c in bareConsonants {
                let baseTop = engine.update(buffer: c + "a", context: [])
                    .candidates.first?.surface ?? ""
                let aaCands = engine.update(buffer: c + "aa", context: []).candidates
                let nonCollapsing = aaCands.contains { $0.surface != baseTop }
                ctx.assertTrue(
                    nonCollapsing,
                    "\(c)aa",
                    detail: "every '\(c)aa' candidate matches '\(c)a' top='\(baseTop)' all=\(aaCands.prefix(6).map(\.surface))"
                )
            }
        },

        // Length 3 (`<C>aaa`) too — the second AND third `a` must be
        // visible somewhere.
        TestCase("repeatedA_tripleAlsoNonCollapsing") { ctx in
            let engine = emptyEngine()
            for c in bareConsonants {
                let baseTop = engine.update(buffer: c + "a", context: [])
                    .candidates.first?.surface ?? ""
                let aaaCands = engine.update(buffer: c + "aaa", context: []).candidates
                let nonCollapsing = aaaCands.contains { $0.surface != baseTop }
                ctx.assertTrue(
                    nonCollapsing,
                    "\(c)aaa",
                    detail: "every '\(c)aaa' candidate matches '\(c)a' top='\(baseTop)' all=\(aaaCands.prefix(6).map(\.surface))"
                )
            }
        },

        // Counter-examples that must continue to work unchanged.
        TestCase("repeatedA_existingPatternsUnchanged") { ctx in
            let engine = emptyEngine()
            // `kar` → `ကာ` (long-aa via `ar` rule)
            let kar = engine.update(buffer: "kar", context: [])
                .candidates.first?.surface ?? ""
            ctx.assertTrue(
                kar == "\u{1000}\u{102C}",
                "kar_unchanged",
                detail: "kar should stay 'ကာ' got '\(kar)'"
            )
            // `kara` → `ကရ` (two syllables — `ka` + `ra` inherent)
            let kara = engine.update(buffer: "kara", context: [])
                .candidates.first?.surface ?? ""
            ctx.assertTrue(
                kara.unicodeScalars.count >= 2,
                "kara_twoSyllables",
                detail: "kara expected 2+ scalars, got '\(kara)' (\(kara.unicodeScalars.count) scalars)"
            )
            // `kaa+ka` → produces both syllables — the `+` provides
            // an explicit break.
            let kaaPlusKa = engine.update(buffer: "kaa+ka", context: [])
                .candidates.first?.surface ?? ""
            ctx.assertTrue(
                kaaPlusKa.unicodeScalars.count >= 2,
                "kaaPlusKa_unchanged",
                detail: "kaa+ka expected 2+ scalars, got '\(kaaPlusKa)'"
            )
        },
    ])
}
