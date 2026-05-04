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

    /// True when `surface` contains a run of contiguous composing-
    /// punct scalars between two Myanmar scalars where the run
    /// includes TWO OR MORE strict-consume chars (`*` or `'`).
    /// Two strict-consume chars in a run can't both fulfill their
    /// semantic role (asat / inherent-vowel separator), so the
    /// run leaks as raw ASCII — the bug shape. A single strict-
    /// consume + a single document-punct (`*.`, `'.`) is NOT
    /// flagged because the strict char gets consumed by the
    /// previous syllable, and the trailing `.`/`:` is the
    /// legitimate split point. Trailing punct (no Myanmar to its
    /// right) is permitted as legitimate literal-tail
    /// post-processing.
    private static func hasInterleavedComposingPunct(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 4 else { return false }
        var i = 0
        while i < scalars.count {
            guard isComposingPunctScalar(scalars[i]) else {
                i += 1
                continue
            }
            var runEnd = i + 1
            var strictConsumeCount = isStrictConsumePunctScalar(scalars[i]) ? 1 : 0
            while runEnd < scalars.count, isComposingPunctScalar(scalars[runEnd]) {
                if isStrictConsumePunctScalar(scalars[runEnd]) { strictConsumeCount += 1 }
                runEnd += 1
            }
            guard strictConsumeCount >= 2 else {
                i = runEnd
                continue
            }
            var leftHasMyanmar = false
            var j = i - 1
            while j >= 0 {
                if isMyanmarScalar(scalars[j]) { leftHasMyanmar = true; break }
                j -= 1
            }
            var rightHasMyanmar = false
            var k = runEnd
            while k < scalars.count {
                if isMyanmarScalar(scalars[k]) { rightHasMyanmar = true; break }
                k += 1
            }
            if leftHasMyanmar && rightHasMyanmar { return true }
            i = runEnd
        }
        return false
    }

    /// Reproduction inputs from TASK-056's bug class — runs of two or
    /// more contiguous composing-punct scalars between Myanmar scalars
    /// where the run includes a strict-consume punct (`*` asat marker
    /// or `'` inherent-vowel separator). Doubled-`:`/`.` runs without
    /// a `*`/`'` are EXCLUDED from this list because the existing
    /// `MidBufferPunctuationSuite` enforces them as legitimate
    /// document-punctuation passthroughs (`ka..tar` → `က..တာ`,
    /// `ka::tar` → `က::တာ`); only the strict-consume class can leak
    /// pathologically because those chars have no semantic role
    /// outside their consume-as-asat / consume-as-separator paths.
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
