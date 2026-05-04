import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-056: any contiguous run of two-or-more composing-
/// punctuation chars (`*`, `'`, `:`, `.`) — and trailing-singleton `'`
/// after Myanmar content — must NOT leak into the rendered Myanmar
/// surface as raw ASCII scalars (U+002A, U+0027, U+003A, U+002E)
/// interleaved between Myanmar consonants / vowels.
///
/// Architectural invariant from CLAUDE.md:
///
/// > Within a single composed run, Myanmar output never has Latin
/// > characters interleaved between Myanmar chars (see PropertySuite
/// > / FuzzSuite).
///
/// The pre-fix engine left doubled `**`, `''`, `::`, `..` mid-buffer
/// runs in the parser's emission, producing surfaces such as
/// `က**အာ` (`1000 002A 002A 1021 102C`) at rank 0. Single-mid-buffer
/// `*` is consumed correctly as the asat scalar; the bug fires when
/// the parser cannot match the redundant duplicate, leaving it as a
/// literal carry in the output.
public enum DoubledLiteralPunctSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    @inline(__always)
    private static func isMyanmarScalar(_ v: UInt32) -> Bool {
        v >= 0x1000 && v <= 0x109F
    }

    @inline(__always)
    private static func isStrictConsumePunctScalar(_ v: UInt32) -> Bool {
        v == 0x002A || v == 0x0027
    }

    @inline(__always)
    private static func isComposingPunctScalar(_ v: UInt32) -> Bool {
        v == 0x002A || v == 0x0027 || v == 0x003A || v == 0x002E
    }

    @inline(__always)
    private static func isAsteriskScalar(_ v: UInt32) -> Bool {
        v == 0x002A
    }

    @inline(__always)
    private static func isDocPunctScalar(_ v: UInt32) -> Bool {
        v == 0x003A || v == 0x002E
    }

    /// True when `surface` contains a PURE strict-consume run
    /// (only `*`/`'`, no `.`/`:`) directly between two Myanmar
    /// scalars where the run either contains `*` (asterisk has no
    /// document-punct role) OR has ≥2 strict-consume chars
    /// (doubled apostrophe leaks even though single `'` between
    /// Myanmar is silently consumed).
    ///
    /// Mixed-punct runs (containing `.` or `:`) are LEGITIMATE
    /// document punctuation per `MidBufferPunctuationSuite`
    /// (`ka*.tar` → `က*.တာ`, `ka..tar` → `က..တာ`).
    /// Trailing or leading punct (no Myanmar on the other side)
    /// is permitted per `ApostropheLiteralSuite` (`thar'`,
    /// `'thar`, `'thar'`). Myanmar punctuation U+104A / U+104B
    /// (`၊` / `။`) is treated as document punct, NOT as Myanmar
    /// for adjacency, so `<C><*><။><C>` is also allowed.
    private static func hasInterleavedComposingPunct(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 3 else { return false }
        @inline(__always) func isMyanmarLetter(_ v: UInt32) -> Bool {
            (v >= 0x1000 && v <= 0x109F) && v != 0x104A && v != 0x104B
        }
        var i = 0
        while i < scalars.count {
            guard isComposingPunctScalar(scalars[i]) else {
                i += 1
                continue
            }
            var runEnd = i + 1
            var strictConsumeCount = isStrictConsumePunctScalar(scalars[i]) ? 1 : 0
            var asteriskCount = isAsteriskScalar(scalars[i]) ? 1 : 0
            var docPunctCount = isDocPunctScalar(scalars[i]) ? 1 : 0
            while runEnd < scalars.count, isComposingPunctScalar(scalars[runEnd]) {
                if isStrictConsumePunctScalar(scalars[runEnd]) { strictConsumeCount += 1 }
                if isAsteriskScalar(scalars[runEnd]) { asteriskCount += 1 }
                if isDocPunctScalar(scalars[runEnd]) { docPunctCount += 1 }
                runEnd += 1
            }
            guard docPunctCount == 0 else {
                i = runEnd
                continue
            }
            guard asteriskCount >= 1 || strictConsumeCount >= 2 else {
                i = runEnd
                continue
            }
            let hasLeftMyanmar = i > 0 && isMyanmarLetter(scalars[i - 1])
            let hasRightMyanmar = runEnd < scalars.count && isMyanmarLetter(scalars[runEnd])
            if hasLeftMyanmar && hasRightMyanmar { return true }
            i = runEnd
        }
        return false
    }

    /// Reproduction inputs from TASK-056's bug class. The shared
    /// invariant: no candidate surface may contain a `*` or doubled
    /// `'` directly between Myanmar letter scalars. Three sub-classes:
    ///
    /// 1. **Doubled `**` / `''` mid-buffer** — original bug
    ///    (`k**ar` → leaked `က**အာ`, `kar''ka` → leaked `ကာ''က`).
    /// 2. **Mixed `*'` / `'*` strict-consume runs** — same shape
    ///    with a mixed-strict run.
    /// 3. **Single `*` directly between Myanmar via tone consumption
    ///    of a neighbouring `.`/`:`** (gap-fix coverage). When `.`
    ///    or `:` consumes as a tone marker (U+1037 / U+1038 — both
    ///    in the Myanmar range), an adjacent `*` ends up between
    ///    `<tone> 002A <Myanmar>`, leaking the asterisk verbatim
    ///    (`kar.*ar` → leaked `ကာ့*အာ`, `kar:*ar` → leaked
    ///    `ကား*အာ`, etc.).
    ///
    /// Doubled-`:`/`.` runs without `*`/`'`, mixed runs containing
    /// `.`/`:` (`*.`, `'.`, `*..`, `.*`, `:*.`), and trailing /
    /// leading singleton `'` are EXCLUDED — those are legitimate
    /// document-punctuation passthroughs enforced by
    /// `MidBufferPunctuationSuite` and `ApostropheLiteralSuite`.
    private static let bugInputs: [String] = [
        // Doubled asterisk
        "k**ar", "k**ka", "k**a", "ka**ka", "ka**ar", "kar**ka", "kar**ar",
        "ki**ar", "ko**ar",
        "k***ar", "k****ka",
        "k+**ka", "k**+ka", "ka**+kar",
        // Doubled apostrophe
        "k''ar", "k''ka", "ka''ka", "kar''ka", "ki''ar",
        "k'''ar", "k''''ka",
        // Mixed strict-consume runs
        "k*'ar", "k'*ar",
        // Two real syllables joined with strict-consume run
        "kya**kar", "kya''kar",
        // Gap-fix coverage: single `*` between Myanmar scalars
        // where the neighbouring `.`/`:` got consumed as a tone
        // marker (1037 / 1038), leaving `*` orphaned. The pre-fix
        // pipeline left these as `<C><vowel><tone><002A><Myanmar>`.
        "kar.*ar", "kar:*ar", "kya.*kar", "kya:*kar",
        "ka.*ar", "ka:*ar",
    ]

    /// Inputs whose top surface must be pure Myanmar OR the literal
    /// fallback — not contain interleaved punctuation.
    private static let regressionGuards: [(buffer: String, expectedTop: String)] = [
        // Single mid-buffer `*` continues to act as asat separator.
        ("k*ar", "\u{1000}\u{103A}\u{1021}\u{102C}"),                     // က်အာ
        // Single mid-buffer `'` continues to act as a soft separator.
        ("k'ka", "\u{1000}\u{1000}"),                                     // ကက
        // Trailing `**` collapses cleanly to a single asat (TASK-008).
        ("ka**", "\u{1000}\u{103A}"),                                     // က်
        ("k**",  "\u{1000}\u{103A}"),                                     // က်
        // TASK-055 + TASK-056 interaction: after the legality scan
        // rejects the `<C><dep-vowel><103A>` shape, the legitimate
        // `<C><consonant><103A>` sibling (`kar*` → `ကရ်`) is
        // promoted at rank 0; the doubled-`**` collapses cleanly
        // to a single asat via `collapseDoubledAsat` and the
        // `kar**`/`kar***` rank-0 surface follows the same
        // resolution as `kar*` itself.
        ("kar**", "\u{1000}\u{101B}\u{103A}"),                            // ကရ်
        ("kar***", "\u{1000}\u{101B}\u{103A}"),                           // ကရ်
        // Mixed-punct passthroughs (MidBufferPunctuationSuite invariants):
        // `*` adjacent to `.`/`:` is interpreted as part of a literal
        // document-punct group, not as an orphaned asat. The Myanmar
        // candidate keeps the `*.`, `.*`, `*:`, `:*` shape verbatim.
        ("ka*.tar", "\u{1000}\u{002A}\u{002E}\u{1010}\u{102C}"),           // က*.တာ
        ("ka.*tar", "\u{1000}\u{002E}\u{002A}\u{1010}\u{102C}"),           // က.*တာ
        ("ka..tar", "\u{1000}\u{002E}\u{002E}\u{1010}\u{102C}"),           // က..တာ
        ("ka::tar", "\u{1000}\u{003A}\u{003A}\u{1010}\u{102C}"),           // က::တာ
        // Trailing-singleton `'` survives as quote mark
        // (ApostropheLiteralSuite invariant).
        ("kar'", "\u{1000}\u{102C}\u{0027}"),                              // ကာ'
        // Trailing-doubled `''` survives (no Myanmar to its right).
        ("kar''", "\u{1000}\u{102C}\u{0027}\u{0027}"),                     // ကာ''
    ]

    public static let suite = TestSuite(name: "DoubledLiteralPunct", cases: [

        // Strict invariant: NO candidate surface in the panel may
        // contain `*`, `'`, `:`, `.` interleaved between Myanmar
        // scalars. Trailing punct (no Myanmar to its right) is OK.
        TestCase("noCandidate_hasComposingPunctBetweenMyanmar") { ctx in
            let engine = emptyEngine()
            for buffer in bugInputs {
                let state = engine.update(buffer: buffer, context: [])
                for c in state.candidates {
                    ctx.assertFalse(
                        hasInterleavedComposingPunct(c.surface),
                        buffer,
                        detail: "candidate '\(c.surface)' [\(hex(c.surface))] has *,',:,. between Myanmar scalars"
                    )
                }
            }
        },

        // Regression guard: existing single-`*`/single-`'`/`**`-trailing
        // shapes continue to surface their pre-fix top candidate.
        TestCase("singlePunct_andTrailingDoubled_unchanged") { ctx in
            let engine = emptyEngine()
            for entry in regressionGuards {
                let top = engine.update(buffer: entry.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top,
                    entry.expectedTop,
                    "\(entry.buffer)_topHex=\(hex(top))_expectedHex=\(hex(entry.expectedTop))"
                )
            }
        },

        // Sanity: no candidate at any rank for a Myanmar-leading
        // composable buffer should contain ASCII letters (which would
        // imply the literal-fallback path) AS WELL AS Myanmar scalars
        // mixed mid-surface (the script-purity invariant).
        TestCase("noCandidateMixesMyanmarAndAsciiLetters") { ctx in
            let engine = emptyEngine()
            for buffer in bugInputs {
                let state = engine.update(buffer: buffer, context: [])
                for c in state.candidates {
                    let scalars = Array(c.surface.unicodeScalars).map(\.value)
                    var sawMyanmar = false
                    var sawAsciiLetter = false
                    for v in scalars {
                        if isMyanmarScalar(v) { sawMyanmar = true }
                        if (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A) {
                            sawAsciiLetter = true
                        }
                    }
                    if sawMyanmar && sawAsciiLetter {
                        ctx.assertTrue(
                            false,
                            buffer,
                            detail: "candidate '\(c.surface)' [\(hex(c.surface))] mixes Myanmar with ASCII letters"
                        )
                    }
                }
            }
        },
    ])
}
