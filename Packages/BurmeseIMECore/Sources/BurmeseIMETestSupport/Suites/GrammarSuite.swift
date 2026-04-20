import BurmeseIMECore

/// Assert that typing `input` does not produce a legitimate kinzi
/// candidate with `lower` as the subscript. The task allows two
/// outcomes: (a) the kinzi surface is emitted but demoted to
/// `legalityScore = 0`, or (b) a different non-kinzi parse wins.
fileprivate func assertKinziIllegal(
    _ ctx: TestContext,
    input: String,
    lower: UInt32,
    file: StaticString = #file,
    line: UInt = #line
) {
    let result = SyllableParser().parseCandidates(input, maxResults: 1).first
    let scalars = result?.output.unicodeScalars.map(\.value) ?? []
    let kinziForm: [UInt32] = [0x1019, 0x1004, 0x103A, 0x1039, lower]
    let isKinziSurface = scalars == kinziForm
    let legal = result?.legalityScore ?? -1
    ctx.assertFalse(
        isKinziSurface && legal > 0,
        input,
        detail: "\(input): kinzi+\(String(format: "%04X", lower)) must not be legitimate; "
            + "got legal=\(legal) scalars=\(scalars.map { String(format: "%04X", $0) })",
        file: file,
        line: line
    )
}

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

        TestCase("validateSyllable_jhaWithDiphthong_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.jha, medials: [], vowelRoman: "own")
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_palaRetroflexWithOte2_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.nna, medials: [], vowelRoman: "ote2")
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_palaRetroflexWithAte2_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.tta, medials: [], vowelRoman: "ate2")
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_palaRetroflexWithOwn2_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.nna, medials: [], vowelRoman: "own2")
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_palaRetroflexWithOwnHeavy_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.nna, medials: [], vowelRoman: "own:")
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_palaRetroflexWithOwn2Heavy_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.nna, medials: [], vowelRoman: "own2:")
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_palaRetroflexWithOwn2Creaky_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.nna, medials: [], vowelRoman: "own2.")
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_palaRetroflexWithAinHeavy_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.tta, medials: [], vowelRoman: "ain:")
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_palaRetroflexWithAinCreaky_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.tta, medials: [], vowelRoman: "ain.")
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_palaRetroflexWithAin2_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.tta, medials: [], vowelRoman: "ain2")
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_palaRetroflexWithAin2Heavy_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.tta, medials: [], vowelRoman: "ain2:")
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_palaRetroflexWithAin2Creaky_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.tta, medials: [], vowelRoman: "ain2.")
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_palaRetroflexWithAiHeavy_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.nna, medials: [], vowelRoman: "ai:")
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_palaRetroflexWithAiCreaky_rareButLegal") { ctx in
            let score = Grammar.validateSyllable(
                onset: Myanmar.nna, medials: [], vowelRoman: "ai.")
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score < 100, detail: "rare; expected < 100, got \(score)")
        },

        TestCase("validateSyllable_palaRetroflexWithAnusvara_legal") { ctx in
            // own3 / on3 are the anusvara family (ုံ / ွံ) — niggahita
            // finals are common in Pali declensions, so they stay legal
            // on retroflex onsets without rarity penalty.
            let score = Grammar.validateSyllable(
                onset: Myanmar.nna, medials: [], vowelRoman: "own3")
            ctx.assertGreaterThan(score, 0)
            ctx.assertTrue(score >= 100, detail: "anusvara should not be penalised; got \(score)")
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

        // MARK: - Asat Before Virama (Kinzi vs. Non-Kinzi Stacks)

        // The only legal `U+103A U+1039` sequence in modern Burmese is
        // kinzi: nga + asat + virama + lower. Any other base consonant
        // producing `...U+103A U+1039...` is orthographically broken —
        // the stack must use the virama-only encoding.

        // Clean virama path exists via `th + a` + `n + virama` glued.
        // After the fix the asat-preserving parse (သန်္ဒ) must lose to
        // the virama-only form (သန္ဒ).
        TestCase("parse_asatVirama_thanDa_prefersCleanVirama") { ctx in
            let output = SyllableParser().parse("than+da").first?.output ?? ""
            let scalars = output.unicodeScalars.map(\.value)
            ctx.assertEqual(scalars, [0x101E, 0x1014, 0x1039, 0x1012])
        },

        TestCase("parse_asatVirama_mutTa_prefersCleanVirama") { ctx in
            // The parser resolves "mu" to long U+1030 (roman "u"); short
            // U+102F requires the explicit "u." disambiguator.
            let output = SyllableParser().parse("mut+ta").first?.output ?? ""
            let scalars = output.unicodeScalars.map(\.value)
            ctx.assertEqual(scalars, [0x1019, 0x1030, 0x1010, 0x1039, 0x1010])
        },

        TestCase("parse_asatVirama_satTa_prefersCleanVirama") { ctx in
            let output = SyllableParser().parse("sat+ta").first?.output ?? ""
            let scalars = output.unicodeScalars.map(\.value)
            ctx.assertEqual(scalars, [0x1005, 0x1010, 0x1039, 0x1010])
        },

        TestCase("parse_asatVirama_patTa_prefersCleanVirama") { ctx in
            let output = SyllableParser().parse("pat+ta").first?.output ?? ""
            let scalars = output.unicodeScalars.map(\.value)
            ctx.assertEqual(scalars, [0x1015, 0x1010, 0x1039, 0x1010])
        },

        TestCase("parse_asatVirama_kanTar_prefersCleanVirama") { ctx in
            let output = SyllableParser().parse("kan+tar").first?.output ?? ""
            let scalars = output.unicodeScalars.map(\.value)
            ctx.assertEqual(scalars, [0x1000, 0x1014, 0x1039, 0x1010, 0x102C])
        },

        // Kinzi case — nga is the single legal upper for `U+103A U+1039`.
        // Must continue to surface the kinzi sequence.
        TestCase("parse_asatVirama_minGa_keepsKinzi") { ctx in
            let output = SyllableParser().parse("min+ga").first?.output ?? ""
            let scalars = output.unicodeScalars.map(\.value)
            ctx.assertEqual(scalars, [0x1019, 0x1004, 0x103A, 0x1039, 0x1002])
        },

        // MARK: - Kinzi Subscript Class (task 03)
        //
        // Kinzi is `U+1004 U+103A U+1039 <lower>`. The upper that
        // determines stack class is nga (U+1004), not the base onset of
        // the preceding syllable. Only velar-class lowers (က / ခ / ဂ /
        // ဃ / င) are legitimate; non-velar kinzi subscripts like
        // မင်္ယ / မင်္လ / မင်္သ are not well-formed Burmese.
        //
        // An illegal kinzi must either surface with `legalityScore = 0`
        // or lose to a non-kinzi parse entirely — both outcomes keep
        // the engine from offering a malformed kinzi as legitimate.

        TestCase("parse_kinzi_velarKa_isLegal") { ctx in
            let result = SyllableParser().parseCandidates("min+ka", maxResults: 1).first
            ctx.assertGreaterThan(result?.legalityScore ?? 0, 0)
            let scalars = result?.output.unicodeScalars.map(\.value) ?? []
            ctx.assertEqual(scalars, [0x1019, 0x1004, 0x103A, 0x1039, 0x1000])
        },

        TestCase("parse_kinzi_velarGa_isLegal") { ctx in
            let result = SyllableParser().parseCandidates("min+ga", maxResults: 1).first
            ctx.assertGreaterThan(result?.legalityScore ?? 0, 0)
            let scalars = result?.output.unicodeScalars.map(\.value) ?? []
            ctx.assertEqual(scalars, [0x1019, 0x1004, 0x103A, 0x1039, 0x1002])
        },

        TestCase("parse_kinzi_semiVowelYa_isIllegal") { ctx in
            assertKinziIllegal(ctx, input: "min+ya", lower: 0x101A)
        },

        TestCase("parse_kinzi_semiVowelRa_isIllegal") { ctx in
            assertKinziIllegal(ctx, input: "min+ra", lower: 0x101B)
        },

        TestCase("parse_kinzi_semiVowelLa_isIllegal") { ctx in
            assertKinziIllegal(ctx, input: "min+la", lower: 0x101C)
        },

        TestCase("parse_kinzi_semiVowelWa_isIllegal") { ctx in
            assertKinziIllegal(ctx, input: "min+wa", lower: 0x101D)
        },

        TestCase("parse_kinzi_sibilantTha_isIllegal") { ctx in
            assertKinziIllegal(ctx, input: "min+tha", lower: 0x101E)
        },

        TestCase("parse_kinzi_ha_isIllegal") { ctx in
            assertKinziIllegal(ctx, input: "min+ha", lower: 0x101F)
        },

        // `thate+ta` / `pate+ta` lack a clean-virama DP alternative, but
        // the top parse must still avoid the illegal `U+103A U+1039` pair
        // on a non-nga upper. (The legality of the winning surface is
        // checked separately; here we only assert the absence of the
        // forbidden adjacency.)
        TestCase("parse_asatVirama_thateTa_noAsatBeforeVirama") { ctx in
            let output = SyllableParser().parse("thate+ta").first?.output ?? ""
            let scalars = output.unicodeScalars.map(\.value)
            for i in 1..<scalars.count where scalars[i] == 0x1039 {
                let prev = scalars[i - 1]
                let twoBack = i >= 2 ? scalars[i - 2] : 0
                ctx.assertFalse(
                    prev == 0x103A && twoBack != 0x1004,
                    detail: "thate+ta: asat before virama on non-nga upper — \(scalars.map { String(format: "%04X", $0) })"
                )
            }
        },

        TestCase("parse_asatVirama_pateTa_noAsatBeforeVirama") { ctx in
            let output = SyllableParser().parse("pate+ta").first?.output ?? ""
            let scalars = output.unicodeScalars.map(\.value)
            for i in 1..<scalars.count where scalars[i] == 0x1039 {
                let prev = scalars[i - 1]
                let twoBack = i >= 2 ? scalars[i - 2] : 0
                ctx.assertFalse(
                    prev == 0x103A && twoBack != 0x1004,
                    detail: "pate+ta: asat before virama on non-nga upper — \(scalars.map { String(format: "%04X", $0) })"
                )
            }
        },

        // MARK: - Virama After Non-Consonant Scalars
        //
        // Virama (U+1039) only bonds a base consonant to a base consonant.
        // Attaching it to a dependent vowel sign, independent vowel, or
        // anusvara yields a scalar run no Myanmar shaper renders sensibly.
        // The top parse for these inputs must have legalityScore = 0 so
        // any fallback parse without the malformed stack wins.

        TestCase("parse_viramaAfterAa_marTar_isIllegal") { ctx in
            let result = SyllableParser().parseCandidates("mar+tar", maxResults: 1).first
            ctx.assertEqual(result?.legalityScore ?? -1, 0,
                "mar+tar: virama after U+102C must not score as legal")
        },

        TestCase("parse_viramaAfterAa_marPa_isIllegal") { ctx in
            let result = SyllableParser().parseCandidates("mar+pa", maxResults: 1).first
            ctx.assertEqual(result?.legalityScore ?? -1, 0,
                "mar+pa: virama after U+102C must not score as legal")
        },

        TestCase("parse_viramaAfterIndependentVowel_mooPa_isIllegal") { ctx in
            let result = SyllableParser().parseCandidates("moo+pa", maxResults: 1).first
            ctx.assertEqual(result?.legalityScore ?? -1, 0,
                "moo+pa: virama after independent vowel U+1029 must not score as legal")
        },

        TestCase("parse_viramaAfterAnusvara_thaan3Ka_isIllegal") { ctx in
            let result = SyllableParser().parseCandidates("thaan3+ka", maxResults: 1).first
            ctx.assertEqual(result?.legalityScore ?? -1, 0,
                "thaan3+ka: virama after anusvara U+1036 must not score as legal")
        },

        TestCase("parse_viramaAfterAnusvara_than3Ka_isIllegal") { ctx in
            let result = SyllableParser().parseCandidates("than3+ka", maxResults: 1).first
            ctx.assertEqual(result?.legalityScore ?? -1, 0,
                "than3+ka: virama after anusvara U+1036 must not score as legal")
        },

        // MARK: - Medial Canonical Order

        // Onset carries medial ha-htoe (U+103E) and the vowel starts with
        // medial wa-hswe (U+103D). Concatenation without normalization
        // yields U+103E followed by U+103D — a violation of Unicode
        // canonical order that no downstream renderer corrects.

        TestCase("parse_canonicalMedialOrder_hmon") { ctx in
            let output = SyllableParser().parse("hmon").first?.output ?? ""
            let scalars = output.unicodeScalars.map(\.value)
            ctx.assertEqual(scalars, [0x1019, 0x103D, 0x103E, 0x1014, 0x103A])
        },

        TestCase("parse_canonicalMedialOrder_hmonTone") { ctx in
            let output = SyllableParser().parse("hmon:").first?.output ?? ""
            let scalars = output.unicodeScalars.map(\.value)
            ctx.assertEqual(scalars, [0x1019, 0x103D, 0x103E, 0x1014, 0x103A, 0x1038])
        },

        TestCase("parse_canonicalMedialOrder_hmut") { ctx in
            let output = SyllableParser().parse("hmut").first?.output ?? ""
            let scalars = output.unicodeScalars.map(\.value)
            ctx.assertEqual(scalars, [0x1019, 0x103D, 0x103E, 0x1010, 0x103A])
        },

        TestCase("parse_canonicalMedialOrder_hnon") { ctx in
            let output = SyllableParser().parse("hnon").first?.output ?? ""
            let scalars = output.unicodeScalars.map(\.value)
            ctx.assertEqual(scalars, [0x1014, 0x103D, 0x103E, 0x1014, 0x103A])
        },

        // Every onset emitted by the parser must have its medial run in
        // ascending codepoint order. Enumerate onsets whose trailing
        // medial is higher than the vowel's leading medial — these are
        // the pairings where concatenation flips the order.
        TestCase("parse_medialRun_isStrictlyAscending_allOnsetVowelPairs") { ctx in
            let parser = SyllableParser()
            // Onsets ending in ha-htoe (U+103E). Excluded: `w`-variants
            // that would also carry U+103D, which duplicates the vowel's
            // leading medial — a separate concern from ordering.
            let onsetKeys = [
                "hm", "hn", "hk", "hng", "hp", "hb", "hl", "hy",
            ]
            // Vowels whose Myanmar form begins with U+103D (wa-hswe).
            let vowelKeys = [
                "on", "on:", "on.", "on2", "on2:", "on2.",
                "on3", "on3:", "on3.", "ut",
            ]
            for onsetKey in onsetKeys {
                for vowelKey in vowelKeys {
                    let key = onsetKey + vowelKey
                    let output = parser.parse(key).first?.output ?? ""
                    let scalars = output.unicodeScalars.map(\.value)
                    var previous: UInt32 = 0
                    for v in scalars {
                        if v >= 0x103B && v <= 0x103E {
                            if previous >= 0x103B && previous <= 0x103E {
                                ctx.assertTrue(
                                    v >= previous,
                                    detail: "\(key): medials out of order — \(String(format: "%04X", previous)) before \(String(format: "%04X", v))"
                                )
                            }
                        }
                        previous = v
                    }
                }
            }
        },

        // Regression: onset-only medials (no vowel medial) stay unchanged.
        TestCase("parse_canonicalMedialOrder_onsetOnly_hma") { ctx in
            let output = SyllableParser().parse("hma").first?.output ?? ""
            let scalars = output.unicodeScalars.map(\.value)
            ctx.assertEqual(scalars, [0x1019, 0x103E])
        },

        // Regression: vowel starts with U+103D but no onset medial collides.
        TestCase("parse_canonicalMedialOrder_vowelOnly_mon") { ctx in
            let output = SyllableParser().parse("mon").first?.output ?? ""
            let scalars = output.unicodeScalars.map(\.value)
            ctx.assertEqual(scalars, [0x1019, 0x103D, 0x1014, 0x103A])
        },

        // MARK: - Onset Emission Canonical Order

        // Direct test of the onset-emission helper. `medialCombinations`
        // currently never pairs ya-pin (U+103B) with ya-yit (U+103C), so
        // the mis-ordered emission path is latent. Exercise it here so a
        // future combination-table extension can't reintroduce the bug.
        TestCase("composeOnset_medialRaAndYa_emitsCanonicalOrder") { ctx in
            let output = Grammar.composeOnset(
                consonant: Myanmar.ka,
                medials: [Myanmar.medialRa, Myanmar.medialYa]
            )
            let scalars = output.unicodeScalars.map(\.value)
            ctx.assertEqual(scalars, [0x1000, 0x103B, 0x103C])
        },

        // Every current entry in `medialCombinations` must round-trip
        // through `composeOnset` in canonical order. Stays green when
        // new combinations are added, as long as emission is sorted.
        TestCase("composeOnset_allMedialCombinations_ascending") { ctx in
            for combo in Grammar.medialCombinations {
                let output = Grammar.composeOnset(consonant: Myanmar.ka, medials: combo)
                let medialScalars = output.unicodeScalars.dropFirst().map(\.value)
                var previous: UInt32 = 0
                for v in medialScalars {
                    ctx.assertTrue(
                        v > previous,
                        detail: "medials not strictly ascending for combo \(combo): \(Array(medialScalars))"
                    )
                    previous = v
                }
            }
        },

        // End-to-end guard: parsing the canonical roman key for each combo
        // must produce medials in Unicode canonical order. Enumerating the
        // combination table keeps the check alive for any future entry.
        TestCase("parse_allMedialCombinations_emitCanonicalOrder") { ctx in
            let parser = SyllableParser()
            for combo in Grammar.medialCombinations {
                let hasH  = combo.contains(Myanmar.medialHa)
                let hasW  = combo.contains(Myanmar.medialWa)
                let hasY  = combo.contains(Myanmar.medialRa)
                let hasY2 = combo.contains(Myanmar.medialYa)
                let roman =
                    (hasH ? "h" : "") +
                    "m" +
                    (hasW ? "w" : "") +
                    (hasY ? "y" : "") +
                    (hasY2 ? "y2" : "") +
                    "a"
                let output = parser.parse(roman).first?.output ?? ""
                let medialScalars = output.unicodeScalars
                    .map(\.value)
                    .filter { $0 >= 0x103B && $0 <= 0x103E }
                var previous: UInt32 = 0
                for v in medialScalars {
                    ctx.assertTrue(
                        v > previous,
                        detail: "\(roman): medials not ascending — \(medialScalars)"
                    )
                    previous = v
                }
            }
        },
    ])
}
