import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-027: a buffer that ends with a vowel rule whose
/// final letter is a consonant-letter coda (`ay`, `aw`, `ar`, `aung`,
/// …) followed by an extra repeat of that final letter (`kayy`,
/// `kaww`, `karr`, `myaungy`) — or with an unrelated trailing
/// consonant letter (`kall`, `myaungy`) — must NOT produce a visible
/// standalone consonant scalar at the end of the rank-0 surface.
///
/// The clean single-syllable form is the user's intended output;
/// the repeated/unrelated trailing letter must be either dropped
/// or routed through the literal-tail recovery (TASK-016 model).
public enum RepeatedVowelRuleCodaSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// Reproductions where the rank-0 surface should equal the
    /// single-syllable form (the trailing repeated letter is dropped
    /// or absorbed).
    private static let cleanSingleSyllableCases: [(buffer: String, expected: [UInt32])] = [
        // ay-rule + repeated `y`
        ("kayy",    [0x1000, 0x1031]),                              // ကေ
        ("khayy",   [0x1001, 0x1031]),                              // ခေ
        ("mayy",    [0x1019, 0x1031]),                              // မေ
        ("tayy",    [0x1010, 0x1031]),                              // တေ
        ("shayy",   [0x101B, 0x103E, 0x1031]),                      // ရှေ
        // aw-rule + repeated `w`
        ("kaww",    [0x1000, 0x1031, 0x102C, 0x103A]),              // ကော်
        ("thaww",   [0x101E, 0x1031, 0x102C, 0x103A]),              // သော်
        // ar-rule + repeated `r`
        ("karr",    [0x1000, 0x102C]),                              // ကာ
        ("kharr",   [0x1001, 0x102B]),                              // ခါ (descender → tall-aa)
        // myaungy — trailing `y` after a closed syllable
        ("myaungy", [0x1019, 0x103C, 0x1031, 0x102C, 0x1004, 0x103A]), // မြောင်
        // kall — trailing `l` after a doubled consonant inherent-`a`
        ("kall",    [0x1000, 0x101C]),                              // ကလ
    ]

    /// Forbidden trailing standalone-consonant scalars by buffer.
    /// These are the visible spurious scalars that must not appear
    /// at the end of the rank-0 surface.
    private static let forbiddenTrailingScalars: [(buffer: String, scalar: UInt32)] = [
        ("kayy",    0x101A),  // ya
        ("khayy",   0x101A),
        ("mayy",    0x101A),
        ("tayy",    0x101A),
        ("shayy",   0x101A),
        ("kaww",    0x101D),  // wa
        ("thaww",   0x101D),
        ("karr",    0x101B),  // ra
        ("kharr",   0x101B),
        ("myaungy", 0x101A),
        // kall — second `l` (101C) appended; the surface should not
        // end in two adjacent base lakaungs.
    ]

    public static let suite = TestSuite(name: "RepeatedVowelRuleCoda", cases: [

        // The clean single-syllable form must be at rank 0.
        TestCase("repeatedCoda_singleSyllableAtRank0") { ctx in
            let engine = emptyEngine()
            for c in cleanSingleSyllableCases {
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

        // The trailing standalone consonant scalar must not appear
        // at the end of the rank-0 surface.
        TestCase("repeatedCoda_noTrailingStandaloneConsonant") { ctx in
            let engine = emptyEngine()
            for c in forbiddenTrailingScalars {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    scalars.last != c.scalar,
                    c.buffer,
                    detail: "rank-0 ends with spurious standalone '\(String(format: "%04X", c.scalar))' in '\(hex(surface))'"
                )
            }
        },

        // Tripled-letter chains must collapse the same way.
        TestCase("tripledCoda_singleSyllableAtRank0") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                ("karrr",  [0x1000, 0x102C]),
                ("kayyy",  [0x1000, 0x1031]),
                ("kawww",  [0x1000, 0x1031, 0x102C, 0x103A]),
            ]
            for c in cases {
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

        // Counter-examples — single-syllable `kay`, `kaw`, `kar`,
        // `myaung` must keep working, and `kya` (medial reading) must
        // remain reachable in the panel for the `kya` spelling.
        TestCase("singleSyllable_unchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                ("kay",    [0x1000, 0x1031]),
                ("kaw",    [0x1000, 0x1031, 0x102C, 0x103A]),
                ("kar",    [0x1000, 0x102C]),
                ("myaung", [0x1019, 0x103C, 0x1031, 0x102C, 0x1004, 0x103A]),
            ]
            for c in cases {
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

        // Medial spelling (`kya` → ya-pin medial) must remain
        // reachable in the panel.
        TestCase("medialSpelling_kya_reachable") { ctx in
            let engine = emptyEngine()
            let cands = engine.update(buffer: "kya", context: []).candidates
            // ya-pin medial = `1000 103B`, ya-yit = `1000 103C`
            let hasMedial = cands.contains { c in
                let s = Array(c.surface.unicodeScalars.map(\.value))
                return s == [0x1000, 0x103B] || s == [0x1000, 0x103C]
            }
            ctx.assertTrue(
                hasMedial,
                "kya_medial_reachable",
                detail: "no medial reading in panel: \(cands.prefix(6).map(\.surface))"
            )
        },
    ])
}
