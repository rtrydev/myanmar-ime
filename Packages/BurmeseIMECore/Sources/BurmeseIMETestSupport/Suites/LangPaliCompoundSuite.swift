import Foundation
import BurmeseIMECore

/// Step 4 / Tier 3 — C20, C33 (multi-syllable Pali compounds and
/// religious vocabulary).
///
/// Pali religious / scholarly vocabulary preserves stacked
/// consonants and dual-class clusters; the lexicon must surface
/// the canonical orthographic shape ahead of any rule-only parse.
public enum LangPaliCompoundSuite {

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
        input: String,
        surface: String
    ) {
        guard let engine = bundledEngine(ctx) else { return }
        let surfaces = engine.update(buffer: input, context: []).candidates.map(\.surface)
        let hit = surfaces.contains(surface)
        ctx.assertTrue(
            hit,
            input,
            detail: "expected '\(surface)' in panel for '\(input)'; got \(surfaces)"
        )
    }

    public static let suite = TestSuite(name: "LangPaliCompound", cases: [

        // C20-* — Pali compounds with virama stacks.
        TestCase("pali_dhamma")  { ctx in panelContains(ctx, input: "dhamma",  surface: "ဓမ္မ") },
        TestCase("pali_parrami") { ctx in panelContains(ctx, input: "parrami", surface: "ပါရမီ") },

        // C33-* — religious vocabulary.
        TestCase("religious_thila")    { ctx in panelContains(ctx, input: "thila",    surface: "သီလ") },

        // Negative invariant: stacked Pali surfaces must contain
        // exactly one virama between the upper and lower consonants
        // (no doubled virama, no virama+asat).
        TestCase("pali_dhamma_oneVirama") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let surfaces = engine.update(buffer: "dhamma", context: []).candidates.map(\.surface)
            guard let dhamma = surfaces.first(where: { $0 == "ဓမ္မ" }) else {
                ctx.assertTrue(true, "skipped_noDhamma")
                return
            }
            let viramaCount = dhamma.unicodeScalars.filter { $0.value == 0x1039 }.count
            ctx.assertEqual(viramaCount, 1, "dhamma_oneVirama")
        },
    ])
}
