import Foundation
import BurmeseIMECore

/// Step 4 / Tier 4 — C25 (polite forms).
///
/// The polite particle `ပါ` softens any verb; combined with `တယ်`
/// it forms the polite declarative `ပါတယ်`, and with `ဘူး` it
/// forms the polite negative `မ V ပါဘူး`. The IME must produce
/// these compound particles as a single rank-0 surface.
public enum LangPolitenessSuite {

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

    private static func panelContainsSubstring(
        _ ctx: TestContext,
        input: String,
        substring: String,
        label: String
    ) {
        guard let engine = bundledEngine(ctx) else { return }
        let surfaces = engine.update(buffer: input, context: []).candidates.map(\.surface)
        let hit = surfaces.contains { $0.range(of: substring, options: .literal) != nil }
        ctx.assertTrue(
            hit,
            label,
            detail: "expected substring '\(substring)' in any panel surface for '\(input)'; got \(surfaces)"
        )
    }

    public static let suite = TestSuite(name: "LangPoliteness", cases: [

        TestCase("polite_mingalarpar_blessing") { ctx in
            panelContainsSubstring(ctx, input: "mingalarpar", substring: "ပါ", label: "ပါ in မင်္ဂလာပါ")
        },

        // ◌ယ် (ya-asat) is romanized `e`, so the polite declarative
        // suffix `ပါတယ်` is typed as `parte`.
        TestCase("polite_loubparte_polite") { ctx in
            panelContainsSubstring(ctx, input: "loubparte", substring: "ပါတယ်", label: "ပါတယ်")
        },

        TestCase("polite_mloubparbu_negativePolite") { ctx in
            // ပါ requires `par` (with `ar` rule = aa); `pa` alone
            // gives bare ပ.
            panelContainsSubstring(ctx, input: "mloubparbu:", substring: "ပါဘူး", label: "ပါဘူး")
        },

        TestCase("polite_thwarparte") { ctx in
            panelContainsSubstring(ctx, input: "thwar:parte", substring: "ပါတယ်", label: "ပါတယ် in သွားပါတယ်")
        },
    ])
}
