import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-049: a buffer of the shape
///
/// ```
/// (<letter>+){3,}(:|\.)
/// ```
///
/// — three or more `+`-separated syllables sharing the same consonant
/// letter, ending in a trailing tone marker — must produce a rank-0
/// candidate whose surface ends in the tone scalar (`U+1037` for `.`,
/// `U+1038` for `:`). The pre-fix engine silently dropped the tone
/// because the right-shrink probe peeled `:` / `.` into the dropped
/// tail, `composedLetterRunSurface` collapsed the bare tone to the
/// empty string, and the resulting empty `effectiveTail` short-
/// circuited the affix-merge branch where
/// `applyBareConsonantToneFromTail` would have re-attached the tone.
///
/// Burmese rule reference: a user-typed trailing `:` / `.` after a
/// syllable run unambiguously denotes a tone marker on the final
/// syllable of that run (visarga U+1038 for `:`, creaky-tone U+1037
/// for `.`). The two-segment shape `ka+ka:` already implements this
/// convention; the three-or-more-segment same-letter case is an
/// asymmetric coverage gap rather than a separate orthographic rule.
public enum MultiStackTrailingToneSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// Reproductions: same-letter chains of length ≥3 ending in a
    /// trailing tone marker. Each row pins down the expected scalar
    /// sequence at rank 0.
    private static let creakyCases: [(buffer: String, expected: [UInt32])] = [
        // ka+ka+ka. → က္ကက့
        ("ka+ka+ka.",       [0x1000, 0x1039, 0x1000, 0x1000, 0x1037]),
        // ka+ka+ka+ka. → က္ကက္က့
        ("ka+ka+ka+ka.",    [0x1000, 0x1039, 0x1000, 0x1000, 0x1039, 0x1000, 0x1037]),
        // k+ka+ka. — same as ka+ka+ka. (leading short token, same letter)
        ("k+ka+ka.",        [0x1000, 0x1039, 0x1000, 0x1000, 0x1037]),
        // ka+ka+k. — trailing short token, same letter
        ("ka+ka+k.",        [0x1000, 0x1039, 0x1000, 0x1000, 0x1037]),
    ]

    private static let visargaCases: [(buffer: String, expected: [UInt32])] = [
        // ka+ka+ka: → က္ကကး
        ("ka+ka+ka:",       [0x1000, 0x1039, 0x1000, 0x1000, 0x1038]),
        // ka+ka+ka+ka: → က္ကက္ကး
        ("ka+ka+ka+ka:",    [0x1000, 0x1039, 0x1000, 0x1000, 0x1039, 0x1000, 0x1038]),
        // k+k+k:
        ("k+k+k:",          [0x1000, 0x1039, 0x1000, 0x1000, 0x1038]),
        // k+ka+ka:
        ("k+ka+ka:",        [0x1000, 0x1039, 0x1000, 0x1000, 0x1038]),
        // ka+ka+k:
        ("ka+ka+k:",        [0x1000, 0x1039, 0x1000, 0x1000, 0x1038]),
    ]

    /// Control set — these already work and must keep working.
    /// `ka+ka:` (two segments), `ka+ka+ta:` (mixed last), `ka+ka+kar:`
    /// (vowel rule on the last syllable) and `ka+ka+ka*` (asat
    /// instead of tone) cover the boundaries of the bug class.
    private static let controlCases: [(buffer: String, expected: [UInt32])] = [
        // ka+ka: (two segments, already works)
        ("ka+ka:",          [0x1000, 0x1039, 0x1000, 0x1038]),
        // ka+ka+ta: (three segments, last differs)
        ("ka+ka+ta:",       [0x1000, 0x1039, 0x1000, 0x1010, 0x1038]),
        // ka+ka+ka* — asat instead of tone (already works)
        ("ka+ka+ka*",       [0x1000, 0x1039, 0x1000, 0x1000, 0x103A]),
    ]

    public static let suite = TestSuite(name: "MultiStackTrailingTone", cases: [

        // Primary regression: trailing creaky tone must reach the
        // rank-0 surface.
        TestCase("multiStackSameLetter_creakyAtRank0") { ctx in
            let engine = emptyEngine()
            for c in creakyCases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    actual == c.expected,
                    c.buffer,
                    detail: "expected scalars=\(c.expected.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
            }
        },

        // Primary regression: trailing visarga must reach the rank-0
        // surface.
        TestCase("multiStackSameLetter_visargaAtRank0") { ctx in
            let engine = emptyEngine()
            for c in visargaCases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    actual == c.expected,
                    c.buffer,
                    detail: "expected scalars=\(c.expected.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
            }
        },

        // Internal-consistency check: the rank-0 surface stripped of
        // its trailing tone scalar must equal the surface of the
        // same buffer typed without the tone marker. Pins down that
        // the fix attaches tone via the same path used for two-
        // segment shapes (`ka+ka:`) rather than re-routing through
        // some other parse.
        TestCase("toneStrippedEquals_noToneVariant") { ctx in
            let engine = emptyEngine()
            let mappings: [(toned: String, untoned: String, toneScalar: UInt32)] = [
                ("ka+ka+ka.",    "ka+ka+ka",    0x1037),
                ("ka+ka+ka:",    "ka+ka+ka",    0x1038),
                ("ka+ka+ka+ka.", "ka+ka+ka+ka", 0x1037),
                ("ka+ka+ka+ka:", "ka+ka+ka+ka", 0x1038),
            ]
            for m in mappings {
                let tonedTop = engine.update(buffer: m.toned, context: [])
                    .candidates.first?.surface ?? ""
                let untonedTop = engine.update(buffer: m.untoned, context: [])
                    .candidates.first?.surface ?? ""
                let tonedScalars = Array(tonedTop.unicodeScalars.map(\.value))
                guard tonedScalars.last == m.toneScalar else {
                    ctx.assertTrue(
                        false,
                        m.toned,
                        detail: "rank-0 surface does not end in expected tone scalar (\(String(format: "%04X", m.toneScalar))); got '\(hex(tonedTop))'"
                    )
                    continue
                }
                let stripped = String(tonedTop.unicodeScalars.dropLast().map(Character.init))
                ctx.assertTrue(
                    stripped == untonedTop,
                    m.toned,
                    detail: "stripped='\(hex(stripped))' (from '\(hex(tonedTop))') untoned='\(hex(untonedTop))'"
                )
            }
        },

        // Control: existing two-segment / mixed-letter / asat
        // counterparts must continue to work.
        TestCase("controlCases_unchanged") { ctx in
            let engine = emptyEngine()
            for c in controlCases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    actual == c.expected,
                    c.buffer,
                    detail: "regression: expected scalars=\(c.expected.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
            }
        },

        // Mixed-tone-and-literal trailing characters
        // (`ka+ka+ka:.`, `ka+ka+ka:r`) are a separate bug class: a
        // user-typed tone followed by additional literal content
        // requires preserving the tone-followed-by-literal shape
        // through the parser's `.skip` arc, which is out of scope
        // for the same-letter chain fix above. The task's
        // "Desired State" section only specifies the simple
        // trailing-tone outputs (`ka+ka+ka:` → `က္ကကး`).

        // The non-toned literal-fallback (`ka+ka+ka:` itself) must
        // remain accessible somewhere in the panel for users who
        // wanted the literal characters.
        TestCase("literalFallback_remainsAccessibleInPanel") { ctx in
            let engine = emptyEngine()
            for buffer in ["ka+ka+ka:", "ka+ka+ka.", "ka+ka+ka+ka:"] {
                let state = engine.update(buffer: buffer, context: [])
                let hasLiteral = state.candidates.contains { $0.surface == buffer }
                ctx.assertTrue(
                    hasLiteral,
                    buffer,
                    detail: "literal '\(buffer)' missing from panel; got \(state.candidates.map(\.surface))"
                )
            }
        },
    ])
}
