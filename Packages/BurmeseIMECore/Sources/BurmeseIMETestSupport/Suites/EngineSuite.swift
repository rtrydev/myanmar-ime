import Foundation
import BurmeseIMECore

public enum EngineSuite {

    private struct KyarPrefixStore: CandidateStore {
        func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
            guard prefix == "kyar" else { return [] }
            return [
                Candidate(surface: "ကြား", reading: "kyar:", source: .lexicon, score: 950),
                Candidate(surface: "ကျား", reading: "ky2ar:", source: .lexicon, score: 900),
            ]
        }
    }

    private struct ExactAliasStore: CandidateStore {
        func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
            guard prefix == "min+galarpar" else { return [] }
            return [
                Candidate(surface: "မင်္ဂလာပါ", reading: "min+galarpar2", source: .lexicon, score: 1000),
                Candidate(surface: "မင်္ဂလာပါတော်", reading: "min+galarpartaw", source: .lexicon, score: 900),
            ]
        }
    }

    private struct ComposeKeyStore: CandidateStore {
        func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
            guard prefix == "mingalarpar" else { return [] }
            return [
                Candidate(surface: "မင်္ဂလာပါ", reading: "min+galarpar2", source: .lexicon, score: 1000),
            ]
        }
    }

    private static func stripZW(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.value != 0x200B && $0.value != 0x200C })
    }

    private static func parseTop(_ input: String) -> String {
        SyllableParser().parse(input).first?.output ?? ""
    }

    public static let suite = TestSuite(name: "Engine", cases: [

        // MARK: - Basic update/commit cycle

        TestCase("emptyBuffer_returnsInactive") { ctx in
            let state = BurmeseEngine().update(buffer: "", context: [])
            ctx.assertFalse(state.isActive, "emptyBuffer_inactive")
            ctx.assertTrue(state.candidates.isEmpty, "emptyBuffer_noCandidates")
        },

        TestCase("singleConsonant_returnsCandidates") { ctx in
            let state = BurmeseEngine().update(buffer: "k", context: [])
            ctx.assertTrue(state.isActive, "singleConsonant_active")
            ctx.assertFalse(state.candidates.isEmpty, "singleConsonant_hasCandidates")
        },

        TestCase("commit_thar") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "thar", context: [])
            ctx.assertEqual(engine.commit(state: state), "သာ")
        },

        TestCase("cancel_thar") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "thar", context: [])
            ctx.assertEqual(engine.cancel(state: state), "thar")
        },

        TestCase("normalize_uppercase") { ctx in
            let state = BurmeseEngine().update(buffer: "THAR", context: [])
            ctx.assertEqual(state.rawBuffer, "thar")
        },

        // MARK: - Ranking

        TestCase("candidates_grammarFirst") { ctx in
            let state = BurmeseEngine().update(buffer: "thar", context: [])
            guard let first = state.candidates.first else {
                ctx.fail("candidates_grammarFirst", detail: "No candidates")
                return
            }
            ctx.assertTrue(first.source == .grammar,
                           detail: "first.source = \(first.source)")
        },

        TestCase("candidates_maxPageSize") { ctx in
            let state = BurmeseEngine().update(buffer: "k", context: [])
            ctx.assertTrue(
                state.candidates.count <= BurmeseEngine.candidatePageSizeDefault,
                detail: "count=\(state.candidates.count) > page=\(BurmeseEngine.candidatePageSizeDefault)"
            )
        },

        TestCase("candidates_mixedGrammarAndLexicon") { ctx in
            let engine = BurmeseEngine(candidateStore: KyarPrefixStore())
            let state = engine.update(buffer: "kyar", context: [])

            ctx.assertFalse(state.candidates.isEmpty)
            ctx.assertTrue(state.candidates.first?.source == .grammar,
                           "first_grammar")
            ctx.assertTrue(
                state.candidates.contains { $0.surface == "ကြား" && $0.source == .lexicon },
                "hasKyar_lexicon"
            )
            ctx.assertTrue(
                state.candidates.contains { $0.surface == "ကျား" && $0.source == .lexicon },
                "hasKy2ar_lexicon"
            )
        },

        TestCase("candidates_exactAliasLexiconPrioritized") { ctx in
            let engine = BurmeseEngine(candidateStore: ExactAliasStore())
            let state = engine.update(buffer: "min+galarpar", context: [])

            ctx.assertEqual(state.candidates.first?.surface, "မင်္ဂလာပါ")
            ctx.assertTrue(
                state.candidates.contains { $0.surface == "မင်္ဂလာပါတော်" },
                "containsSecondaryLexicon"
            )
        },

        TestCase("candidates_aaShapeMatchesDescender") {
            ctx in
            let engine = BurmeseEngine()
            let par = engine.update(buffer: "par", context: [])
            ctx.assertTrue(
                par.candidates.contains { $0.surface.contains("\u{102B}") },
                "par_tallAa", detail: "Expected ါ variant for ပ onset"
            )
            ctx.assertFalse(
                par.candidates.contains { $0.surface.contains("\u{102C}") },
                "par_noShortAa", detail: "ာ must not appear after ပ"
            )

            let thar = engine.update(buffer: "thar", context: [])
            ctx.assertTrue(
                thar.candidates.contains { $0.surface.contains("\u{102C}") },
                "thar_shortAa", detail: "Expected ာ variant for သ onset"
            )
            ctx.assertFalse(
                thar.candidates.contains { $0.surface.contains("\u{102B}") },
                "thar_noTallAa", detail: "ါ must not appear after သ"
            )
        },

        TestCase("candidates_aaShapeOnStackedConjunct") {
            ctx in
            let engine = BurmeseEngine()

            // ပ္ပ + aa: stacked round-bottomed subscript takes plain ာ, not ါ.
            let stackedP = "\u{1015}\u{1039}\u{1015}"
            let pPar = engine.update(buffer: "p+par", context: [])
            ctx.assertTrue(
                pPar.candidates.contains { $0.surface.contains(stackedP + "\u{102C}") },
                "p+par_shortAa", detail: "Expected ပ္ပာ (plain ာ) for stacked ပ္ပ"
            )
            ctx.assertFalse(
                pPar.candidates.contains { $0.surface.contains(stackedP + "\u{102B}") },
                "p+par_noTallAa", detail: "ါ must not appear after stacked ပ္ပ"
            )

            // User typing the tall-aa token explicitly still gets rewritten
            // to plain ာ when the preceding consonant is a stacked subscript.
            let pPar2 = engine.update(buffer: "p+par2", context: [])
            ctx.assertTrue(
                pPar2.candidates.contains { $0.surface.contains(stackedP + "\u{102C}") },
                "p+par2_shortAa", detail: "ar2 after stacked ပ္ပ must fold to ာ"
            )
            ctx.assertFalse(
                pPar2.candidates.contains { $0.surface.contains(stackedP + "\u{102B}") },
                "p+par2_noTallAa", detail: "ါ must not survive after stacked ပ္ပ"
            )

            // Same rule for another round-bottomed stack (ဂ္ဂ as in အဂ္ဂ…).
            let stackedG = "\u{1002}\u{1039}\u{1002}"
            let gGar = engine.update(buffer: "g+gar", context: [])
            ctx.assertTrue(
                gGar.candidates.contains { $0.surface.contains(stackedG + "\u{102C}") },
                "g+gar_shortAa", detail: "Expected ဂ္ဂာ (plain ာ) for stacked ဂ္ဂ"
            )
            ctx.assertFalse(
                gGar.candidates.contains { $0.surface.contains(stackedG + "\u{102B}") },
                "g+gar_noTallAa", detail: "ါ must not appear after stacked ဂ္ဂ"
            )
        },

        TestCase("candidates_consonantFormRanksAheadOfMedialFallback") { ctx in
            let state = BurmeseEngine().update(buffer: "hsa", context: [])
            ctx.assertEqual(state.candidates.first?.surface, "ဆ")
        },

        TestCase("candidates_composeMatchPrioritizedWhenSeparatorOmitted") { ctx in
            let engine = BurmeseEngine(candidateStore: ComposeKeyStore())
            let state = engine.update(buffer: "mingalarpar", context: [])
            ctx.assertEqual(state.candidates.first?.surface, "မင်္ဂလာပါ")
            ctx.assertTrue(state.candidates.first?.source == .lexicon,
                           "first_lexicon")
        },

        TestCase("candidates_longerInputPreservesTallAaAfterDescender") { ctx in
            let engine = BurmeseEngine(candidateStore: ComposeKeyStore())
            let state = engine.update(buffer: "mingalarpar", context: [])
            ctx.assertTrue(
                state.candidates.contains { $0.source == .grammar && $0.surface.hasSuffix("ပါ") },
                "hasPaTallAa"
            )
            ctx.assertFalse(
                state.candidates.contains { $0.surface.hasSuffix("ပာ") },
                "noPaShortAa"
            )
        },

        // MARK: - Grammar filtering at engine level

        TestCase("grammarFilter_retroflexDiphthongRejected") { ctx in
            let state = BurmeseEngine().update(buffer: "t2ote", context: [])
            ctx.assertFalse(
                state.candidates.contains {
                    $0.surface == "ဋောက်" ||
                    ($0.surface.contains("\u{1031}\u{102C}\u{1000}\u{103A}") &&
                     $0.surface.hasPrefix("ဋ"))
                }
            )
        },

        TestCase("grammarFilter_medialHaPlusLongI_rejected") { ctx in
            let state = BurmeseEngine().update(buffer: "hki:", context: [])
            ctx.assertFalse(
                state.candidates.contains {
                    $0.surface.contains("\u{103E}") && $0.surface.contains("\u{102E}")
                }
            )
        },

        // MARK: - Unconvertible tail preservation

        TestCase("commit_digitIsLiteral_thar2") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "thar2", context: [])
            ctx.assertEqual(engine.commit(state: state), "သာ၂")
            ctx.assertTrue(state.candidates.contains { $0.surface == "သာ2" },
                           "hasArabicVariant")
        },

        // Digits in user input are literal at the position typed, regardless
        // of whether they happen to align with an internal alias key. See
        // tasks/01-digits-must-be-literal-in-user-input.md.
        TestCase("digits_midBuffer_areLiteralNotAliasDisambiguators") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "min+galar2par2", context: [])
            ctx.assertEqual(
                state.candidates.first?.surface ?? "",
                "\u{1019}\u{1004}\u{103A}\u{1039}\u{1002}\u{101C}\u{102C}\u{1042}\u{1015}\u{102B}\u{1042}",
                "min+galar2par2_top"
            )
        },

        TestCase("digits_noOpAliasKeyStillRenderedAsLiteralDigit") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "pa2", context: [])
            ctx.assertEqual(
                state.candidates.first?.surface ?? "",
                "\u{1015}\u{1042}",
                "pa2_top"
            )
        },

        TestCase("digits_trailingLiteralAfterLexiconMatch") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "min+galarpar2", context: [])
            ctx.assertEqual(
                state.candidates.first?.surface ?? "",
                "\u{1019}\u{1004}\u{103A}\u{1039}\u{1002}\u{101C}\u{102C}\u{1015}\u{102B}\u{1042}",
                "min+galarpar2_top"
            )
        },

        TestCase("commit_preservesTrailingDigits") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "min:123", context: [])
            let committed = engine.commit(state: state)
            ctx.assertTrue(committed.hasSuffix("၁၂၃"),
                           "burmeseDigitSuffix",
                           detail: "Got: \(committed)")
            ctx.assertTrue(committed.hasPrefix("မင်း"),
                           "minPrefix",
                           detail: "Got: \(committed)")
            ctx.assertTrue(state.candidates.contains { $0.surface.hasSuffix("123") },
                           "arabicVariant")
        },

        TestCase("update_candidatesIncludeTrailingDigits") { ctx in
            let state = BurmeseEngine().update(buffer: "thar123", context: [])
            ctx.assertFalse(state.candidates.isEmpty, "nonEmpty")
            ctx.assertTrue(
                state.candidates.allSatisfy {
                    $0.surface.hasSuffix("၁၂၃") || $0.surface.hasSuffix("123")
                },
                "allHaveTail"
            )
            ctx.assertTrue(state.candidates.first!.surface.hasSuffix("၁၂၃"),
                           "primaryBurmese")
            ctx.assertTrue(state.candidates.contains { $0.surface.hasSuffix("123") },
                           "hasArabic")
        },

        TestCase("commit_preservesNonComposingTail") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "thar!", context: [])
            let committed = engine.commit(state: state)
            ctx.assertTrue(committed.hasSuffix("!"),
                           detail: "Got: \(committed)")
        },

        TestCase("commit_preservesMixedDigitAndPunctuationTail") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "min:123!", context: [])
            let committed = engine.commit(state: state)
            ctx.assertTrue(committed.hasSuffix("၁၂၃!"),
                           "burmeseMixedTail",
                           detail: "Got: \(committed)")
            ctx.assertTrue(state.candidates.contains { $0.surface.hasSuffix("123!") },
                           "arabicMixedVariant")
        },

        TestCase("commit_standaloneTallAa_splitsAsLiteralTail") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "ar2", context: [])
            let committed = engine.commit(state: state)
            ctx.assertTrue(committed.hasSuffix("၂"),
                           "burmeseDigitSuffix",
                           detail: "Got: \(committed)")
            ctx.assertFalse(committed.contains("\u{102B}"),
                            "noTallAa",
                            detail: "Got: \(committed)")
            ctx.assertTrue(committed.contains("\u{102C}"),
                           "hasShortAa",
                           detail: "Got: \(committed)")
        },

        TestCase("update_pureDigitBuffer_producesBurmeseAndArabicCandidates") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "123", context: [])
            ctx.assertTrue(state.isActive, "active")
            ctx.assertFalse(state.candidates.isEmpty, "nonEmpty")
            ctx.assertEqual(state.candidates[0].surface, "၁၂၃",
                            "primaryBurmese")
            ctx.assertTrue(state.candidates.count >= 2, "hasTwoCandidates",
                           detail: "count=\(state.candidates.count)")
            ctx.assertEqual(state.candidates[1].surface, "123",
                            "secondaryArabic")
            ctx.assertEqual(engine.commit(state: state), "၁၂၃",
                            "commitsBurmese")
        },

        TestCase("update_leadingDigits_parsedWithBurmeseText") { ctx in
            let state = BurmeseEngine().update(buffer: "123kwyantaw", context: [])
            ctx.assertFalse(state.candidates.isEmpty, "hasCandidates")
            let primary = state.candidates[0].surface
            ctx.assertTrue(primary.hasPrefix("၁၂၃"),
                           "burmesePrefix",
                           detail: "Got: \(primary)")
            ctx.assertFalse(primary.contains("kwyantaw"),
                            "noRawLatin",
                            detail: "Got: \(primary)")
            ctx.assertTrue(state.candidates.contains { $0.surface.hasPrefix("123") },
                           "arabicVariant")
        },

        TestCase("update_leadingDigits_withTrailingDigits") { ctx in
            let state = BurmeseEngine().update(buffer: "123thar456", context: [])
            ctx.assertFalse(state.candidates.isEmpty, "hasCandidates")
            let primary = state.candidates[0].surface
            ctx.assertTrue(primary.hasPrefix("၁၂၃"),
                           "burmesePrefix",
                           detail: "Got: \(primary)")
            ctx.assertTrue(primary.hasSuffix("၄၅၆"),
                           "burmeseSuffix",
                           detail: "Got: \(primary)")
            ctx.assertTrue(
                state.candidates.contains {
                    $0.surface.hasPrefix("123") && $0.surface.hasSuffix("456")
                },
                "arabicVariant"
            )
        },

        // MARK: - Prefix stability

        TestCase("update_longerBufferPreservesPreviouslyRenderedPrefix") { ctx in
            let engine = BurmeseEngine()
            let short = engine.update(buffer: "kwyantaw", context: [])
            let longer = engine.update(buffer: "kwyantawkahtamin", context: [])
            guard let shortTop = short.candidates.first?.surface,
                  let longerTop = longer.candidates.first?.surface else {
                ctx.fail("prefixStability", detail: "missing candidates")
                return
            }
            ctx.assertTrue(
                longerTop.hasPrefix(shortTop),
                detail: "prefix drift: '\(longerTop)' should start with '\(shortTop)'"
            )
        },

        // MARK: - Progressive typing correctness

        TestCase("progressiveTyping_mingalarpar_producesCorrectOutput") { ctx in
            let engine = BurmeseEngine()
            var buffer = ""
            for ch in Array("min+galarpar") {
                buffer.append(ch)
                _ = engine.update(buffer: buffer, context: [])
            }
            let state = engine.update(buffer: "min+galarpar", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertEqual(stripZW(top), "မင်္ဂလာပါ")
        },

        TestCase("progressiveTyping_kwyantawkahtamin_producesCorrectSuffix") { ctx in
            let engine = BurmeseEngine()
            var buffer = ""
            for ch in Array("kwyantawkahtamin") {
                buffer.append(ch)
                _ = engine.update(buffer: buffer, context: [])
            }
            let state = engine.update(buffer: "kwyantawkahtamin", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertTrue(stripZW(top).hasSuffix("ကထမင်"),
                           detail: "Got: \(top)")
        },

        TestCase("progressiveTyping_longInput_thaNotSplitAsTaHa") { ctx in
            let engine = BurmeseEngine()
            let input = "kwyantawkahtamin:masar:rathar"
            var buffer = ""
            for ch in Array(input) {
                buffer.append(ch)
                _ = engine.update(buffer: buffer, context: [])
            }
            let state = engine.update(buffer: input, context: [])
            let top = stripZW(state.candidates.first?.surface ?? "")
            ctx.assertFalse(top.contains("တဟ"),
                            detail: "Found တဟ split, got: \(top)")
        },

        // MARK: - Composition state

        TestCase("compositionState_selectedIndex_startsAtZero") { ctx in
            let state = BurmeseEngine().update(buffer: "thar", context: [])
            ctx.assertEqual(state.selectedCandidateIndex, 0)
        },

        TestCase("compositionState_rawBuffer_normalized") { ctx in
            let state = BurmeseEngine().update(buffer: "TH+ar", context: [])
            ctx.assertEqual(state.rawBuffer, "th+ar")
        },

        // MARK: - Parser fixtures (bare parser.parse calls)

        TestCase("parse_thar") { ctx in
            ctx.assertEqual(parseTop("thar"), "သာ")
        },

        TestCase("parse_kyaw") { ctx in
            ctx.assertEqual(parseTop("kyaw"), "ကြော်")
        },

        TestCase("parse_minGalarPar") { ctx in
            ctx.assertEqual(parseTop("min+galarpar"), "မင်္ဂလာပာ")
        },

        TestCase("parse_thiuDot_producesStandaloneBu") { ctx in
            ctx.assertEqual(parseTop("thiu."), "\u{101E}\u{102E}\u{1025}")
        },

        TestCase("parse_thiu_doesNotProduceDoubleDependentVowel") { ctx in
            let top = parseTop("thiu")
            ctx.assertFalse(top.contains("\u{102E}\u{102F}"),
                            detail: "Found i+u dependents on same onset: \(top)")
            ctx.assertFalse(top.contains("\u{102E}\u{1030}"),
                            detail: "Found i+uu dependents on same onset: \(top)")
        },

        TestCase("parse_thu_stillProducesLongU") { ctx in
            ctx.assertEqual(parseTop("thu"), "\u{101E}\u{1030}")
        },

        // MARK: - Mixed-script rejection

        TestCase("mixedScript_foo_noLatinLeak") { ctx in
            let result = parseTop("foo")
            let hasMyanmar = result.unicodeScalars.contains { Myanmar.isMyanmar($0) }
            let hasLatin = result.unicodeScalars.contains {
                let v = $0.value
                return (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            }
            ctx.assertFalse(hasMyanmar && hasLatin,
                            detail: "Mixed script: \(result)")
        },

        TestCase("mixedScript_abc_noLatinLeak") { ctx in
            let result = parseTop("abc")
            let hasMyanmar = result.unicodeScalars.contains { Myanmar.isMyanmar($0) }
            let hasLatin = result.unicodeScalars.contains {
                let v = $0.value
                return (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            }
            ctx.assertFalse(hasMyanmar && hasLatin,
                            detail: "Mixed script: \(result)")
        },

        TestCase("par_noLatinInOutput") { ctx in
            let result = parseTop("par")
            for scalar in result.unicodeScalars {
                ctx.assertTrue(
                    Myanmar.isMyanmar(scalar) || scalar.value == 0x200C,
                    "onlyMyanmarOrZwnj",
                    detail: "Found non-Myanmar U+\(String(scalar.value, radix: 16))"
                )
            }
        },

        // MARK: - Leading-vowel / U+200C

        TestCase("leadingVowel_u") { ctx in
            ctx.assertEqual(parseTop("u"), "\u{200C}\u{1030}")
        },

        TestCase("leadingVowel_ay") { ctx in
            ctx.assertEqual(parseTop("ay"), "\u{200C}\u{1031}")
        },

        TestCase("leadingVowel_aw") { ctx in
            ctx.assertEqual(parseTop("aw"), "\u{200C}\u{1031}\u{102C}\u{103A}")
        },

        TestCase("leadingVowel_awColon") { ctx in
            ctx.assertEqual(parseTop("aw:"), "\u{200C}\u{1031}\u{102C}")
        },

        TestCase("leadingVowel_own") { ctx in
            ctx.assertEqual(parseTop("own"), "\u{200C}\u{102F}\u{1014}\u{103A}")
        },

        TestCase("leadingVowel_medialWa_on") { ctx in
            // U+103D (medial wa) is a combining sign — standalone parses
            // beginning with it must be prefixed with U+200C so the mark
            // has a display base.
            ctx.assertEqual(parseTop("on"), "\u{200C}\u{103D}\u{1014}\u{103A}")
        },

        TestCase("leadingVowel_virama") { ctx in
            // U+1039 (virama) as a standalone parse must be ZWNJ-prefixed.
            ctx.assertEqual(parseTop("+"), "\u{200C}\u{1039}")
        },

        TestCase("leadingVowel_asat") { ctx in
            // U+103A (asat) as a standalone parse must be ZWNJ-prefixed.
            ctx.assertEqual(parseTop("*"), "\u{200C}\u{103A}")
        },

        // MARK: - Standard Burmese character coverage

        TestCase("standardChar_gha_types") { ctx in
            // ဃ (U+1003) is a regular consonant; "gh" + "a" should produce ဃ.
            let state = BurmeseEngine().update(buffer: "gha", context: [])
            ctx.assertTrue(
                state.candidates.contains { $0.surface.contains("\u{1003}") },
                "gha_hasGha",
                detail: "surfaces=\(state.candidates.map(\.surface))"
            )
        },

        TestCase("standardChar_gha_withFinal") { ctx in
            // Confirm ဃ composes with a final (ဃာ is a legitimate sequence).
            let state = BurmeseEngine().update(buffer: "ghar", context: [])
            ctx.assertTrue(
                state.candidates.contains {
                    $0.surface.hasPrefix("\u{1003}") && $0.surface.contains("\u{102C}")
                },
                "ghar_hasGhaWithAa",
                detail: "surfaces=\(state.candidates.map(\.surface))"
            )
        },

        TestCase("standardChar_shortIndependentI") { ctx in
            // ii. → ဣ (U+1023), no ZWNJ prefix since this is an independent vowel.
            ctx.assertEqual(parseTop("ii."), "\u{1023}")
        },

        TestCase("standardChar_longIndependentI") { ctx in
            // ii → ဤ (U+1024).
            ctx.assertEqual(parseTop("ii"), "\u{1024}")
        },

        TestCase("standardChar_independentO") { ctx in
            // oo → ဩ (U+1029).
            ctx.assertEqual(parseTop("oo"), "\u{1029}")
        },

        TestCase("standardChar_independentOTonal") { ctx in
            // oo: → ဪ (U+102A).
            ctx.assertEqual(parseTop("oo:"), "\u{102A}")
        },

        TestCase("standardChar_locativeSymbol") { ctx in
            // ywe → ၍ (U+104D, conjunctive particle).
            ctx.assertEqual(parseTop("ywe"), "\u{104D}")
        },

        TestCase("standardChar_genitiveSymbol") { ctx in
            // ei → ၏ (U+104F, possessive particle).
            ctx.assertEqual(parseTop("ei"), "\u{104F}")
        },

        TestCase("standardChar_greatSa_bare") { ctx in
            // ss → ဿ + inherent a. ဿ itself (U+103F) must be present.
            let state = BurmeseEngine().update(buffer: "ssa", context: [])
            ctx.assertTrue(
                state.candidates.contains { $0.surface.contains("\u{103F}") },
                "ssa_hasGreatSa",
                detail: "surfaces=\(state.candidates.map(\.surface))"
            )
        },

        // MARK: - Medial deduplication at onset/vowel join

        TestCase("dedupeMedial_wOverlap_khwon") { ctx in
            // Onset "khw" contributes U+103D; vowel "on" also starts with U+103D.
            // The duplicate must collapse.
            let state = BurmeseEngine().update(buffer: "khwon", context: [])
            ctx.assertEqual(state.candidates.first?.surface, "\u{1001}\u{103D}\u{1014}\u{103A}")
        },

        TestCase("dedupeMedial_hOverlap_hmh") { ctx in
            // Onset "hm" contributes U+103E; standalone vowel "h" is also U+103E.
            // The duplicate must collapse.
            let state = BurmeseEngine().update(buffer: "hmh", context: [])
            ctx.assertEqual(state.candidates.first?.surface, "\u{1019}\u{103E}")
        },

        TestCase("standardChar_greatSa_withVowel") { ctx in
            // ဿ accepts a vowel suffix (appears as ဿ + ာ for non-descender onsets).
            let state = BurmeseEngine().update(buffer: "ssar", context: [])
            ctx.assertTrue(
                state.candidates.contains {
                    $0.surface.hasPrefix("\u{103F}") && $0.surface.contains("\u{102C}")
                },
                "ssar_hasGreatSaWithAa",
                detail: "surfaces=\(state.candidates.map(\.surface))"
            )
        },
    ])
}
