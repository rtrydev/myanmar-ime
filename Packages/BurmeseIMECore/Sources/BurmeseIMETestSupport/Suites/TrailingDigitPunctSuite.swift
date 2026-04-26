import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-003: a buffer of the shape
/// `<one or more ASCII digits>` + a single composing-punctuation modifier
/// in `{`.`, `:`}` must produce at least the Myanmar-digit primary
/// candidate and the ASCII-digit secondary candidate. The previous
/// implementation handled digits only inside the empty-`initialNormalized`
/// fallback branch; when the buffer had a non-empty composable that
/// shrank to empty under the right-shrink probe, the digit fallback
/// was never re-entered and the panel emptied.
public enum TrailingDigitPunctSuite {

    private static func emptyEngine(burmesePunctuation: Bool = false) -> BurmeseEngine {
        let suite = "TrailingDigitPunct-\(UUID().uuidString)"
        let settings = IMESettings(suiteName: suite)
        settings.burmesePunctuationEnabled = burmesePunctuation
        return BurmeseEngine(
            candidateStore: EmptyCandidateStore(),
            languageModel: NullLanguageModel(),
            settings: settings
        )
    }

    public static let suite = TestSuite(name: "TrailingDigitPunct", cases: [

        // Punctuation off: `<digits>.` must produce `<myanmar-digits>.`
        // and `<digits>.` candidates. `<digits>:` similarly.
        TestCase("trailingDot_punctOff_emitsDigitFallback") { ctx in
            let engine = emptyEngine(burmesePunctuation: false)
            let cases: [(buffer: String, expected: [String])] = [
                ("1.",   ["၁.",     "1."]),
                ("12.",  ["၁၂.",    "12."]),
                ("100.", ["၁၀၀.",   "100."]),
                ("1234.", ["၁၂၃၄.", "1234."]),
            ]
            for entry in cases {
                let surfaces = engine.update(buffer: entry.buffer, context: []).candidates.map(\.surface)
                ctx.assertFalse(
                    surfaces.isEmpty,
                    entry.buffer,
                    detail: "no candidates"
                )
                for expected in entry.expected {
                    ctx.assertTrue(
                        surfaces.contains(expected),
                        entry.buffer,
                        detail: "missing '\(expected)' in \(surfaces)"
                    )
                }
            }
        },

        TestCase("trailingColon_punctOff_emitsDigitFallback") { ctx in
            let engine = emptyEngine(burmesePunctuation: false)
            let cases: [(buffer: String, expected: [String])] = [
                ("1:",   ["၁:",     "1:"]),
                ("12:",  ["၁၂:",    "12:"]),
                ("100:", ["၁၀၀:",   "100:"]),
                ("1234:", ["၁၂၃၄:", "1234:"]),
            ]
            for entry in cases {
                let surfaces = engine.update(buffer: entry.buffer, context: []).candidates.map(\.surface)
                ctx.assertFalse(
                    surfaces.isEmpty,
                    entry.buffer,
                    detail: "no candidates"
                )
                for expected in entry.expected {
                    ctx.assertTrue(
                        surfaces.contains(expected),
                        entry.buffer,
                        detail: "missing '\(expected)' in \(surfaces)"
                    )
                }
            }
        },

        // Myanmar-digit primary first, ASCII-digit secondary second
        // (matches the convention of the existing digit-fallback path).
        TestCase("trailingPunct_myanmarPrimaryFirst") { ctx in
            let engine = emptyEngine(burmesePunctuation: false)
            let cases: [(buffer: String, primary: String, secondary: String)] = [
                ("1.",   "၁.",   "1."),
                ("12:",  "၁၂:",  "12:"),
                ("100.", "၁၀၀.", "100."),
            ]
            for entry in cases {
                let surfaces = engine.update(buffer: entry.buffer, context: []).candidates.map(\.surface)
                guard let primaryIdx = surfaces.firstIndex(of: entry.primary),
                      let secondaryIdx = surfaces.firstIndex(of: entry.secondary)
                else {
                    ctx.assertTrue(
                        false,
                        entry.buffer,
                        detail: "primary='\(entry.primary)' or secondary='\(entry.secondary)' missing in \(surfaces)"
                    )
                    continue
                }
                ctx.assertTrue(
                    primaryIdx < secondaryIdx,
                    entry.buffer,
                    detail: "primary at \(primaryIdx) should precede secondary at \(secondaryIdx); surfaces=\(surfaces)"
                )
            }
        },

        // Punctuation on: `.` maps to `။` (U+104B) on the Myanmar-digit
        // primary candidate. The ASCII-digit secondary keeps the raw
        // tail per the existing empty-`initialNormalized` fallback
        // convention (mapped on primary, unmapped on secondary). `:` is
        // NOT in `PunctuationMapper.mapping` (only `. ! ? , ;` are) and
        // stays as ASCII `:` regardless of the setting.
        TestCase("trailingDot_punctOn_mapsToMyanmarPunct") { ctx in
            let engine = emptyEngine(burmesePunctuation: true)
            let cases: [(buffer: String, expected: [String])] = [
                ("1.",  ["၁။",  "1."]),
                ("12.", ["၁၂။", "12."]),
            ]
            for entry in cases {
                let surfaces = engine.update(buffer: entry.buffer, context: []).candidates.map(\.surface)
                ctx.assertFalse(
                    surfaces.isEmpty,
                    entry.buffer,
                    detail: "no candidates"
                )
                for expected in entry.expected {
                    ctx.assertTrue(
                        surfaces.contains(expected),
                        entry.buffer,
                        detail: "missing '\(expected)' in \(surfaces)"
                    )
                }
            }
        },

        TestCase("trailingColon_punctOn_staysAscii") { ctx in
            let engine = emptyEngine(burmesePunctuation: true)
            let cases: [(buffer: String, expected: [String])] = [
                ("1:",  ["၁:",  "1:"]),
                ("12:", ["၁၂:", "12:"]),
            ]
            for entry in cases {
                let surfaces = engine.update(buffer: entry.buffer, context: []).candidates.map(\.surface)
                ctx.assertFalse(
                    surfaces.isEmpty,
                    entry.buffer,
                    detail: "no candidates"
                )
                for expected in entry.expected {
                    ctx.assertTrue(
                        surfaces.contains(expected),
                        entry.buffer,
                        detail: "missing '\(expected)' in \(surfaces)"
                    )
                }
            }
        },

        // Regression guards: counter-examples that work today must
        // continue to behave the same. `1.2` (additional content
        // after the punct) re-engages the parser. `1aa` and `aa1`
        // are existing digit-edge cases.
        TestCase("trailingPunct_counterExamplesUnchanged") { ctx in
            let engine = emptyEngine(burmesePunctuation: false)
            let cases: [(buffer: String, mustContain: [String])] = [
                ("1.2", ["၁.၂"]),
                ("1aa", ["၁အ"]),
                ("aa1", ["အ၁"]),
            ]
            for entry in cases {
                let surfaces = engine.update(buffer: entry.buffer, context: []).candidates.map(\.surface)
                for expected in entry.mustContain {
                    ctx.assertTrue(
                        surfaces.contains(expected),
                        entry.buffer,
                        detail: "missing '\(expected)' in \(surfaces)"
                    )
                }
            }
        },
    ])
}
