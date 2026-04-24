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
    ])
}
