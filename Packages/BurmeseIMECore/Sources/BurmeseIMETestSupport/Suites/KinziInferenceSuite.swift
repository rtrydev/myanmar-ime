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

        // Task 03: <leading independent vowel> + bare-onset `nga` +
        // stackable consonant must still trigger the kinzi inference,
        // even though the upper `nga` arrives as an `onsetOnly` arc
        // (no preceding asat-vowel reading).
        TestCase("inferredKinzi_leadingVowelBareNgaUpperWinsTop1") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases = [
                "anggar",     // အင်္ဂါ Tuesday
                "angkar",     // အင်္ကာ
                "anggalip",   // အင်္ဂလိပ် English
                "angkareya",  // အင်္ကြိယာ verb
            ]
            for input in cases {
                assertTopHasKinzi(ctx, engine: engine, input: input)
            }
        },

        // The explicit-`+` virama-stack path must continue to give a
        // user-reachable non-kinzi rendering when desired (loanwords /
        // acronyms typed deliberately as `ang+kar`). The plain
        // (no-`+`) flat form may be pruned for inputs like `anggar`
        // where the LM strongly prefers the canonical kinzi spelling
        // by more than `lmPruneMargin`, but the explicit-`+` path
        // remains the documented escape hatch.
        TestCase("inferredKinzi_explicitViramaStackRemainsReachable") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for input in ["ang+gar", "ang+kar"] {
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                // Explicit `+` produces a virama stack, NOT kinzi.
                ctx.assertFalse(
                    containsKinzi(top),
                    "explicitViramaNoKinzi.\(input)",
                    detail: "top='\(top)'"
                )
            }
        },

        // Negative controls: non-`nga` uppers, non-stackable consonants,
        // and inputs whose preceding arc *does* end in an asat-vowel
        // must continue to behave as before (no false kinzi from the
        // bare-onset arm).
        TestCase("inferredKinzi_leadingVowelBareNgaUpper_noFalseKinzi") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            // `kha` (ခ) is NOT a kinzi-upper, so the `kh` digraph after
            // `a` must not trigger inference.
            let akhgar = engine.update(buffer: "akhgar", context: [])
            ctx.assertFalse(
                akhgar.candidates.prefix(1).contains(where: { containsKinzi($0.surface) }),
                "akhgar_noKinzi",
                detail: "top='\(akhgar.candidates.first?.surface ?? "")'"
            )
            // `ankgar` and `ampgar` must remain Pali stacks (`အန္ကဂါ` /
            // `အမ္ပဂါ`), not nga-kinzi.
            let kway = engine.update(buffer: "kway", context: [])
            ctx.assertFalse(
                kway.candidates.prefix(1).contains(where: { containsKinzi($0.surface) }),
                "kway_noKinzi",
                detail: "top='\(kway.candidates.first?.surface ?? "")'"
            )
        },

        // Existing asat-vowel kinzi cases must continue to fire.
        TestCase("inferredKinzi_existingAsatVowelSitesUntouched") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for input in ["mingalarpar", "yinggar", "thinggyan", "bingala"] {
                assertTopHasKinzi(ctx, engine: engine, input: input)
            }
        },
    ])
}
