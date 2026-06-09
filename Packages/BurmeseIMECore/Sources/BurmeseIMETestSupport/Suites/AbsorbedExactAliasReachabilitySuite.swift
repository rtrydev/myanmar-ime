import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-083: digit-disambiguated homophone variants
/// (retroflex ဏ/ဋ/ဌ family) must stay panel-reachable from the
/// digit-less reading even when their exact alias-index hit is
/// *absorbed* into a rarity-penalized grammar parse of the same
/// surface. The absorption chain that previously made them
/// unreachable:
///
///   1. alias rows score `rank_score − alias_penalty × 1000`, going
///      negative for most penalty ≥ 1 rows (`ခဏ` = 682 − 1000);
///   2. the absorption folds the negative score into the grammar
///      candidate and removes the hit from `uniqueLexiconCandidates`
///      (bypassing the `prioritizedLexicon` guarantee);
///   3. the rarity-first comparator buries the ဏ-parse below every
///      non-rare sibling and the LM-margin prune drops it — its
///      absorption carve-out (`score > parserScore`) fails for
///      negative absorbed scores.
///
/// The unreachable class is rare-consonant variants whose digit-less
/// reading ALSO spells real high-frequency words (`ခန`/`ခံ` for
/// `khana`) — exactly where the panel must offer the variant, since
/// digits are literal and the alias index is the only path to these
/// spellings. Panel presence (page through) is the bar; rank-0 for
/// the common spelling must not be displaced.
public enum AbsorbedExactAliasReachabilitySuite {

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

    public static let suite = TestSuite(name: "AbsorbedExactAliasReachability", cases: [

        // The absorbed exact alias hits must be reachable somewhere in
        // the panel (any page) for the digit-less reading.
        TestCase("production_absorbedExactHitsReachable") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, expected: String)] = [
                ("khana",     "ခဏ"),       // ခဏ "a moment" — alias khan2a, penalty 1
                ("ku.m+pani", "ကုမ္ပဏီ"),  // "company" — alias ku.m+pan2i, penalty 1
            ]
            for c in cases {
                let candidates = engine.update(buffer: c.buffer, context: []).candidates
                ctx.assertTrue(
                    candidates.contains { $0.surface == c.expected },
                    c.buffer,
                    detail: "expected '\(c.expected)' reachable in panel; got \(candidates.map(\.surface))"
                )
            }
        },

        // Rank-0 ordering for the common spellings is NOT displaced:
        // this is a reachability fix, not a ranking promotion.
        TestCase("production_commonSpellingKeepsRank0") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, expectedTop: String)] = [
                ("khana",  "ခန"),    // corpus-dominant spelling stays top
                ("htarna", "ဌာန"),   // ဌ variant already wins — must keep winning
                ("thi",    "သည်"),
            ]
            for c in cases {
                let top = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertEqual(top, c.expectedTop, c.buffer)
            }
        },

        // Retroflex variant reachability that already works must not
        // regress: `ti` keeps `ဋီ` reachable.
        TestCase("production_existingVariantReachabilityUnchanged") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let candidates = engine.update(buffer: "ti", context: []).candidates
            ctx.assertTrue(
                candidates.contains { $0.surface == "ဋီ" },
                "ti",
                detail: "expected 'ဋီ' reachable; got \(candidates.map(\.surface))"
            )
        },

        // Non-exact rare-consonant prefix completions keep their
        // current behavior — the `ခဏ…` completions stay in the panel
        // alongside the newly reachable exact hit.
        TestCase("production_prefixCompletionsUnchanged") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let candidates = engine.update(buffer: "khana", context: []).candidates
            ctx.assertTrue(
                candidates.contains { $0.surface.hasPrefix("ခဏ") && $0.surface != "ခဏ" },
                "khana_completions",
                detail: "expected ခဏ-prefixed completions; got \(candidates.map(\.surface))"
            )
        },
    ])
}
