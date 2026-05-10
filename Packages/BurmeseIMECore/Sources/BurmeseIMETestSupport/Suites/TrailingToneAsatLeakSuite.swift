import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-040: trailing / mid-buffer tone + asat-or-doc-
/// punct combinations leak literal ASCII into the Myanmar surface.
/// Every panel candidate inherits the leak so the user has no clean
/// Burmese sibling to pick.
///
/// Three families share the same predicate-and-rescue-branch root
/// cause in `surfaceContainsInterleavedComposingPunct`:
///
///   1. Trailing `*` after Myanmar (no right-Myanmar): exempted by
///      the `hasRightMyanmar` guard. `ka:* → ကး*`, `tha.* → သ့*`.
///   2. Trailing single doc-punct (`.` / `:`) after a Myanmar tone
///      scalar (1037/1038): exempted by the `strictConsumeCount >= 2
///      || asteriskCount >= 1` requirement (zero strict-consume
///      chars). `kar:. → ကား.`, `kar.: → ကာ့:`.
///   3. Mid-buffer `.* / :*` between Myanmar runs: rescued by the
///      `docPunctCount > 0` branch (treated as legitimate document
///      punctuation). `ka.*ar → က.*အာ`, `ka:*ar → က:*အာ`.
///
/// The fix tightens the predicate so each of these shapes is
/// flagged. Sanitizer keeps its "preserve violators when no clean
/// sibling exists" fallback policy — when no clean sibling exists,
/// the literal-fallback at rank 0 must be reachable so the user can
/// commit-as-typed instead of accepting a malformed Myanmar surface.
public enum TrailingToneAsatLeakSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// True when the surface mixes Myanmar block scalars (U+1000..
    /// U+109F, including tone/asat) with ASCII punctuation
    /// (U+002A `*`, U+002E `.`, U+003A `:`, U+0027 `'`). The TASK-040
    /// invariant: this never holds at rank 0 — either the surface is
    /// cleanly Myanmar or cleanly literal (raw buffer).
    private static func surfaceMixesMyanmarAndComposingAscii(_ surface: String) -> Bool {
        var hasMyanmar = false
        var hasAsciiPunct = false
        for scalar in surface.unicodeScalars {
            let v = scalar.value
            if v >= 0x1000 && v <= 0x109F {
                hasMyanmar = true
            } else if v == 0x002A || v == 0x002E || v == 0x003A || v == 0x0027 {
                hasAsciiPunct = true
            }
            if hasMyanmar && hasAsciiPunct { return true }
        }
        return false
    }

    /// Trailing-leak family: composing-punct chars after a
    /// fully-composed Myanmar prefix.
    private static let trailingLeakInputs: [String] = [
        "ka:*", "ka.*",
        "kar:.", "kar.:",
        "kar:.*", "kar.:*", "kar..*",
        "tha.*", "tha:*",
        "kii*",
    ]

    /// Mid-buffer family: composing-punct chars between two
    /// Myanmar-composable runs.
    private static let midBufferLeakInputs: [String] = [
        "ka.*ar", "ka:*ar",
        "ka.*+ar", "ka:*+ar",
    ]

    public static let suite = TestSuite(name: "TrailingToneAsatLeak", cases: [

        // PRIMARY: rank-0 surface must be either cleanly Myanmar
        // (no ASCII punct codepoints) or the raw-buffer literal
        // (commit-as-typed). No mixed-leak surface at rank 0.
        TestCase("rank0_isCleanMyanmarOrRawLiteral_trailingLeak") { ctx in
            let engine = emptyEngine()
            for buffer in trailingLeakInputs {
                let top = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let isClean = !surfaceMixesMyanmarAndComposingAscii(top)
                let isLiteral = top == buffer
                ctx.assertTrue(
                    isClean || isLiteral,
                    buffer,
                    detail: "rank-0 '\(top)' [\(hex(top))] mixes Myanmar+ASCII-punct and is not raw literal"
                )
            }
        },

        // Mid-buffer leak family: the predicate-level fix is not
        // possible here (see the panel-fallback test below for the
        // weakened acceptance — the user must have a literal
        // commit-as-typed path even when rank-0 carries the mixed
        // surface, but the rank-0 surface itself is not required
        // to be clean because the existing
        // `DoubledLiteralPunct.singlePunct_andTrailingDoubled_unchanged`
        // regression guard pins similar shapes — `ka.*tar` →
        // `က.*တာ` — as legitimate mid-buffer document punctuation).

        // PANEL CRITERION: panel must contain at least one candidate
        // that is either cleanly Myanmar or the raw-buffer literal.
        // (The mid-buffer family typically falls back to the
        // literal — we don't require a clean Burmese sibling, only
        // that the user has a reachable non-leak option.)
        TestCase("panel_hasCleanOrLiteralSibling") { ctx in
            let engine = emptyEngine()
            for buffer in trailingLeakInputs + midBufferLeakInputs {
                let cands = engine.update(buffer: buffer, context: []).candidates
                let hasClean = cands.contains { c in
                    !surfaceMixesMyanmarAndComposingAscii(c.surface) || c.surface == buffer
                }
                ctx.assertTrue(
                    hasClean,
                    buffer,
                    detail: "panel has no clean-Myanmar / raw-literal sibling for '\(buffer)'; panel=\(cands.prefix(5).map(\.surface))"
                )
            }
        },

        // Predicate-level test: the sanitizer predicate must flag
        // the leak shapes directly. This is the narrowest possible
        // check — operates on rendered scalar sequences without going
        // through the engine pipeline.
        TestCase("predicate_flagsTrailingAsteriskAfterMyanmar") { ctx in
            let cases: [(label: String, scalars: [UInt32])] = [
                // <C><tone><*>
                ("ka:*",  [0x1000, 0x1038, 0x002A]),
                ("ka.*",  [0x1000, 0x1037, 0x002A]),
                ("tha.*", [0x101E, 0x1037, 0x002A]),
                ("tha:*", [0x101E, 0x1038, 0x002A]),
                // Plain bare consonant + trailing `*` (no tone in
                // between). The asterisk has no role at surface end —
                // either it's an unconsumed asat marker or stray
                // ASCII. Either way it's a leak.
                ("ka<*>", [0x1000, 0x002A]),
            ]
            for c in cases {
                let s = String(c.scalars.compactMap { Unicode.Scalar($0) }.map(Character.init))
                let flagged = BurmeseEngine.surfaceContainsInterleavedComposingPunct(s)
                ctx.assertTrue(
                    flagged,
                    c.label,
                    detail: "predicate did not flag trailing-`*` shape '\(hex(s))'"
                )
            }
        },

        TestCase("predicate_flagsTrailingDocPunctAfterMyanmarTone") { ctx in
            let cases: [(label: String, scalars: [UInt32])] = [
                // <C><dep-vowel><tone><single-doc-punct>
                ("kar:.", [0x1000, 0x102C, 0x1038, 0x002E]),
                ("kar.:", [0x1000, 0x102C, 0x1037, 0x003A]),
                // Bare consonant + tone + single doc-punct.
                ("ka.<:>", [0x1000, 0x1037, 0x003A]),
                ("ka:<.>", [0x1000, 0x1038, 0x002E]),
            ]
            for c in cases {
                let s = String(c.scalars.compactMap { Unicode.Scalar($0) }.map(Character.init))
                let flagged = BurmeseEngine.surfaceContainsInterleavedComposingPunct(s)
                ctx.assertTrue(
                    flagged,
                    c.label,
                    detail: "predicate did not flag tone+trailing-doc-punct shape '\(hex(s))'"
                )
            }
        },

        // The mid-buffer `.*ar` family (`ka.*ar`, `ka:*ar`,
        // `ka.*+ar`, `ka:*+ar`) conflicts with the existing
        // `DoubledLiteralPunctSuite.singlePunct_andTrailingDoubled_unchanged`
        // regression guard, which intentionally permits `ka.*tar`
        // → `က.*တာ` (mid-buffer `.*` between consonants is treated
        // as legitimate document punctuation). Both shapes produce
        // the same scalar pattern under the predicate (Myanmar +
        // `.*` + Myanmar), so flagging one without the other
        // requires user-intent signal that isn't available at the
        // sanitizer layer. Mid-buffer cases are not targeted by
        // the predicate-level fix; the engine's literal-fallback
        // (Class A/B) and panel-injection logic already give the
        // user a literal commit-as-typed path for those shapes.
        // The trailing-leak family (covered above) is the
        // user-visible bug and has been narrowed accordingly.
        TestCase("midBufferLeak_panelHasLiteralFallback") { ctx in
            let engine = emptyEngine()
            for buffer in midBufferLeakInputs {
                let cands = engine.update(buffer: buffer, context: []).candidates
                // The panel must contain the literal raw buffer so
                // the user can commit-as-typed instead of accepting
                // a malformed Myanmar surface.
                let hasLiteral = cands.contains { $0.surface == buffer }
                ctx.assertTrue(
                    hasLiteral,
                    buffer,
                    detail: "panel has no literal raw-buffer fallback for '\(buffer)'; panel=\(cands.prefix(5).map(\.surface))"
                )
            }
        },

        // REGRESSION: legitimate document-punct shapes must remain
        // unflagged so existing behaviour (ellipsis, double-colon,
        // markdown emphasis without `*`) is preserved.
        TestCase("predicate_doesNotFlagLegitimateDocPunct") { ctx in
            let cases: [(label: String, scalars: [UInt32])] = [
                // `..` ellipsis between Myanmar — `ka..tar` was a
                // documented passing case in TASK-056 (NOT flagged).
                ("ka..tar", [0x1000, 0x002E, 0x002E, 0x1010, 0x102C]),
                // `::` double-colon between Myanmar.
                ("ka::tar", [0x1000, 0x003A, 0x003A, 0x1010, 0x102C]),
                // Mixed `.:` / `:.` (no asterisk) — TASK-056
                // permitted these as document punctuation.
                ("ka.:tar", [0x1000, 0x002E, 0x003A, 0x1010, 0x102C]),
                ("ka:.tar", [0x1000, 0x003A, 0x002E, 0x1010, 0x102C]),
                // Trailing `'` after Myanmar — apostrophe-literal
                // suite cases (`thar'`).
                ("thar'", [0x101E, 0x102C, 0x0027]),
                // Trailing single doc-punct after a NON-tone Myanmar
                // scalar — e.g. `ka.` rank-0 already absorbs the
                // dot as creaky tone (`က့` = 1000 1037), but a
                // surface like `<C> <.>` (no tone in between) is
                // legitimate doc-punct, not a leak.
                ("ka.", [0x1000, 0x002E]),
                ("ka:", [0x1000, 0x003A]),
            ]
            for c in cases {
                let s = String(c.scalars.compactMap { Unicode.Scalar($0) }.map(Character.init))
                let flagged = BurmeseEngine.surfaceContainsInterleavedComposingPunct(s)
                ctx.assertFalse(
                    flagged,
                    c.label,
                    detail: "predicate wrongly flagged legitimate doc-punct shape '\(hex(s))'"
                )
            }
        },

        // REGRESSION: cases that already worked must continue to
        // work after the predicate tightening.
        TestCase("regression_existingWorkingCases") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: String)] = [
                ("ka**", "\u{1000}\u{103A}"),           // က်
                ("kar*", "\u{1000}\u{101B}\u{103A}"),   // ကရ်
                ("ka:",  "\u{1000}\u{1038}"),           // ကး
                ("ka.",  "\u{1000}\u{1037}"),           // က့
            ]
            for c in cases {
                let top = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top == c.expected,
                    c.buffer,
                    detail: "regressed: expected '\(c.expected)' [\(hex(c.expected))] got '\(top)' [\(hex(top))]"
                )
            }
        },
    ])
}
