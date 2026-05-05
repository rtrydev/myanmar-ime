import Foundation
import BurmeseIMECore

/// Step 4 / Tier 4 — C22 (verb particles), C23 (postpositions).
///
/// The most frequent particles in Burmese are တယ် ပြီ မယ် နေ ပါ ဘူး
/// (verb particles) and ကို က မှာ နဲ့ ရဲ့ များ (postpositions).
/// They appear at the tail of multi-syllable inputs and must merge
/// correctly into the surface — neither dropped nor split.
public enum LangParticleSuite {

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

    public static let suite = TestSuite(name: "LangParticle", cases: [

        // C22-* — verb particles tail-merging. The romanization for
        // ◌ယ် (ya-asat) is `e`, so `တယ်` is `te` and `မယ်` is `me`.
        // The romanization for သွား is `thwar:` (sa + medial-wa-swe
        // + heavy aa).
        TestCase("particle_te_declarative") { ctx in
            panelContainsSubstring(ctx, input: "thwar:parte", substring: "ပါတယ်", label: "ပါတယ်")
        },
        TestCase("particle_pyi_perfective") { ctx in
            panelContainsSubstring(ctx, input: "thwar:pyi", substring: "ပြီ", label: "ပြီ")
        },
        TestCase("particle_me_future") { ctx in
            panelContainsSubstring(ctx, input: "thwar:me", substring: "မယ်", label: "မယ်")
        },
        TestCase("particle_nay_progressive") { ctx in
            panelContainsSubstring(ctx, input: "thwar:nay", substring: "နေ", label: "နေ")
        },

        // C23-* — postpositions
        TestCase("postpos_ko_accusative") { ctx in
            panelContainsSubstring(ctx, input: "kunko", substring: "ကို", label: "ကို")
        },
        TestCase("postpos_mhar_locative") { ctx in
            panelContainsSubstring(ctx, input: "kownhmar", substring: "မှာ", label: "မှာ")
        },
        TestCase("postpos_myar_plural") { ctx in
            panelContainsSubstring(ctx, input: "lumyar:", substring: "များ", label: "များ")
        },
    ])
}
