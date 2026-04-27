import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-014: a bare consonant followed by `:` (heavy
/// tone) or `.` (creaky tone) must produce a candidate whose surface
/// ends in `<consonant> U+1038` (visarga) or `<consonant> U+1037`
/// (creaky tone marker), not the literal ASCII `:`/`.`.
///
/// The bug class: `Romanization.swift::vowels` defined visarga /
/// creaky-tone-bearing entries only as siblings of explicit vowel
/// suffixes (`ar:`, `i:`, `u:`, …). The bare inherent-`a` case
/// (`ka:`, `tha:`, `pa:`, …) had no rule, so `:` fell through to a
/// literal-tail fallback and surfaced as ASCII U+003A.
public enum BareConsonantToneSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    /// True if `surface` contains `<consonant in U+1000..U+1021> U+1038`
    /// or U+1037 at any position. Defines the structural success.
    private static func surfaceContainsToneOnConsonant(
        _ surface: String,
        toneScalar: UInt32
    ) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 2 else { return false }
        for i in 0..<(scalars.count - 1) {
            let v = scalars[i]
            if (v >= 0x1000 && v <= 0x1021) && scalars[i + 1] == toneScalar {
                return true
            }
        }
        return false
    }

    private static func surfaceContainsLiteralAscii(
        _ surface: String,
        scalar: UInt32
    ) -> Bool {
        surface.unicodeScalars.contains { $0.value == scalar }
    }

    /// Reproduction-table consonant + visarga/creaky cases. Each
    /// entry's expected surface ends in `<myanmar consonant> +
    /// <tone marker>`.
    private static let bareConsonantCases: [(roman: String, mc: UInt32)] = [
        ("k", 0x1000),    // က
        ("kh", 0x1001),   // ခ
        ("t", 0x1010),    // တ
        ("th", 0x101E),   // သ
        ("p", 0x1015),    // ပ
        ("m", 0x1019),    // မ
        ("n", 0x1014),    // န
        ("l", 0x101C),    // လ
        ("y", 0x101A),    // ယ
        ("w", 0x101D),    // ဝ
    ]

    public static let suite = TestSuite(name: "BareConsonantTone", cases: [

        // `<C>:` — visarga heavy tone on inherent `a`. Rank-0 surface
        // must end with `<consonant> U+1038`; the literal-colon
        // fallback may remain accessible at rank ≥ 1.
        TestCase("bareConsonantVisarga_topHasVisarga") { ctx in
            let engine = emptyEngine()
            for c in bareConsonantCases {
                let buffer = c.roman + "a:"
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    surfaceContainsToneOnConsonant(surface, toneScalar: 0x1038),
                    buffer,
                    detail: "expected `\(String(format: "%04X", c.mc))` 1038 in '\(buffer)' surface='\(surface)'"
                )
                ctx.assertFalse(
                    surfaceContainsLiteralAscii(surface, scalar: 0x003A),
                    "\(buffer)_noLiteralColon",
                    detail: "literal colon survived in '\(buffer)' surface='\(surface)'"
                )
            }
        },

        // `<C>.` — creaky tone on inherent `a`. Rank-0 surface must
        // end with `<consonant> U+1037`.
        TestCase("bareConsonantCreaky_topHasCreaky") { ctx in
            let engine = emptyEngine()
            for c in bareConsonantCases {
                let buffer = c.roman + "a."
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    surfaceContainsToneOnConsonant(surface, toneScalar: 0x1037),
                    buffer,
                    detail: "expected `\(String(format: "%04X", c.mc))` 1037 in '\(buffer)' surface='\(surface)'"
                )
                ctx.assertFalse(
                    surfaceContainsLiteralAscii(surface, scalar: 0x002E),
                    "\(buffer)_noLiteralDot",
                    detail: "literal dot survived in '\(buffer)' surface='\(surface)'"
                )
            }
        },

        // The literal-colon / literal-dot fallback must remain
        // accessible at rank ≥ 1 so users typing English mid-buffer
        // can still pick it.
        TestCase("bareConsonantTone_literalFallbackReachable") { ctx in
            let engine = emptyEngine()
            for tone in [":", "."] {
                for c in bareConsonantCases.prefix(5) {
                    let buffer = c.roman + "a" + tone
                    let cands = engine.update(buffer: buffer, context: []).candidates
                    let asciiScalar: UInt32 = (tone == ":") ? 0x003A : 0x002E
                    let literalReachable = cands.contains { c in
                        c.surface.unicodeScalars.contains { $0.value == asciiScalar }
                    }
                    ctx.assertTrue(
                        literalReachable,
                        buffer,
                        detail: "no literal-`\(tone)` candidate in panel for '\(buffer)' all=\(cands.prefix(6).map(\.surface))"
                    )
                }
            }
        },

        // Counter-examples: existing vowel-rule visarga / creaky
        // forms (`kar:`, `ki:`, `ku:`, `kar.`, `ki.`, `ku.`) must
        // continue to render unchanged.
        TestCase("explicitVowelTone_unchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(input: String, expectedTone: UInt32, mc: UInt32)] = [
                ("kar:", 0x1038, 0x1000),
                ("ki:", 0x1038, 0x1000),
                ("ku:", 0x1038, 0x1000),
                ("kar.", 0x1037, 0x1000),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.input, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    surface.unicodeScalars.contains { $0.value == c.expectedTone },
                    c.input,
                    detail: "expected `\(String(format: "%04X", c.expectedTone))` in '\(c.input)' surface='\(surface)'"
                )
            }
        },
    ])
}
