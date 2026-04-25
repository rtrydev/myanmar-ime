import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for mid-buffer kinzi / Pali-stack inference once the
/// preceding syllables have run through ASCII vowel letters
/// (`r`/`w`/`y`) that are not actually medials of the *current*
/// onset. See `tasks/01-stack-inference-blocked-by-non-medial-y-r-w-letters.md`.
public enum MidBufferStackInferenceSuite {

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
            detail: "top='\(top)' all=\(state.candidates.prefix(5).map(\.surface))",
            file: file,
            line: line
        )
    }

    public static let suite = TestSuite(name: "MidBufferStackInference", cases: [

        // Inputs whose prefixes contain `r`/`w`/`y` letters that are
        // part of a *vowel* (`ar`, `aw`, `ay`) — NOT medials of the
        // current syllable's onset. The kinzi at `min+g` must still
        // fire as the top candidate. Multi-stack inputs whose primary
        // pool is also poisoned by an unwanted *liberal* cross-class
        // inferred site are out of scope here — see task 04.
        TestCase("kinzi_firesAfterVowelLetterPrefix") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for input in [
                "tarminga",
                "kawminga",
                "yawminga",
                "kwyantawminga",
                "kwyantawminglarpar",
            ] {
                assertTopHasKinzi(ctx, engine: engine, input: input)
            }
        },

        // Same shape, but tested at the inference level so a passing
        // top-rank candidate cannot mask a missing `+` insertion.
        // Includes the multi-stack inputs whose `+` insertion is
        // correct even if the resulting candidate is out-ranked by
        // the no-`+` parse (task 04 owns the ranking fix).
        TestCase("inferImplicit_firesAfterVowelLetterPrefix") { ctx in
            for input in [
                "tarminga",
                "kawminga",
                "yawminga",
                "shinbyarminga",
                "pyinthitminga",
                "kwyantawminga",
                "kwyantawminglarpar",
            ] {
                guard let inferred = BurmeseEngine.inferImplicitStackMarkers(input) else {
                    ctx.assertTrue(false, input, detail: "no inferred stack site")
                    continue
                }
                ctx.assertTrue(
                    inferred.input.contains("+"),
                    input,
                    detail: "inferred='\(inferred.input)'"
                )
            }
        },

        // Negative case — the *current* syllable's onset is genuinely
        // medial-heavy. The narrower medial check must still reject
        // inferring `+` *between* the medial-heavy onset and its
        // following consonant. In `kwyanminga` the `kwy + an + m`
        // site at index 5 (`m`) sits behind the `kwy` onset with `w`
        // and `y` medials, so the `n+m` stack inference must NOT fire
        // at that position. (Kinzi at `min+g` is still allowed and
        // covered by the positive cases above.)
        TestCase("inferImplicit_rejectsCurrentOnsetMedials") { ctx in
            // Confirm the rejection by checking that the inferred output
            // does not contain a `+` immediately after the leading `kwy`
            // onset (i.e. between `n` at index 4 and `m` at index 5).
            // We do this by checking the absolute character position of
            // any inserted `+`.
            for input in ["kwyanmingar", "kwyanmuda"] {
                let inferred = BurmeseEngine.inferImplicitStackMarkers(input)
                if let inferred {
                    let chars = Array(inferred.input)
                    for (idx, ch) in chars.enumerated() where ch == "+" {
                        // Strip earlier `+` inserts when computing the
                        // position-in-the-original-buffer index.
                        let originalIdx = idx - chars[..<idx].filter({ $0 == "+" }).count
                        ctx.assertTrue(
                            originalIdx != 5,
                            input,
                            detail: "stack inserted at medial-heavy onset boundary; inferred='\(inferred.input)'"
                        )
                    }
                }
            }
        },

        // Mid-buffer Pali stacks behind a vowel-only prefix
        // (`mantara`, `tarbandana`, `yarpadma`). Each must produce a
        // virama-stack surface (U+1039) at the relevant boundary.
        TestCase("midBufferPaliStack_firesBehindVowelPrefix") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for input in ["mantara", "tarbandana", "yarpadma"] {
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top.unicodeScalars.contains(where: { $0.value == 0x1039 }),
                    input,
                    detail: "top='\(top)'"
                )
            }
        },

        // Mixed-stack inputs: a strict-valid kinzi site coexists with
        // a cross-class (liberal-only) inferred site. The strict-only
        // sibling parse generated by `inferImplicitStackMarkers` lets
        // the kinzi-only candidate compete without carrying the
        // unwanted liberal cross-class virama (task 04).
        TestCase("kinzi_winsTopWhenLiberalSiblingExists") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for input in [
                "takminga",        // tak+m liberal, min+g kinzi
                "shinbyarminga",   // shin+b liberal, min+g kinzi
                "pyinthitminga",   // t+m liberal, min+g kinzi
            ] {
                assertTopHasKinzi(ctx, engine: engine, input: input)
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                // The top candidate must NOT carry the unwanted
                // cross-class liberal virama (a U+1039 that comes
                // immediately after the medial-bearing onset's coda
                // letter — distinct from the kinzi marker
                // `U+1004 U+103A U+1039`).
                let scalars = Array(top.unicodeScalars.map(\.value))
                var unwantedVirama = false
                for i in 0..<scalars.count where scalars[i] == 0x1039 {
                    let prev = i >= 1 ? scalars[i - 1] : 0
                    let twoBack = i >= 2 ? scalars[i - 2] : 0
                    let isKinziMark = prev == 0x103A && twoBack == 0x1004
                    if !isKinziMark {
                        // Strict same-class stacks (e.g. min+ga has
                        // kinzi only) are flagged as the kinzi-mark
                        // path; cross-class virama (e.g. tak+m at
                        // U+1000 U+1039 U+1019) trips this.
                        unwantedVirama = true
                    }
                }
                ctx.assertFalse(
                    unwantedVirama,
                    "\(input).noCrossClassVirama",
                    detail: "top='\(top)' carries cross-class virama; expected kinzi-only"
                )
            }
        },
    ])
}
