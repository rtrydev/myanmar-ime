import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-080: the suffixing particles ၏ (U+104F, `ei`) and
/// ၍ (U+104D, `ywe`) attach after a completed word — that is their only
/// grammatical position — but the engine could not serve them
/// mid-buffer: the right-shrink acceptability probe truncated the
/// buffer inside the particle (dropping the final `i` of `ei`), the
/// alias prefix for the lexicon lookup was computed from the truncated
/// buffer, and the exact alias hits (`သင်၏` ← `thinei`, `မိမိ၏` ←
/// `mi.mi.ei`, …) were never queried. Non-lexicon combinations
/// (`tharywe` → `သာ၍`) additionally need the generative
/// `<word> + particle` segmentation, which the parser's mid-buffer
/// standalone gate (TASK-007) suppresses.
///
/// The fix injects (1) whole-buffer exact alias/compose hits when the
/// right-shrink cut the reading, and (2) `<prefix parse> + particle`
/// variants for panel reachability. Bare-engine rank-0 cleanliness for
/// mid-buffer particle scalars (StandaloneParticleMidBufferSuite) is
/// unaffected — reachability injections never displace rank 0 for
/// buffers whose existing rendering is sound.
public enum SuffixingParticleReachabilitySuite {

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

    public static let suite = TestSuite(name: "SuffixingParticleReachability", cases: [

        // Exact penalty-0 alias hits whose reading the right-shrink
        // used to truncate must reach the panel — top 3 for the
        // penalty-0 rows.
        TestCase("production_truncatedExactAliasHitsReachable") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let topThreeCases: [(buffer: String, expected: String)] = [
                ("thinei",   "သင်၏"),
                ("mi.mi.ei", "မိမိ၏"),
                ("aso:rei",  "အစိုးရ၏"),
            ]
            for c in topThreeCases {
                let candidates = engine.update(buffer: c.buffer, context: []).candidates
                let rank = candidates.firstIndex { $0.surface == c.expected }
                ctx.assertTrue(
                    rank != nil && rank! < 3,
                    c.buffer,
                    detail: "expected '\(c.expected)' in top 3; got \(candidates.prefix(5).map(\.surface)) (rank=\(rank.map(String.init) ?? "absent"))"
                )
            }
            // `naingnganei`'s row carries alias penalty 1 — panel
            // presence, not rank 0, is the bar.
            let naing = engine.update(buffer: "naingnganei", context: []).candidates
            ctx.assertTrue(
                naing.contains { $0.surface == "နိုင်ငံ၏" },
                "naingnganei",
                detail: "expected 'နိုင်ငံ၏' in panel; got \(naing.map(\.surface))"
            )
        },

        // No fabricated `ယ်အီ`-style tail at rank 0 for `…ei` readings
        // whose exact lexicon entry exists.
        TestCase("production_noFabricatedTailAtRank0") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for buffer in ["thinei", "mi.mi.ei", "aso:rei"] {
                let top = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    top.hasSuffix("ယ်အီ") || top.hasSuffix("အီ"),
                    buffer,
                    detail: "rank 0 '\(top)' carries a fabricated tail"
                )
            }
        },

        // Generative segmentation: `tharywe` has NO lexicon row for
        // `သာ၍` — the `<word> + ၍` variant must still be reachable,
        // while the letter-chain parses keep the panel (and rank 0:
        // this is a reachability fix, not a rank-0 mandate for the
        // symbol in non-lexicon contexts).
        TestCase("production_generativeParticleVariantReachable") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let candidates = engine.update(buffer: "tharywe", context: []).candidates
            ctx.assertTrue(
                candidates.contains { $0.surface == "သာ၍" },
                "tharywe_particle",
                detail: "expected 'သာ၍' in panel; got \(candidates.map(\.surface))"
            )
            ctx.assertTrue(
                candidates.contains { $0.surface == "သာရွယ်" || $0.surface == "သာယွယ်" },
                "tharywe_letterChainKept",
                detail: "letter-chain sibling missing; got \(candidates.map(\.surface))"
            )
            let top = candidates.first?.surface ?? ""
            ctx.assertFalse(
                top.unicodeScalars.contains { $0.value == 0x104D },
                "tharywe_rank0NotParticle",
                detail: "rank 0 '\(top)' must stay the letter-chain parse"
            )
        },

        // The third symbol-particle: `ng*:` must surface the canonical
        // `၎င်း` (penalty-0 alias row) somewhere in the panel.
        TestCase("production_ngStarColonSurfacesCanonicalSymbol") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let candidates = engine.update(buffer: "ng*:", context: []).candidates
            ctx.assertTrue(
                candidates.contains { $0.surface == "၎င်း" },
                "ng*:",
                detail: "expected '၎င်း' in panel; got \(candidates.map(\.surface))"
            )
        },

        // Controls verified working today — the fix must not regress
        // the whole-buffer-lookup and embedded-split paths that
        // already serve these at rank 0.
        TestCase("production_workingParticleCompoundsKeepRank0") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, expected: String)] = [
                ("phyitywe", "ဖြစ်၍"),
                ("huywe",    "ဟူ၍"),
                ("akeywe",   "အကယ်၍"),
                ("to.ei",    "တို့၏"),
                ("thuto.ei", "သူတို့၏"),
            ]
            for c in cases {
                let top = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertEqual(top, c.expected, c.buffer)
            }
        },

        // Standalone particle usage keeps working (bare engine).
        TestCase("bareEngine_standaloneParticlesUnchanged") { ctx in
            let engine = BurmeseEngine(
                candidateStore: EmptyCandidateStore(),
                languageModel: NullLanguageModel()
            )
            let cases: [(buffer: String, scalar: UInt32)] = [
                ("ei",  0x104F),
                ("ywe", 0x104D),
            ]
            for c in cases {
                let candidates = engine.update(buffer: c.buffer, context: []).candidates
                ctx.assertTrue(
                    candidates.contains { cand in
                        cand.surface.unicodeScalars.contains { $0.value == c.scalar }
                    },
                    c.buffer,
                    detail: "standalone particle missing; got \(candidates.map(\.surface))"
                )
            }
        },
    ])
}
