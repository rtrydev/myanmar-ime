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

        return TestSuite(name: "Ranking", cases: cases)
    }()
}
