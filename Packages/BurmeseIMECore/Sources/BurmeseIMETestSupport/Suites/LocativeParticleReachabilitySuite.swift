import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-086: the locative particle ၌ (U+104C, read
/// နှိုက် "hnai'", formal "at/in") had no roman key anywhere — no
/// parser rule, no reverse-romanizer mapping, no lexicon alias — so it
/// was unwritable, and `ReverseRomanizer.romanize` silently dropped
/// the scalar (`romanize("ရာ၌")` → `rar`), which is how the shipped
/// store ended up indexing all 21 ၌-bearing entries under
/// particle-less readings.
///
/// The fix is one standalone vowel-table entry, `hnite` → ၌,
/// mirroring `ei` → ၏ and `ywe` → ၍: the TASK-080 suffixing-particle
/// machinery picks it up automatically (standalone typing +
/// `<word>၌` composition), `ReverseRomanizer.vowelPatterns` derives
/// the reverse mapping from the same table, and the TASK-007
/// mid-buffer gate is extended to the full symbol-particle block
/// U+104C–U+104F so the standalone rule cannot pollute mid-surface
/// positions. `hnite` is a true homophone of the verb နှိုက်
/// (canonical penalty-0 store row) — both must stay reachable as
/// competing homophone candidates under the one key (durable rule
/// §7); the data-pipeline rerun that re-indexes the 21 mis-indexed
/// rows is a separate follow-up.
public enum LocativeParticleReachabilitySuite {

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

    public static let suite = TestSuite(name: "LocativeParticleReachability", cases: [

        // The reverse romanizer must never silently delete a scalar
        // from the reading. Scoped to U+104C: bare ၎ (U+104E) has no
        // standalone use outside ၎င်း, which round-trips via ng*:.
        TestCase("reverse_romanizeLocativeParticleRoundTrips") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("၌"), "hnite", "bare_particle")
            ctx.assertTrue(
                ReverseRomanizer.romanize("ရာ၌").contains("hnite"),
                "rar_particle",
                detail: "romanize('ရာ၌') = '\(ReverseRomanizer.romanize("ရာ၌"))' should contain 'hnite'"
            )
            ctx.assertTrue(
                ReverseRomanizer.romanize("တို့၌").contains("hnite"),
                "to._particle",
                detail: "romanize('တို့၌') = '\(ReverseRomanizer.romanize("တို့၌"))' should contain 'hnite'"
            )
            // Sibling particles keep their existing round-trips.
            ctx.assertEqual(ReverseRomanizer.romanize("၏"), "ei", "genitive_control")
            ctx.assertEqual(ReverseRomanizer.romanize("၍"), "ywe", "conjunctive_control")
        },

        // Standalone typing produces the particle on the bare engine,
        // mirroring `ei` / `ywe`.
        TestCase("bareEngine_standaloneHniteProducesParticle") { ctx in
            let engine = BurmeseEngine(
                candidateStore: EmptyCandidateStore(),
                languageModel: NullLanguageModel()
            )
            let candidates = engine.update(buffer: "hnite", context: []).candidates
            ctx.assertTrue(
                candidates.contains { cand in
                    cand.surface.unicodeScalars.contains { $0.value == 0x104C }
                },
                "hnite",
                detail: "standalone particle missing; got \(candidates.map(\.surface))"
            )
        },

        // Production: `hnite` is a homophone key — the particle ၌ and
        // the verb နှိုက် are competing candidates and both must be
        // panel-reachable.
        TestCase("production_standaloneHniteServesParticleAndVerb") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let candidates = engine.update(buffer: "hnite", context: []).candidates
            ctx.assertTrue(
                candidates.contains { $0.surface == "၌" },
                "hnite_particle",
                detail: "expected '၌' in panel; got \(candidates.map(\.surface))"
            )
            ctx.assertTrue(
                candidates.contains { $0.surface == "နှိုက်" },
                "hnite_verb",
                detail: "expected 'နှိုက်' in panel; got \(candidates.map(\.surface))"
            )
        },

        // `<word reading><key>` composes `<word>၌`, mirroring the
        // TASK-080 acceptance shape for ၏/၍.
        TestCase("production_wordPlusHniteComposesParticle") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, expected: String)] = [
                ("atwin:hnite", "အတွင်း၌"),
                ("rarhnite",    "ရာ၌"),
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

        // Mid-buffer cleanliness: when more letters follow, the
        // standalone arc must not wedge ၌ between consonant bases at
        // rank 0 — the TASK-007 gate extends to U+104C.
        TestCase("bareEngine_midBufferHniteStaysClean") { ctx in
            let engine = BurmeseEngine(
                candidateStore: EmptyCandidateStore(),
                languageModel: NullLanguageModel()
            )
            for buffer in ["kahnitema", "tahnitelar"] {
                let top = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(top.unicodeScalars).map(\.value)
                var polluted = false
                for i in 0..<scalars.count where scalars[i] == 0x104C {
                    if scalars[0..<i].contains(where: { $0 >= 0x1000 && $0 <= 0x1021 }) {
                        polluted = true
                    }
                }
                ctx.assertFalse(
                    polluted,
                    buffer,
                    detail: "rank 0 '\(top)' wedges ၌ after a consonant base"
                )
            }
        },

        // Sibling-particle controls verified working today — must not
        // regress.
        TestCase("production_siblingParticleControlsKeepRank0") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, expected: String)] = [
                ("to.ei",    "တို့၏"),
                ("phyitywe", "ဖြစ်၍"),
            ]
            for c in cases {
                let top = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertEqual(top, c.expected, c.buffer)
            }
        },
    ])
}
