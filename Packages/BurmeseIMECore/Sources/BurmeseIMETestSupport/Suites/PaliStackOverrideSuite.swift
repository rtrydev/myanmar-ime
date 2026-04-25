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

        // Lint: every override surface must contain a virama (U+1039)
        // sitting between two stackable consonants. Same-class entries
        // (`ganda`, `vandana`) are intentional rank-promotions over
        // the asat-closed parser-native rendering; cross-class entries
        // (`padma`) are the only path to the canonical loanword shape
        // at all. Both must pass `isValidStackLiberal` — the entry is
        // a typo if either neighbour isn't in the stackable set
        // (e.g. ya, wa, sa) or if the virama lands at the surface edge.
        TestCase("paliStackOverrides_viramaSitsBetweenStackableConsonants") { ctx in
            for (reading, surface) in BurmeseEngine.paliStackOverrides {
                let scalars = Array(surface.unicodeScalars.map(\.value))
                guard let viramaIdx = scalars.firstIndex(of: 0x1039) else {
                    ctx.assertTrue(
                        false,
                        reading,
                        detail: "override surface '\(surface)' lacks U+1039 (virama)"
                    )
                    continue
                }
                ctx.assertTrue(
                    viramaIdx >= 1 && viramaIdx + 1 < scalars.count,
                    reading,
                    detail: "virama at edge of '\(surface)' — needs an upper and a lower consonant"
                )
                guard viramaIdx >= 1, viramaIdx + 1 < scalars.count else { continue }
                let upper = scalars[viramaIdx - 1]
                let lower = scalars[viramaIdx + 1]
                guard let upperChar = Unicode.Scalar(upper).map(Character.init),
                      let lowerChar = Unicode.Scalar(lower).map(Character.init) else {
                    ctx.assertTrue(false, reading, detail: "non-scalar consonant around virama")
                    continue
                }
                ctx.assertTrue(
                    Grammar.isValidStackLiberal(upper: upperChar, lower: lowerChar),
                    reading,
                    detail: "override '\(surface)' has a non-stackable consonant adjacent to the virama (\(String(format: "%04X", upper)) + 1039 + \(String(format: "%04X", lower)))"
                )
                ctx.assertTrue(
                    upper != lower,
                    reading,
                    detail: "override '\(surface)' has identical consonants on both sides of the virama — likely a typo"
                )
            }
        },

        // Lint: every override reading must reduce to a sequence of
        // recognised romanization syllables. Catches typos that
        // wouldn't appear in any user-typed buffer (e.g. an `x` or
        // an unsupported digit) and would silently never trigger.
        TestCase("paliStackOverrides_readingsAreParseable") { ctx in
            let parser = SyllableParser()
            for (reading, _) in BurmeseEngine.paliStackOverrides {
                let candidates = parser.parseCandidates(reading, maxResults: 1)
                ctx.assertFalse(
                    candidates.isEmpty,
                    reading,
                    detail: "reading '\(reading)' produces no parser candidates — typo?"
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
