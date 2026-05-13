import Foundation
import BurmeseIMECore

/// Panel reachability for the native Burmese ya/ra homophony when the
/// user types `y` for ရ across a syllable boundary. The single-syllable
/// case (`yay` -> ရေ) and the lexicon-emitted compound case
/// (`hsayar` -> ဆရာ) were already covered by the lookup-time alias
/// rewrite; this suite locks in the parser-synthesized compound case
/// (`hnaryay` -> နှာရေ, `panyay` -> ပန်ရေ, `lwanyay` -> လွန်ရေ, …)
/// where the lexicon does NOT carry the compound and the parser's
/// canonical romanization is what produces the surface.
///
/// CLAUDE.md §7 reachability rule: the intended surface must be in the
/// candidate panel; top 3 is strongly preferred but not required.
public enum BareYaRaHomophonyAliasSuite {

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
            detail: "expected '\(surface)' in panel for '\(input)'; got top10=\(Array(surfaces.prefix(10)))"
        )
    }

    private static func panelDoesNotContain(
        _ ctx: TestContext,
        input: String,
        surface: String
    ) {
        guard let engine = bundledEngine(ctx) else { return }
        let surfaces = engine.update(buffer: input, context: []).candidates.map(\.surface)
        ctx.assertFalse(
            surfaces.contains(surface),
            input,
            detail: "did NOT expect '\(surface)' in panel for '\(input)'; got top10=\(Array(surfaces.prefix(10)))"
        )
    }

    private static func panelTopIs(
        _ ctx: TestContext,
        input: String,
        surface: String
    ) {
        guard let engine = bundledEngine(ctx) else { return }
        let top = engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
        ctx.assertTrue(
            top == surface,
            input,
            detail: "expected '\(surface)' at rank 0 for '\(input)'; got '\(top)'"
        )
    }

    public static let suite = TestSuite(name: "BareYaRaHomophonyAlias", cases: [

        // The canonical user case: `hnaryay` (user typed `y` for the
        // second syllable's onset) reaches the same `နှာရေ` surface
        // that `hnarray` already produced. The `r`-coda of `-ar` must
        // be recognised as a syllable-ending terminator so the
        // y -> r alias site check fires on the trailing `yay`
        // syllable's onset.
        TestCase("hnaryay_reaches_hnamucus")  { ctx in panelContains(ctx, input: "hnaryay",  surface: "နှာရေ") },
        TestCase("hnarray_canonical_remains") { ctx in panelContains(ctx, input: "hnarray",  surface: "နှာရေ") },

        // Same gap with other coda-bearing prior syllables.
        TestCase("panyay_reaches_panwater")   { ctx in panelContains(ctx, input: "panyay",   surface: "ပန်ရေ") },
        TestCase("lwanyay_reaches_lwanwater") { ctx in panelContains(ctx, input: "lwanyay",  surface: "လွန်ရေ") },
        TestCase("pawyay_reaches_pawwater")   { ctx in panelContains(ctx, input: "pawyay",   surface: "ပေါ်ရေ") },
        TestCase("anyay_reaches_anwater")     { ctx in panelContains(ctx, input: "anyay",    surface: "အန်ရေ") },

        // Initial-onset y -> r alias for parser-synthesized compounds.
        TestCase("yarray_reaches_yawater")    { ctx in panelContains(ctx, input: "yarray",   surface: "ရာရေ") },
        TestCase("rayyay_reaches_water_water"){ ctx in panelContains(ctx, input: "rayyay",   surface: "ရေရေ") },
        TestCase("paryay_reaches_parwater")   { ctx in panelContains(ctx, input: "paryay",   surface: "ပါရေ") },

        // The lookup-time alias keeps the lexicon compounds reachable
        // both ways (`hsararma` canonical and `hsayarma` alias).
        TestCase("hsararma_canonical_remains"){ ctx in panelContains(ctx, input: "hsararma", surface: "ဆရာမ") },
        TestCase("hsayarma_alias_reaches")    { ctx in panelContains(ctx, input: "hsayarma", surface: "ဆရာမ") },

        // Explicit `+` boundary pins the consonant the user typed —
        // the alias swap must NOT displace the canonical `ka + ya`
        // surface for `k+ya`.
        TestCase("plus_ya_keeps_yapin_rank0") { ctx in panelTopIs(ctx, input: "k+ya", surface: "ကယ") },
    ])
}
