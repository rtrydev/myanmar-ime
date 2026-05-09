import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-034: vowel-chain shapes the parser has no dedicated rule for
/// (`ein`, `eik`, `eit`, `eip`, `oun`, `iu`, `oui`) must not produce
/// a structurally invalid Myanmar surface at rank 0 nor leave the
/// panel empty of Myanmar candidates.
///
/// Three failure modes pre-fix:
///   1. Empty Myanmar panel: `<C>ein` (Thein, Khin, Sein, Phyu) emits
///      ASCII-literal-only at rank 0 — the parser's chained-rule
///      fallback fails every legality predicate, the sanitizer drops
///      every candidate, and the literal is the only survivor.
///   2. Multi-cluster on multi-anchor surface: `<C>oun`, `<C>iu`
///      surfaces carry `1021 102D 102F 1030 ...` — a legal o-cluster
///      directly adjacent to a fresh u-family scalar on the same
///      anchor, then a trailing consonant base (so the narrow
///      `surfaceIsWhollyMultiClusterOnSingleAnchor` predicate doesn't
///      match because `baseCount > 1`).
///   3. Single-anchor false-negative on category-level o-cluster
///      check: `iu`/`kiu` produce `<base> 102E 1030` — the `(2,3)`
///      category pair passes the legal-cluster check but the exact
///      scalar pair `(102E, 1030)` is NOT the canonical o-cluster
///      `(102D, 102F)`. The broad predicate must reject all four
///      `(102D|102E, 102F|1030)` pairings except the canonical one.
///
/// Fix policy:
///   - Tighten the broad multi-cluster predicate to require the
///     exact canonical scalar pairs `102D 102F` (o-cluster) and
///     `1031 102B|102C` (aw-family) — not category-level pairs.
///   - Extend the narrow "wholly single-anchor" predicate to allow
///     a trailing consonant-only orphan-anchor residue after the
///     multi-cluster, so the Class A literal-promotion gate fires
///     for `<C>oun`/`<C>iu` shapes.
public enum UncoveredVowelChainShapeSuite {

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

    // Predicate replicas — engine-side ground truth used to assert that
    // rank-0 surfaces are NOT structurally invalid post-fix.
    private static func categoryOf(_ v: UInt32) -> Int {
        switch v {
        case 0x102B, 0x102C: return 1
        case 0x102D, 0x102E: return 2
        case 0x102F, 0x1030: return 3
        case 0x1031:        return 4
        case 0x1032:        return 5
        default:            return 0
        }
    }

    /// True when `surface` carries the multi-cluster shape (the
    /// engine's broad predicate, post-fix). Recognises the exact
    /// canonical multi-scalar clusters only: `102D 102F` and
    /// `1031 102B|102C`.
    private static func surfaceCarriesIllegalMultiCluster(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        var clusterCats: [Int] = []
        var firstScalar: UInt32 = 0
        var afterClusterClosed = false
        @inline(__always) func reset() {
            clusterCats.removeAll(keepingCapacity: true)
            firstScalar = 0
            afterClusterClosed = false
        }
        @inline(__always) func isBase(_ v: UInt32) -> Bool {
            if v == 0x103F { return true }
            if (0x1000...0x1021).contains(v) { return true }
            if (0x1023...0x102A).contains(v) { return true }
            return false
        }
        for v in scalars {
            if v < 0x1000 || v > 0x103F { continue }
            if isBase(v) { reset(); continue }
            if v == 0x103A || v == 0x1039 { reset(); continue }
            if v >= 0x103B && v <= 0x103E { continue }
            if v == 0x1036 || v == 0x1037 || v == 0x1038 { continue }
            let cat = categoryOf(v)
            if cat == 0 { continue }
            if afterClusterClosed { return true }
            for prevCat in clusterCats where prevCat == cat { return true }
            clusterCats.append(cat)
            if clusterCats.count == 1 {
                firstScalar = v
                if cat != 2 && cat != 4 {
                    afterClusterClosed = true
                }
            } else if clusterCats.count == 2 {
                let isOCluster = firstScalar == 0x102D && v == 0x102F
                let isAungOrder = firstScalar == 0x1031 && (v == 0x102B || v == 0x102C)
                if isOCluster || isAungOrder {
                    afterClusterClosed = true
                } else {
                    return true
                }
            }
        }
        return false
    }

    public static let suite = TestSuite(name: "UncoveredVowelChainShape", cases: [

        // Manifestation 1: `<C>ein` family must not have an empty
        // Myanmar panel. Rank-0 must be either a structurally legal
        // Myanmar surface OR the ASCII literal raw buffer (Class A
        // escape hatch). Never zero candidates and never the parser's
        // doubled-coda / multi-syllable garbage.
        TestCase("Cein_rank0NotIllegalMyanmar") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for buffer in [
                "kein", "lein", "thein", "phein", "khein",
                "eik", "keik", "eit",
            ] {
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                // Either the literal raw buffer at rank 0 (Class A
                // escape) or a structurally legal Myanmar surface.
                let isLiteral = top == buffer
                let isCleanMyanmar = !isLiteral
                    && !surfaceCarriesIllegalMultiCluster(top)
                ctx.assertTrue(
                    isLiteral || isCleanMyanmar,
                    buffer,
                    detail: "rank-0 is illegal Myanmar in '\(buffer)' top='\(top)' hex=\(hex(top))"
                )
                ctx.assertFalse(
                    state.candidates.isEmpty,
                    "\(buffer)_panelNotEmpty",
                    detail: "panel is empty for '\(buffer)'"
                )
            }
        },

        // Manifestation 2: `<C>oun` family must not produce a
        // multi-cluster-on-single-anchor surface at rank 0. The
        // surface `<C> 102D 102F 1030 <next-base>` is illegal — the
        // u-family `1030` after the closed o-cluster is a fresh
        // cluster on the same anchor.
        TestCase("Coun_rank0NotMultiCluster") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for buffer in [
                "oun", "koun", "loun", "thoun", "moun", "noun", "poun",
            ] {
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                let isLiteral = top == buffer
                let isCleanMyanmar = !isLiteral
                    && !surfaceCarriesIllegalMultiCluster(top)
                ctx.assertTrue(
                    isLiteral || isCleanMyanmar,
                    buffer,
                    detail: "rank-0 carries multi-cluster in '\(buffer)' top='\(top)' hex=\(hex(top))"
                )
            }
        },

        // Manifestation 3: `<C>iu` shapes (single-anchor
        // `1021|<C> 102E 1030`). The category-level legal-cluster
        // check pre-fix admits `(102E, 1030)` because both belong to
        // categories 2 and 3, but the exact scalar pair must reject
        // because only `(102D, 102F)` is canonical.
        TestCase("Ciu_rank0NotIllegalCluster") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for buffer in [
                "iu", "kiu", "miu", "thiu", "phiu",
            ] {
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                let isLiteral = top == buffer
                let isCleanMyanmar = !isLiteral
                    && !surfaceCarriesIllegalMultiCluster(top)
                ctx.assertTrue(
                    isLiteral || isCleanMyanmar,
                    buffer,
                    detail: "rank-0 carries non-canonical i+u cluster in '\(buffer)' top='\(top)' hex=\(hex(top))"
                )
            }
        },

        // Direct predicate test for the broad multi-cluster check.
        // Pre-fix: `<C> 102E 1030` admitted as a legal cluster
        // because cats `(2,3)` match the o-cluster shape. Post-fix:
        // only `(102D, 102F)` is the canonical o-cluster.
        TestCase("multiClusterPredicate_rejectsNonCanonicalOClusterPairs") { ctx in
            // Each surface is a single anchor + non-canonical
            // i-family + u-family scalar pair. All four MUST flag
            // post-fix; only `1021 102D 102F` is canonical and
            // unflagged.
            let illegalSurfaces: [(label: String, surface: String)] = [
                ("1021_102D_1030", "\u{1021}\u{102D}\u{1030}"),
                ("1021_102E_102F", "\u{1021}\u{102E}\u{102F}"),
                ("1021_102E_1030", "\u{1021}\u{102E}\u{1030}"),
                ("1000_102E_1030", "\u{1000}\u{102E}\u{1030}"),
                ("1000_102D_1030", "\u{1000}\u{102D}\u{1030}"),
                ("1000_102E_102F", "\u{1000}\u{102E}\u{102F}"),
            ]
            for c in illegalSurfaces {
                ctx.assertTrue(
                    BurmeseEngine.surfaceContainsMultiClusterOnSingleAnchor(c.surface),
                    "rejectNonCanonicalIU_\(c.label)",
                    detail: "non-canonical i+u pair must flag, surface='\(c.surface)' hex=\(hex(c.surface))"
                )
            }
            // The canonical o-cluster `1021 102D 102F` and
            // `1000 102D 102F` must NOT flag.
            for surface in ["\u{1021}\u{102D}\u{102F}", "\u{1000}\u{102D}\u{102F}"] {
                ctx.assertFalse(
                    BurmeseEngine.surfaceContainsMultiClusterOnSingleAnchor(surface),
                    "canonicalOCluster_\(hex(surface))",
                    detail: "canonical o-cluster must not flag, surface='\(surface)'"
                )
            }
            // Aung-family canonical: `1031 102B|102C` legal.
            for surface in ["\u{1021}\u{1031}\u{102B}", "\u{1021}\u{1031}\u{102C}"] {
                ctx.assertFalse(
                    BurmeseEngine.surfaceContainsMultiClusterOnSingleAnchor(surface),
                    "canonicalAung_\(hex(surface))",
                    detail: "canonical aung-family must not flag, surface='\(surface)'"
                )
            }
        },

        // Negative controls — well-formed parses must NOT be affected
        // by the predicate tightening or the literal-promotion gate
        // change.
        TestCase("negativeControls_cleanRank0Surfaces") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, expectedTop: String)] = [
                ("aung",          "အောင်"),
                ("kaung",         "ကောင်"),
                ("kyaung:tha",    "ကျောင်းသ"),
                ("mingalarpar",   "မင်္ဂလာပါ"),
            ]
            for c in cases {
                let top = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top, c.expectedTop,
                    "\(c.buffer)_negativeControlRegression_got=\(hex(top))"
                )
            }
        },

        // Mid-typing intermediate prefixes from the
        // `ComprehensiveRanking.sentence_longArticle_literaryInfluence`
        // case. The TASK-030 narrow predicate guarded against
        // promoting the literal at rank 0 for these prefixes. The
        // fix must preserve that behaviour — the multi-anchor surface
        // resolves as the next keystroke arrives, so the literal
        // should NOT be promoted to rank 0 here.
        TestCase("midTypingPrefixes_doNotForceLiteralAtRank0") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            // `thueiooz` is a known mid-typing prefix from a longer
            // sentence — its rank-0 should not be the literal.
            for buffer in ["thueiooz", "thueiooza"] {
                let top = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    top == buffer,
                    "midTyping_\(buffer)",
                    detail: "literal escape must not fire for mid-typing prefix '\(buffer)' top='\(top)'"
                )
            }
        },
    ])
}
