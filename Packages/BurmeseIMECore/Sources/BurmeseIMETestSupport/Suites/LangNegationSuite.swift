import Foundation
import BurmeseIMECore

/// Step 4 / Tier 4 — C24 (negation circumfix).
///
/// Standard Burmese negation is the circumfix `မ V ဘူး`. Both
/// affixes appear; either alone is ungrammatical. The IME must
/// surface the leading `မ` and the trailing `ဘူး` together when
/// the user types the canonical input.
public enum LangNegationSuite {

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

    private static func panelHasNegationFrame(
        _ ctx: TestContext,
        input: String
    ) {
        guard let engine = bundledEngine(ctx) else { return }
        let surfaces = engine.update(buffer: input, context: []).candidates.map(\.surface)
        let frame = surfaces.contains {
            $0.hasPrefix("မ") && $0.range(of: "ဘူး", options: .literal) != nil
        }
        ctx.assertTrue(
            frame,
            input,
            detail: "expected 'မ…ဘူး' frame in any panel surface; got \(surfaces)"
        )
    }

    public static let suite = TestSuite(name: "LangNegation", cases: [

        TestCase("negation_mthwarbu_dontGo") { ctx in panelHasNegationFrame(ctx, input: "mthwarbu:") },
        TestCase("negation_mloubu_dontDo")   { ctx in panelHasNegationFrame(ctx, input: "mloubu:") },
        TestCase("negation_mhsibu_isNot")    { ctx in panelHasNegationFrame(ctx, input: "mhsibu:") },

        // Negative invariant: positive form must NOT trigger a
        // negation frame (defensive — keeps the affix detection
        // honest).
        TestCase("positive_loubpartal_noFrame") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let surfaces = engine.update(buffer: "loubpartal", context: []).candidates.map(\.surface)
            for s in surfaces {
                if s.hasPrefix("မ") && s.range(of: "ဘူး", options: .literal) != nil {
                    ctx.fail("loubpartal_falseNegation",
                             detail: "positive 'loubpartal' produced negation-shaped '\(s)'")
                    return
                }
            }
            ctx.assertTrue(true, "loubpartal_clean")
        },
    ])
}
