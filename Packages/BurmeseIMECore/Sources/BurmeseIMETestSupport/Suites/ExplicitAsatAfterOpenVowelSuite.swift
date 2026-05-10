import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-041: an explicit `*` (asat marker) typed
/// immediately after a non-asat-bearing vowel rule (`u`, `u:`, `i`,
/// `i:`, `ar`, `ar:`, `ay`, `ay:`, `aw`, `aw:`, `o`, `o:`) is
/// silently absorbed — the rank-0 surface is identical to the same
/// input without the `*`, and the panel may not even contain the
/// raw-buffer literal so the user has no way to round-trip the
/// keystroke.
///
/// The asat scalar `103A` is structurally illegal after a long-u
/// (`102F`/`1030`) or long-i (`102E`) dep-vowel sign — `ူ်` and `ီ်`
/// are unattested in modern Burmese orthography. The parser is right
/// to reject the `<C><dep-vowel><103A>` surface (TASK-055
/// `scanOutputLegality` already does), but the user's keystroke is
/// data: when the asat cannot be consumed, the engine should at
/// minimum surface the literal `*` so the user can commit-as-typed
/// and knows the keystroke registered.
///
/// The bug surfaces strongly with `<C>u*` and `kii*` because the
/// lexicon has many completions for `<C>u` / `kii` readings that
/// push the literal off the candidate panel. The bare-engine panel
/// (no lexicon) does include the literal at the bottom; the
/// production-stack panel does not, because `injectLiteralFallback`'s
/// `.lexicon`-source carve-out skips injection when rank-0 is a
/// lexicon hit on a TRUNCATED reading.
public enum ExplicitAsatAfterOpenVowelSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func bundledEngine(_ ctx: TestContext) -> BurmeseEngine? {
        guard let lexPath = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lexPath),
              let lmPath = BundledArtifacts.trigramLMPath,
              let lm = try? TrigramLanguageModel(path: lmPath) else {
            ctx.assertTrue(true, "skipped_noBundledArtifacts")
            return nil
        }
        return BurmeseEngine(candidateStore: store, languageModel: lm)
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// Bare consonants that don't have medial-extension role.
    private static let bareConsonants: [String] = [
        "k", "kh", "g", "gh", "ng", "s", "z", "t", "ht", "d", "dh",
        "n", "p", "ph", "v", "b", "m", "l", "th",
    ]

    /// Non-asat-bearing vowel rules — their Myanmar emission does
    /// NOT end in `103A`, so an immediately following explicit `*`
    /// has no legal placement and must either re-segment or surface
    /// as a literal.
    private static let nonAsatVowelRules: [String] = [
        "u", "u:", "i", "i:",
        "ar", "ar:",
        "ay", "ay:",
        "aw", "aw:",
        "o", "o:",
    ]

    /// True when `surface` contains the raw `*` (U+002A) char.
    private static func surfaceContainsAsterisk(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value == 0x002A }
    }

    public static let suite = TestSuite(name: "ExplicitAsatAfterOpenVowel", cases: [

        // PRIMARY ACCEPTANCE: for every (consonant, non-asat
        // vowel rule), the candidate panel for `<C><V>*` must
        // contain at least one candidate whose surface differs from
        // `<C><V>`'s rank-0 surface. The user's `*` keystroke must
        // produce a visible signal somewhere in the panel.
        TestCase("panelContainsCandidateDifferingFromBase_emptyEngine") { ctx in
            let engine = emptyEngine()
            for c in bareConsonants {
                for v in nonAsatVowelRules {
                    let base = c + v
                    let baseTop = engine.update(buffer: base, context: [])
                        .candidates.first?.surface ?? ""
                    let buffer = base + "*"
                    let cands = engine.update(buffer: buffer, context: []).candidates
                    let hasDifferent = cands.contains { $0.surface != baseTop }
                    ctx.assertTrue(
                        hasDifferent,
                        buffer,
                        detail: "panel for '\(buffer)' is identical to base '\(baseTop)'; panel=\(cands.prefix(5).map(\.surface))"
                    )
                }
            }
        },

        // STRENGTHENED CRITERION (per task validation notes): the
        // panel for `<C><V>*` must contain a candidate whose surface
        // includes the raw `*` ASCII char — i.e. the literal-fallback
        // candidate must be reachable so the user can commit-as-typed.
        // This is the primary user-facing acceptance bar.
        TestCase("panelContainsLiteralCarryingAsterisk_emptyEngine") { ctx in
            let engine = emptyEngine()
            for c in bareConsonants {
                for v in nonAsatVowelRules {
                    let buffer = c + v + "*"
                    let cands = engine.update(buffer: buffer, context: []).candidates
                    let hasAsterisk = cands.contains { surfaceContainsAsterisk($0.surface) }
                    ctx.assertTrue(
                        hasAsterisk,
                        buffer,
                        detail: "panel for '\(buffer)' contains no candidate with raw `*`; panel=\(cands.prefix(5).map(\.surface))"
                    )
                }
            }
        },

        // BUFFER-LEADING vowel-rule + `*` forms (`i*`, `u*`, `ar*`,
        // `o*`, …) — same invariant. The user's keystroke must
        // surface somewhere.
        TestCase("panelContainsLiteralCarryingAsterisk_bufferLeading") { ctx in
            let engine = emptyEngine()
            let leading = ["i", "u", "ar", "o", "ay", "aw", "i:", "u:"]
            for v in leading {
                let buffer = v + "*"
                let cands = engine.update(buffer: buffer, context: []).candidates
                let hasAsterisk = cands.contains { surfaceContainsAsterisk($0.surface) }
                ctx.assertTrue(
                    hasAsterisk,
                    buffer,
                    detail: "panel for '\(buffer)' contains no candidate with raw `*`; panel=\(cands.prefix(5).map(\.surface))"
                )
            }
        },

        // PRODUCTION-STACK ACCEPTANCE: the bug is most visible with
        // the bundled lexicon present (lexicon completions push the
        // literal off the panel). Verify the literal-`*` candidate
        // is reachable on the production stack too.
        TestCase("panelContainsLiteralCarryingAsterisk_productionStack") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            // Subset focused on the long-u / long-i family where
            // lexicon completions overwhelm the panel pre-fix:
            // `ku*`, `khu*`, `tu*`, `pu*`, `mu*`, `nu*`, `kii*`.
            let inputs = ["ku*", "khu*", "tu*", "pu*", "mu*", "nu*", "kii*"]
            for buffer in inputs {
                let cands = engine.update(buffer: buffer, context: []).candidates
                let hasAsterisk = cands.contains { surfaceContainsAsterisk($0.surface) }
                ctx.assertTrue(
                    hasAsterisk,
                    buffer,
                    detail: "production-stack panel for '\(buffer)' contains no candidate with raw `*`; panel=\(cands.prefix(8).map(\.surface))"
                )
            }
        },

        // REGRESSION: `ka*`, `ki*`, `kai*`, `kaw*` continue to work
        // — these already produced acceptable surfaces / had the
        // literal in the panel pre-fix. Ensure the fix doesn't
        // regress them.
        TestCase("regression_workingCasesUnchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expectedRank0: String)] = [
                ("ka*",  "\u{1000}\u{103A}"),                   // က်
                ("ki*",  "\u{1000}\u{100A}\u{103A}"),           // ကည် (i2 rule)
                ("k*",   "\u{1000}\u{103A}"),                   // က်
            ]
            for c in cases {
                let top = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top == c.expectedRank0,
                    c.buffer,
                    detail: "regressed: expected rank-0 '\(c.expectedRank0)' got '\(top)'"
                )
            }
            // The digit-asat-literal suite already exercises shape
            // like `ka1*`; this guard is the asat-after-open-vowel
            // class only.
        },
    ])
}
