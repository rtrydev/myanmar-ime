import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-023 + TASK-024: a syllable that ends either in
/// a stop-coda asat (`<C> U+103A`) or a bare medial-bearing onset
/// (`<C> + medial(s)`) followed by a tone marker (`.` or `:`) must
/// produce a candidate whose surface absorbs the tone scalar at the
/// orthographically correct position, instead of leaving the literal
/// ASCII `.` / `:` in the surface tail.
///
/// Burmese rule reference (asat coda):
///   creaky:  `<C> U+1037 U+103A`  (tone before asat)
///   visarga: `<C> U+103A U+1038`  (tone after  asat)
///
/// Burmese rule reference (medial-bearing inherent-`a`):
///   creaky:  `<C> <medial(s)> U+1037`
///   visarga: `<C> <medial(s)> U+1038`
public enum AsatCodaToneSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    private static func surfaceContains(_ surface: String, scalar: UInt32) -> Bool {
        surface.unicodeScalars.contains { $0.value == scalar }
    }

    /// Asat-coda + tone reproductions from TASK-023.
    /// Each entry's expected scalar sequence is hand-verified against
    /// the Burmese orthographic ordering rule.
    private static let asatCreakyCases: [(buffer: String, expected: [UInt32])] = [
        ("kit.",   [0x1000, 0x1005, 0x1037, 0x103A]),                     // ကစ့်
        ("kut.",   [0x1000, 0x103D, 0x1010, 0x1037, 0x103A]),             // ကွတ့်
        ("let.",   [0x101C, 0x1000, 0x1037, 0x103A]),                     // လက့်
        ("myit.",  [0x1019, 0x103C, 0x1005, 0x1037, 0x103A]),             // မြစ့်
        ("kyaut.", [0x1000, 0x103B, 0x103D, 0x1010, 0x1037, 0x103A]),     // ကျွတ့်
        ("tibet.", [0x1010, 0x102E, 0x1018, 0x1000, 0x1037, 0x103A]),     // တီဘက့်
        ("kakat.", [0x1000, 0x1000, 0x1010, 0x1037, 0x103A]),             // ကကတ့်
    ]

    private static let asatVisargaCases: [(buffer: String, expected: [UInt32])] = [
        ("kit:",   [0x1000, 0x1005, 0x103A, 0x1038]),                            // ကစ်း
        ("let:",   [0x101C, 0x1000, 0x103A, 0x1038]),                            // လက်း
        ("myit:",  [0x1019, 0x103C, 0x1005, 0x103A, 0x1038]),                    // မြစ်း
        ("kywet:", [0x1000, 0x103B, 0x103D, 0x1000, 0x103A, 0x1038]),            // ကျွက်း
    ]

    /// Medial-bearing onset (no vowel) + tone — TASK-024.
    /// The engine emits ya-pin `103B` or ya-yit `103C` depending on
    /// rank tie-breaking — accept either as the medial scalar.
    private static let medialCreakyCases: [(buffer: String, prefixHexAlternatives: [[UInt32]], tail: UInt32)] = [
        // kya. → ကျ့ or ကြ့
        ("kya.",  [[0x1000, 0x103B], [0x1000, 0x103C]], 0x1037),
        // kywa. → ကျွ့ or ကြွ့
        ("kywa.", [[0x1000, 0x103B, 0x103D], [0x1000, 0x103C, 0x103D]], 0x1037),
        // khya. → ချ့ or ခြ့
        ("khya.", [[0x1001, 0x103B], [0x1001, 0x103C]], 0x1037),
        // kr. → ကြ့
        ("kr.",   [[0x1000, 0x103C]], 0x1037),
        // kw. → ကွ့
        ("kw.",   [[0x1000, 0x103D]], 0x1037),
    ]

    private static let medialVisargaCases: [(buffer: String, prefixHexAlternatives: [[UInt32]], tail: UInt32)] = [
        ("kya:",  [[0x1000, 0x103B], [0x1000, 0x103C]], 0x1038),
        ("kywa:", [[0x1000, 0x103B, 0x103D], [0x1000, 0x103C, 0x103D]], 0x1038),
        ("khya:", [[0x1001, 0x103B], [0x1001, 0x103C]], 0x1038),
    ]

    public static let suite = TestSuite(name: "AsatCodaTone", cases: [

        // TASK-023: stop-coda asat + creaky → `<C> 1037 103A`
        TestCase("asatStopCoda_creakyAtRank0") { ctx in
            let engine = emptyEngine()
            for c in asatCreakyCases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = surface.unicodeScalars.map(\.value)
                ctx.assertTrue(
                    Array(actual) == c.expected,
                    c.buffer,
                    detail: "expected '\(hex(String(c.expected.compactMap(Unicode.Scalar.init).map(Character.init))))' got '\(hex(surface))'"
                )
                ctx.assertFalse(
                    surfaceContains(surface, scalar: 0x002E),
                    "\(c.buffer)_noLiteralDot",
                    detail: "literal dot survived in '\(c.buffer)' surface='\(surface)'"
                )
            }
        },

        // TASK-023: stop-coda asat + visarga → `<C> 103A 1038`
        TestCase("asatStopCoda_visargaAtRank0") { ctx in
            let engine = emptyEngine()
            for c in asatVisargaCases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = surface.unicodeScalars.map(\.value)
                ctx.assertTrue(
                    Array(actual) == c.expected,
                    c.buffer,
                    detail: "expected scalars=\(c.expected.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
                ctx.assertFalse(
                    surfaceContains(surface, scalar: 0x003A),
                    "\(c.buffer)_noLiteralColon",
                    detail: "literal colon survived in '\(c.buffer)' surface='\(surface)'"
                )
            }
        },

        // TASK-024: medial-bearing onset + creaky tone → `<C> <medial(s)> 1037`
        TestCase("medialOnset_creakyAtRank0") { ctx in
            let engine = emptyEngine()
            for c in medialCreakyCases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                let matched = c.prefixHexAlternatives.contains { prefix in
                    actual == prefix + [c.tail]
                }
                ctx.assertTrue(
                    matched,
                    c.buffer,
                    detail: "expected '<medial-prefix> 1037' got '\(hex(surface))'"
                )
                ctx.assertFalse(
                    surfaceContains(surface, scalar: 0x002E),
                    "\(c.buffer)_noLiteralDot",
                    detail: "literal dot survived in '\(c.buffer)' surface='\(surface)'"
                )
            }
        },

        // TASK-024: medial-bearing onset + visarga → `<C> <medial(s)> 1038`
        TestCase("medialOnset_visargaAtRank0") { ctx in
            let engine = emptyEngine()
            for c in medialVisargaCases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                let matched = c.prefixHexAlternatives.contains { prefix in
                    actual == prefix + [c.tail]
                }
                ctx.assertTrue(
                    matched,
                    c.buffer,
                    detail: "expected '<medial-prefix> 1038' got '\(hex(surface))'"
                )
                ctx.assertFalse(
                    surfaceContains(surface, scalar: 0x003A),
                    "\(c.buffer)_noLiteralColon",
                    detail: "literal colon survived in '\(c.buffer)' surface='\(surface)'"
                )
            }
        },

        // Counter-examples that already work today must keep working —
        // nasal-coda asat + tone, and bare-consonant + tone (TASK-014).
        TestCase("nasalCodaAndBareConsonant_unchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                ("kan.",   [0x1000, 0x1014, 0x1037, 0x103A]),
                ("kan:",   [0x1000, 0x1014, 0x103A, 0x1038]),
                ("shin.",  [0x101B, 0x103E, 0x1004, 0x1037, 0x103A]),
                ("kaung.", [0x1000, 0x1031, 0x102C, 0x1004, 0x1037, 0x103A]),
                ("khain.", [0x1001, 0x102D, 0x1014, 0x1037, 0x103A]),
                ("kywin:", [0x1000, 0x103B, 0x103D, 0x1004, 0x103A, 0x1038]),
                ("ka.",    [0x1000, 0x1037]),
                ("kha.",   [0x1001, 0x1037]),
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

        // Mid-buffer-letter guard: `kit.kha` — the tone helper must
        // refuse when the next char in the literal tail is an ASCII
        // letter (user is mid-typing English mid-buffer).
        TestCase("midBufferLetterGuard_preserved") { ctx in
            let engine = emptyEngine()
            let cases = ["kit.kha", "let.kha", "myit.kha", "kya.kha", "kywa.kha"]
            for buffer in cases {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    surfaceContains(surface, scalar: 0x002E),
                    buffer,
                    detail: "expected literal `.` to survive in mid-buffer position; surface='\(surface)'"
                )
                ctx.assertFalse(
                    surfaceContains(surface, scalar: 0x1037),
                    "\(buffer)_noTone",
                    detail: "tone scalar must not be inserted before an ASCII letter; surface='\(surface)'"
                )
            }
        },
    ])
}
