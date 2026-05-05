import Foundation
import BurmeseIMECore

/// Step 4 / Tier 3 — C19, C32 (multi-syllable native compounds and
/// proper nouns).
///
/// High-frequency native multi-syllable words must surface
/// correctly when typed in their canonical romanization. These
/// assertions run at the production-equivalent layer; they skip
/// cleanly when bundled artifacts are not available.
public enum LangNativeCompoundSuite {

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

    public static let suite = TestSuite(name: "LangNativeCompound", cases: [

        // C19-* — common native compounds.
        TestCase("compound_lunar_patient")    { ctx in panelContains(ctx, input: "lunar",    surface: "လူနာ") },
        TestCase("compound_hsarar_teacher_canonical")   { ctx in panelContains(ctx, input: "hsarar",   surface: "ဆရာ") },
        TestCase("compound_hsararma_teacher_canonical") { ctx in panelContains(ctx, input: "hsararma", surface: "ဆရာမ") },
        TestCase("compound_hsayar_teacher")   { ctx in panelContains(ctx, input: "hsayar",   surface: "ဆရာ") },
        TestCase("compound_hsayarma_teacher") { ctx in panelContains(ctx, input: "hsayarma", surface: "ဆရာမ") },
        TestCase("compound_panyar_knowledge") { ctx in panelContains(ctx, input: "panyar", surface: "ပညာ") },

        // C32-* — proper nouns / lexicalised forms.
        TestCase("propnoun_rankown")  { ctx in panelContains(ctx, input: "rankown",  surface: "ရန်ကုန်") },
        TestCase("propnoun_arsha")    { ctx in panelContains(ctx, input: "arsha",    surface: "အာရှ") },
        TestCase("propnoun_america")  { ctx in panelContains(ctx, input: "ahmayri.kan", surface: "အမေရိကန်") },
    ])
}
