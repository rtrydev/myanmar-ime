import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-035: chains of three or more identical medial-bearing open
/// syllables joined by explicit `+` (`kya+kya+kya`, `pwa+pwa+pwa`,
/// `mya+mya+mya`, …) collapse at rank 0 to the lexicon prefix match
/// for ONLY the first syllable. The trailing `+<C>{y/w}a+...`
/// portion of the buffer is silently dropped from rank 0; the
/// literal raw buffer sits at the bottom of the panel (rank 9 in
/// observed cases).
///
/// The bug is specific to:
/// - Explicit-`+` boundaries between syllables (not inferred);
/// - Medial-bearing OPEN syllables (`<C>` + ya-pin / ya-yit /
///   wa-hswe / ha-htoe + bare inherent `a`, no closing coda or
///   independent vowel);
/// - Three or more **identical** such syllables in the chain.
///
/// Acceptance: rank 0 must be either the full N-syllable Myanmar
/// segmentation OR the literal raw buffer. It must NOT be a
/// single-syllable (or short-prefix) lexicon match with the
/// remainder of the buffer silently dropped.
///
/// Suite uses the production-equivalent engine (bundled SQLite
/// lexicon + trigram LM). The bare engine ranks differently; the
/// displacement only manifests once the LM/lexicon ranking is
/// wired in.
public enum IdenticalMedialPlusChainSuite {

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
        s.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
    }

    /// Count Myanmar syllable boundaries by scanning for cluster
    /// onsets — every base consonant in U+1000..U+1021 (excluding
    /// the medial scalars and tone scalars) starts a new syllable
    /// for these test inputs.
    private static func myanmarBaseConsonantCount(_ s: String) -> Int {
        var count = 0
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0x1000...0x1021).contains(v) {
                // Skip independent vowels U+1023..U+1021? Independent
                // vowels are not bases for medial-bearing syllables;
                // count them too because they are syllable anchors.
                count += 1
            }
        }
        return count
    }

    public static let suite = TestSuite(name: "IdenticalMedialPlusChain", cases: [

        // --- Bug-class buffers from TASK-035 COLLAPSED column ---

        TestCase("kya_x3_doesNotCollapse") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "kya+kya+kya"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            // Acceptance: rank 0 is either the full 3-syllable
            // Myanmar segmentation OR the literal raw buffer
            // (`kya+kya+kya`). It must NOT be a 1-syllable surface
            // (`ကျ` / `ကြ`).
            let isLiteral = top.surface == buffer
            let baseCount = myanmarBaseConsonantCount(top.surface)
            let isFullSegmentation = baseCount >= 3
            ctx.assertTrue(isLiteral || isFullSegmentation,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount); expected literal or 3+ syllables")
        },

        TestCase("kya_x4_doesNotCollapse") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "kya+kya+kya+kya"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let isLiteral = top.surface == buffer
            let baseCount = myanmarBaseConsonantCount(top.surface)
            let isFullSegmentation = baseCount >= 4
            ctx.assertTrue(isLiteral || isFullSegmentation,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount); expected literal or 4+ syllables")
        },

        TestCase("pya_x3_doesNotCollapse") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "pya+pya+pya"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let isLiteral = top.surface == buffer
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(isLiteral || baseCount >= 3,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount)")
        },

        TestCase("gya_x3_doesNotCollapse") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "gya+gya+gya"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let isLiteral = top.surface == buffer
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(isLiteral || baseCount >= 3,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount)")
        },

        TestCase("pwa_x3_doesNotCollapse") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "pwa+pwa+pwa"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let isLiteral = top.surface == buffer
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(isLiteral || baseCount >= 3,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount)")
        },

        TestCase("kwa_x3_doesNotCollapse") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "kwa+kwa+kwa"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let isLiteral = top.surface == buffer
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(isLiteral || baseCount >= 3,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount)")
        },

        TestCase("swa_x3_doesNotCollapse") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "swa+swa+swa"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let isLiteral = top.surface == buffer
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(isLiteral || baseCount >= 3,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount)")
        },

        TestCase("mya_x3_doesNotCollapse") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "mya+mya+mya"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let isLiteral = top.surface == buffer
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(isLiteral || baseCount >= 3,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount)")
        },

        TestCase("khya_x3_doesNotCollapse") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "khya+khya+khya"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let isLiteral = top.surface == buffer
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(isLiteral || baseCount >= 3,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount)")
        },

        TestCase("phya_x3_doesNotCollapse") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "phya+phya+phya"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let isLiteral = top.surface == buffer
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(isLiteral || baseCount >= 3,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount)")
        },

        TestCase("bya_x3_doesNotCollapse") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "bya+bya+bya"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let isLiteral = top.surface == buffer
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(isLiteral || baseCount >= 3,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount)")
        },

        TestCase("ka_kya_x3_doesNotCollapseTail") { ctx in
            // `ka+kya+kya+kya`: 4 syllables. The bug surfaced
            // `က္ကြ` (only first 2 syllables); rank 0 must include
            // all 4 (or the literal).
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "ka+kya+kya+kya"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let isLiteral = top.surface == buffer
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(isLiteral || baseCount >= 4,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount); expected literal or 4+ syllables")
        },

        // --- Negative controls (must keep working) ---

        TestCase("kya_x2_keeps2Syllables") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "kya+kya"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(top.surface == buffer || baseCount >= 2,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount)")
        },

        TestCase("kyakyakya_noPlus_keeps3Syllables") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "kyakyakya"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(top.surface == buffer || baseCount >= 3,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount)")
        },

        TestCase("kya_kar_kya_keeps3Syllables") { ctx in
            // Inserting a different syllable defeats the collapse.
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "kya+kar+kya"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(top.surface == buffer || baseCount >= 3,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount)")
        },

        TestCase("kya_pya_mya_mixed_keeps3Syllables") { ctx in
            // Mixing medial consonants defeats the collapse.
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "kya+pya+mya"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(top.surface == buffer || baseCount >= 3,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount)")
        },

        TestCase("tha_x4_keeps4Syllables") { ctx in
            // No medial; should not collapse.
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "tha+tha+tha+tha"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(top.surface == buffer || baseCount >= 4,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount)")
        },

        TestCase("lwa_x3_keeps3Syllables") { ctx in
            // Wa medial on `l` doesn't trigger the ya-pin/ya-yit
            // ambiguity that drives the collapse.
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "lwa+lwa+lwa"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(top.surface == buffer || baseCount >= 3,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount)")
        },

        TestCase("cha_x3_clusterAlias_keeps3Syllables") { ctx in
            // Cluster alias path; should not collapse.
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "cha+cha+cha"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(top.surface == buffer || baseCount >= 3,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount)")
        },

        TestCase("kyaw_x3_closedSyllable_keeps3Syllables") { ctx in
            // Closed syllable; should not collapse.
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "kyaw+kyaw+kyaw"
            let state = engine.update(buffer: buffer, context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, buffer, detail: "panel empty")
                return
            }
            let baseCount = myanmarBaseConsonantCount(top.surface)
            ctx.assertTrue(top.surface == buffer || baseCount >= 3,
                buffer,
                detail: "rank-0='\(top.surface)' (\(hex(top.surface))) base-consonant-count=\(baseCount)")
        },
    ])
}
