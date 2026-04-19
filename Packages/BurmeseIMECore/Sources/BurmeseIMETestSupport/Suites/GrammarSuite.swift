import BurmeseIMECore

public enum GrammarSuite {
    public static let suite = TestSuite(name: "Grammar", cases: [

        TestCase("medialRa_ka_isLegal") { ctx in
            ctx.assertTrue(Grammar.canConsonantTakeMedial(Myanmar.ka, Myanmar.medialRa))
        },

        TestCase("medialYa_ka_isLegal") { ctx in
            ctx.assertTrue(Grammar.canConsonantTakeMedial(Myanmar.ka, Myanmar.medialYa))
        },

        TestCase("medialWa_ka_isLegal") { ctx in
            ctx.assertTrue(Grammar.canConsonantTakeMedial(Myanmar.ka, Myanmar.medialWa))
        },

        TestCase("medialHa_ka_isLegal") { ctx in
            ctx.assertTrue(Grammar.canConsonantTakeMedial(Myanmar.ka, Myanmar.medialHa))
        },

        TestCase("medialRa_nga_isIllegal") { ctx in
            ctx.assertFalse(Grammar.canConsonantTakeMedial(Myanmar.nga, Myanmar.medialRa))
        },

        TestCase("medialCombination_count") { ctx in
            ctx.assertEqual(Grammar.medialCombinations.count, 11)
        },

        TestCase("validateSyllable_ka_noMedials_ar") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.ka, medials: [], vowelRoman: "ar")
            ctx.assertGreaterThan(score, 0)
        },

        TestCase("validateSyllable_noOnset_standalone") { ctx in
            let score = Grammar.validateSyllable(
                onset: nil, medials: [], vowelRoman: "ay2")
            ctx.assertGreaterThan(score, 0)
        },

        TestCase("validateSyllable_noOnset_nonStandalone_lowPriority") { ctx in
            let score = Grammar.validateSyllable(
                onset: nil, medials: [], vowelRoman: "ar")
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "Expected score < 100, got \(score)")
        },

        TestCase("validateSyllable_medialHaPlusLongI_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.ka,
                medials: [Myanmar.medialHa],
                vowelRoman: "i:"
            )
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_medialHaPlusLongU_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.ka,
                medials: [Myanmar.medialHa],
                vowelRoman: "u:"
            )
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_medialHaPlusShortI_legal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.ka,
                medials: [Myanmar.medialHa],
                vowelRoman: "i"
            )
            ctx.assertGreaterThan(score, 0)
        },

        TestCase("validateSyllable_tripleMedialWithInherentVowel_legal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.ka,
                medials: [Myanmar.medialYa, Myanmar.medialWa, Myanmar.medialHa],
                vowelRoman: "a"
            )
            ctx.assertGreaterThan(score, 0)
        },

        TestCase("validateSyllable_tripleMedialWithComplexVowel_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.ka,
                medials: [Myanmar.medialYa, Myanmar.medialWa, Myanmar.medialHa],
                vowelRoman: "aung"
            )
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_palaRetroflexWithDiphthong_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.tta, medials: [], vowelRoman: "ote")
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_palaRetroflexWithSimpleVowel_legal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.tta, medials: [], vowelRoman: "i")
            ctx.assertGreaterThan(score, 0)
        },

        TestCase("validateSyllable_palaRetroflexWithAr_legal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.nna, medials: [], vowelRoman: "ar")
            ctx.assertGreaterThan(score, 0)
        },

        // MARK: - Virama Stack Legality

        TestCase("isValidStack_velarSameClass_isLegal") { ctx in
            ctx.assertTrue(Grammar.isValidStack(upper: Myanmar.ka, lower: Myanmar.ka))
        },

        TestCase("isValidStack_labialSameClass_isLegal") { ctx in
            ctx.assertTrue(Grammar.isValidStack(upper: Myanmar.pa, lower: Myanmar.pa))
        },

        TestCase("isValidStack_dentalCrossMember_isLegal") { ctx in
            ctx.assertTrue(Grammar.isValidStack(upper: Myanmar.na, lower: Myanmar.da))
        },

        TestCase("isValidStack_velarNasalWithClassMember_isLegal") { ctx in
            ctx.assertTrue(Grammar.isValidStack(upper: Myanmar.nga, lower: Myanmar.ka))
        },

        TestCase("isValidStack_velarWithMedialConsonant_isIllegal") { ctx in
            // ka + ya is not a legal subscript combination in modern Burmese
            ctx.assertFalse(Grammar.isValidStack(upper: Myanmar.ka, lower: Myanmar.ya))
        },

        TestCase("isValidStack_velarWithWa_isIllegal") { ctx in
            ctx.assertFalse(Grammar.isValidStack(upper: Myanmar.ka, lower: Myanmar.wa))
        },

        TestCase("isValidStack_velarWithPalatalNnya_isIllegal") { ctx in
            ctx.assertFalse(Grammar.isValidStack(upper: Myanmar.ka, lower: Myanmar.nnya))
        },

        TestCase("isValidStack_velarWithLa_isIllegal") { ctx in
            ctx.assertFalse(Grammar.isValidStack(upper: Myanmar.ka, lower: Myanmar.la))
        },

        TestCase("isValidStack_velarWithRa_isIllegal") { ctx in
            ctx.assertFalse(Grammar.isValidStack(upper: Myanmar.ka, lower: Myanmar.ra))
        },

        TestCase("isValidStack_velarWithGreatSa_isIllegal") { ctx in
            ctx.assertFalse(Grammar.isValidStack(upper: Myanmar.ka, lower: Myanmar.greatSa))
        },

        TestCase("isValidStack_velarWithDental_isIllegal") { ctx in
            ctx.assertFalse(Grammar.isValidStack(upper: Myanmar.ka, lower: Myanmar.ta))
        },

        // MARK: - Virama Stack End-to-End (Parser)

        TestCase("parse_invalidStack_kya_isIllegal") { ctx in
            let result = SyllableParser().parse("k+ya").first
            ctx.assertEqual(result?.legalityScore ?? -1, 0,
                "k+ya should not pass the legality threshold")
        },

        TestCase("parse_invalidStack_kwa_isIllegal") { ctx in
            let result = SyllableParser().parse("k+wa").first
            ctx.assertEqual(result?.legalityScore ?? -1, 0,
                "k+wa should not pass the legality threshold")
        },

        TestCase("parse_invalidStack_knya_isIllegal") { ctx in
            let result = SyllableParser().parse("k+nya").first
            ctx.assertEqual(result?.legalityScore ?? -1, 0,
                "k+nya should not pass the legality threshold")
        },

        TestCase("parse_invalidStack_kla_isIllegal") { ctx in
            let result = SyllableParser().parse("k+la").first
            ctx.assertEqual(result?.legalityScore ?? -1, 0,
                "k+la should not pass the legality threshold")
        },

        TestCase("parse_invalidStack_kra_isIllegal") { ctx in
            let result = SyllableParser().parse("k+ra").first
            ctx.assertEqual(result?.legalityScore ?? -1, 0,
                "k+ra should not pass the legality threshold")
        },

        TestCase("parse_invalidStack_kss_isIllegal") { ctx in
            let result = SyllableParser().parse("k+ss").first
            ctx.assertEqual(result?.legalityScore ?? -1, 0,
                "k+ss should not pass the legality threshold")
        },

        TestCase("parse_validStack_kka_isLegal") { ctx in
            let result = SyllableParser().parse("k+ka").first
            ctx.assertGreaterThan(result?.legalityScore ?? 0, 0)
        },

        TestCase("parse_validStack_ppa_isLegal") { ctx in
            let result = SyllableParser().parse("p+pa").first
            ctx.assertGreaterThan(result?.legalityScore ?? 0, 0)
        },

        TestCase("parse_validStack_gga_isLegal") { ctx in
            let result = SyllableParser().parse("g+ga").first
            ctx.assertGreaterThan(result?.legalityScore ?? 0, 0)
        },

        TestCase("parse_validStack_mma_isLegal") { ctx in
            let result = SyllableParser().parse("m+ma").first
            ctx.assertGreaterThan(result?.legalityScore ?? 0, 0)
        },

        TestCase("parse_validStack_nda_isLegal") { ctx in
            let result = SyllableParser().parse("n+da").first
            ctx.assertGreaterThan(result?.legalityScore ?? 0, 0)
        },
    ])
}
