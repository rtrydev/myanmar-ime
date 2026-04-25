import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for task 02: stack inference must not split aspirated /
/// cluster-alias consonant digraphs (`dh`, `ph`, `gh`, `bh`, `th`,
/// `sh`, `hm`, …) into `<base> + virama + <ha-or-medial>`. The
/// inferred-`+` site must respect the digraph that the next two
/// (or three) ASCII letters form, not chop it in half.
public enum ConsonantDigraphIntegritySuite {

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

    /// `<base> + U+1039 + U+101F` is the spurious `<C> + virama + ha`
    /// shape inference produces when it splits an aspirated digraph
    /// at the wrong byte. Real native subscripts never use ha (101F)
    /// as the lower; aspirated consonants are atomic.
    private static func surfaceHasViramaHa(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        guard scalars.count >= 2 else { return false }
        for i in 0..<(scalars.count - 1) {
            if scalars[i].value == 0x1039 && scalars[i + 1].value == 0x101F {
                return true
            }
        }
        return false
    }

    public static let suite = TestSuite(name: "ConsonantDigraphIntegrity", cases: [

        // Aspirated digraphs (`dh`, `ph`, `gh`, `bh`, `th`) followed by
        // a same-class double consonant stack site (`mm`, `nn`, `tt`).
        // The stack inference must not slice the digraph open at `+`.
        TestCase("aspiratedDigraphs_notSplitByStackInference") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for input in [
                "kadhamma",
                "kaphamma",
                "kaghamma",
                "kabhamma",
                "kathamma",
            ] {
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    !surfaceHasViramaHa(top),
                    input,
                    detail: "top='\(top)' contains spurious U+1039 U+101F (digraph split)"
                )
            }
        },

        // Cluster-alias digraph: `sh` → ရှ (ra + ha-htoe medial). Must
        // not be split into ra + virama + ha by inference.
        TestCase("clusterAliasShDigraph_notSplitByStackInference") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "kashamma", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertTrue(
                !surfaceHasViramaHa(top),
                "kashamma",
                detail: "top='\(top)' contains spurious U+1039 U+101F (sh split)"
            )
        },

        // Inference-level guard: the `+` insertion must not land
        // *between* the two letters of a consonant digraph.
        TestCase("inferImplicit_doesNotSplitConsonantDigraphs") { ctx in
            // Each entry: input, the buffer position the `+` must NOT
            // land at (the index inside the original buffer).
            let cases: [(input: String, forbiddenIndex: Int)] = [
                ("kadhamma", 3),  // between `d` (idx 2) and `h` (idx 3)
                ("kaphamma", 3),
                ("kaghamma", 3),
                ("kabhamma", 3),
                ("kathamma", 3),
                ("kashamma", 3),
            ]
            for c in cases {
                guard let inferred = BurmeseEngine.inferImplicitStackMarkers(c.input) else {
                    continue
                }
                let chars = Array(inferred.input)
                for (idx, ch) in chars.enumerated() where ch == "+" {
                    let originalIdx = idx - chars[..<idx].filter({ $0 == "+" }).count
                    ctx.assertTrue(
                        originalIdx != c.forbiddenIndex,
                        c.input,
                        detail: "stack `+` split digraph at original index \(c.forbiddenIndex); inferred='\(inferred.input)'"
                    )
                }
            }
        },

        // Regression: real Pali stacks must still parse correctly.
        TestCase("paliStacks_stillParseAfterDigraphGuard") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let viramaScalar: UInt32 = 0x1039
            for input in ["atta", "dhamma", "brahma"] {
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top.unicodeScalars.contains(where: { $0.value == viramaScalar }),
                    input,
                    detail: "top='\(top)' lost its virama stack"
                )
            }
        },
    ])
}
