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

        TestCase("validateSyllable_medialHaPlusLongI_rejected") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.ka,
                medials: [Myanmar.medialHa],
                vowelRoman: "i:"
            )
            ctx.assertEqual(score, 0)
        },

        TestCase("validateSyllable_medialHaPlusLongU_rejected") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.ka,
                medials: [Myanmar.medialHa],
                vowelRoman: "u:"
            )
            ctx.assertEqual(score, 0)
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

        TestCase("validateSyllable_tripleMedialWithComplexVowel_rejected") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.ka,
                medials: [Myanmar.medialYa, Myanmar.medialWa, Myanmar.medialHa],
                vowelRoman: "aung"
            )
            ctx.assertEqual(score, 0)
        },

        TestCase("validateSyllable_palaRetroflexWithDiphthong_rejected") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.tta, medials: [], vowelRoman: "ote")
            ctx.assertEqual(score, 0)
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
    ])
}
