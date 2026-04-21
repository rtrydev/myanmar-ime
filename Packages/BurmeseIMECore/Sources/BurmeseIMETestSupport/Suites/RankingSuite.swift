import Foundation
import BurmeseIMECore

/// Ranking regressions reported by users. These tests capture three
/// bugs in the candidate-ranking pipeline:
///
///   A. The candidate pool collapses for long out-of-vocabulary inputs —
///      long buffers surface just one candidate, so legitimate
///      decompositions are unreachable.
///   B. Rare Myanmar codepoints (Pali retroflex consonants) outrank
///      common ones too early in the panel, even when the input has no
///      "2" disambiguator.
///   C. Some orthographically-legal forms are missing from the panel
///      (e.g. ပေါင်း for "paung:" — the tall-aa shape required after ပ).
///
/// Tests use the default `BurmeseEngine()` which pairs an empty
/// lexicon with a `NullLanguageModel`. That isolates the grammar ranking
/// path (no lexicon boost, no LM tiebreak), matching the failure mode
/// the user actually sees when typing OOV words.
public enum RankingSuite {

    // MARK: - Surface helpers (scalar-based, grapheme-cluster safe)

    private static let shortAaScalar: UInt32 = 0x102C // ာ
    private static let tallAaScalar: UInt32 = 0x102B  // ါ

    /// Consonants that require tall aa (ါ) — descender onsets per
    /// `Grammar.requiresTallAa`. Any short aa (ာ) following one of these
    /// through medials/vowel-signs is orthographically wrong.
    private static let requiresTallAaScalars: Set<UInt32> = [
        0x1001, // kha  ခ
        0x1002, // ga   ဂ
        0x1004, // nga  င
        0x1012, // da   ဒ
        0x1015, // pa   ပ
        0x101D, // wa   ဝ
    ]

    /// Pali retroflex consonants — correctly romanized with "t2" / "d2" /
    /// "n2" / "l2". Appearing under a bare "t" / "d" / "n" / "l" input is
    /// the rarity bug.
    private static let palaRetroflexScalars: Set<UInt32> = [
        0x100B, 0x100C, 0x100D, 0x100E, 0x100F, 0x1020,
    ]

    private static func isConsonantScalar(_ value: UInt32) -> Bool {
        (0x1000...0x1021).contains(value)
    }

    /// Walk back from each aa sign to its preceding consonant (skipping
    /// medials, e-kar, etc.) and flag any mismatch between the consonant's
    /// descender requirement and the aa shape used. Returns true if any
    /// wrong-shape aa is present.
    private static func hasWrongAaShape(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        for i in 0..<scalars.count {
            let v = scalars[i].value
            guard v == shortAaScalar || v == tallAaScalar else { continue }
            var j = i - 1
            while j >= 0 {
                let prev = scalars[j].value
                if isConsonantScalar(prev) {
                    let wantsTall = requiresTallAaScalars.contains(prev)
                    if wantsTall && v == shortAaScalar { return true }
                    if !wantsTall && v == tallAaScalar { return true }
                    break
                }
                j -= 1
            }
        }
        return false
    }

    /// True if the surface contains a `ပ` → `ေ` → `ါ` sequence (possibly
    /// with intervening medials), i.e. the expected tall-aa form for
    /// inputs like "paung:" / "paw" / "pyaung".
    private static func containsPaTallAaAfterEkar(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        for i in 0..<scalars.count where scalars[i].value == tallAaScalar {
            var sawEkar = false
            var j = i - 1
            while j >= 0 {
                let prev = scalars[j].value
                if prev == 0x1031 {
                    sawEkar = true
                } else if isConsonantScalar(prev) {
                    if sawEkar && prev == 0x1015 { return true }
                    break
                }
                j -= 1
            }
        }
        return false
    }

    private static func usesPalaRetroflex(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { palaRetroflexScalars.contains($0.value) }
    }

    private static func stripZW(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.value != 0x200B && $0.value != 0x200C })
    }

    public static let suite: TestSuite = {
        var cases: [TestCase] = []

        // MARK: - Issue A: OOV candidate pool too narrow

        cases.append(TestCase("issueA_rarthiuOffersIndependentVowelVariant") { ctx in
            // Regression guard: typing "rarthiu." in isolation must still
            // surface ရာသီဥ (standalone ဥ from the "u2." rule).
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "rarthiu.", context: [])
            let surfaces = state.candidates.map(\.surface)
            let hasIndependent = surfaces.contains { $0.contains("ရာသီဥ") }
            ctx.assertTrue(
                hasIndependent,
                "rarthiu_hasIndependentVowelBranch",
                detail: "no ရာသီဥ candidate; got: \(surfaces)"
            )
        })

        cases.append(TestCase("issueA_longOOVInputReturnsMultipleCandidates") { ctx in
            // Long out-of-vocabulary inputs (those crossing the sliding-
            // window boundary) must still offer more than one candidate.
            // Currently "rarthiu.tu.pyaung" collapses to a single panel
            // entry, leaving the user no way to pick an alternate parse.
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "rarthiu.tu.pyaung", context: [])
            ctx.assertTrue(
                state.candidates.count > 1,
                "longOOV_panelNotDegenerate",
                detail: "count=\(state.candidates.count); got: \(state.candidates.map(\.surface))"
            )
        })

        cases.append(TestCase("issueA_longOOVInputKeepsTallAaAfterPa") { ctx in
            // Same buffer, same pool-collapse bug, but verified via a
            // semantic anchor: the "pyaung" syllable must render with the
            // tall-aa shape ပြေါင် (ပ carries a descender → tall aa), not
            // the uncorrected short-aa ပြောင်.
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "rarthiu.tu.pyaung", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertFalse(
                surfaces.contains(where: hasWrongAaShape),
                "longOOV_noWrongShapeAa",
                detail: "wrong-shape aa on descender onset; got: \(surfaces)"
            )
        })

        // MARK: - Issue B: rare codepoints outranking common ones

        cases.append(TestCase("issueB_tuDoesNotShowRetroflexInTopTwo") { ctx in
            // For bare "tu" the common parse တူ lands at index 0, but the
            // Pali retroflex ဋူ currently shows at index 1 — far too
            // prominent for an onset the user did not spell with "t2".
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "tu", context: [])
            let top2 = Array(state.candidates.prefix(2)).map(\.surface)
            let hasRetroflex = top2.contains(where: usesPalaRetroflex)
            ctx.assertFalse(
                hasRetroflex,
                "tu_top2HasNoRetroflex",
                detail: "top2=\(top2); all=\(state.candidates.map(\.surface))"
            )
        })

        cases.append(TestCase("issueB_tuTopCandidateIsCommonTa") { ctx in
            // Anchor the observable behavior: the top pick for "tu" must
            // be the common တူ (ta + long u), never a retroflex form.
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "tu", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertTrue(
                top == "တူ",
                "tu_topIsTa",
                detail: "got top='\(top)'; all=\(state.candidates.map(\.surface))"
            )
        })

        cases.append(TestCase("issueB_rarthiuTuTopCandidateUsesCommonTa") { ctx in
            // With the OOV prefix, the trailing "tu" should still resolve
            // to the common ta (…တူ), not the retroflex tta (…ဋူ).
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "rarthiu.tu", context: [])
            guard let top = state.candidates.first else {
                ctx.fail("rarthiuTu_noCandidates", detail: "panel empty")
                return
            }
            ctx.assertTrue(
                top.surface.hasSuffix("တူ"),
                "rarthiuTu_topEndsWithCommonTa",
                detail: "top=\(top.surface); all=\(state.candidates.map(\.surface))"
            )
        })

        // MARK: - Issue C: tall-aa shape missing after ပ

        cases.append(TestCase("issueC_paungColonProducesTallAa") { ctx in
            // "paung:" should produce ပေါင်း (tall ါ after ပ). Currently
            // the panel only offers the uncorrected ပောင်း.
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "paung:", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(
                surfaces.contains(where: containsPaTallAaAfterEkar),
                "paungColon_hasTallAa",
                detail: "missing ပေါင်း; got: \(surfaces)"
            )
            ctx.assertFalse(
                surfaces.contains(where: hasWrongAaShape),
                "paungColon_noWrongAa",
                detail: "wrong-shape aa present; got: \(surfaces)"
            )
        })

        cases.append(TestCase("issueC_pawProducesTallAaAndDropsShortAa") { ctx in
            // Simpler isolate of the same bug — "paw" must render with
            // the tall-aa shape and strip the short-aa sibling completely.
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "paw", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(
                surfaces.contains(where: containsPaTallAaAfterEkar),
                "paw_hasTallAa",
                detail: "missing ပေါ; got: \(surfaces)"
            )
            ctx.assertFalse(
                surfaces.contains(where: hasWrongAaShape),
                "paw_noWrongAa",
                detail: "wrong-shape aa present; got: \(surfaces)"
            )
        })

        // MARK: - Issue D: standalone independent vowels from digitless input
        //
        // Digits are literal in user input (see tasks/01). Users type the
        // digitless form and the engine's grammar-legality filter promotes
        // the standalone-vowel variant (internally keyed `u2`, `u2.`,
        // `ay2`) to top-1 because the base rule produces a medial form
        // that is illegal standalone.

        cases.append(TestCase("issueD_engineTopSurfacesLegalStandaloneVowel") { ctx in
            let engine = BurmeseEngine()
            let expectations: [(key: String, expected: String)] = [
                ("u.", "ဥ"),
                ("u", "ဦ"),
                ("ay", "ဧ"),
            ]

            for expectation in expectations {
                let engineTop = engine.update(buffer: expectation.key, context: []).candidates.first?.surface
                ctx.assertEqual(
                    engineTop ?? "",
                    expectation.expected,
                    "engineTop.\(expectation.key)"
                )
            }
        })

        cases.append(TestCase("issueD_standaloneVowelDigitSuffixIsConsumed") { ctx in
            // Typing the variant-suffix form of a standalone independent
            // vowel in isolation must not leak the `2` as a literal
            // Myanmar digit. `u2` selects ဦ, `ay2` selects ဧ, and the
            // `u2:` compound picks up ဦး.
            let engine = BurmeseEngine()
            let expectations: [(key: String, expected: String)] = [
                ("u2", "ဦ"),
                ("ay2", "ဧ"),
                ("u2:", "ဦး"),
            ]
            for expectation in expectations {
                let top = engine.update(buffer: expectation.key, context: []).candidates.first?.surface ?? ""
                ctx.assertEqual(top, expectation.expected, "standaloneDigit.\(expectation.key)")
                let scalars = top.unicodeScalars.map(\.value)
                ctx.assertFalse(
                    scalars.contains(0x1042),
                    "standaloneDigit.\(expectation.key).noLiteralDigit",
                    detail: "top=\(top) scalars=\(scalars)"
                )
            }
        })

        // MARK: - Issue E: mid-buffer digit selects variant when the
        // letters+digit form a known rule-key prefix; stays literal otherwise.

        cases.append(TestCase("issueE_ky2arSelectsYaPinVariant") { ctx in
            // "ky2ar" should route through the ya-pin onset (103B), not
            // leak a literal Myanmar digit (1042) mid-syllable.
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "ky2ar", context: [])
            guard let top = state.candidates.first else {
                ctx.fail("ky2ar_noCandidates", detail: "panel empty")
                return
            }
            let scalars = top.surface.unicodeScalars.map(\.value)
            ctx.assertTrue(
                scalars.contains(0x103B),
                "ky2ar_topHasYaPin",
                detail: "missing 103B; top=\(top.surface) scalars=\(scalars)"
            )
            ctx.assertFalse(
                scalars.contains(0x1042),
                "ky2ar_topHasNoMyanmarDigit2",
                detail: "1042 present; top=\(top.surface) scalars=\(scalars)"
            )
            ctx.assertFalse(
                scalars.contains(0x103C),
                "ky2ar_topHasNoYaYit",
                detail: "103C present; top=\(top.surface) scalars=\(scalars)"
            )
        })

        cases.append(TestCase("issueE_t2aaSelectsRetroflex") { ctx in
            // "t2aa" should produce the Pali retroflex ဋ (100B) with aa,
            // not ta + literal digit + ah.
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "t2aa", context: [])
            guard let top = state.candidates.first else {
                ctx.fail("t2aa_noCandidates", detail: "panel empty")
                return
            }
            let scalars = top.surface.unicodeScalars.map(\.value)
            ctx.assertTrue(
                scalars.first == 0x100B,
                "t2aa_topStartsWithRetroflexT",
                detail: "expected 100B first; top=\(top.surface) scalars=\(scalars)"
            )
            ctx.assertFalse(
                scalars.contains(0x1042),
                "t2aa_topHasNoMyanmarDigit2",
                detail: "1042 present; top=\(top.surface) scalars=\(scalars)"
            )
        })

        cases.append(TestCase("issueE_loo2KeepsDigitAsLiteral") { ctx in
            // `l2` retroflex requires the `2` *before* the vowel letters
            // (i.e. `l2oo` → ဠဩ). When the `2` lands at the end of the
            // letters (`loo2`), no letter-run suffix pairs with `2` to
            // reach an onset terminal or standalone vowel, so the digit
            // stays literal and renders as `၂`.
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "loo2", context: [])
            guard let top = state.candidates.first else {
                ctx.fail("loo2_noCandidates", detail: "panel empty")
                return
            }
            let scalars = top.surface.unicodeScalars.map(\.value)
            ctx.assertTrue(
                scalars.contains(0x1042),
                "loo2_topHasLiteralDigit",
                detail: "expected 1042; top=\(top.surface) scalars=\(scalars)"
            )
        })

        cases.append(TestCase("issueE_kya2KeepsDigitAsLiteral") { ctx in
            // "kya2": `kya` is a full onset+vowel; `2` after it does not
            // extend any rule key, so it must stay literal (1042).
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "kya2", context: [])
            guard let top = state.candidates.first else {
                ctx.fail("kya2_noCandidates", detail: "panel empty")
                return
            }
            let scalars = top.surface.unicodeScalars.map(\.value)
            ctx.assertTrue(
                scalars.contains(0x1042),
                "kya2_topHasMyanmarDigit",
                detail: "expected 1042; top=\(top.surface) scalars=\(scalars)"
            )
        })

        // MARK: - Task 06: digit after a consonant+vowel run stays literal
        //
        // When a letter run already contains a consonant, a trailing `2`
        // cannot meaningfully select a standalone-vowel variant (consonant
        // + standalone vowel is illegal). The digit must peel off as a
        // literal Myanmar digit, not be absorbed as the `ay2`/`u2` suffix.

        cases.append(TestCase("task06_nay2dayKeepsDigitLiteral") { ctx in
            let engine = BurmeseEngine()
            let top = engine.update(buffer: "nay2day", context: []).candidates.first?.surface ?? ""
            let scalars = top.unicodeScalars.map(\.value)
            ctx.assertTrue(
                scalars.contains(0x1042),
                "nay2day_expectsLiteralDigit",
                detail: "top=\(top) scalars=\(scalars)"
            )
            ctx.assertFalse(
                scalars.contains(0x1027),
                "nay2day_mustNotContainIndependentE",
                detail: "ay2 absorbed as standalone ဧ; top=\(top) scalars=\(scalars)"
            )
        })

        cases.append(TestCase("task06_nay2KeepsDigitLiteralAtEnd") { ctx in
            let engine = BurmeseEngine()
            let top = engine.update(buffer: "nay2", context: []).candidates.first?.surface ?? ""
            let scalars = top.unicodeScalars.map(\.value)
            ctx.assertTrue(
                scalars.contains(0x1042),
                "nay2_expectsLiteralDigit",
                detail: "top=\(top) scalars=\(scalars)"
            )
            ctx.assertFalse(
                scalars.contains(0x1027),
                "nay2_mustNotContainIndependentE",
                detail: "top=\(top) scalars=\(scalars)"
            )
        })

        cases.append(TestCase("task06_kar2niKeepsDigitLiteral") { ctx in
            // `kar2` would match `ar2` (tall-aa cosmetic) but `correctAaShape`
            // already reconciles it. `2` must stay literal so the user sees
            // their typed digit in the surface.
            let engine = BurmeseEngine()
            let top = engine.update(buffer: "kar2ni", context: []).candidates.first?.surface ?? ""
            let scalars = top.unicodeScalars.map(\.value)
            ctx.assertTrue(
                scalars.contains(0x1042),
                "kar2ni_expectsLiteralDigit",
                detail: "top=\(top) scalars=\(scalars)"
            )
        })

        // MARK: - Issue F: kinzi cross-class fallback
        //
        // "pyin+thit" should parse as ပြင် (py + in) + kinzi stack + သစ်
        // (th + it), producing a surface with U+101E (tha). The previous
        // behavior consumed the `t` of `th` as a stack subscript via the
        // same-class na/ta path, leaving an orphan `h` that surfaced as a
        // standalone U+101F (ha) injection. Kinzi allows nga as a stack
        // upper over any consonant class — relaxing the stack rule for
        // nga restores the expected reading.
        cases.append(TestCase("issueF_pyinPlusThitRendersThaNotHa") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "pyin+thit", context: [])
            guard let top = state.candidates.first else {
                ctx.fail("pyinThit_noCandidates", detail: "panel empty")
                return
            }
            let scalars = top.surface.unicodeScalars.map(\.value)
            ctx.assertFalse(
                scalars.contains(0x101F),
                "pyinThit_noStandaloneHa",
                detail: "expected no 101F; top=\(top.surface) scalars=\(scalars)"
            )
            ctx.assertTrue(
                scalars.contains(0x101E),
                "pyinThit_hasTha",
                detail: "expected 101E (tha); top=\(top.surface) scalars=\(scalars)"
            )
        })

        cases.append(TestCase("issueF_hninPlusThitRendersThaNotHa") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "hnin+thit", context: [])
            guard let top = state.candidates.first else {
                ctx.fail("hninThit_noCandidates", detail: "panel empty")
                return
            }
            let scalars = top.surface.unicodeScalars.map(\.value)
            ctx.assertFalse(
                scalars.contains(0x101F),
                "hninThit_noStandaloneHa",
                detail: "expected no 101F; top=\(top.surface) scalars=\(scalars)"
            )
            ctx.assertTrue(
                scalars.contains(0x101E),
                "hninThit_hasTha",
                detail: "expected 101E (tha); top=\(top.surface) scalars=\(scalars)"
            )
        })

        cases.append(TestCase("issueF_myanPlusTharRendersThaNotHa") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "myan+thar", context: [])
            guard let top = state.candidates.first else {
                ctx.fail("myanThar_noCandidates", detail: "panel empty")
                return
            }
            let scalars = top.surface.unicodeScalars.map(\.value)
            ctx.assertFalse(
                scalars.contains(0x101F),
                "myanThar_noStandaloneHa",
                detail: "expected no 101F; top=\(top.surface) scalars=\(scalars)"
            )
            ctx.assertTrue(
                scalars.contains(0x101E),
                "myanThar_hasTha",
                detail: "expected 101E (tha); top=\(top.surface) scalars=\(scalars)"
            )
        })

        return TestSuite(name: "Ranking", cases: cases)
    }()
}
