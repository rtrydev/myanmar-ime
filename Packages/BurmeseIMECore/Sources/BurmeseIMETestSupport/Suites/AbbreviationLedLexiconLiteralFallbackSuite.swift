import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-050b: when a user types the unrecognised phonetic
/// spelling `ein` (= /eɪn/ — short-i + na-asat shape), the
/// rebuilt lexicon's sentence-boundary-polluted row
/// `surface='၏န' reading='eina'` (a collision of the genitive
/// abbreviation `၏` ending one corpus sentence and `န` starting
/// the next) wins the prefix match at rank 0 with
/// `source=.lexicon`. The literal-fallback path's lexicon
/// carve-out then suppresses the literal-ASCII echo entirely,
/// leaving the panel as `["၏န"]` — a single candidate the user
/// did NOT intend, with no clean exit. This violates CLAUDE.md
/// §2: "for non-empty typeable input, the panel must not be
/// empty".
///
/// The fix narrows the lexicon-source literal-fallback
/// carve-out: a lexicon hit whose surface starts with an
/// abbreviation mark (U+104A..U+104F — `၊ ။ ၌ ၍ ၎ ၏`) is
/// treated as structurally suspect corpus pollution. Those
/// scalars are standalone punctuation/abbreviation marks that
/// never head a multi-scalar Burmese word; a row whose surface
/// begins with one and continues into a consonant is a
/// sentence-boundary collision artifact. Falling through to
/// the literal-fallback injection path lets the user commit
/// `ein` as typed, while the abbreviation-led lexicon row
/// stays in the panel as a lower-ranked alternative.
///
/// **Scope notes**:
/// - TASK-050a (sanitizer for `oun` / `koun` cross-category
///   chains): the bare-engine and bundled probes both show that
///   the panel for these buffers already contains a clean rank-0
///   candidate (either the literal-ASCII fallback or a
///   structurally-legal Burmese surface) — the malformed
///   surfaces sit at rank 1+. No additional sanitizer needed.
/// - TASK-050c (romanization-scheme expansion question — adding
///   `ein`/`oun` as phonetic aliases of `ain`/`own`): deferred,
///   needs explicit product call. See task body.
public enum AbbreviationLedLexiconLiteralFallbackSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func makeBundledEngine() -> BurmeseEngine? {
        guard let lexPath = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lexPath),
              let lmPath = BundledArtifacts.trigramLMPath,
              let lm = try? TrigramLanguageModel(path: lmPath) else {
            return nil
        }
        return BurmeseEngine(candidateStore: store, languageModel: lm)
    }

    private static func surfaces(_ candidates: [Candidate]) -> [String] {
        candidates.map(\.surface)
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    public static let suite = TestSuite(name: "AbbreviationLedLexiconLiteralFallback", cases: [

        // TASK-050b core: bare `ein` panel must contain the
        // literal-ASCII fallback. Reproduces the §2 violation
        // surfaced by the Step-2 re-verification against the
        // production-equivalent engine.
        TestCase("ein_literalPresentInPanel_bundled") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let state = engine.update(buffer: "ein", context: [])
            ctx.assertTrue(
                state.candidates.contains { $0.surface == "ein" },
                "ein",
                detail: "literal 'ein' missing from panel; got \(surfaces(state.candidates))"
            )
        },

        // TASK-050b core: `<C>oun` panel must contain the
        // literal-ASCII fallback. The rebuilt-LM Step-2 probe
        // showed `koun`/`poun`/`toun`/`noun`/`houn` rank-0 was
        // the malformed Myanmar surface and the literal had
        // dropped off the visible page — invariant requires the
        // literal to be IN the panel at all.
        TestCase("cOunFamily_literalPresentInPanel_bundled") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            for buffer in ["koun", "poun", "toun", "noun", "houn"] {
                let state = engine.update(buffer: buffer, context: [])
                ctx.assertTrue(
                    state.candidates.contains { $0.surface == buffer },
                    buffer,
                    detail: "literal '\(buffer)' missing from panel; got \(surfaces(state.candidates))"
                )
            }
        },

        // TASK-050b: when rank-0 is a `surfaceIsWhollyMultiCluster
        // OnSingleAnchor` violator, the literal must take rank 0
        // (per CLAUDE.md §2 "sanitizer-retained illegal rank 0 →
        // literal at rank 0"). Previously the rule only fired for
        // vowel-only-alpha buffers; consonant-bearing buffers
        // like `koun` / `poun` bypassed it.
        TestCase("cOunFamily_literalAtRankZero_whenStructurallyIllegal_bundled") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            for buffer in ["koun", "poun", "toun", "noun", "houn"] {
                let state = engine.update(buffer: buffer, context: [])
                let topSurface = state.candidates.first?.surface ?? ""
                // Either the top is the literal, or the top is a
                // structurally-legal Myanmar surface (which would
                // mean a future romanization-scheme expansion
                // landed and `<C>oun` now resolves cleanly). The
                // ONE thing it must NOT be is a multi-cluster-on-
                // single-anchor violator.
                if topSurface == buffer { continue }
                ctx.assertFalse(
                    BurmeseEngine.surfaceContainsMultiClusterOnSingleAnchor(topSurface),
                    buffer,
                    detail: "rank-0 = '\(topSurface)' [\(hex(topSurface))] (cross-category chain on single anchor); panel=\(surfaces(state.candidates))"
                )
            }
        },

        // Bare-engine analogue of `ein_literalPresentInPanel`.
        // The bare-engine probe today produces a panel that DOES
        // include the literal (the bug is production-LM-specific),
        // but this case locks the invariant in regardless.
        TestCase("ein_literalPresentInPanel_bareEngine") { ctx in
            let engine = emptyEngine()
            let state = engine.update(buffer: "ein", context: [])
            ctx.assertTrue(
                state.candidates.contains { $0.surface == "ein" },
                "ein",
                detail: "literal 'ein' missing from panel; got \(surfaces(state.candidates))"
            )
        },

        // TASK-050b: abbreviation-led lexicon row must NOT
        // suppress the literal fallback. The narrower way to
        // assert this is to verify that the abbreviation-led
        // surface (`၏န` for `ein`, `၎င်` for hypothetical
        // sentence-boundary inputs) coexists in the panel with
        // the literal, rather than monopolising the panel.
        TestCase("ein_abbreviationLedLexiconRowDoesNotMonopolisePanel_bundled") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let state = engine.update(buffer: "ein", context: [])
            ctx.assertTrue(
                state.candidates.count >= 2,
                "ein",
                detail: "expected ≥2 panel candidates after fix; got \(surfaces(state.candidates))"
            )
            // The original abbreviation-led row is still
            // reachable somewhere in the panel; only its
            // suppression of the literal was the bug.
            let hasAbbrev = state.candidates.contains { c in
                guard let firstScalar = c.surface.unicodeScalars.first else { return false }
                return firstScalar.value >= 0x104A && firstScalar.value <= 0x104F
            }
            ctx.assertTrue(
                hasAbbrev,
                "ein",
                detail: "expected abbreviation-led row reachable in panel; got \(surfaces(state.candidates))"
            )
        },

        // Probe-style test: print rank-0 for `koun` family (only
        // fails if rank-0 is one of the structurally-illegal
        // shapes the task notes flag — phantom mid-word `1026`
        // after asat, or `103A 1030` adjacency).
        TestCase("cOunFamily_rank0_isLiteralOrCleanMyanmar_bundled") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            for buffer in ["koun", "poun", "toun", "noun", "houn"] {
                let state = engine.update(buffer: buffer, context: [])
                let topSurface = state.candidates.first?.surface ?? ""
                // The rank-0 must be either (a) the literal ASCII,
                // OR (b) a structurally-legal Myanmar surface. The
                // failing path is a multi-cluster violator at
                // rank-0.
                let hasMultiCluster = BurmeseEngine.surfaceContainsMultiClusterOnSingleAnchor(topSurface)
                ctx.assertFalse(
                    hasMultiCluster,
                    buffer,
                    detail: "rank-0='\(topSurface)' [\(hex(topSurface))] is multi-cluster violator; panel=\(surfaces(state.candidates))"
                )
            }
        },

        // Carve-out: `pain` (documented romanization for the
        // `<C>ein` sound — short-i + na-asat) MUST still produce
        // a clean Myanmar rank-0 surface. The literal-fallback
        // widening must not regress the documented `ain` path.
        TestCase("carveOut_pain_cleanMyanmarAtRankZero_bundled") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let state = engine.update(buffer: "pain", context: [])
            let topSurface = state.candidates.first?.surface ?? ""
            ctx.assertFalse(
                topSurface == "pain",
                "pain",
                detail: "documented 'pain' must NOT collapse to literal; got '\(topSurface)' [\(hex(topSurface))]; panel=\(surfaces(state.candidates))"
            )
            let topIsMyanmar = topSurface.unicodeScalars.contains {
                $0.value >= 0x1000 && $0.value <= 0x109F
            }
            ctx.assertTrue(
                topIsMyanmar,
                "pain",
                detail: "expected rank-0 Myanmar surface; got '\(topSurface)' [\(hex(topSurface))]"
            )
        },

        // Carve-out: `pown` (documented `<C>oun` romanization —
        // short-u + anusvara) MUST still produce a clean Myanmar
        // rank-0 surface.
        TestCase("carveOut_pown_cleanMyanmarAtRankZero_bundled") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let state = engine.update(buffer: "pown", context: [])
            let topSurface = state.candidates.first?.surface ?? ""
            ctx.assertFalse(
                topSurface == "pown",
                "pown",
                detail: "documented 'pown' must NOT collapse to literal; got '\(topSurface)' [\(hex(topSurface))]; panel=\(surfaces(state.candidates))"
            )
            let topIsMyanmar = topSurface.unicodeScalars.contains {
                $0.value >= 0x1000 && $0.value <= 0x109F
            }
            ctx.assertTrue(
                topIsMyanmar,
                "pown",
                detail: "expected rank-0 Myanmar surface; got '\(topSurface)' [\(hex(topSurface))]"
            )
        },
    ])
}
