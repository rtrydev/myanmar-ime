import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-056: an explicit user-typed `+` between a consonant and a
/// following ya-pin / ya-yit / wa-hswe cluster letter (`y`, `w`)
/// must NOT be silently merged into the medial cluster when the
/// cluster letter carries a trailing vowel. The bug fires only
/// in the production-equivalent engine (bundled lexicon + trigram
/// LM) — the bare engine already produces the correct two-syllable
/// rank-0 surface for every listed buffer. The LM-favoured cluster-
/// medial parse (`ကြ` / `ကွ` for buffers like `k+ya` / `k+wa`)
/// displaces the user-respecting two-syllable parse (`ကယ` / `ကဝ`)
/// at rank 0 when a trailing vowel is present.
///
/// Per CLAUDE.md §6 ("Explicit `+`"): *User-typed `+` is a hard
/// syllable / stack boundary. The LM may rank among legal stack
/// variants, but it should not displace the user's explicit kinzi/
/// stack intent with an unrelated segmentation.* Promoting
/// `<C>+<C>` into a single-syllable medial cluster IS displacing
/// the user's explicit boundary intent with the LM-preferred
/// segmentation.
///
/// The fix lives in the explicit-`+` rank-0 promotion path
/// (mirroring TASK-031 for kinzi displacement) — a parser-level
/// fix would regress `CwyClusterPromotionSuite` and the bare-engine
/// no-`+` cluster invariants. The bare engine already produces the
/// right result; only the LM-driven ranking in the production
/// engine needs adjusting.
public enum PlusBeforeClusterLetterSuite {

    private static func makeBundledEngine() -> BurmeseEngine? {
        guard let lp = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lp),
              let lmp = BundledArtifacts.trigramLMPath,
              let lm = try? TrigramLanguageModel(path: lmp) else {
            return nil
        }
        return BurmeseEngine(candidateStore: store, languageModel: lm)
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
    }

    /// True when `surface` contains a Myanmar medial scalar
    /// (`103B` ya-pin / `103C` ya-yit / `103D` wa-hswe / `103E`
    /// ha-htoe) on the FIRST consonant — i.e. the cluster-medial
    /// interpretation that would discard the user's explicit `+`
    /// boundary between the first consonant and the medial letter.
    private static func firstConsonantHasMedial(_ surface: String) -> Bool {
        let v = Array(surface.unicodeScalars).map(\.value)
        guard v.count >= 2 else { return false }
        // Find the first base consonant (U+1000–U+1021); check the
        // immediately-following scalar.
        for i in 0..<v.count {
            let scalar = v[i]
            if scalar >= 0x1000 && scalar <= 0x1021 {
                if i + 1 < v.count {
                    let next = v[i + 1]
                    if next >= 0x103B && next <= 0x103E { return true }
                }
                return false
            }
        }
        return false
    }

    /// Bug-class buffers from TASK-056 *Current State*. Each rank-0
    /// surface in the production engine before the fix carries a
    /// medial scalar (103B/103C/103D) on the first consonant — the
    /// user's explicit `+` is discarded.
    private static let bugBuffers: [String] = [
        "k+ya", "k+yar", "k+yu",
        "k+wa", "k+wi", "k+war",
        "ka+ya", "ka+wa", "ka+yu",
        "p+ya", "p+wa",
    ]

    /// Concrete two-syllable rank-0 expectations for the canonical
    /// cases. Each surface has TWO consonant anchors with the cluster
    /// letter rendered as an independent consonant (`101A` for `y`,
    /// `101D` for `w`) attached to a fresh syllable.
    private static let twoSyllableRank0: [(buffer: String, expectedHex: [UInt32])] = [
        // ka + ya → ကယ
        ("k+ya",  [0x1000, 0x101A]),
        ("ka+ya", [0x1000, 0x101A]),
        // ka + wa → ကဝ
        ("k+wa",  [0x1000, 0x101D]),
        ("ka+wa", [0x1000, 0x101D]),
        // ka + yar → ကယာ
        ("k+yar", [0x1000, 0x101A, 0x102C]),
        // ka + war → ကဝါ (descender ascender takes tall ါ U+102B)
        ("k+war", [0x1000, 0x101D, 0x102B]),
        // ka + yu → ကယူ
        ("k+yu",  [0x1000, 0x101A, 0x1030]),
        // ka + wi → ကဝီ
        ("k+wi",  [0x1000, 0x101D, 0x102E]),
        // pa + ya → ပယ
        ("p+ya",  [0x1015, 0x101A]),
        // pa + wa → ပဝ
        ("p+wa",  [0x1015, 0x101D]),
    ]

    public static let suite = TestSuite(name: "PlusBeforeClusterLetter", cases: [

        // Headline: rank-0 surface for every bug buffer must NOT
        // carry a medial scalar on the first consonant — the user's
        // explicit `+` must be honored as a hard syllable boundary.
        TestCase("rank0HasNoMedialOnFirstConsonant") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            for buffer in bugBuffers {
                let cands = engine.update(buffer: buffer, context: []).candidates
                guard let top = cands.first else {
                    ctx.assertTrue(false, buffer, detail: "panel empty")
                    continue
                }
                ctx.assertFalse(
                    firstConsonantHasMedial(top.surface),
                    buffer,
                    detail: "rank-0='\(top.surface)' (\(hex(top.surface))) carries medial on first consonant; user's `+` was discarded"
                )
            }
        },

        // Concrete scalar-level rank-0 expectations.
        TestCase("rank0IsTwoSyllableSurface") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            for entry in twoSyllableRank0 {
                let cands = engine.update(buffer: entry.buffer, context: []).candidates
                guard let top = cands.first else {
                    ctx.assertTrue(false, entry.buffer, detail: "panel empty")
                    continue
                }
                let topHex = top.surface.unicodeScalars.map(\.value)
                ctx.assertEqual(
                    Array(topHex),
                    entry.expectedHex,
                    "\(entry.buffer)_actualHex=\(topHex.map { String(format: "%04X", $0) })"
                )
            }
        },

        // Cluster-medial sibling reachability: the cluster-medial
        // form must remain reachable in the panel (rank ≤ 5) so
        // legacy user expectations are preserved.
        TestCase("clusterMedialReachableInPanel") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            for buffer in bugBuffers {
                let cands = engine.update(buffer: buffer, context: []).candidates
                let top5 = cands.prefix(5)
                let hasMedial = top5.contains { firstConsonantHasMedial($0.surface) }
                ctx.assertTrue(
                    hasMedial,
                    buffer,
                    detail: "cluster-medial form not reachable in top 5; surfaces=\(cands.prefix(5).map(\.surface))"
                )
            }
        },

        // Regression guard: TASK-058's `CwyClusterPromotionSuite`
        // and `ClusterMedialPreferenceSuite` cases (no-`+` cluster
        // shapes) must NOT regress. Without `+`, `kya` / `kwa`
        // remain medial-cluster rank-0.
        TestCase("noPlusClusterShapesUnchanged") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            // `kya` without `+` should still be the medial cluster
            // (the LM-driven ya-pin or ya-yit choice is fine — we
            // only check that a medial scalar is present on the
            // first consonant).
            let noPlusBuffers = ["kya", "kwa", "kyar", "kwi", "pya", "pwa"]
            for buffer in noPlusBuffers {
                let cands = engine.update(buffer: buffer, context: []).candidates
                guard let top = cands.first else {
                    ctx.assertTrue(false, buffer, detail: "panel empty")
                    continue
                }
                ctx.assertTrue(
                    firstConsonantHasMedial(top.surface),
                    buffer,
                    detail: "no-`+` cluster `\(buffer)` lost its medial: rank-0='\(top.surface)' (\(hex(top.surface)))"
                )
            }
        },

        // Regression guard: TASK-031 explicit-`+` kinzi / asat-
        // closure shapes must NOT regress. The `min+ga` / `kan+ga`
        // family produces kinzi (`1004 103A 1039`) or asat-closure
        // (`<base> 103A`) at rank 0; the new promotion must not
        // displace them.
        TestCase("explicitPlusKinziAndAsatStillRank0") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            // Kinzi.
            let kinziTop = engine.update(buffer: "min+ga", context: [])
                .candidates.first?.surface ?? ""
            let kinziHex = kinziTop.unicodeScalars.map(\.value)
            ctx.assertEqual(
                Array(kinziHex),
                [0x1019, 0x1004, 0x103A, 0x1039, 0x1002],
                "min+ga_actual=\(kinziHex.map { String(format: "%04X", $0) })"
            )
            // Asat closure.
            let asatTop = engine.update(buffer: "kan+ga", context: [])
                .candidates.first?.surface ?? ""
            let asatHex = asatTop.unicodeScalars.map(\.value)
            ctx.assertEqual(
                Array(asatHex),
                [0x1000, 0x1014, 0x103A, 0x1002],
                "kan+ga_actual=\(asatHex.map { String(format: "%04X", $0) })"
            )
        },

        // Regression guard: TASK-047 `<C>+<vowel-rule>` cases (e.g.
        // `ka+aung` → `ကအောင်`) must NOT regress.
        TestCase("plusBeforeVowelRuleStillRank0") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let cases: [(buffer: String, expectedHex: [UInt32])] = [
                ("ka+aung", [0x1000, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
                ("k+aung",  [0x1000, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
                ("ka+i",    [0x1000, 0x1021, 0x102E]),
            ]
            for entry in cases {
                let surface = engine.update(buffer: entry.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let hexArr = surface.unicodeScalars.map(\.value)
                ctx.assertEqual(
                    Array(hexArr),
                    entry.expectedHex,
                    "\(entry.buffer)_actualHex=\(hexArr.map { String(format: "%04X", $0) })"
                )
            }
        },

        // Regression guard: `r`-cluster (already correct) stays
        // correct. `k+ra` → `ကရ` (two syllables); the `r` cluster
        // letter does NOT have the LM-driven medial promotion that
        // affects `y` / `w`.
        TestCase("rClusterUnchanged") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let cases: [(buffer: String, expectedHex: [UInt32])] = [
                ("k+ra",  [0x1000, 0x101B]),
                ("ka+ra", [0x1000, 0x101B]),
                ("p+ra",  [0x1015, 0x101B]),
            ]
            for entry in cases {
                let surface = engine.update(buffer: entry.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let hexArr = surface.unicodeScalars.map(\.value)
                ctx.assertEqual(
                    Array(hexArr),
                    entry.expectedHex,
                    "\(entry.buffer)_actualHex=\(hexArr.map { String(format: "%04X", $0) })"
                )
            }
        },
    ])
}
