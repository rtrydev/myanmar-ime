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

        // Single-site liberal-only buffers: `<C><V><coda><C>` where
        // the coda/lower pair is cross-class (liberal-only) and the
        // rest of the buffer is otherwise plain. The acceptance bar
        // for task 04 is that the top candidate must NOT carry a
        // virama at the cross-class position. Buffers whose
        // transliteration carries an `r` (Pali/Sanskrit hint —
        // `karma`, `dharma`, `brahma`, `yarpadma`) are the carve-out:
        // those are intentionally allowed to keep the virama at top.
        TestCase("liberalOnlySingleSite_noViramaAtTop") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            // Each entry pairs a cross-class coda+lower combination
            // (different phonetic classes — would only stack via the
            // liberal rule) with a buffer that would otherwise be a
            // plain Burmese compound.
            let cases = [
                "takmaung",  // velar coda + labial lower (k+m)
                "pakta",     // velar coda + dental lower (k+t)
                "satka",     // dental coda + velar lower (t+k)
                "patma",     // dental coda + labial lower (t+m)
                "sapna",     // labial coda + dental lower (p+n)
                "kabna",     // labial coda + dental lower (b+n)
                "kakna",     // velar coda + dental lower (k+n)
                "lakta",     // velar coda + dental lower (k+t) under liquid onset
                "nakpa",     // velar coda + labial lower (k+p)
            ]
            for input in cases {
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                let hasVirama = top.unicodeScalars.contains(where: { $0.value == 0x1039 })
                ctx.assertFalse(
                    hasVirama,
                    input,
                    detail: "top='\(top)' carries cross-class virama; expected no-stack form"
                )
            }
        },

        // The `kawatta` case from the task spec: the same-class `tt`
        // stack is strict-valid and must reach the panel. The top
        // ranking depends on how the parser interprets the `aw`
        // diphthong vs explicit `wa`, and that choice is outside the
        // scope of task 04 — what task 04 guarantees is that the
        // strict-stack form (`ka + wa + tta`, with virama on `tt`)
        // appears in the panel for the user to pick.
        TestCase("kawatta_strictStackReachesPanel") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            // ကဝတ္တ = 1000 101D 1010 1039 1010
            let expectedScalars: [UInt32] = [0x1000, 0x101D, 0x1010, 0x1039, 0x1010]
            let state = engine.update(buffer: "kawatta", context: [])
            let found = state.candidates.contains { c in
                Array(c.surface.unicodeScalars.map(\.value)) == expectedScalars
            }
            ctx.assertTrue(
                found,
                "kawatta",
                detail: "ကဝတ္တ missing from panel; got \(state.candidates.prefix(6).map(\.surface))"
            )
        },

        // Negative regression for the spec's own example: `mintara`
        // shows the guard already worked (no liberal cross-class
        // stack at top). Asserts the top doesn't add one back.
        TestCase("mintara_noLiberalStack") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "mintara", context: [])
            let top = state.candidates.first?.surface ?? ""
            let hasVirama = top.unicodeScalars.contains(where: { $0.value == 0x1039 })
            ctx.assertFalse(
                hasVirama,
                "mintara",
                detail: "top='\(top)' acquired a cross-class virama"
            )
        },

        // Carve-out: Pali/Sanskrit transliterations carrying `r` keep
        // their cross-class stack at top via the liberal-inference
        // path. Verifies the gate isn't over-aggressive.
        TestCase("paliRTransliterations_keepStackAtTop") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for input in ["yarpadma", "tarbandana", "mantara"] {
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top.unicodeScalars.contains(where: { $0.value == 0x1039 }),
                    input,
                    detail: "top='\(top)' lost its virama stack"
                )
            }
        },
    ])
}
