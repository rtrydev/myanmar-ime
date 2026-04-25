import Foundation
import BurmeseIMECore

public enum MedialStabilitySuite {

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

    private static func progressiveTop(_ buffer: String, _ ctx: TestContext) -> String? {
        guard let engine = bundledEngine(ctx) else { return nil }
        var top = ""
        for i in 1...buffer.count {
            let prefix = String(buffer.prefix(i))
            let state = engine.update(buffer: prefix, context: [])
            top = state.candidates.first?.surface ?? ""
        }
        return top
    }

    private static func oneShotTop(_ buffer: String, _ ctx: TestContext) -> String? {
        guard let engine = bundledEngine(ctx) else { return nil }
        let state = engine.update(buffer: buffer, context: [])
        return state.candidates.first?.surface ?? ""
    }

    private static func firstMedialScalar(_ surface: String) -> UInt32? {
        for scalar in surface.unicodeScalars {
            let v = scalar.value
            if v == 0x103B || v == 0x103C { return v }
        }
        return nil
    }

    public static let suite = TestSuite(name: "MedialStability", cases: [

        // Task 05: progressive (character-at-a-time) and one-shot
        // typing of the same buffer must converge on the same medial
        // (ya-pin ျ U+103B vs ya-yit ြ U+103C) on ambiguous onsets
        // like `ky` / `khy` / `gy` / `phy` / `by` / `my` / `py`.
        // Before the LM-margin guard on anchor promotion (task 02),
        // the early prefix-anchor would freeze whichever medial the
        // parser picked at the maturity threshold even when the
        // LM-best for the longer buffer disagreed.
        TestCase("progressive_pureMedialFlipsConverge") { ctx in
            for buffer in [
                "kywantawkabethu",          // medial-only flip
                "kywantawpyaw:thi",         // medial-only flip
                "kywantawkalaungbethu",     // medial flip + segmentation
                "kywantawnaylathebethu",    // medial flip + segmentation
            ] {
                guard let prog = progressiveTop(buffer, ctx),
                      let one = oneShotTop(buffer, ctx) else { return }
                ctx.assertEqual(
                    firstMedialScalar(prog),
                    firstMedialScalar(one),
                    "medialAgreement.\(buffer)"
                )
                ctx.assertEqual(
                    prog, one,
                    "fullSurfaceAgreement.\(buffer)"
                )
            }
        },

        // Below-threshold negative controls: short buffers and
        // sentences that already converge must continue to converge.
        TestCase("progressive_belowThresholdControlsConverge") { ctx in
            for buffer in [
                "kyaung:",
                "kyaungtha:",
                "myanmar",
                "thuthuthu",
                "mingalapar",
            ] {
                guard let prog = progressiveTop(buffer, ctx),
                      let one = oneShotTop(buffer, ctx) else { return }
                ctx.assertEqual(
                    prog, one,
                    "controlAgreement.\(buffer)"
                )
            }
        },
    ])
}
