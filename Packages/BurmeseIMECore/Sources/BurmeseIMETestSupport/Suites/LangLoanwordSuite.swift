import Foundation
import BurmeseIMECore

/// Step 4 / Tier 4 — C21 (loanword romanizations).
///
/// English / Pali / Sanskrit loanwords preserve their distinctive
/// orthographic features (kinzi, ya-yit /r/, ha-htoe). These are
/// production-equivalent assertions.
public enum LangLoanwordSuite {

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

    public static let suite = TestSuite(name: "LangLoanword", cases: [

        TestCase("loanword_america")  { ctx in panelContains(ctx, input: "ahmayri.kan", surface: "အမေရိကန်") },
        TestCase("loanword_intarnet") { ctx in panelContains(ctx, input: "intarnet", surface: "အင်တာနက်") },
        TestCase("loanword_arsha")    { ctx in panelContains(ctx, input: "arsha",    surface: "အာရှ") },
        TestCase("loanword_brahma")   { ctx in panelContains(ctx, input: "brahma",   surface: "ဗြဟ္မ") },

        // Cross-cutting invariant: loanwords must produce
        // pure-Myanmar surfaces (no leaked ASCII).
        TestCase("loanword_noAsciiLeak") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for input in ["ahmayri.kan", "intarnet", "arsha", "brahma"] {
                let top = engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
                let hasAscii = top.unicodeScalars.contains { $0.value >= 0x21 && $0.value <= 0x7E }
                ctx.assertFalse(
                    hasAscii,
                    input,
                    detail: "rank-0 leaks ASCII: '\(top)'"
                )
            }
        },
    ])
}
