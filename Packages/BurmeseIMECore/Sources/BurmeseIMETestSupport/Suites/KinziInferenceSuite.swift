import Foundation
@_spi(Testing) import BurmeseIMECore

public enum KinziInferenceSuite {

    private static let kinziScalars: [UInt32] = [0x1004, 0x103A, 0x1039]

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

    private static func containsKinzi(_ surface: String) -> Bool {
        let scalars = surface.unicodeScalars.map(\.value)
        guard scalars.count >= kinziScalars.count else { return false }
        for i in 0...(scalars.count - kinziScalars.count) {
            if Array(scalars[i..<i + kinziScalars.count]) == kinziScalars {
                return true
            }
        }
        return false
    }

    private static func assertTopHasKinzi(
        _ ctx: TestContext,
        engine: BurmeseEngine,
        input: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let state = engine.update(buffer: input, context: [])
        let top = state.candidates.first?.surface ?? ""
        ctx.assertTrue(
            containsKinzi(top),
            input,
            detail: "top='\(top)' all=\(state.candidates.map(\.surface))",
            file: file,
            line: line
        )
    }

    private static func assertStrictStackInference(
        _ ctx: TestContext,
        input: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard let inferred = BurmeseEngine.inferImplicitStackMarkers(input) else {
            ctx.assertTrue(false, input, detail: "no inferred stack site", file: file, line: line)
            return
        }
        ctx.assertTrue(
            inferred.input.contains("+") && inferred.liberalInsertions == 0,
            input,
            detail: "inferred='\(inferred.input)' liberal=\(inferred.liberalInsertions)",
            file: file,
            line: line
        )
    }

    public static let suite = TestSuite(name: "KinziInference", cases: [

        TestCase("inferredKinzi_velarLowersWinTop1") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases = [
                "minka",  // k
                "minkh",  // kh
                "kinga",  // g
                "mingh",  // gh
                "minnga", // ng
            ]
            for input in cases {
                assertTopHasKinzi(ctx, engine: engine, input: input)
            }
        },

        TestCase("inferredKinzi_clusterAliasLowersWinTop1") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for input in ["minja", "mincha", "mingya"] {
                assertTopHasKinzi(ctx, engine: engine, input: input)
            }
        },

        TestCase("inferredKinzi_survivesTrailingSyllable") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for input in ["minkhapar", "kingalar", "pinkarpar"] {
                assertTopHasKinzi(ctx, engine: engine, input: input)
            }
        },

        TestCase("inferredStack_usesRenderedVowelFinalForOtherMismatches") { ctx in
            for input in [
                "ketka",   // et -> ka-asat + ka
                "koutka",  // out -> ka-asat + ka
                "kitsa",   // it -> ca-asat + ca
                "kotepha", // ote2 alias -> pa-asat + pha
                "katepa",  // ate2 alias -> pa-asat + pa
            ] {
                assertStrictStackInference(ctx, input: input)
            }
        },
    ])
}
