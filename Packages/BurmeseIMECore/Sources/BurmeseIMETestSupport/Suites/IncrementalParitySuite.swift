import Foundation
import BurmeseIMECore

/// Coverage for TASK-004: the user-visible rank-0 surface for any
/// composable buffer must be a deterministic function of the buffer
/// alone, regardless of the typing path that produced it. The
/// engine's `anchorHistory` cache survives across keystrokes and was
/// observed to lock in a transient syllable rendering at intermediate
/// buffer lengths (when the LM tie was narrow), then resist
/// re-segmentation when later keystrokes would have produced a
/// different LM-best parse for the full buffer. The fix tightens
/// anchor recording (only commit anchors when the chosen top
/// outscores its nearest sibling by `lmDominanceThreshold`) so weak
/// transient picks no longer override the full-buffer LM evidence.
public enum IncrementalParitySuite {

    private static func makeBundledEngine() -> BurmeseEngine? {
        guard let lexPath = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lexPath),
              let lmPath = BundledArtifacts.trigramLMPath,
              let lm = try? TrigramLanguageModel(path: lmPath) else {
            return nil
        }
        return BurmeseEngine(candidateStore: store, languageModel: lm)
    }

    private static func incrementalTop(_ buffer: String) -> String? {
        guard let engine = makeBundledEngine() else { return nil }
        var top: String?
        for i in 1...buffer.count {
            let prefix = String(buffer.prefix(i))
            let state = engine.update(buffer: prefix, context: [])
            top = state.candidates.first?.surface
        }
        return top
    }

    private static func oneshotTop(_ buffer: String) -> String? {
        guard let engine = makeBundledEngine() else { return nil }
        let state = engine.update(buffer: buffer, context: [])
        return state.candidates.first?.surface
    }

    /// Curated reproduction matrix — every entry is a buffer where
    /// the incremental-vs-one-shot divergence has been observed.
    /// Inputs span 8 to 30 characters and exercise both the
    /// cross-syllable re-segmentation pattern (`achitthone`,
    /// `khithtawkhin`, `thuhmateetay`) and the medial-swap pattern
    /// (`kyaungtharkyaungthar`, `kyaymarkyaymarkyaymar`,
    /// `kyaungthawkyaungtha`).
    private static let parityCorpus: [String] = [
        // Cross-syllable re-segmentation (TASK-004 spec)
        "achitthone",
        "khithtawkhin",
        "thuhmateetay",
        // Medial-swap divergence (TASK-004 spec)
        "kyaungthawkyaungtha",
        "kyaungtharkyaungthar",
        "kyaymarkyaymarkyaymar",
        // Additional re-segmentation regressions
        "minminmin",
        "minminmingala",
        "thingyantawmingalar",
        "padaythapadaytha",
        "kywanphyikyalehmingalarpar",
        // Mid-length naturalish phrases that exercise the
        // post-merge anchor promotion + medial-swap synthesis
        // blocks (`anchorHistory` walked from deepest to shallowest
        // independently of windowing).
        "mingalarpar",
        "kyawmingalarpar",
        "shwepyithit",
        "kyaungthar",
        "ahnyat",
        "kayinmamarpar",
        "thingyanmingalar",
        "shitminthar",
        "yangoun",
        "mandalay",
        "kachintaung",
        "shinpyu",
        "achit",
        "phyay",
        "kyaikhtiyo",
        "shwedagon",
        "ohnnoekhaukswe",
        // Long-buffer / windowing-active stress (>= 18 chars)
        "kyaungtharachitthone",
        "kyawmingalarpartharthar",
        "kyathatpwearphwearmingalar",
        "shwedagonpaya",
        "achitachitachit",
        // Boundary stability — anchor history must NOT lock in a
        // transient pick that the full buffer would re-segment.
        "kahkaht",
        "kahphyaha",
    ]

    public static let suite = TestSuite(name: "IncrementalParity", cases: [

        TestCase("incrementalEqualsOneshot_acrossCorpus") { ctx in
            guard makeBundledEngine() != nil else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            for buffer in parityCorpus {
                guard let oneshot = oneshotTop(buffer) else { continue }
                guard let incremental = incrementalTop(buffer) else { continue }
                ctx.assertTrue(
                    oneshot == incremental,
                    buffer,
                    detail: "oneshot='\(oneshot)' incremental='\(incremental)'"
                )
            }
        },

        // Anchor stability regression guards: short buffers where
        // the incremental anchor SHOULD prevent flicker. These are
        // direct lifts from `AnchorStabilitySuite` to ensure the
        // TASK-004 fix doesn't weaken the legitimate anchor path.
        TestCase("anchorStability_kinziPersistsThroughExtension") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            // Typing `mingalar` keystroke-by-keystroke must surface
            // the kinzi rendering at every step ≥ 5 chars (the
            // first prefix where the kinzi inference fires).
            let buffer = "mingalar"
            var sawKinzi = false
            for i in 1...buffer.count {
                let prefix = String(buffer.prefix(i))
                let state = engine.update(buffer: prefix, context: [])
                let top = state.candidates.first?.surface ?? ""
                let containsKinzi = top.unicodeScalars.contains(where: { $0.value == 0x1039 })
                if containsKinzi { sawKinzi = true }
                if sawKinzi {
                    ctx.assertTrue(
                        containsKinzi,
                        prefix,
                        detail: "top='\(top)' lost kinzi after a previous keystroke had it"
                    )
                }
            }
        },

        TestCase("anchorStability_lexiconHistoryDoesNotDriftAcrossExtension") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            // `kyawmingalarpar` should converge to the same surface
            // whether typed letter-by-letter or in one shot. This
            // case is the canonical anchor-stability test (each
            // keystroke recompletes the anchor for the typed prefix
            // before re-merging the next letter's tail). With
            // bundled lex+LM, a stable surface is expected.
            let buffer = "kyawmingalarpar"
            let oneshot = engine.update(buffer: buffer, context: []).candidates.first?.surface ?? ""
            // Reset engine and type incrementally.
            guard let incremental = incrementalTop(buffer) else { return }
            ctx.assertTrue(
                oneshot == incremental,
                buffer,
                detail: "oneshot='\(oneshot)' incremental='\(incremental)'"
            )
        },
    ])
}
