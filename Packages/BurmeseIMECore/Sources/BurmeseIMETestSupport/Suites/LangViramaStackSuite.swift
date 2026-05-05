import Foundation
import BurmeseIMECore

/// Step 4 / Tier 3 — C13, C14, C15, C17 (virama stacking).
///
/// Native Burmese strictly admits same-class virama stacks (velar /
/// palatal / dental / labial / retroflex within their own class).
/// Cross-class stacks (k+ya, k+wa, t+ya etc.) must not surface as
/// rank-0 native syllables, although Pali/Sanskrit loanwords with
/// `-ha` as the lower member are tolerated. Great Sa (ဿ U+103F) is
/// a single codepoint historically derived from a stacked sa-sa.
public enum LangViramaStackSuite {

    private static func bareEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

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

    private static func panelContains(
        _ ctx: TestContext,
        engine: BurmeseEngine,
        input: String,
        scalars: [UInt32],
        label: String
    ) {
        let needle = String(scalars.compactMap { Unicode.Scalar($0).map { Character($0) } })
        let surfaces = engine.update(buffer: input, context: []).candidates.map(\.surface)
        let hit = surfaces.contains { $0.range(of: needle, options: .literal) != nil }
        ctx.assertTrue(
            hit,
            label,
            detail: "expected \(needle) in panel for '\(input)'; got \(surfaces)"
        )
    }

    public static let suite = TestSuite(name: "LangViramaStack", cases: [

        // C13-* — same-class native stacks.
        TestCase("stack_kk_velar") { ctx in
            panelContains(ctx, engine: bareEngine(), input: "k+ka",
                          scalars: [0x1000, 0x1039, 0x1000], label: "က္က")
        },
        TestCase("stack_gg_velar") { ctx in
            panelContains(ctx, engine: bareEngine(), input: "g+ga",
                          scalars: [0x1002, 0x1039, 0x1002], label: "ဂ္ဂ")
        },
        TestCase("stack_ss_palatal") { ctx in
            panelContains(ctx, engine: bareEngine(), input: "s+sa",
                          scalars: [0x1005, 0x1039, 0x1005], label: "စ္စ")
        },
        TestCase("stack_tt_dental") { ctx in
            panelContains(ctx, engine: bareEngine(), input: "t+ta",
                          scalars: [0x1010, 0x1039, 0x1010], label: "တ္တ")
        },
        TestCase("stack_nd_dental") { ctx in
            panelContains(ctx, engine: bareEngine(), input: "n+da",
                          scalars: [0x1014, 0x1039, 0x1012], label: "န္ဒ")
        },
        TestCase("stack_pp_labial") { ctx in
            panelContains(ctx, engine: bareEngine(), input: "p+pa",
                          scalars: [0x1015, 0x1039, 0x1015], label: "ပ္ပ")
        },
        TestCase("stack_mm_labial") { ctx in
            panelContains(ctx, engine: bareEngine(), input: "m+ma",
                          scalars: [0x1019, 0x1039, 0x1019], label: "မ္မ")
        },

        // C14-* — cross-class rejection: rank-0 surface should not
        // be the literal cross-class stack.
        TestCase("stack_kya_notRank0Native") { ctx in
            // `k+ya` stacked → ka + virama + ya, cross-class.
            // Engine must not produce that as a rank-0 native form.
            guard let engine = bundledEngine(ctx) else { return }
            let surfaces = engine.update(buffer: "k+ya", context: []).candidates.map(\.surface)
            let needle = String([0x1000, 0x1039, 0x101A].compactMap { Unicode.Scalar($0).map { Character($0) } })
            let topIsLiteralStack = surfaces.first?.range(of: needle, options: .literal) != nil
            ctx.assertFalse(
                topIsLiteralStack,
                "k+ya cross-class",
                detail: "rank-0 == literal cross-class stack \(needle); panel=\(surfaces)"
            )
        },

        TestCase("stack_kwa_notRank0Native") { ctx in
            // `k+wa` cross-class — distinct from medial wa-swe `kwa`.
            guard let engine = bundledEngine(ctx) else { return }
            let surfaces = engine.update(buffer: "k+wa", context: []).candidates.map(\.surface)
            let needle = String([0x1000, 0x1039, 0x101D].compactMap { Unicode.Scalar($0).map { Character($0) } })
            let topIsLiteralStack = surfaces.first?.range(of: needle, options: .literal) != nil
            ctx.assertFalse(
                topIsLiteralStack,
                "k+wa cross-class",
                detail: "rank-0 == literal cross-class stack; panel=\(surfaces)"
            )
        },

        // C15-* — Pali / Sanskrit loanword tolerance.
        TestCase("stack_brahma_loanword") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            // "Brahma" — should produce ဗြဟ္မ as a candidate.
            panelContains(ctx, engine: engine, input: "brahma",
                          scalars: [0x1017, 0x103C, 0x101F, 0x1039, 0x1019],
                          label: "ဗြဟ္မ")
        },

        // C17-* — Great Sa (ဿ U+103F).
        TestCase("greatSa_inherent") { ctx in
            panelContains(ctx, engine: bareEngine(), input: "ssa",
                          scalars: [0x103F], label: "ဿ")
        },
        TestCase("greatSa_aaShape") { ctx in
            // Great sa is non-descender; takes round aa.
            panelContains(ctx, engine: bareEngine(), input: "ssar",
                          scalars: [0x103F, 0x102C], label: "ဿာ")
        },
    ])
}
