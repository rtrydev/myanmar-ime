import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-030: chained vowel-rule arcs surface a structurally illegal
/// multi-cluster dep-vowel shape at rank 0. When the user types
/// `<C>ay<vowel-rule>`, `<C><single-vowel><vowel-rule>`, or
/// `<vowel-rule><vowel-rule>` standalone, the production engine emits
/// rank-0 surfaces like `ကေိုို` (1000 1031 102D 102F 102D 102F),
/// `ကေီီ` (1000 1031 102E 102E), `အူူ` (1021 1030 1030) — a single
/// anchor carrying TWO dep-vowel clusters or a same-category dep-vowel
/// duplicate.
///
/// The class is broader than TASK-028 (cross-category single-cluster
/// duplicates) and broader than `RepeatedDepVowelSuite` (consonant-only
/// `<C>ii`/`<C>uu`/`<C>oo` pollution): this covers (a) chained vowel
/// rules with a vowel-rule preceding the duplicate, and (b) onsetless
/// vowel-only buffers under the LM-ranked production engine where the
/// bare-engine path was already correct.
///
/// Suite uses the production-equivalent engine (bundled SQLite lexicon
/// + trigram LM) because the LM/lexicon ranking layer is what introduces
/// the violator surfaces — the bare engine never produces these for
/// pure vowel-only buffers.
public enum MultiClusterDepVowelOnAnchorSuite {

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

    /// Dep-vowel category index used by `hasMultiClusterOnSingleAnchor`.
    private static func categoryOf(_ scalar: UInt32) -> Int {
        switch scalar {
        case 0x102B, 0x102C: return 1   // aa family
        case 0x102D, 0x102E: return 2   // i family
        case 0x102F, 0x1030: return 3   // u family
        case 0x1031:        return 4   // e family
        case 0x1032:        return 5   // ai family
        default:            return 0
        }
    }

    private static func isBase(_ value: UInt32) -> Bool {
        if value == 0x103F { return true }
        if (0x1000...0x1021).contains(value) { return true }
        if (0x1023...0x102A).contains(value) { return true }
        return false
    }

    /// Engine-layer predicate covering both shapes from TASK-030:
    ///   (a) same-category dep-vowel duplicate within a single base run,
    ///   (b) two distinct dep-vowel clusters on a single base run.
    ///
    /// A "base run" is any range of scalars between two consecutive
    /// bases (consonant U+1000..U+1021 except indep-vowel range itself,
    /// independent vowel U+1023..U+102A, U+103F). Asat (U+103A) and
    /// virama (U+1039) close the cluster so they reset the walk.
    ///
    /// Within a base run, we form clusters by category sequence. The two
    /// legal multi-scalar cluster shapes are the o-cluster
    /// (`102D 102F`, categories {2,3}) and the leading-`1031` aa-family
    /// (`1031 102B|102C`, categories {4,1}). After a complete cluster
    /// closes, ANY further dep-vowel scalar means a second cluster on
    /// the same anchor — flag it. A category that repeats inside a
    /// cluster (same-category duplicate) is also flagged.
    private static func hasMultiClusterOnSingleAnchor(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        var clusterCategories: [Int] = []
        var afterClusterClosed = false
        @inline(__always) func reset() {
            clusterCategories.removeAll(keepingCapacity: true)
            afterClusterClosed = false
        }
        for v in scalars {
            // Bases reset the walk — fresh anchor, fresh cluster slate.
            if isBase(v) {
                reset()
                continue
            }
            // Asat / virama close the syllable; further marks would
            // belong to a new syllable. Reset.
            if v == 0x103A || v == 0x1039 {
                reset()
                continue
            }
            // Medial signs (`103B..103E`) belong to the consonant onset
            // cluster, not the dep-vowel cluster — skip them.
            if (0x103B...0x103E).contains(v) { continue }
            // Tone marks (`1037`/`1038`) and anusvara (`1036`) are
            // syllable closers / not part of dep-vowel cluster; skip.
            if v == 0x1036 || v == 0x1037 || v == 0x1038 { continue }
            // Format controls / non-dep-vowel scalars: ignore for the
            // walk, but they don't reset (the dep-vowel cluster
            // continues if the same anchor still owns it).
            let cat = categoryOf(v)
            guard cat != 0 else { continue }
            if afterClusterClosed {
                // We already have a cluster on this anchor, and now
                // another dep-vowel arrives without an intervening base.
                // That's the multi-cluster violator.
                return true
            }
            // Same-category duplicate inside the in-progress cluster:
            // also a violator.
            if clusterCategories.contains(cat) {
                return true
            }
            clusterCategories.append(cat)
            // Decide whether the cluster is now complete (further marks
            // would constitute a second cluster).
            let isOCluster = clusterCategories == [2, 3]   // 102D 102F
            let isAungOrder = clusterCategories == [4, 1]  // 1031 102B/102C
            if isOCluster || isAungOrder {
                afterClusterClosed = true
            } else if clusterCategories.count >= 2 {
                // A cluster of 2+ categories that isn't one of the two
                // legal multi-scalar shapes is itself a violator
                // (cross-category invariants are handled by TASK-028's
                // suite, but if such a shape slips through, calling it
                // a multi-cluster violator is also fine).
                return true
            } else {
                // Single-scalar cluster (any one of categories 1..5).
                // After it, a fresh dep-vowel would mean a second
                // cluster on the same anchor.
                afterClusterClosed = true
                // For the o-cluster prefix `102D` the second `102F`
                // legitimately extends the cluster — re-open. Same for
                // `1031` then `102B`/`102C`. Drop afterClusterClosed
                // when we still expect a possible legal continuation:
                if cat == 2 || cat == 4 {
                    afterClusterClosed = false
                }
            }
        }
        return false
    }

    /// Bug-class buffers from TASK-030 *Steps to Reproduce*. Each one
    /// currently produces a multi-cluster-on-single-anchor surface at
    /// rank 0 under the production-equivalent engine.
    private static let bugBuffers: [String] = [
        // Onset + chained vowel rule:
        "kayoo", "kayii", "kayuu",
        "thayoo", "thayuu",
        "ngayoo", "ngaii",
        "kuoo", "kioo", "kaayoo",
        "ayoo",
        // Onsetless vowel-only chains:
        "iuu", "uii", "ouu", "ooi", "uua",
    ]

    public static let suite = TestSuite(name: "MultiClusterDepVowelOnAnchor", cases: [

        // Predicate sanity: every observed bug-class surface is rejected
        // by `hasMultiClusterOnSingleAnchor`, and a representative set of
        // legitimate multi-syllable surfaces is accepted.
        TestCase("predicate_rejectsBugClassSurfaces") { ctx in
            let illegal: [String] = [
                "\u{1000}\u{1031}\u{102D}\u{102F}\u{102D}\u{102F}",   // ကေိုို
                "\u{1000}\u{1031}\u{102E}\u{102E}",                   // ကေီီ
                "\u{1000}\u{1031}\u{1030}\u{1030}",                   // ကေူူ
                "\u{1004}\u{102E}\u{102E}",                           // ငီီ
                "\u{1000}\u{102E}\u{102D}\u{102F}\u{102D}\u{102F}",   // ကီိုို
                "\u{1000}\u{1030}\u{102D}\u{102F}\u{102D}\u{102F}",   // ကူိုို
                "\u{1021}\u{102E}\u{1030}\u{1030}",                   // အီူူ
                "\u{1021}\u{1030}\u{102E}\u{102E}",                   // အူီီ
                "\u{1021}\u{102D}\u{102F}\u{1030}\u{1030}",           // အိုူူ
                "\u{1021}\u{1030}\u{1030}",                           // အူူ
                "\u{1021}\u{102D}\u{102F}\u{102D}\u{102F}\u{102E}",   // အိုိုီ
                "\u{1021}\u{1031}\u{102D}\u{102F}\u{102D}\u{102F}",   // အေိုို
                "\u{101E}\u{1031}\u{102D}\u{102F}\u{102D}\u{102F}",   // သေိုို
                "\u{101E}\u{1031}\u{1030}\u{1030}",                   // သေူူ
                "\u{1004}\u{1031}\u{102D}\u{102F}\u{102D}\u{102F}",   // ငေိုို
            ]
            for surface in illegal {
                ctx.assertTrue(
                    hasMultiClusterOnSingleAnchor(surface),
                    surface,
                    detail: "predicate failed to flag illegal multi-cluster surface"
                )
            }
        },

        TestCase("predicate_acceptsLegalSurfaces") { ctx in
            // Single dep-vowel-cluster shapes, multi-syllable shapes
            // separated by asat or a fresh base, and the legal o- and
            // aung-order multi-scalar clusters.
            let legal: [String] = [
                "\u{1021}\u{1030}",                                              // အူ
                "\u{1021}\u{102E}",                                              // အီ
                "\u{1021}\u{102D}\u{102F}",                                      // အို
                "\u{1000}\u{102C}",                                              // ကာ
                "\u{1000}\u{102D}\u{102F}",                                      // ကို
                "\u{1019}\u{102D}\u{102F}\u{1000}\u{103A}",                      // မိုက် (mok closed)
                "\u{1000}\u{1031}\u{102C}",                                      // ကော
                "\u{1019}\u{1031}\u{102B}\u{1004}\u{103A}",                      // မောင် (descender + tall aa + kinzi-shape)
                // Two complete o-clusters back-to-back, each on its own
                // anchor (legitimate orphan-anchor pair):
                "\u{1021}\u{102D}\u{102F}\u{1021}\u{102D}\u{102F}",
                // `ကိုယ်အိုယ်` shape — two clusters separated by
                // asat-closed coda + fresh base.
                "\u{1000}\u{102D}\u{102F}\u{101A}\u{103A}\u{1021}\u{102D}\u{102F}\u{101A}\u{103A}",
                "\u{1019}\u{1004}\u{103A}\u{1039}\u{1002}\u{101C}\u{102C}\u{1015}\u{102B}",  // မင်္ဂလာပါ
            ]
            for surface in legal {
                ctx.assertFalse(
                    hasMultiClusterOnSingleAnchor(surface),
                    surface,
                    detail: "predicate falsely flagged legal surface"
                )
            }
        },

        // Acceptance criteria from TASK-030. Production rank-0 surface
        // for every bug-class buffer must either:
        //   - contain no same-category-duplicate dep-vowel and no two
        //     dep-vowel clusters on a single anchor, OR
        //   - equal the raw buffer (literal-fallback promotion fired).
        TestCase("rank0_neverMultiClusterOnSingleAnchor") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for buffer in bugBuffers {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first else {
                    ctx.assertTrue(false, buffer, detail: "panel empty")
                    continue
                }
                let isLiteral = top.surface == buffer
                let isClean = !hasMultiClusterOnSingleAnchor(top.surface)
                ctx.assertTrue(
                    isLiteral || isClean,
                    buffer,
                    detail: "rank-0='\(top.surface)' all=\(state.candidates.prefix(5).map(\.surface))"
                )
            }
        },
    ])
}
