import Foundation
import BurmeseIMECore

public enum NumberMeasureWordsSuite {

    private static func makeSettings() -> (IMESettings, String) {
        let suiteName = "NumberMeasureWordsSuite.\(UUID().uuidString)"
        return (IMESettings(suiteName: suiteName), suiteName)
    }

    private static func cleanup(_ suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    public static let suite = TestSuite(name: "NumberMeasureWords", cases: [

        TestCase("pattern_year4digit") { ctx in
            ctx.assertTrue(NumberMeasureWords.Pattern.year4digit.matches("2024"), "2024")
            ctx.assertTrue(NumberMeasureWords.Pattern.year4digit.matches("1999"), "1999")
            ctx.assertFalse(NumberMeasureWords.Pattern.year4digit.matches("0999"), "leading0")
            ctx.assertFalse(NumberMeasureWords.Pattern.year4digit.matches("24"), "short")
            ctx.assertFalse(NumberMeasureWords.Pattern.year4digit.matches("20240"), "long")
        },

        TestCase("pattern_currencyGe100") { ctx in
            ctx.assertTrue(NumberMeasureWords.Pattern.currencyGe100.matches("100"), "100")
            ctx.assertTrue(NumberMeasureWords.Pattern.currencyGe100.matches("1000"), "1000")
            ctx.assertFalse(NumberMeasureWords.Pattern.currencyGe100.matches("99"), "99")
            ctx.assertFalse(NumberMeasureWords.Pattern.currencyGe100.matches("5"), "5")
        },

        TestCase("pattern_hourRange") { ctx in
            ctx.assertTrue(NumberMeasureWords.Pattern.hourGe1Le24.matches("1"), "1")
            ctx.assertTrue(NumberMeasureWords.Pattern.hourGe1Le24.matches("24"), "24")
            ctx.assertFalse(NumberMeasureWords.Pattern.hourGe1Le24.matches("0"), "0")
            ctx.assertFalse(NumberMeasureWords.Pattern.hourGe1Le24.matches("25"), "25")
        },

        TestCase("pattern_any") { ctx in
            ctx.assertTrue(NumberMeasureWords.Pattern.any.matches("0"), "zero")
            ctx.assertTrue(NumberMeasureWords.Pattern.any.matches("999999"), "large")
        },

        TestCase("candidates_year_returnsYearPattern") { ctx in
            let picks = NumberMeasureWords.shared
                .candidates(forDigits: "2024", limit: 5)
                .map(\.measureWord)
            ctx.assertTrue(picks.contains("ခုနှစ်"),
                           "yearSuffix", detail: "picks=\(picks)")
        },

        TestCase("candidates_smallNumber_excludesYearAndCurrency") { ctx in
            let picks = NumberMeasureWords.shared
                .candidates(forDigits: "5", limit: 5)
                .map(\.measureWord)
            ctx.assertFalse(picks.contains("ခုနှစ်"), "noYearFor5")
            ctx.assertFalse(picks.contains("ကျပ်"), "noCurrencyFor5")
            ctx.assertTrue(picks.contains("ခု"), "genericMeasure")
        },

        TestCase("candidates_largeNumber_includesCurrency") { ctx in
            let picks = NumberMeasureWords.shared
                .candidates(forDigits: "1000", limit: 5)
                .map(\.measureWord)
            ctx.assertTrue(picks.contains("ကျပ်"),
                           "currencySuffix", detail: "picks=\(picks)")
        },

        TestCase("candidates_honorsLimit") { ctx in
            let picks = NumberMeasureWords.shared
                .candidates(forDigits: "2024", limit: 2)
            ctx.assertTrue(picks.count <= 2, "limit2", detail: "count=\(picks.count)")
        },

        TestCase("candidates_sortedByScoreDescending") { ctx in
            let picks = NumberMeasureWords.shared
                .candidates(forDigits: "2024", limit: 10)
            if picks.count >= 2 {
                for i in 1..<picks.count {
                    ctx.assertTrue(picks[i - 1].score >= picks[i].score,
                                   "monotonicAt\(i)",
                                   detail: "\(picks[i-1].score) < \(picks[i].score)")
                }
            }
        },

        TestCase("candidates_nonDigitInput_empty") { ctx in
            ctx.assertTrue(NumberMeasureWords.shared.candidates(forDigits: "", limit: 2).isEmpty,
                           "empty")
            ctx.assertTrue(NumberMeasureWords.shared.candidates(forDigits: "12a", limit: 2).isEmpty,
                           "mixed")
        },

        TestCase("candidates_zeroLimit_empty") { ctx in
            ctx.assertTrue(NumberMeasureWords.shared.candidates(forDigits: "100", limit: 0).isEmpty,
                           "zeroLimit")
        },

        TestCase("candidates_missingBundleResource_emptyList") { ctx in
            let loader = NumberMeasureWords(
                bundle: .main,
                resourceName: "NumberMeasureWords-does-not-exist",
                resourceExtension: "tsv"
            )
            ctx.assertEqual(loader.candidates(forDigits: "2024", limit: 5), [],
                            "missingResource")
        },

        TestCase("engine_year_addsYearSuffix_whenEnabled") { ctx in
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.numberMeasureWordsEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "2024", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("၂၀၂၄"),
                           "baselineDigits", detail: "surfaces=\(surfaces)")
            ctx.assertTrue(surfaces.contains("၂၀၂၄ ခုနှစ်"),
                           "yearSuffix", detail: "surfaces=\(surfaces)")
        },

        TestCase("engine_digitOnly_unchanged_whenDisabled") { ctx in
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.numberMeasureWordsEnabled = false
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "2024", context: [])
            let surfaces = Set(state.candidates.map(\.surface))
            ctx.assertEqual(surfaces, Set(["၂၀၂၄", "2024"]),
                            "baselineOnly_\(surfaces)")
        },

        TestCase("engine_currency_addsCurrencySuffix") { ctx in
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.numberMeasureWordsEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "1000", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("၁၀၀၀ ကျပ်"),
                           "currencySuffix", detail: "surfaces=\(surfaces)")
        },

        TestCase("engine_limit_capsAtTwoExpansions") { ctx in
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.numberMeasureWordsEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "2024", context: [])
            ctx.assertTrue(state.candidates.count <= 4,
                           "atMost4", detail: "count=\(state.candidates.count)")
        },
    ])
}
