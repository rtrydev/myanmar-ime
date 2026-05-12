import Foundation
import BurmeseIMECore

/// TASK-076: One-shot and incremental keystroke paths must agree on
/// rank-0 for the `achitthone` / `kyaungtharachitthone` family, which
/// exercises a cross-segment re-segmentation that the TASK-004
/// anchor-dominance gate cannot detect at recording time.
///
/// Root cause (verbatim from task notes): at prefix `achitthon`
/// (length 9) the visible siblings of the LM-top `အချစ်သွံ` are minor
/// spelling variants of the `thon3` family. The anchor-recording
/// dominance gate therefore passes and commits the length-9 anchor.
/// One keystroke later (`e`), the one-shot lattice re-segments to
/// `အချစ်သိုနယ်` (chit + tho + ne) — a syllable structure that the
/// anchor surface is NOT a scalar prefix of. The post-merge
/// anchor-promotion path nevertheless finds the length-9 anchor's
/// extension (`အချစ်သွံယ်`) inside `merged` and promotes it because
/// the LM gap top vs anchor-extension sits below the 1-nat dominance
/// threshold.
///
/// The fix tightens the post-merge anchor-promotion gate so that when
/// the anchor's surface is NOT a scalar prefix of the comparator-
/// chosen top (i.e. the candidate represents a different segmentation,
/// not a tail spelling tweak), promotion requires the anchor-extension
/// candidate to STRICTLY DOMINATE the merged top on LM rather than
/// merely sit within the 1-nat tie band. The full-buffer LM is the
/// strongest signal available; if it prefers the new segmentation
/// even narrowly, the anchor is stale.
public enum CrossSegmentResegmentationParitySuite {

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

    public static let suite = TestSuite(name: "CrossSegmentResegmentationParity", cases: [

        // Direct repro witnesses — these are the two buffers
        // IncrementalParitySuite already exercises, called out here
        // again so a future LM regeneration that re-introduces the
        // divergence fails this suite under its own name (and not just
        // as a side effect of IncrementalParitySuite).
        TestCase("achitthone_oneshot_equals_incremental") { ctx in
            guard makeBundledEngine() != nil else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let buffer = "achitthone"
            guard let one = oneshotTop(buffer),
                  let inc = incrementalTop(buffer) else { return }
            ctx.assertTrue(
                one == inc,
                buffer,
                detail: "oneshot='\(one)' incremental='\(inc)'"
            )
        },

        TestCase("kyaungtharachitthone_oneshot_equals_incremental") { ctx in
            guard makeBundledEngine() != nil else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let buffer = "kyaungtharachitthone"
            guard let one = oneshotTop(buffer),
                  let inc = incrementalTop(buffer) else { return }
            ctx.assertTrue(
                one == inc,
                buffer,
                detail: "oneshot='\(one)' incremental='\(inc)'"
            )
        },

        // Cross-segment re-segmentation regression breadth: every
        // buffer in this list pairs a stable mid-buffer prefix
        // (`achitthon`, `khithtaw`, `thuhmatee`) with a final
        // keystroke that should resegment the tail under the
        // full-buffer LM. The invariant is identical: the typing path
        // must not change the rank-0 surface.
        TestCase("cross_segment_resegmentation_corpus") { ctx in
            guard makeBundledEngine() != nil else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let corpus = [
                "achitthone",
                "kyaungtharachitthone",
                "achitachitthone",
                // Buffers from the existing IncrementalParitySuite list
                // that have always passed — included here as
                // anchor-stability regression guards. Tightening the
                // promotion gate must not make these flicker.
                "khithtawkhin",
                "thuhmateetay",
                "achitthone",
                "minminmin",
                "kyawmingalarpar",
                "kahphyaha",
            ]
            for buffer in corpus {
                guard let one = oneshotTop(buffer),
                      let inc = incrementalTop(buffer) else { continue }
                ctx.assertTrue(
                    one == inc,
                    buffer,
                    detail: "oneshot='\(one)' incremental='\(inc)'"
                )
            }
        },

        // Direction-3 / direction-1 specific witness: anchor history
        // must be invalidated when the longer-buffer LM prefers a
        // segmentation that the anchor's surface is NOT a scalar
        // prefix of.
        //
        // Verifies that the structural condition holds:
        // for `achitthone` the typed-letter prefix-by-prefix walk
        // records an anchor at some length, but the FINAL rank-0
        // surface still matches the one-shot full-buffer parse —
        // i.e. anchor stability does not block re-segmentation when
        // the full-buffer LM diverges in syllable structure.
        TestCase("anchor_not_promoted_across_resegmentation") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let buffer = "achitthone"
            // First, drive the engine through the prefix walk so that
            // an anchor IS recorded (this mirrors how a real user
            // types). Then check that the final rank-0 matches the
            // one-shot result.
            var lastTop = ""
            for i in 1...buffer.count {
                let prefix = String(buffer.prefix(i))
                let state = engine.update(buffer: prefix, context: [])
                lastTop = state.candidates.first?.surface ?? ""
            }
            guard let one = oneshotTop(buffer) else { return }
            ctx.assertTrue(
                lastTop == one,
                buffer,
                detail: "incremental='\(lastTop)' oneshot='\(one)'"
            )
        },
    ])
}
