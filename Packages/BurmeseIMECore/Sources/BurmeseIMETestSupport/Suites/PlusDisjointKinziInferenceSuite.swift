import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-045: implicit kinzi inference must continue to fire on
/// kinzi-prone segments even when an explicit `+` syllable boundary
/// is present elsewhere in the buffer. The bug:
/// `inferImplicitStackMarkers` short-circuits as soon as `input`
/// contains any `+`, so `minga+lar`, `tinga+thar`, `ka+minga`, and
/// every `<C>(in|an|on|...)ga<...>` shape that the user terminates
/// or precedes with `+` loses its kinzi candidate from the entire
/// candidate panel.
///
/// `+` is a hard *syllable* boundary marker — orthogonal to whether
/// the boundary itself is a stack site. The user typing
/// `<word with kinzi>+<particle>` is asking for two units; the
/// kinzi inference should fire independently inside each `+`-delimited
/// segment. See CLAUDE.md "general reachability rule": panel presence
/// (top 3 strongly preferred) satisfies the reachability bar.
public enum PlusDisjointKinziInferenceSuite {

    private static let kinziScalars: [UInt32] = [0x1004, 0x103A, 0x1039]

    private static func makeBundledEngine() -> BurmeseEngine? {
        guard let lp = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lp),
              let lmp = BundledArtifacts.trigramLMPath,
              let lm = try? TrigramLanguageModel(path: lmp) else {
            return nil
        }
        return BurmeseEngine(candidateStore: store, languageModel: lm)
    }

    private static func hasKinzi(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 3 else { return false }
        for i in 0...(scalars.count - 3)
        where Array(scalars[i..<i + 3]) == kinziScalars {
            return true
        }
        return false
    }

    private static func panelHasKinzi(
        _ candidates: [Candidate]
    ) -> Bool {
        return candidates.contains { hasKinzi($0.surface) }
    }

    private static func panelHasMingaKinzi(
        _ candidates: [Candidate]
    ) -> Bool {
        // `မင်္ဂ` = 1019 1004 103A 1039 1002.
        let target: [UInt32] = [0x1019, 0x1004, 0x103A, 0x1039, 0x1002]
        return candidates.contains { cand in
            let scalars = Array(cand.surface.unicodeScalars).map(\.value)
            guard scalars.count >= target.count else { return false }
            for i in 0...(scalars.count - target.count)
            where Array(scalars[i..<i + target.count]) == target {
                return true
            }
            return false
        }
    }

    /// Buffers from TASK-045 *Steps to Reproduce*. Each row's panel
    /// must contain at least one candidate carrying the kinzi triple.
    private static let kinziPanelReachabilityBuffers: [String] = [
        "minga+lar",
        "minga+lar+par",
        "minga+ka",
        "tinga+lar",
        "tinga+thar",
        "thaungminga+lar",
        "ka+minga",
        "ka+minga+lar",
    ]

    public static let suite = TestSuite(name: "PlusDisjointKinziInference", cases: [

        // Sanity: the `+`-less prefix renders kinzi at rank 0. If
        // this fails, the LM/lexicon stack changed and the bug-class
        // assertions below need to be re-grounded.
        TestCase("noPlusVariants_haveKinziAtRankZero_production") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            for buffer in ["minga", "tinga", "thaungminga"] {
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    hasKinzi(top),
                    buffer,
                    detail: "rank-0='\(top)' lacks kinzi"
                )
            }
        },

        // Hard floor: every bug-class buffer's panel must contain at
        // least one candidate carrying the kinzi triple
        // `1004 103A 1039`. Production-equivalent engine.
        TestCase("plusBufferPanel_containsKinzi_production") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            for buffer in kinziPanelReachabilityBuffers {
                let state = engine.update(buffer: buffer, context: [])
                ctx.assertTrue(
                    panelHasKinzi(state.candidates),
                    buffer,
                    detail: "no kinzi in panel; top10=\(state.candidates.prefix(10).map(\.surface))"
                )
            }
        },

        // Stronger floor: the kinzi-bearing candidate must carry the
        // SAME morpheme as the no-`+` sibling. For every `minga`-class
        // buffer the panel must contain a candidate whose surface
        // includes `မင်္ဂ` (1019 1004 103A 1039 1002).
        TestCase("plusBufferPanel_carriesMingaKinziMorpheme_production") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let mingaCarriers: [String] = [
                "minga+lar",
                "minga+lar+par",
                "minga+ka",
                "thaungminga+lar",
                "ka+minga",
                "ka+minga+lar",
            ]
            for buffer in mingaCarriers {
                let state = engine.update(buffer: buffer, context: [])
                ctx.assertTrue(
                    panelHasMingaKinzi(state.candidates),
                    buffer,
                    detail: "no `မင်္ဂ` morpheme in panel; top10=\(state.candidates.prefix(10).map(\.surface))"
                )
            }
        },

        // Bare-engine reachability. The bug reproduces in the parser
        // input shaping path, so a bare engine must also surface the
        // kinzi-bearing candidate (the bare engine does not have the
        // LM rerank fallback).
        TestCase("plusBufferPanel_containsKinzi_bareEngine") { ctx in
            let engine = BurmeseEngine()
            for buffer in kinziPanelReachabilityBuffers {
                let state = engine.update(buffer: buffer, context: [])
                ctx.assertTrue(
                    panelHasKinzi(state.candidates),
                    buffer,
                    detail: "bare-engine: no kinzi in panel; top10=\(state.candidates.prefix(10).map(\.surface))"
                )
            }
        },

        // TASK-031 explicit-`+` rank-0 promotion must not regress.
        // When the user types `+` AT the kinzi site itself
        // (`min+ga`), the kinzi parse keeps rank 0.
        TestCase("explicitPlusAtKinziSite_keepsRankZero") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            for buffer in ["min+ga", "tin+ga", "min+ga+lar"] {
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    hasKinzi(top),
                    buffer,
                    detail: "explicit-`+` site: rank-0='\(top)' lacks kinzi"
                )
            }
        },

        // Per-segment inference: the inference function itself must
        // return a non-nil rewrite for buffers carrying both
        // kinzi-prone segments AND explicit `+`s elsewhere. This is
        // the structural property that the bug fix must restore.
        TestCase("inferImplicitStackMarkers_firesPerSegment") { ctx in
            // `minga+lar` → kinzi inference site at offset 3 in segment
            // 0 (`min+ga`); segment 1 (`lar`) carries no inference
            // site. The rewrite should contain `min+ga` somewhere.
            let r1 = BurmeseEngine.inferImplicitStackMarkers("minga+lar")
            ctx.assertTrue(r1 != nil, "minga+lar should produce inference rewrite")
            if let r1 = r1 {
                ctx.assertTrue(
                    r1.input.contains("min+ga"),
                    "minga+lar inferred input",
                    detail: "got '\(r1.input)' (expected to contain 'min+ga')"
                )
            }

            let r2 = BurmeseEngine.inferImplicitStackMarkers("ka+minga")
            ctx.assertTrue(r2 != nil, "ka+minga should produce inference rewrite")
            if let r2 = r2 {
                ctx.assertTrue(
                    r2.input.contains("min+ga"),
                    "ka+minga inferred input",
                    detail: "got '\(r2.input)' (expected to contain 'min+ga')"
                )
            }

            let r3 = BurmeseEngine.inferImplicitStackMarkers("ka+minga+lar")
            ctx.assertTrue(r3 != nil, "ka+minga+lar should produce inference rewrite")
            if let r3 = r3 {
                ctx.assertTrue(
                    r3.input.contains("min+ga"),
                    "ka+minga+lar inferred input",
                    detail: "got '\(r3.input)' (expected to contain 'min+ga')"
                )
            }

            // Buffers with no kinzi-prone segment continue to
            // return nil (no spurious inference).
            let none = BurmeseEngine.inferImplicitStackMarkers("ka+lar")
            ctx.assertTrue(none == nil, "ka+lar should yield nil")
        },
    ])
}
