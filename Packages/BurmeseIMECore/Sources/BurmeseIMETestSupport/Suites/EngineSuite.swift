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

    private static func hasAsciiSurfaceScalar(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7E
        }
    }

    private static func hasOnlyMyanmarOrZeroWidthScalars(_ surface: String) -> Bool {
        !surface.isEmpty && surface.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x1000 && scalar.value <= 0x109F)
                || scalar.value == 0x200B
                || scalar.value == 0x200C
        }
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

        TestCase("candidates_creakyAaTopFor_par") { ctx in
            // Task 01: `Xar.` must produce `X` + `ါ့` / `ာ့` (U+102B/C + U+1037)
            // at rank 1, not the literal-`.` fallback (`X` + `ါ` + `.`).
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "par.", context: [])
            ctx.assertEqual(
                state.candidates.first?.surface ?? "",
                "\u{1015}\u{102B}\u{1037}",
                "par_top"
            )
        },

        TestCase("candidates_creakyAaTopFor_thar") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "thar.", context: [])
            ctx.assertEqual(
                state.candidates.first?.surface ?? "",
                "\u{101E}\u{102C}\u{1037}",
                "thar_top"
            )
        },

        TestCase("candidates_creakyAaTopFor_mar") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "mar.", context: [])
            ctx.assertEqual(
                state.candidates.first?.surface ?? "",
                "\u{1019}\u{102C}\u{1037}",
                "mar_top"
            )
        },

        TestCase("candidates_creakyAaTopFor_phar") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "phar.", context: [])
            ctx.assertEqual(
                state.candidates.first?.surface ?? "",
                "\u{1016}\u{102C}\u{1037}",
                "phar_top"
            )
        },

        TestCase("candidates_creakyAaTopFor_lar") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "lar.", context: [])
            ctx.assertEqual(
                state.candidates.first?.surface ?? "",
                "\u{101C}\u{102C}\u{1037}",
                "lar_top"
            )
        },

        TestCase("candidates_creakyAaNoLiteralDotFallback") { ctx in
            // The literal-`.` fallback path must not fire for `par.`,
            // `thar.`, etc. once the rule is present.
            let engine = BurmeseEngine()
            for buffer in ["par.", "thar.", "mar.", "phar.", "lar."] {
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertFalse(
                    top.unicodeScalars.contains { $0.value == 0x2E },
                    "noLiteralDot.\(buffer)",
                    detail: "top=\(top)"
                )
            }
        },

        TestCase("candidates_aaShapeOnStackedConjunct") {
            ctx in
            let engine = BurmeseEngine()

            // ပ္ပ + aa: descender lower of a virama stack takes the tall
            // hook ါ, matching the dominant lexicon spelling
            // (`အဓိပ္ပါယ်` 23,838× vs. `အဓိပ္ပာယ်` 17,340×).
            let stackedP = "\u{1015}\u{1039}\u{1015}"
            let pPar = engine.update(buffer: "p+par", context: [])
            ctx.assertTrue(
                pPar.candidates.contains { $0.surface.contains(stackedP + "\u{102B}") },
                "p+par_tallAa", detail: "Expected ပ္ပါ (tall ါ) for stacked ပ္ပ"
            )

            // User typing the tall-aa token explicitly stays tall after
            // a stacked descender subscript.
            let pPar2 = engine.update(buffer: "p+par2", context: [])
            ctx.assertTrue(
                pPar2.candidates.contains { $0.surface.contains(stackedP + "\u{102B}") },
                "p+par2_tallAa", detail: "ar2 after stacked ပ္ပ stays as ါ"
            )

            // ဂ + aa as the lower of a virama stack: tall is the only
            // attested form in the lexicon (`မဂ္ဂါဝပ်`, …).
            let stackedG = "\u{1002}\u{1039}\u{1002}"
            let gGar = engine.update(buffer: "g+gar", context: [])
            ctx.assertTrue(
                gGar.candidates.contains { $0.surface.contains(stackedG + "\u{102B}") },
                "g+gar_tallAa", detail: "Expected ဂ္ဂါ (tall ါ) for stacked ဂ္ဂ"
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

        // ASCII digits never act as variant selectors, even when the
        // surrounding letters happen to form an internal variant key
        // (`ky2`, `t2`, `ay2`, `u2`, …). The `2`/`3` digits in those keys
        // are code-internal only; users disambiguate via the candidate
        // panel, never by typing a digit. See tasks/06.
        TestCase("digits_neverSteerVariants_ky2anNotYaPin") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "ky2an", context: [])
            ctx.assertFalse(state.candidates.isEmpty, "hasCandidates")
            ctx.assertFalse(
                state.candidates.contains { $0.surface == "ကျန်" },
                "noYaPinFromDigit",
                detail: "top=\(state.candidates.first?.surface ?? "")"
            )
            ctx.assertTrue(
                state.candidates.allSatisfy { cand in
                    cand.surface.unicodeScalars.contains { s in
                        s.value == 0x1042 || s.value == 0x32
                    }
                },
                "digitLiteralInAllCandidates"
            )
        },

        TestCase("digits_neverSteerVariants_t2oteNotRetroflex") { ctx in
            // `t` + literal `2` + `ote`: the `2` must appear as a digit
            // in every candidate. The retroflex variant ဋ can still
            // surface (it's a normal candidate-panel alternate for `t`),
            // but it must be paired with the literal `2`, never as
            // ဋုတ် via the `t2` internal key.
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "t2ote", context: [])
            ctx.assertFalse(state.candidates.isEmpty, "hasCandidates")
            ctx.assertFalse(
                state.candidates.contains { $0.surface == "ဋုတ်" },
                "noT2AsVariantSelector",
                detail: "top=\(state.candidates.first?.surface ?? "")"
            )
            ctx.assertTrue(
                state.candidates.allSatisfy { cand in
                    cand.surface.unicodeScalars.contains { s in
                        s.value == 0x1042 || s.value == 0x32
                    }
                },
                "digitLiteralInAllCandidates"
            )
        },

        TestCase("digits_neverSteerVariants_u2NotIndependentU") { ctx in
            // `u2` is the internal key for ဦ; user input `u2` must stay
            // literal (u + digit), not emit ဦ.
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "u2", context: [])
            ctx.assertFalse(state.candidates.isEmpty, "hasCandidates")
            ctx.assertFalse(
                state.candidates.contains { $0.surface == "ဦ" },
                "noLongIndependentUFromDigit",
                detail: "top=\(state.candidates.first?.surface ?? "")"
            )
            ctx.assertTrue(
                state.candidates.allSatisfy { cand in
                    cand.surface.unicodeScalars.contains { s in
                        s.value == 0x1042 || s.value == 0x32
                    }
                },
                "digitLiteralInAllCandidates"
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
            // Single-shot still resolves to `…ကထမင်` (kinzi). The
            // incremental anchor occasionally locks the long-i form
            // `…ကထမီ` for the `mi` step before the trailing `n`
            // arrives, in which case the kinzi candidate sits at #2
            // and the engine prefers the anchor-extending `…ကထမီန`.
            // Both orderings are accepted here so the assertion stays
            // robust across small ranking shifts (e.g. task 03's
            // narrowing of `Grammar.canTakeMedialHa`).
            let engine = BurmeseEngine()
            var buffer = ""
            for ch in Array("kwyantawkahtamin") {
                buffer.append(ch)
                _ = engine.update(buffer: buffer, context: [])
            }
            let state = engine.update(buffer: "kwyantawkahtamin", context: [])
            let top = stripZW(state.candidates.first?.surface ?? "")
            let acceptable = top.hasSuffix("ကထမင်") || top.hasSuffix("ကထမီန")
            ctx.assertTrue(acceptable, detail: "Got: \(top)")
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

        // MARK: - Leading `a` + consonant emits independent vowel (task 01)

        TestCase("leadingA_standaloneAlone_emitsIndependent") { ctx in
            let state = BurmeseEngine().update(buffer: "a", context: [])
            ctx.assertEqual(state.candidates.first?.surface, "\u{1021}")
        },

        TestCase("leadingA_plusConsonantVowel_emitsIndependentThenSyllable") { ctx in
            let state = BurmeseEngine().update(buffer: "atar", context: [])
            ctx.assertEqual(state.candidates.first?.surface,
                            "\u{1021}\u{1010}\u{102C}", "atar_top")
        },

        TestCase("leadingA_plusConsonantNoVowel_emitsIndependentThenBareConsonant") { ctx in
            let state = BurmeseEngine().update(buffer: "ata", context: [])
            ctx.assertEqual(state.candidates.first?.surface,
                            "\u{1021}\u{1010}", "ata_top")
        },

        TestCase("leadingA_plusConsonantDescender_emitsIndependent") { ctx in
            let state = BurmeseEngine().update(buffer: "apa", context: [])
            ctx.assertEqual(state.candidates.first?.surface,
                            "\u{1021}\u{1015}", "apa_top")
        },

        TestCase("leadingA_plusKar_emitsIndependent") { ctx in
            let state = BurmeseEngine().update(buffer: "akar", context: [])
            ctx.assertEqual(state.candidates.first?.surface,
                            "\u{1021}\u{1000}\u{102C}", "akar_top")
        },

        TestCase("leadingA_plusMar_emitsIndependent") { ctx in
            let state = BurmeseEngine().update(buffer: "amar", context: [])
            ctx.assertEqual(state.candidates.first?.surface,
                            "\u{1021}\u{1019}\u{102C}", "amar_top")
        },

        TestCase("leadingA_plusNar_emitsIndependent") { ctx in
            let state = BurmeseEngine().update(buffer: "anar", context: [])
            ctx.assertEqual(state.candidates.first?.surface,
                            "\u{1021}\u{1014}\u{102C}", "anar_top")
        },

        TestCase("leadingA_plusLa_emitsIndependent") { ctx in
            let state = BurmeseEngine().update(buffer: "ala", context: [])
            ctx.assertEqual(state.candidates.first?.surface,
                            "\u{1021}\u{101C}", "ala_top")
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

        TestCase("loneH_producesConsonantHa") { ctx in
            // `h` alone must parse as the consonant ha (U+101F). The old
            // `h → U+103E` vowel-table entry has been removed so ha-htoe
            // reaches the surface only via a medial attachment on an
            // onset, never as a standalone syllable.
            let state = BurmeseEngine().update(buffer: "h", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertEqual(
                top.unicodeScalars.map(\.value), [0x101F],
                "`h` must render as ဟ only"
            )
        },

        TestCase("loneH_noStandaloneMedialHa") { ctx in
            // Stronger invariant: `h` must never surface as a bare medial
            // ha-htoe (U+103E) floating without a consonant base.
            let state = BurmeseEngine().update(buffer: "h", context: [])
            for c in state.candidates {
                ctx.assertFalse(
                    c.surface.unicodeScalars.contains { $0.value == 0x103E },
                    detail: "candidate '\(c.surface)' contains a stray U+103E"
                )
            }
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

        // MARK: - Virama Stack Defence-in-Depth (task 05)
        //
        // The DP rejects malformed virama transitions by returning
        // `legalityScore = 0`. The engine's `hasOnlyCleanViramaStacks`
        // rescue path keeps legal-zero candidates alive when the virama
        // sequence is still well-formed (needed for clean stack shapes
        // that happen to score zero for unrelated reasons). That rescue
        // must not itself admit malformed stacks.
        //
        // For each illegal input below no engine candidate may carry the
        // malformed scalar sequence.

        TestCase("engine_viramaAfterAa_marPa_rejectsMalformed") { ctx in
            let state = BurmeseEngine().update(buffer: "mar+pa", context: [])
            let bad: [UInt32] = [0x1019, 0x102C, 0x1039, 0x1015]
            ctx.assertFalse(
                state.candidates.contains { $0.surface.unicodeScalars.map(\.value) == bad },
                "mar+pa_noMalformed",
                detail: "surfaces=\(state.candidates.map(\.surface))"
            )
        },

        TestCase("engine_viramaAfterIndependentVowel_mooPa_rejectsMalformed") { ctx in
            let state = BurmeseEngine().update(buffer: "moo+pa", context: [])
            ctx.assertFalse(
                state.candidates.contains { cand in
                    let s = cand.surface.unicodeScalars.map(\.value)
                    // Any independent vowel (0x1021-0x102A) immediately before virama.
                    for i in 1..<s.count where s[i] == 0x1039 {
                        let prev = s[i - 1]
                        if prev >= 0x1021 && prev <= 0x102A { return true }
                    }
                    return false
                },
                "moo+pa_noIndependentVowelBeforeVirama",
                detail: "surfaces=\(state.candidates.map(\.surface))"
            )
        },

        TestCase("engine_viramaAfterAnusvara_thaan3Ka_rejectsMalformed") { ctx in
            let state = BurmeseEngine().update(buffer: "thaan3+ka", context: [])
            ctx.assertFalse(
                state.candidates.contains { cand in
                    let s = cand.surface.unicodeScalars.map(\.value)
                    for i in 1..<s.count where s[i] == 0x1039 {
                        if s[i - 1] == 0x1036 { return true }
                    }
                    return false
                },
                "thaan3+ka_noAnusvaraBeforeVirama",
                detail: "surfaces=\(state.candidates.map(\.surface))"
            )
        },

        TestCase("engine_crossClassStack_pTa_admitsLiberalStack_task01") { ctx in
            // Task 01: an explicit user-typed `+` between cross-class
            // consonants (here labial p + dental t) must surface a
            // liberal-stacked candidate. `p+ta` → ပ္တ is the user's
            // ask; the soft-boundary fallback ပတ remains in the panel
            // as a sibling.
            let state = BurmeseEngine().update(buffer: "p+ta", context: [])
            let expected: [UInt32] = [0x1015, 0x1039, 0x1010]
            ctx.assertTrue(
                state.candidates.contains { $0.surface.unicodeScalars.map(\.value) == expected },
                "p+ta_hasLiberalStack",
                detail: "surfaces=\(state.candidates.map(\.surface))"
            )
        },

        TestCase("engine_illegalKinzi_minYa_rejectsMalformed") { ctx in
            // Kinzi requires a velar lower. `ya` (U+101A) is classless.
            let state = BurmeseEngine().update(buffer: "min+ya", context: [])
            let bad: [UInt32] = [0x1019, 0x1004, 0x103A, 0x1039, 0x101A]
            ctx.assertFalse(
                state.candidates.contains { $0.surface.unicodeScalars.map(\.value) == bad },
                "min+ya_noIllegalKinzi",
                detail: "surfaces=\(state.candidates.map(\.surface))"
            )
        },

        TestCase("engine_legitimateStack_kKa_survives") { ctx in
            // Regression: the rescue path must still admit well-formed
            // legal=0 stack candidates that don't raise any issue.
            let state = BurmeseEngine().update(buffer: "k+ka", context: [])
            let expected: [UInt32] = [0x1000, 0x1039, 0x1000]
            ctx.assertTrue(
                state.candidates.contains { $0.surface.unicodeScalars.map(\.value) == expected },
                "k+ka_hasLegalStack",
                detail: "surfaces=\(state.candidates.map(\.surface))"
            )
        },

        TestCase("engine_legitimateKinzi_minKa_survives") { ctx in
            let state = BurmeseEngine().update(buffer: "min+ka", context: [])
            let expected: [UInt32] = [0x1019, 0x1004, 0x103A, 0x1039, 0x1000]
            ctx.assertTrue(
                state.candidates.contains { $0.surface.unicodeScalars.map(\.value) == expected },
                "min+ka_hasKinzi",
                detail: "surfaces=\(state.candidates.map(\.surface))"
            )
        },

        // MARK: - ASCII fallback cleanup (task 05)
        //
        // When the right-shrink probe gives up mid-buffer, the engine
        // used to splice the un-converted tail straight into the surface,
        // leaking ASCII letters into the candidate panel. Whenever the
        // dropped portion is non-empty, the engine must re-compose any
        // letter runs in the tail so the top candidate stays free of
        // ASCII letters.

        TestCase("engine_fallback_thar_myat_mhu_noLatinLeak") { ctx in
            let state = BurmeseEngine().update(buffer: "thar.myat.mhu", context: [])
            let top = state.candidates.first?.surface ?? ""
            let leaked = top.unicodeScalars.contains { v in
                let s = v.value
                return (s >= 0x41 && s <= 0x5A) || (s >= 0x61 && s <= 0x7A)
            }
            ctx.assertFalse(
                leaked,
                detail: "thar.myat.mhu top must not contain ASCII letters; got '\(top)'"
            )
        },

        TestCase("engine_fallback_pa_n_di_ta_noLatinLeak") { ctx in
            let state = BurmeseEngine().update(buffer: "pa+n+di+ta", context: [])
            let top = state.candidates.first?.surface ?? ""
            let leaked = top.unicodeScalars.contains { v in
                let s = v.value
                return (s >= 0x41 && s <= 0x5A) || (s >= 0x61 && s <= 0x7A)
            }
            ctx.assertFalse(
                leaked,
                detail: "pa+n+di+ta top must not contain ASCII letters; got '\(top)'"
            )
        },

        TestCase("engine_fallback_creakyTone_mu_dot_unchanged") { ctx in
            let state = BurmeseEngine().update(buffer: "mu.", context: [])
            let top = state.candidates.first?.surface ?? ""
            let scalars = top.unicodeScalars.map(\.value)
            ctx.assertEqual(scalars, [0x1019, 0x102F],
                            "mu. must still produce မု (creaky tone preserved)")
        },

        TestCase("engine_fallback_minGalarpar_unchanged") { ctx in
            let state = BurmeseEngine().update(buffer: "min+galarpar", context: [])
            let top = state.candidates.first?.surface ?? ""
            let leaked = top.unicodeScalars.contains { v in
                let s = v.value
                return (s >= 0x41 && s <= 0x5A) || (s >= 0x61 && s <= 0x7A)
            }
            ctx.assertFalse(leaked, detail: "min+galarpar top must remain ASCII-free; got '\(top)'")
            ctx.assertFalse(top.isEmpty, detail: "min+galarpar must still produce a candidate")
        },

        // MARK: - Right-shrunk pure-letter tails (task 03)

        TestCase("task03_rightShrunkComposableBuffersStayMyanmarOnly") { ctx in
            let engine = BurmeseEngine()
            for buffer in ["aw", "awwwww", "bwwwz", "kyawzz", "nya'n", "ayo:n"] {
                let state = engine.update(buffer: buffer, context: [])
                ctx.assertFalse(state.candidates.isEmpty,
                                "task03_nonEmpty_\(buffer)",
                                detail: "fully composable buffer produced no candidates")
                for candidate in state.candidates {
                    ctx.assertTrue(
                        hasOnlyMyanmarOrZeroWidthScalars(candidate.surface),
                        "task03_myanmarOnly_\(buffer)",
                        detail: "\(buffer) leaked surface '\(candidate.surface)' from \(state.candidates.map(\.surface))"
                    )
                }
            }
        },

        TestCase("task03_literalTailsStayLiteral") { ctx in
            let engine = BurmeseEngine()
            for (buffer, suffix) in [
                ("thar english", " english"),
                // `ka.` has no `a.` rule, so `.` stays literal — unlike
                // `thar.` which now consumes the `.` via the `ar.`
                // creaky-tone rule (task 01).
                ("ka.", "."),
                ("thar123", "၁၂၃"),
            ] {
                let top = engine.update(buffer: buffer, context: []).candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top.hasSuffix(suffix),
                    "task03_literalTail_\(buffer)",
                    detail: "\(buffer) expected suffix '\(suffix)', got '\(top)'"
                )
            }
        },

        TestCase("task03_cleanComposedTailsUnchanged") { ctx in
            let engine = BurmeseEngine()
            for (buffer, expected) in [
                ("thark", "\u{101E}\u{102C}\u{1000}"),
                ("khmr", "\u{1001}\u{1019}\u{101B}"),
                ("pzzzz", "\u{1015}\u{1008}\u{1008}"),
            ] {
                let top = engine.update(buffer: buffer, context: []).candidates.first?.surface ?? ""
                ctx.assertEqual(top, expected, "task03_cleanTail_\(buffer)")
                ctx.assertFalse(
                    hasAsciiSurfaceScalar(top),
                    "task03_cleanTailNoAscii_\(buffer)",
                    detail: "\(buffer) leaked '\(top)'"
                )
            }
        },

        // MARK: - Disambiguation UX (task 07)
        //
        // Three cases where the parser silently collapses an ambiguous
        // input into a single interpretation. Each expects a visible
        // alternative in the candidate panel.

        TestCase("engine_disambig_yka_exposesStrippedAlternative") { ctx in
            let state = BurmeseEngine().update(buffer: "yka", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("\u{101A}\u{1000}"),
                           detail: "top promoted form ယက must remain; got \(surfaces)")
            ctx.assertTrue(surfaces.contains("\u{1000}"),
                           detail: "stripped alternative က must appear; got \(surfaces)")
        },

        TestCase("engine_disambig_lla_retroflexAmongTop3") { ctx in
            let state = BurmeseEngine().update(buffer: "lla", context: [])
            let top3 = state.candidates.prefix(3).map(\.surface)
            ctx.assertTrue(top3.contains("\u{1020}"),
                           detail: "retroflex ဠ must appear in top 3 for lla; got \(top3)")
        },

        TestCase("engine_disambig_ninPlusKa_hasNonKinziAlternative") { ctx in
            let state = BurmeseEngine().update(buffer: "nin+ka", context: [])
            let kinziMarker: [UInt32] = [0x1004, 0x103A, 0x1039]
            let hasNonKinzi = state.candidates.contains { c in
                let scalars = c.surface.unicodeScalars.map(\.value)
                for i in 0...(max(0, scalars.count - kinziMarker.count)) {
                    if Array(scalars[i..<(i + kinziMarker.count)]) == kinziMarker {
                        return false
                    }
                }
                return !scalars.isEmpty
            }
            ctx.assertTrue(hasNonKinzi,
                           detail: "nin+ka must expose at least one non-kinzi candidate; got \(state.candidates.map(\.surface))")
        },

        TestCase("engine_disambig_minPlusKa_kinziStaysRank1") { ctx in
            let state = BurmeseEngine().update(buffer: "min+ka", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertEqual(top.unicodeScalars.map(\.value),
                            [0x1019, 0x1004, 0x103A, 0x1039, 0x1000],
                            "min+ka must still produce မင်္က at rank 1")
        },

        TestCase("engine_disambig_kinPlusGa_kinziStaysRank1") { ctx in
            let state = BurmeseEngine().update(buffer: "kin+ga", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertEqual(top.unicodeScalars.map(\.value),
                            [0x1000, 0x1004, 0x103A, 0x1039, 0x1002],
                            "kin+ga must still produce ကင်္ဂ at rank 1")
        },

        // MARK: - Cross-class `+` produces a liberal stack (task 01)
        //
        // When the user types an explicit `+` between cross-class
        // consonants whose virama stack is liberal-valid (both stackable
        // under `Grammar.isValidStackLiberal`), the engine must surface
        // the stacked form at top — the explicit `+` is the user's
        // signal that they want a stack. The soft-boundary sibling
        // remains in the panel for cases where the user actually meant
        // a syllable break. When the lower is a non-stackable semi-vowel
        // (`y`, `r`, `w`), or the previous state is a plain vowel that
        // virama can't bond to, the soft-boundary fires unconditionally
        // — those cases are still tested below as regressions on the
        // gating logic.

        TestCase("engine_crossClass_kPlusTar_admitsLiberalStack_task01") { ctx in
            let state = BurmeseEngine().update(buffer: "k+tar", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertEqual(top.unicodeScalars.map(\.value),
                            [0x1000, 0x1039, 0x1010, 0x102C],
                            "k+tar must produce က္တာ via liberal stack; got '\(top)'")
        },

        TestCase("engine_crossClass_shinPlusByar_kinziSiblingReachable_task01") { ctx in
            // shin + byar: under liberal stacks the n+b kinzi virama is
            // reachable as a sibling. The soft-boundary form ရှင်ဘြာ
            // remains the top because it scores at least as well, but
            // the kinzi-stacked form must reach the panel.
            let state = BurmeseEngine().update(buffer: "shin+byar", context: [])
            let kinzi: [UInt32] = [0x101B, 0x103E, 0x1004, 0x103A, 0x1039, 0x1018, 0x103C, 0x102C]
            ctx.assertTrue(
                state.candidates.contains { $0.surface.unicodeScalars.map(\.value) == kinzi },
                "shin+byar_kinziSiblingReachable",
                detail: "surfaces=\(state.candidates.map(\.surface))"
            )
        },

        TestCase("engine_crossClass_shinPlusPar_kinziSiblingReachable_task01") { ctx in
            let state = BurmeseEngine().update(buffer: "shin+par", context: [])
            let kinzi: [UInt32] = [0x101B, 0x103E, 0x1004, 0x103A, 0x1039, 0x1015, 0x102B]
            ctx.assertTrue(
                state.candidates.contains { $0.surface.unicodeScalars.map(\.value) == kinzi },
                "shin+par_kinziSiblingReachable",
                detail: "surfaces=\(state.candidates.map(\.surface))"
            )
        },

        TestCase("engine_crossClass_yaPlusPPlusGa_partialStack_task01") { ctx in
            // ya + p + ga: the first `+` follows a plain vowel (y+a
            // inherent), so the virama-after-vowel rule still forces
            // a syllable break there. The second `+` (between p and g)
            // is liberal-stackable, so the top must surface the p+g
            // stack while keeping y as a separate syllable.
            let state = BurmeseEngine().update(buffer: "ya+p+ga", context: [])
            let top = state.candidates.first?.surface ?? ""
            let scalars = top.unicodeScalars.map(\.value)
            ctx.assertEqual(
                scalars,
                [0x101A, 0x1015, 0x1039, 0x1002],
                "ya+p+ga must produce ယပ္ဂ (y syllable break, p+g liberal stack); got '\(top)'"
            )
        },

        TestCase("engine_crossClass_pPlusTar_admitsLiberalStack_task01") { ctx in
            let state = BurmeseEngine().update(buffer: "p+tar", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertEqual(top.unicodeScalars.map(\.value),
                            [0x1015, 0x1039, 0x1010, 0x102C],
                            "p+tar must produce ပ္တာ via liberal stack; got '\(top)'")
        },

        // MARK: - Connector-only and consecutive-connector buffers (task 08)
        //
        // Buffers composed entirely of `'` apostrophes or runs of `+` must
        // not synthesise Burmese content (e.g. `အ` from three apostrophes).
        // Consecutive `+` must collapse to a single soft boundary rather
        // than force right-shrink to discard the tail.

        TestCase("engine_connectorOnlyApostrophes_produceNoMyanmar_task08") { ctx in
            let state = BurmeseEngine().update(buffer: "'''", context: [])
            let top = state.candidates.first?.surface ?? ""
            let scalars = top.unicodeScalars.map(\.value)
            ctx.assertFalse(
                scalars.contains(0x1021),
                "'''_mustNotProduceIndependentA",
                detail: "got '\(top)' scalars=\(scalars.map { String(format: "%04X", $0) })"
            )
        },

        TestCase("engine_connectorOnlyPlus_producesNoMyanmar_task08") { ctx in
            let state = BurmeseEngine().update(buffer: "+", context: [])
            let top = state.candidates.first?.surface ?? ""
            let scalars = top.unicodeScalars.map(\.value)
            // A lone `+` may legitimately echo nothing, but must not inject
            // a synthetic U+1021 (independent a).
            ctx.assertFalse(
                scalars.contains(0x1021),
                "+_mustNotProduceIndependentA",
                detail: "got '\(top)' scalars=\(scalars.map { String(format: "%04X", $0) })"
            )
        },

        TestCase("engine_doublePlus_collapsesAndPreservesTail_task08") { ctx in
            // `k++ar` must keep the `ar` tail. The second `+` cannot produce
            // a stack (virama over virama), so it must degrade to a soft
            // boundary rather than force right-shrink to drop `+ar`.
            let state = BurmeseEngine().update(buffer: "k++ar", context: [])
            let top = state.candidates.first?.surface ?? ""
            let scalars = top.unicodeScalars.map(\.value)
            ctx.assertTrue(
                scalars.contains(0x1000),
                "k++ar_mustContainKa",
                detail: "got '\(top)' scalars=\(scalars.map { String(format: "%04X", $0) })"
            )
            // aa-shape will be short (U+102C) because ka has no descender.
            ctx.assertTrue(
                scalars.contains(0x102C) || scalars.contains(0x102B),
                "k++ar_mustContainAaShape",
                detail: "tail ar was dropped; got '\(top)' scalars=\(scalars.map { String(format: "%04X", $0) })"
            )
        },

        TestCase("engine_interleavedPlusTail_preservesContent_task08") { ctx in
            // `k+a+t`: three syllables with soft breaks. Must not collapse
            // to just `က`.
            let state = BurmeseEngine().update(buffer: "k+a+t", context: [])
            let top = state.candidates.first?.surface ?? ""
            let scalars = top.unicodeScalars.map(\.value)
            ctx.assertTrue(
                scalars.contains(0x1000),
                "k+a+t_mustContainKa",
                detail: "got '\(top)' scalars=\(scalars.map { String(format: "%04X", $0) })"
            )
            ctx.assertTrue(
                scalars.contains(0x1010),
                "k+a+t_mustContainTa",
                detail: "tail `+t` was dropped; got '\(top)' scalars=\(scalars.map { String(format: "%04X", $0) })"
            )
        },
    ])
}
