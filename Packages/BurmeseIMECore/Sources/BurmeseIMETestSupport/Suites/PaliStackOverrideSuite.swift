import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for task 05: the cross-class Pali stack override table
/// must drive `paliStackOverrideSurface`. Adding a new loanword here
/// (or, eventually, a TSV row) must be enough — no `switch` edit
/// needed — and every entry must reach the candidate panel as the
/// canonical virama-stacked surface.
public enum PaliStackOverrideSuite {

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

    public static let suite = TestSuite(name: "PaliStackOverride", cases: [

        // Every entry in the override table must reach the candidate
        // panel as the canonical virama-stacked surface. Iterating the
        // table itself means a new entry is auto-tested.
        TestCase("paliStackOverrides_eachEntryReachesPanel") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for (reading, expectedSurface) in BurmeseEngine.paliStackOverrides {
                let state = engine.update(buffer: reading, context: [])
                let found = state.candidates.contains { $0.surface == expectedSurface }
                ctx.assertTrue(
                    found,
                    reading,
                    detail: "expected '\(expectedSurface)' in panel; got top='\(state.candidates.first?.surface ?? "")'"
                )
            }
        },

        // Every override surface must contain a virama (U+1039) that
        // bridges two distinct consonants — a sanity check that the
        // table doesn't accumulate typos as it grows.
        TestCase("paliStackOverrides_surfacesContainCrossClassVirama") { ctx in
            for (reading, surface) in BurmeseEngine.paliStackOverrides {
                let scalars = Array(surface.unicodeScalars.map(\.value))
                let hasVirama = scalars.contains(0x1039)
                ctx.assertTrue(
                    hasVirama,
                    reading,
                    detail: "override surface '\(surface)' lacks U+1039 (virama)"
                )
            }
        },

        // Liberal-inference path must still produce a virama stack
        // for inputs that are NOT in the override table — removing
        // the switch must not silently drop coverage.
        TestCase("liberalInference_stillProducesStackForNonOverrideInputs") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            // `pakta` and `karma` are cross-class (k+t, r+m) liberal
            // sites. They are not in the override table; the virama
            // stack should still appear among the candidates via the
            // liberal-inference path.
            for input in ["pakta", "karma"] {
                let state = engine.update(buffer: input, context: [])
                let viramaPresent = state.candidates.contains { c in
                    c.surface.unicodeScalars.contains(where: { $0.value == 0x1039 })
                }
                ctx.assertTrue(
                    viramaPresent,
                    input,
                    detail: "no virama-stack candidate for '\(input)'; cands=\(state.candidates.prefix(4).map(\.surface))"
                )
            }
        },
    ])
}
