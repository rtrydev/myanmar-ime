import Foundation
import BurmeseIMECore

/// Step 4 / Tier 3 — C31 (reduplication).
///
/// Burmese has productive reduplication for emphasis (`မြန်မြန်`
/// "very fast", `ကျယ်ကျယ်` "loudly"). Orthographically this is
/// just the same syllable typed twice in sequence.
public enum LangReduplicationSuite {

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
            detail: "expected '\(surface)' in panel; got \(surfaces)"
        )
    }

    public static let suite = TestSuite(name: "LangReduplication", cases: [

        TestCase("redup_myanmyan") { ctx in panelContains(ctx, input: "myanmyan", surface: "မြန်မြန်") },
        TestCase("redup_kyekye")   { ctx in panelContains(ctx, input: "kyekye",   surface: "ကျယ်ကျယ်") },

        // Negative invariant: the reduplicated surface should not
        // collapse the two syllables into one (no `မြန်` only).
        TestCase("redup_doubleSyllable") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let surfaces = engine.update(buffer: "myanmyan", context: []).candidates.map(\.surface)
            let hasDouble = surfaces.contains { $0.contains("မြန်မြန်") || ($0.range(of: "မြန်", options: .literal) != nil && $0.utf8.count > "မြန်".utf8.count) }
            ctx.assertTrue(
                hasDouble,
                "myanmyan_double",
                detail: "expected doubled syllable in panel; got \(surfaces)"
            )
        },
    ])
}
