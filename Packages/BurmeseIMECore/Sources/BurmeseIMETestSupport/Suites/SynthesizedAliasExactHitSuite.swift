import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-084: the LexiconBuilder emits synthetic alias rows
/// so the legacy `ah-` typing convention (and the bare `a-`
/// double-onset convention) for word-initial `အ` keeps working — every
/// `အ…` entry gets `ah<alias>` rows (penalty +0) and `a<alias>` rows
/// (penalty +2) in `reading_alias_index`. Two engine-side mechanisms
/// defeated that intent:
///
/// 1. **Matched-alias identity loss.** The store SELECTs only the
///    canonical reading, and the engine reconstructed "is this hit
///    exact?" via `Romanization.aliasReading(hit.reading)` — which for
///    a builder-synthesized row (`ahain` row → canonical `ain2`) never
///    equals the typed buffer, so the hit was excluded from
///    `prioritizedLexicon`, `exactReadingLexiconSurfaces`, the
///    anchor-windowing suppression, and the TASK-078 punct-split
///    evidence injection.
/// 2. **Prefix-lookup LIMIT-20 crowd-out.** The prefix query orders by
///    `alias_penalty ASC, rank_score DESC LIMIT 20` with no preference
///    for exact-length matches, so a penalty-1 exact row (`ahain` →
///    `အိမ်`, rank 767.5) lost to 20 penalty-0 completions of longer
///    readings and never reached the engine at all.
///
/// The fix recognizes exactness by the MATCHED alias (the engine
/// queries the equality indexes for the typed buffer and unions the
/// hits into the lexicon pool in both the whole-buffer and windowed
/// paths), and the store's prefix lookup unions the exact-equality
/// rows so they can never be crowded out of the LIMIT window.
public enum SynthesizedAliasExactHitSuite {

    private static func bundledStore(_ ctx: TestContext) -> SQLiteCandidateStore? {
        guard let lexPath = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lexPath) else {
            ctx.assertTrue(true, "skipped_noBundledArtifacts")
            return nil
        }
        return store
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

    public static let suite = TestSuite(name: "SynthesizedAliasExactHit", cases: [

        // Store level: an exact-equality row must survive the prefix
        // lookup even when 20+ same-prefix lower-penalty completions
        // fill the LIMIT window (`ahain` has 63 penalty-0 `ahaing…`
        // crowding rows; 434 rows share the `ahaya` prefix).
        TestCase("store_exactRowsSurvivePrefixCrowdOut") { ctx in
            guard let store = bundledStore(ctx) else { return }
            let cases: [(prefix: String, surface: String)] = [
                ("ahain", "အိမ်"),
                ("ahaya", "အရ"),
            ]
            for c in cases {
                let hits = store.lookup(prefix: c.prefix, previousSurface: nil)
                ctx.assertTrue(
                    hits.contains { $0.surface == c.surface },
                    c.prefix,
                    detail: "exact row '\(c.surface)' crowded out; got \(hits.map(\.surface))"
                )
            }
        },

        // Single-word `ah`-convention typings: the synthetic exact row
        // is the buffer's highest-scored exact hit and must reach the
        // top 3.
        TestCase("production_ahConventionSingleWordsTop3") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, expected: String)] = [
                ("ahain", "အိမ်"),
                ("ahaya", "အရ"),
            ]
            for c in cases {
                let candidates = engine.update(buffer: c.buffer, context: []).candidates
                let rank = candidates.firstIndex { $0.surface == c.expected }
                ctx.assertTrue(
                    rank != nil && rank! < 3,
                    c.buffer,
                    detail: "expected '\(c.expected)' in top 3; got \(candidates.prefix(5).map(\.surface)) (rank=\(rank.map(String.init) ?? "absent"))"
                )
            }
        },

        // Multi-word and tone-bearing `ah`-convention typings: panel
        // presence required (the `a|h…` parser garbage may keep rank 0
        // where the LM genuinely prefers it).
        TestCase("production_ahConventionCompoundsReachable") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, expected: String)] = [
                ("ahayar",          "အရာ"),
                ("ahakhan:ahanar:", "အခမ်းအနား"),
                ("ahahti.ahatway.", "အထိအတွေ့"),
                ("aharo:aho:",      "အရိုးအိုး"),
            ]
            for c in cases {
                let candidates = engine.update(buffer: c.buffer, context: []).candidates
                ctx.assertTrue(
                    candidates.contains { $0.surface == c.expected },
                    c.buffer,
                    detail: "expected '\(c.expected)' in panel; got \(candidates.map(\.surface))"
                )
            }
        },

        // Windowed path: `ahathaing:ahawaing:` (19 chars, penalty-0
        // exact row → `အသိုင်းအဝိုင်း`) crosses the composition window
        // — the matched-alias recognition must work through the
        // frozen-prefix path too, both one-shot and incrementally.
        TestCase("production_windowedWholeBufferExactRowReachable") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "ahathaing:ahawaing:"
            let expected = "အသိုင်းအဝိုင်း"
            let oneShot = engine.update(buffer: buffer, context: []).candidates
            ctx.assertTrue(
                oneShot.contains { $0.surface == expected },
                "oneShot",
                detail: "expected '\(expected)' in panel; got \(oneShot.map(\.surface))"
            )
            // Incremental: same engine, keystroke by keystroke, so the
            // anchor history participates like a real typing session.
            guard let incrementalEngine = bundledEngine(ctx) else { return }
            var final: [Candidate] = []
            for end in 1...buffer.count {
                let prefix = String(buffer.prefix(end))
                final = incrementalEngine.update(buffer: prefix, context: []).candidates
            }
            ctx.assertTrue(
                final.contains { $0.surface == expected },
                "incremental",
                detail: "expected '\(expected)' in panel; got \(final.map(\.surface))"
            )
        },

        // The already-working canonical typings stay at rank 0 — the
        // fix must not displace them.
        TestCase("production_canonicalTypingsKeepRank0") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, expected: String)] = [
                ("ain",            "အိမ်"),
                ("ara",            "အရ"),
                ("arar",           "အရာ"),
                ("ahti.ahatway.",  "အထိအတွေ့"),
                ("aro:aho:",       "အရိုးအိုး"),
                ("akhan:ahanar:",  "အခမ်းအနား"),
                ("ah",             "အ"),
            ]
            for c in cases {
                let top = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertEqual(top, c.expected, c.buffer)
            }
        },
    ])
}
