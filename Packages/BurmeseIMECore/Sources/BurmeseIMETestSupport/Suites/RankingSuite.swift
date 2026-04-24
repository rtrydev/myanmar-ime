import Foundation
@_spi(Testing) import BurmeseIMECore

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
    ///
    /// A descender onset with an intervening medial (U+103B…U+103E) keeps
    /// short-aa — the medial already disambiguates the round bottom, and
    /// native orthography writes `ပြော`, `ပွား`, `ဂြော` with ာ. Matches
    /// the medial exception applied by `BurmeseEngine.correctAaShape`.
    private static func hasWrongAaShape(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        for i in 0..<scalars.count {
            let v = scalars[i].value
            guard v == shortAaScalar || v == tallAaScalar else { continue }
            var sawMedial = false
            var j = i - 1
            while j >= 0 {
                let prev = scalars[j].value
                if prev >= 0x103B && prev <= 0x103E { sawMedial = true }
                if isConsonantScalar(prev) {
                    let wantsTall = requiresTallAaScalars.contains(prev) && !sawMedial
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

        cases.append(TestCase("issueA_longOOVInputKeepsCanonicalAaAfterPa") { ctx in
            // Same buffer, same pool-collapse bug, but verified via a
            // semantic anchor: `pyaung` carries a medial (ya-yit U+103C)
            // on the descender ပ, so the canonical orthography is
            // short-aa ပြောင် — the medial already disambiguates the
            // round bottom and tall-aa ါ would be wrong (task 11).
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
            // Bare-vowel top picks depend on LM log-prob + lexicon frequency
            // to break the grammar-legal tie between the short and long
            // independent-vowel siblings. Under null signals all candidates
            // tie at `parserScore=0` and the comparator falls back to raw
            // parser order, which picks the long form. Bind to the bundled
            // artifacts so the real engine signals decide the ranking.
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath),
                  let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let expectations: [(key: String, expected: String)] = [
                ("u.", "ဥ"),
                ("u", "ဥ"),
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

        // MARK: - Issue E: digit always literal, never a variant selector
        //
        // ASCII digits typed by the user are always literal Myanmar/Arabic
        // numerals at the position typed. They never route to an internal
        // variant key (`ky2`, `t2`, `u2`, `ay2`, …) — users pick variants
        // from the candidate panel after typing the digit-less reading.

        cases.append(TestCase("issueE_ky2arKeepsDigitLiteral") { ctx in
            // `ky2ar`: the `2` must render as a literal digit (U+1042),
            // not steer the parser to the ya-pin (103B) variant. The
            // composable prefix is `ky` (ya-yit → 103C) and `2ar` is
            // literal tail; `ar` re-composes within the tail.
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "ky2ar", context: [])
            guard let top = state.candidates.first else {
                ctx.fail("ky2ar_noCandidates", detail: "panel empty")
                return
            }
            let scalars = top.surface.unicodeScalars.map(\.value)
            ctx.assertTrue(
                scalars.contains(0x1042),
                "ky2ar_topHasLiteralDigit",
                detail: "expected 1042; top=\(top.surface) scalars=\(scalars)"
            )
        })

        cases.append(TestCase("issueE_t2aaKeepsDigitLiteral") { ctx in
            // `t2aa`: the `2` must render as a literal digit (U+1042),
            // not steer the parser to the retroflex (`t2` → ဋ U+100B)
            // variant. Users who want ဋ type `ta` and pick from the panel.
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "t2aa", context: [])
            guard let top = state.candidates.first else {
                ctx.fail("t2aa_noCandidates", detail: "panel empty")
                return
            }
            let scalars = top.surface.unicodeScalars.map(\.value)
            ctx.assertTrue(
                scalars.contains(0x1042),
                "t2aa_topHasLiteralDigit",
                detail: "expected 1042; top=\(top.surface) scalars=\(scalars)"
            )
            ctx.assertFalse(
                state.candidates.contains { $0.surface == "ဋာ" },
                "t2aa_noRetroflexTFromDigit",
                detail: "top=\(top.surface) scalars=\(scalars)"
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

        // MARK: - Medial exception on descender onsets (task 11)
        //
        // `Grammar.requiresTallAa` lists six descender consonants whose
        // round bottom collides with short-aa ာ — the engine normally
        // rewrites them to tall-aa ါ. But when a medial sign (U+103B…
        // U+103E) sits between the consonant and the aa, the medial
        // already disambiguates the visual, and native orthography keeps
        // short-aa ာ (e.g. ပြော "say" — the single most frequent verb in
        // the lexicon — not ပြေါ). `correctAaShape` must skip the
        // rewrite in that case.

        @Sendable func assertTopScalars(
            _ ctx: TestContext,
            _ buffer: String,
            _ expected: [UInt32],
            _ label: String
        ) {
            let state = BurmeseEngine().update(buffer: buffer, context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertEqual(top.unicodeScalars.map(\.value), expected,
                "\(label): buffer=\(buffer) got=\(top)")
        }

        cases.append(TestCase("task11_pyawColon_shortAaAfterPaYaYitEkar") { ctx in
            // ပြော — ပ + ya-yit + e-kar + short-aa (canonical "say").
            assertTopScalars(ctx, "pyaw:",
                [0x1015, 0x103C, 0x1031, 0x102C],
                "pyawColon_shortAa")
        })

        cases.append(TestCase("task11_pyaw_shortAaAfterPaYaYitEkar") { ctx in
            assertTopScalars(ctx, "pyaw",
                [0x1015, 0x103C, 0x1031, 0x102C, 0x103A],
                "pyaw_shortAa")
        })

        cases.append(TestCase("task11_pyawDot_shortAaAfterPaYaYitEkar") { ctx in
            assertTopScalars(ctx, "pyaw.",
                [0x1015, 0x103C, 0x1031, 0x102C, 0x1037],
                "pyawDot_shortAa")
        })

        cases.append(TestCase("task11_pyaungColon_shortAaAfterPaYaYitEkar") { ctx in
            assertTopScalars(ctx, "pyaung:",
                [0x1015, 0x103C, 0x1031, 0x102C, 0x1004, 0x103A, 0x1038],
                "pyaungColon_shortAa")
        })

        cases.append(TestCase("task11_pyarColon_shortAaAfterPaYaYit") { ctx in
            assertTopScalars(ctx, "pyar:",
                [0x1015, 0x103C, 0x102C, 0x1038],
                "pyarColon_shortAa")
        })

        cases.append(TestCase("task11_pwarColon_shortAaAfterPaWaHswe") { ctx in
            assertTopScalars(ctx, "pwar:",
                [0x1015, 0x103D, 0x102C, 0x1038],
                "pwarColon_shortAa")
        })

        cases.append(TestCase("task11_gyawColon_shortAaAfterGaYaYitEkar") { ctx in
            assertTopScalars(ctx, "gyaw:",
                [0x1002, 0x103C, 0x1031, 0x102C],
                "gyawColon_shortAa")
        })

        cases.append(TestCase("task11_khyawColon_shortAaAfterKhaYaYitEkar") { ctx in
            assertTopScalars(ctx, "khyaw:",
                [0x1001, 0x103C, 0x1031, 0x102C],
                "khyawColon_shortAa")
        })

        cases.append(TestCase("task11_dyawColon_shortAaAfterDaYaYitEkar") { ctx in
            assertTopScalars(ctx, "dyaw:",
                [0x1012, 0x103C, 0x1031, 0x102C],
                "dyawColon_shortAa")
        })

        // Controls: bare descender with no medial must KEEP tall-aa.

        cases.append(TestCase("task11_pawColon_tallAaPreservedWithoutMedial") { ctx in
            assertTopScalars(ctx, "paw:",
                [0x1015, 0x1031, 0x102B],
                "pawColon_tallAa")
        })

        cases.append(TestCase("task11_parColon_tallAaPreservedWithoutMedial") { ctx in
            assertTopScalars(ctx, "par:",
                [0x1015, 0x102B, 0x1038],
                "parColon_tallAa")
        })

        // Control: non-descender onset with medial always used short-aa;
        // regression guard so the exception doesn't accidentally flip
        // anyone's correct shape.
        cases.append(TestCase("task11_kyawColon_shortAaPreservedOnNonDescender") { ctx in
            assertTopScalars(ctx, "kyaw:",
                [0x1000, 0x103C, 0x1031, 0x102C],
                "kyawColon_shortAa")
        })

        // MARK: - Task 02: orphan ZWNJ + dep-vowel sanitizer

        @Sendable func hasOrphanZwnjMark(_ surface: String) -> Bool {
            let scalars = Array(surface.unicodeScalars)
            guard scalars.count >= 2, scalars[0].value == 0x200C else { return false }
            let v = scalars[1].value
            return (v >= 0x102B && v <= 0x103A)
        }

        // Group 1: independent-vowel rank 1 exists; orphan ZWNJ forms must
        // be removed from the panel. Bare `u` resolves to `ဥ` (short u)
        // per tasks/ 03; the long-u `ဦ` stays in the panel as an
        // alternate. Bare `u` needs real LM + lexicon signals to rank the
        // short form above the long sibling — both surfaces are grammar-
        // legal and tie under the null comparator. Cases with a unique
        // rank-1 surface stay on the default engine.
        for (buffer, expected, needsBundled) in [
            ("u", "ဥ", true),
            ("u:", "ဦး", false),
            ("u.", "ဥ", false),
            ("ay", "ဧ", false),
            ("oo", "ဩ", false),
            ("oo:", "ဪ", false),
            ("ii", "ဤ", false),
            ("ii.", "ဣ", false),
        ] {
            cases.append(TestCase("task02_orphanZwnj_suppressed_\(buffer)") { ctx in
                let engine: BurmeseEngine
                if needsBundled {
                    guard let lexPath = BundledArtifacts.lexiconPath,
                          let store = SQLiteCandidateStore(path: lexPath),
                          let lmPath = BundledArtifacts.trigramLMPath,
                          let lm = try? TrigramLanguageModel(path: lmPath) else {
                        ctx.assertTrue(true, "skipped_noBundledArtifacts")
                        return
                    }
                    engine = BurmeseEngine(candidateStore: store, languageModel: lm)
                } else {
                    engine = BurmeseEngine()
                }
                let state = engine.update(buffer: buffer, context: [])
                let surfaces = state.candidates.map(\.surface)
                ctx.assertTrue(
                    surfaces.first == expected,
                    "task02_top_\(buffer)",
                    detail: "expected top=\(expected); got: \(surfaces)"
                )
                ctx.assertFalse(
                    surfaces.contains(where: hasOrphanZwnjMark),
                    "task02_noOrphanSibling_\(buffer)",
                    detail: "orphan ZWNJ+mark present for \(buffer); got: \(surfaces)"
                )
            })
        }

        // Group 2: no legal independent-vowel form exists; orphan must
        // survive as fallback so the user can still commit something.
        for buffer in ["ay.", "ay:", "aw.", "aw:"] {
            cases.append(TestCase("task02_orphanZwnj_preservedFallback_\(buffer)") { ctx in
                let state = BurmeseEngine().update(buffer: buffer, context: [])
                let surfaces = state.candidates.map(\.surface)
                ctx.assertFalse(
                    surfaces.isEmpty,
                    "task02_fallbackNotEmpty_\(buffer)",
                    detail: "panel must keep orphan fallback when no legal sibling exists")
            })
        }

        cases.append(TestCase("task02_awPromotedOrphanBecomesLegalCandidate") { ctx in
            let state = BurmeseEngine().update(buffer: "aw", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(
                surfaces.first == "\u{1021}\u{1031}\u{102C}\u{103A}",
                "task02_awTopPromoted",
                detail: "expected promoted orphan surface; got: \(surfaces)"
            )
            ctx.assertFalse(
                surfaces.contains { surface in
                    surface.unicodeScalars.contains { $0.value < 0x1000 || $0.value > 0x109F }
                },
                "task02_awNoAsciiTail",
                detail: "aw candidates must stay Myanmar-only; got: \(surfaces)"
            )
        })

        // Task 01 (mid-surface orphan promotion): buffers whose DP emits
        // a dep-vowel after an asat with no anchor now generate a legal
        // အ-anchored sibling. The panel top must be the anchored form.
        for (buffer, expectedTop) in [
            ("aungain", "\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}\u{1021}\u{102D}\u{1014}\u{103A}"),  // အောင်အိန်
            ("aungout", "\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}\u{1021}\u{1031}\u{1021}\u{102C}\u{1000}\u{103A}"),  // အောင်အေအာက်
            ("outain",  "\u{1021}\u{1031}\u{102C}\u{1000}\u{103A}\u{1021}\u{102D}\u{1014}\u{103A}"),  // အောက်အိန်
        ] {
            cases.append(TestCase("tasksDir01_midSurfaceOrphanPromoted_\(buffer)") { ctx in
                let top = BurmeseEngine().update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top, expectedTop,
                    "tasksDir01_midSurfaceOrphanPromoted_\(buffer)"
                )
            })
        }

        // Task 01 (sanitizer): no candidate in the panel may contain a
        // dependent-vowel / tone-mark / medial without a consonant anchor
        // reachable via the skippable back-walk, when at least one clean
        // sibling exists in the panel.
        cases.append(TestCase("tasksDir01_noOrphanWhenCleanAvailable") { ctx in
            let engine = BurmeseEngine()
            for buffer in ["aungain", "aungout", "outain", "outaung", "nayout", "kayout"] {
                let surfaces = engine.update(buffer: buffer, context: []).candidates.map(\.surface)
                for surface in surfaces {
                    ctx.assertTrue(
                        SyllableParser.scanOutputLegality(surface),
                        "tasksDir01_noOrphanWhenCleanAvailable_\(buffer)",
                        detail: "unanchored mark surfaced for \(buffer): \(surface)"
                    )
                }
            }
        })

        cases.append(TestCase("task02_promotedOrphanRecomputesLegality") { ctx in
            let parser = SyllableParser()
            let orphan = parser.parseCandidates("aw", maxResults: 8).first {
                let scalars = Array($0.output.unicodeScalars)
                return scalars.count >= 2
                    && scalars[0].value == 0x200C
                    && (0x102B...0x103E).contains(scalars[1].value)
            }
            guard let orphan,
                  let promoted = BurmeseEngine.promoteOrphanZwnjToImplicitA(orphan) else {
                ctx.fail("task02_promotedSetup", detail: "expected an orphan parse for aw")
                return
            }
            ctx.assertTrue(
                promoted.output == "\u{1021}\u{1031}\u{102C}\u{103A}",
                "task02_promotedSurface",
                detail: "expected promoted output to replace ZWNJ with အ; got: \(promoted.output)"
            )
            ctx.assertTrue(
                promoted.legalityScore > 0,
                "task02_promotedIsLegal",
                detail: "promoted parse inherited legality=\(promoted.legalityScore); output=\(promoted.output)"
            )
        })

        // Group 3: unrelated buffers (no orphan to begin with) must remain
        // byte-identical at rank 1.
        for (buffer, expectedTop) in [
            ("a", "အ"),
            ("aa", "အ"),
        ] {
            cases.append(TestCase("task02_unchanged_\(buffer)") { ctx in
                let state = BurmeseEngine().update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertEqual(top, expectedTop,
                    "task02_group3_\(buffer)_top")
            })
        }

        // Task 04 — leading literal characters must not collapse the
        // candidate panel. Each bug case maps the literal head verbatim
        // onto each Myanmar surface produced by the composable middle,
        // so the top candidate = leadingLiteral + engine(composable).top.
        for (buffer, leading, middle, trailing) in [
            (".aung", ".", "aung", ""),
            (",aung", ",", "aung", ""),
            ("!mu", "!", "mu", ""),
            ("?mu", "?", "mu", ""),
            ("(thar)", "(", "thar", ")"),
            ("[thar]", "[", "thar", "]"),
            ("<thar>", "<", "thar", ">"),
            (";thar", ";", "thar", ""),
            ("@thar", "@", "thar", ""),
            ("#thar", "#", "thar", ""),
            ("$thar", "$", "thar", ""),
            ("%thar", "%", "thar", ""),
            ("&thar", "&", "thar", ""),
            ("\"thar\"", "\"", "thar", "\""),
        ] {
            cases.append(TestCase("task04_leadingLiteral_\(buffer)") { ctx in
                let engine = BurmeseEngine()
                let state = engine.update(buffer: buffer, context: [])
                let surfaces = state.candidates.map(\.surface)
                ctx.assertFalse(
                    surfaces.isEmpty,
                    "task04_nonEmpty_\(buffer)",
                    detail: "leading literal \(buffer) produced no candidates"
                )
                let middleState = engine.update(buffer: middle, context: [])
                let middleTop = middleState.candidates.first?.surface ?? ""
                let expected = leading + middleTop + trailing
                ctx.assertTrue(
                    surfaces.first == expected,
                    "task04_top_\(buffer)",
                    detail: "expected top=\(expected); got: \(surfaces)"
                )
            })
        }

        // Task 04 — currently-working inputs must return byte-identical
        // surfaces after the refactor. `'thar'` uses `'` as a composable
        // null-vowel separator so the apostrophes get swallowed; `123kya`
        // flows through the separate leading-digit path.
        for (buffer, expectedTop) in [
            ("'thar'", "သာ"),
            ("123kya", "၁၂၃ကြ"),
        ] {
            cases.append(TestCase("task04_preservedBehavior_\(buffer)") { ctx in
                let state = BurmeseEngine().update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertEqual(top, expectedTop,
                    "task04_preserved_\(buffer)")
            })
        }

        // Task 09 — implicit kinzi / virama stack inference.
        //
        // When a buffer has an orthographic same-class stack site
        // (coda `n`/`ng` followed by a same-class onset), the stacked
        // form must appear within the top 3 candidates without the user
        // having to type `+`. Cross-class or non-stackable sites must
        // leave the unstacked form at the top (negative controls).
        for (buffer, stacked) in [
            ("minga",       "မင်္ဂ"),
            ("mingalar",    "မင်္ဂလာ"),
            ("mingalarpar", "မင်္ဂလာပါ"),
            ("singa",       "စင်္ဂ"),
            ("sanda",       "စန္ဒ"),
        ] {
            cases.append(TestCase("task09_impliedStack_\(buffer)") { ctx in
                let engine = BurmeseEngine()
                let state = engine.update(buffer: buffer, context: [])
                let top3 = Array(state.candidates.prefix(3)).map(\.surface)
                ctx.assertTrue(
                    top3.contains(stacked),
                    "task09_stacked_\(buffer)",
                    detail: "expected \(stacked) in top3; got: \(top3); all: \(state.candidates.map(\.surface))"
                )
            })
        }

        // Negative controls: inputs whose context does not produce a
        // legal same-class stack must keep the unstacked form at rank 1.
        for (buffer, expectedTop) in [
            ("min",       "မင်"),
            ("san",       "စန်"),
            ("sin",       "စင်"),
            ("minmin",    "မင်မင်"),
            ("kanlay",    "ကန်လေ"),
            ("kaung",     "ကောင်"),
        ] {
            cases.append(TestCase("task09_noStack_\(buffer)") { ctx in
                let engine = BurmeseEngine()
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top, expectedTop,
                    "task09_noStackTop_\(buffer)"
                )
            })
        }
        cases.append(TestCase("task09_noStack_onsetlessNonA_idsvlye") { ctx in
            let top = BurmeseEngine().update(buffer: "idsvlye", context: [])
                .candidates
                .first?
                .surface ?? ""
            ctx.assertFalse(
                top.unicodeScalars.contains { $0.value == 0x1039 },
                "task09_noStack_onsetlessNonA_idsvlye",
                detail: "initial non-a vowel must not trigger implicit Pali stack; got \(top)"
            )
        })

        // Explicit `+` disambiguator must continue to produce the same
        // stacked top candidate as before. Regression guard for the fix.
        for (buffer, stacked) in [
            ("min+galar", "မင်္ဂလာ"),
            ("sin+ga",    "စင်္ဂ"),
            ("san+da",    "စန္ဒ"),
        ] {
            cases.append(TestCase("task09_explicitPlus_\(buffer)") { ctx in
                let engine = BurmeseEngine()
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top, stacked,
                    "task09_explicitPlusTop_\(buffer)"
                )
            })
        }

        // Task 10: a mid-buffer ASCII digit must not strand a dependent
        // vowel or medial behind a ZWNJ. The digit is literal — it splices
        // into the composed surface at the scalar offset corresponding to
        // the letters typed before it, while the letters on both sides
        // parse as a unified syllable.
        for (buffer, expectedTop) in [
            ("t2ote",    "တ၂ုတ်"),
            ("p2ote",    "ပ၂ုတ်"),
            ("k2ote",    "က၂ုတ်"),
            ("th2ar",    "သ၂ာ"),
            ("n2ay",     "န၂ေ"),
            ("k3aung",   "က၃ောင်"),
            ("ky2un",    "ကြ၂ူန"),
        ] {
            cases.append(TestCase("task10_midDigit_\(buffer)") { ctx in
                let engine = BurmeseEngine()
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top, expectedTop,
                    "task10_midDigitTop_\(buffer)"
                )
                // Belt-and-suspenders: no candidate may emit ZWNJ + mark.
                for candidate in state.candidates {
                    let scalars = Array(candidate.surface.unicodeScalars)
                    for i in 0..<(scalars.count - 1) where scalars[i].value == 0x200C {
                        let next = scalars[i + 1].value
                        let isDepMark = (0x102B...0x103A).contains(next)
                        ctx.assertFalse(
                            isDepMark,
                            "task10_noZwnjMark_\(buffer)",
                            detail: "candidate '\(candidate.surface)' has ZWNJ+mark at \(i)"
                        )
                    }
                }
            })
        }

        // Trailing digits after a complete syllable must keep the current
        // behaviour: digit appears at the end, no surface rewriting.
        // `u2` / `u2:` depend on LM + lexicon to pick the short `ဥ` head
        // over the long `ဦ` sibling (both grammar-legal, tie under null
        // signals); others (`u.2`, `pa2`) have a unique rank-1 surface.
        for (buffer, expectedTop, needsBundled) in [
            ("u2",   "ဥ၂",   true),
            ("u.2",  "ဥ၂",   false),
            ("u2:",  "ဥ၂:",  true),
            ("pa2",  "ပ၂",   false),
        ] {
            cases.append(TestCase("task10_trailingDigit_\(buffer)") { ctx in
                let engine: BurmeseEngine
                if needsBundled {
                    guard let lexPath = BundledArtifacts.lexiconPath,
                          let store = SQLiteCandidateStore(path: lexPath),
                          let lmPath = BundledArtifacts.trigramLMPath,
                          let lm = try? TrigramLanguageModel(path: lmPath) else {
                        ctx.assertTrue(true, "skipped_noBundledArtifacts")
                        return
                    }
                    engine = BurmeseEngine(candidateStore: store, languageModel: lm)
                } else {
                    engine = BurmeseEngine()
                }
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top, expectedTop,
                    "task10_trailingDigitTop_\(buffer)"
                )
            })
        }

        // `ta2in` used to silently drop the `i` because `in` alone parsed
        // as the -ng coda and the `a` vowel got lost. After the mid-digit
        // strip, `tain` parses as one syllable with the `i` preserved.
        cases.append(TestCase("task10_taIn_preservesI") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "ta2in", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertEqual(top, "တ၂ိန်", "task10_ta2inTop")
            // The `ိ` (U+102D) must survive somewhere in the surface.
            let hasI = top.unicodeScalars.contains { $0.value == 0x102D }
            ctx.assertTrue(hasI, "task10_ta2in_retainsDepVowelI")
        })

        // Mid-digit after a kinzi connector must round-trip: the kinzi
        // stack on the letter side stays intact, and the digit lands
        // after the stacked cluster.
        cases.append(TestCase("task10_kinziPlusDigit_mingGa2lar") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "min+ga2lar", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertEqual(top, "မင်္ဂ၂လာ", "task10_minGa2larTop")
        })

        // Digit between an onset consonant and a medial letter (rarer
        // shape from the task spec). The medial must stay attached to
        // the onset rather than promoting to a standalone consonant.
        for (buffer, expectedTop) in [
            ("k2yun",  "က၂ြူန"),
            ("l2wann", "လ၂ွန်န"),
        ] {
            cases.append(TestCase("task10_digitBetweenMedial_\(buffer)") { ctx in
                let engine = BurmeseEngine()
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top, expectedTop,
                    "task10_digitBetweenMedialTop_\(buffer)"
                )
            })
        }

        // tasks/ 01: onsetless bare-vowel buffers must never surface a ZWNJ
        // orphan at the top. The engine promotes the parser's
        // ZWNJ-prefixed dependent-vowel sequence to an implicit U+1021 (အ)
        // onset so a legal independent-vowel syllable is available.
        @Sendable func startsWithZwnj(_ surface: String) -> Bool {
            guard let first = surface.unicodeScalars.first else { return false }
            return first.value == 0x200C
        }
        for buffer in [
            "ain", "ain.", "ain:",
            "ar", "ar:",
            "on", "oun",
            "ote", "ate", "owk",
        ] {
            cases.append(TestCase("tasksDir01_onsetlessBareVowel_\(buffer)") { ctx in
                let state = BurmeseEngine().update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertFalse(
                    top.isEmpty,
                    "tasksDir01_nonEmpty_\(buffer)",
                    detail: "expected top candidate for onsetless \(buffer)"
                )
                ctx.assertFalse(
                    startsWithZwnj(top),
                    "tasksDir01_noZwnjTop_\(buffer)",
                    detail: "top candidate for \(buffer) begins with U+200C: '\(top)'"
                )
            })
        }

        // Specific surface assertions where the parser has a canonical
        // vowel rule and promotion yields a single-syllable independent-
        // vowel form.
        for (buffer, expectedTop) in [
            ("ar",    "\u{1021}\u{102C}"),               // အာ
            ("ain",   "\u{1021}\u{102D}\u{1014}\u{103A}"), // အိန်
            ("ain.",  "\u{1021}\u{102D}\u{1014}\u{1037}\u{103A}"), // အိန့်
            ("ain:",  "\u{1021}\u{102D}\u{1014}\u{103A}\u{1038}"), // အိန်း
            ("ote",   "\u{1021}\u{102F}\u{1010}\u{103A}"), // အုတ်
            ("ate",   "\u{1021}\u{102D}\u{1010}\u{103A}"), // အိတ်
        ] {
            cases.append(TestCase("tasksDir01_onsetlessBareVowelSurface_\(buffer)") { ctx in
                let state = BurmeseEngine().update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top, expectedTop,
                    "tasksDir01_onsetlessBareVowelSurfaceTop_\(buffer)"
                )
            })
        }

        // tasks/ 02: `aung`, `aung.`, `aung:` must produce the expected
        // `အောင်` family surfaces, not the multi-syllable garbage parses
        // that formerly won on score.
        for (buffer, expectedTop) in [
            ("aung",  "\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}"),        // အောင်
            ("aung.", "\u{1021}\u{1031}\u{102C}\u{1004}\u{1037}\u{103A}"),// အောင့်
            ("aung:", "\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}\u{1038}"),// အောင်း
        ] {
            cases.append(TestCase("tasksDir02_onsetlessAung_\(buffer)") { ctx in
                let state = BurmeseEngine().update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top, expectedTop,
                    "tasksDir02_onsetlessAungTop_\(buffer)"
                )
            })
        }

        // tasks/ 03: bare `i`, `ee`, `u` surface the short-form
        // independent vowel / implicit-a realization at the top, not the
        // coda-cluster (ည် / ယ်ယ်) or long-u (ဦ) that the DP would pick
        // on raw rule order. All three grammar-legal siblings tie under
        // null LM signals, so bind the real LM + lexicon to drive the
        // correct rank-1 pick.
        for (buffer, expectedTop) in [
            ("i",  "\u{1021}\u{102D}"),  // အိ (implicit-a + short i)
            ("ee", "\u{1021}\u{102E}"),  // အီ (implicit-a + long i)
            ("u",  "\u{1025}"),          // ဥ (short independent u)
        ] {
            cases.append(TestCase("tasksDir03_bareVowelPrimary_\(buffer)") { ctx in
                guard let lexPath = BundledArtifacts.lexiconPath,
                      let store = SQLiteCandidateStore(path: lexPath),
                      let lmPath = BundledArtifacts.trigramLMPath,
                      let lm = try? TrigramLanguageModel(path: lmPath) else {
                    ctx.assertTrue(true, "skipped_noBundledArtifacts")
                    return
                }
                let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top, expectedTop,
                    "tasksDir03_bareVowelPrimaryTop_\(buffer)"
                )
            })
        }

        // tasks/ 08: `Romanization.normalize` lowercases the buffer before
        // anything else runs, so an uppercase letter can never appear in a
        // composed surface. Lock the contract: typing an uppercase buffer
        // must produce the same composed output as its lowercase
        // equivalent (no raw A–Z leaking through).
        cases.append(TestCase("tasksDir08_uppercaseNormalization_KAR") { ctx in
            let upper = BurmeseEngine().update(buffer: "KAR", context: []).candidates.first?.surface ?? ""
            let lower = BurmeseEngine().update(buffer: "kar", context: []).candidates.first?.surface ?? ""
            ctx.assertEqual(upper, lower, "tasksDir08_KAR_matchesLowerKar")
            for scalar in upper.unicodeScalars {
                ctx.assertFalse(
                    scalar.value >= 0x41 && scalar.value <= 0x5A,
                    "tasksDir08_KAR_noUppercaseLeak",
                    detail: "surface '\(upper)' contains uppercase Latin"
                )
            }
        })

        // tasks/ 05: canonical Pali-loanword stacked forms must rank 1
        // for readings whose `<C>an+<C>` / `<C>ad+<C>` layout is the
        // authentic orthography. `padma` in particular wants a
        // cross-class `ဒ္မ` stack that `Grammar.isValidStack` rejects,
        // so the parser cannot synthesise it without help. The
        // engine's `paliStackOverrideSurface` injects the canonical
        // surface — exercise it with the default engine so the
        // contract holds without any bundled lexicon / LM coverage.
        for (buffer, expectedTop) in [
            ("ganda",   "\u{1002}\u{1014}\u{1039}\u{1012}"),              // ဂန္ဒ
            ("padma",   "\u{1015}\u{1012}\u{1039}\u{1019}"),              // ပဒ္မ
            ("vandana", "\u{1017}\u{1014}\u{1039}\u{1012}\u{1014}"),      // ဗန္ဒန
        ] {
            cases.append(TestCase("tasksDir05_paliStackTop_\(buffer)") { ctx in
                let state = BurmeseEngine().update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top, expectedTop,
                    "tasksDir05_paliStackTop_\(buffer)"
                )
            })
        }
        for (buffer, expectedSurface) in [
            ("atta",     "\u{1021}\u{1010}\u{1039}\u{1010}"),                      // အတ္တ
            ("padmaya",  "\u{1015}\u{1012}\u{1039}\u{1019}\u{101A}"),              // ပဒ္မယ
            ("vandanar", "\u{1017}\u{1014}\u{1039}\u{1012}\u{1014}\u{102C}"),      // ဗန္ဒနာ
            ("dhamma",   "\u{1013}\u{1019}\u{1039}\u{1019}"),                      // ဓမ္မ
            ("kappa",    "\u{1000}\u{1015}\u{1039}\u{1015}"),                      // ကပ္ပ
            ("ratna",    "\u{101B}\u{1010}\u{1039}\u{1014}"),                      // ရတ္န
            ("ahmada",   "\u{1021}\u{101F}\u{1039}\u{1019}\u{1012}"),              // အဟ္မဒ
            ("brahma",   "\u{1018}\u{101B}\u{101F}\u{1039}\u{1019}"),              // ဘရဟ္မ
        ] {
            cases.append(TestCase("tasksDir05_paliStackReachable_\(buffer)") { ctx in
                let surfaces = BurmeseEngine().update(buffer: buffer, context: [])
                    .candidates
                    .map(\.surface)
                ctx.assertTrue(
                    surfaces.contains(expectedSurface),
                    "tasksDir05_paliStackReachable_\(buffer)",
                    detail: "expected \(expectedSurface) in panel for \(buffer); got \(surfaces)"
                )
            })
        }

        // tasks/ 03: existing alternate surfaces must remain reachable in
        // the panel — promotion is a ranking change, not a delete.
        cases.append(TestCase("tasksDir03_bareVowelAlternates_u_retainsBwaUh") { ctx in
            let state = BurmeseEngine().update(buffer: "u", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(
                surfaces.contains("\u{1026}"),
                "tasksDir03_uKeepsLongIndependent",
                detail: "long ဦ must remain in the panel for 'u'; got: \(surfaces)"
            )
        })
        cases.append(TestCase("tasksDir03_bareVowelAlternates_i_retainsNyaCoda") { ctx in
            let state = BurmeseEngine().update(buffer: "i", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(
                surfaces.contains("\u{100A}\u{103A}"),
                "tasksDir03_iKeepsCoda",
                detail: "ည် must remain available for 'i'; got: \(surfaces)"
            )
        })

        return TestSuite(name: "Ranking", cases: cases)
    }()
}
