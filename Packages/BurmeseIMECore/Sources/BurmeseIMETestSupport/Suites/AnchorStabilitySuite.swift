import Foundation
import BurmeseIMECore

public enum AnchorStabilitySuite {

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

    private static func containsVirama(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value == 0x1039 }
    }

    private static func assertViramaPersists(
        _ ctx: TestContext,
        engine: BurmeseEngine,
        input: String,
        from marker: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        var shouldHaveVirama = false
        for i in 1...input.count {
            let prefix = String(input.prefix(i))
            let state = engine.update(buffer: prefix, context: [])
            let top = state.candidates.first?.surface ?? ""
            if prefix == marker || containsVirama(top) {
                shouldHaveVirama = true
            }
            if shouldHaveVirama {
                ctx.assertTrue(
                    containsVirama(top),
                    prefix,
                    detail: "top='\(top)' all=\(state.candidates.map(\.surface))",
                    file: file,
                    line: line
                )
            }
        }
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

    public static let suite = TestSuite(name: "AnchorStability", cases: [

        TestCase("kinziAnchorsSurviveLexiconExtension") { ctx in
            for (input, marker) in [
                ("minglarpars", "mingl"),
                ("pinkarpars", "pink"),
                ("hingapar", "hing"),
            ] {
                guard let engine = bundledEngine(ctx) else { return }
                assertViramaPersists(ctx, engine: engine, input: input, from: marker)
            }
        },

        TestCase("nativeViramaAnchorSurvivesExtension") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            assertViramaPersists(ctx, engine: engine, input: "dhammabya", from: "dhamm")
        },

        // Task 02 / 05: progressive (character-at-a-time) typing must not
        // freeze a stale anchor when the LM evidence prefers a different
        // segmentation or medial in the full-buffer parse. The expectation
        // is convergence with the one-shot top — whichever surface the LM
        // ranks highest at the *final* buffer length should win in both
        // modes.
        TestCase("progressiveMatchesOneShot_anchorYieldsToLm") { ctx in
            // The LM-margin guard (task 02) makes the anchor yield only
            // when the full-buffer LM-best is clearly stronger than the
            // anchor's recorded surface. `kywantawmingalarpar` falls
            // outside this set: its progressive form preserves a kinzi
            // (`မင်္ဂ`) that the one-shot full-buffer parse drops because
            // the kinzi-inference path itself is incomplete — see task
            // 03. The anchor here is *not* stale; convergence in that
            // direction would actively erase the better surface.
            for buffer in [
                "kywantawkalaungbethu",
                "kywantawkabethu",
                "kywantawpyaw:thi",
                "kywantawnaylathebethu",
                "kmptsbethu",
                "mathaungbethu",
            ] {
                guard let prog = progressiveTop(buffer, ctx),
                      let one = oneShotTop(buffer, ctx) else { return }
                ctx.assertEqual(
                    prog, one,
                    "progressiveMatchesOneShot.\(buffer)"
                )
            }
        },

        // Negative controls: short / non-anchor-triggering buffers and
        // sentences that already converge must continue to converge.
        TestCase("progressiveMatchesOneShot_stableControls") { ctx in
            for buffer in [
                "myanmar",
                "thuthuthu",
                "mingalapar",
                "mingalarpar:saka",
                "tabilan:kabar",
                "kalaung:kabar",
            ] {
                guard let prog = progressiveTop(buffer, ctx),
                      let one = oneShotTop(buffer, ctx) else { return }
                ctx.assertEqual(
                    prog, one,
                    "stableControl.\(buffer)"
                )
            }
        },
    ])
}
