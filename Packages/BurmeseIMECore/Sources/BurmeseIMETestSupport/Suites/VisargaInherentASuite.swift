import Foundation
@_spi(Testing) import BurmeseIMECore

/// Regression suite for TASK-009: visarga `:` (`U+1038`) silently
/// consumes the inherent-`a` start of the next syllable.
///
/// The asymmetry between creaky-tone `.` and visarga `:` lives in
/// `Engine/PunctuationHandling.swift`. The `.` open-dot-vowel-modifier
/// branch forces a buffer split when the next character is a vowel-
/// starting letter, so the suffix is parsed against a fresh buffer and
/// gets its leading `အ` (U+1021) anchor via the parser's leading-A
/// promotion. The parallel `:` branch returns `false` and skips the
/// split, fusing the entire buffer into one parser pass — where the
/// inherent-`a` arc is silently absorbed without anchor synthesis.
///
/// The fix mirrors the open-dot logic for the colon: when `:` acts as
/// a vowel modifier AND the next character is a vowel-starting letter
/// AND the suffix `:` form's Myanmar surface ends in a structural
/// non-asat scalar (i.e. `1038` visarga), force the split.
public enum VisargaInherentASuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func topSurface(_ engine: BurmeseEngine, _ input: String) -> String {
        engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
    }

    private static func count1021(_ s: String) -> Int {
        s.unicodeScalars.filter { $0.value == 0x1021 }.count
    }

    private static func replacingScalar(_ s: String, from: UInt32, to: UInt32) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if scalar.value == from {
                out.append(Unicode.Scalar(to)!)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Bug-class table: `kar:<X>` shapes whose desired rank-0 surface
    /// includes an explicit `အ` anchor for the second syllable.
    private static let bugClassCases: [(buffer: String, expected: String)] = [
        ("kar:a",        "\u{1000}\u{102C}\u{1038}\u{1021}"),
        ("kar:akar",     "\u{1000}\u{102C}\u{1038}\u{1021}\u{1000}\u{102C}"),
        ("kar:apar",     "\u{1000}\u{102C}\u{1038}\u{1021}\u{1015}\u{102B}"),
        ("kar:athit",    "\u{1000}\u{102C}\u{1038}\u{1021}\u{101E}\u{1005}\u{103A}"),
        ("thar:akar",    "\u{101E}\u{102C}\u{1038}\u{1021}\u{1000}\u{102C}"),
        ("khaung:athit", "\u{1001}\u{1031}\u{102B}\u{1004}\u{103A}\u{1038}\u{1021}\u{101E}\u{1005}\u{103A}"),
        ("kar:aung",     "\u{1000}\u{102C}\u{1038}\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}"),
        ("kar:aing",     "\u{1000}\u{102C}\u{1038}\u{1021}\u{102D}\u{102F}\u{1004}\u{103A}"),
    ]

    /// Symmetry pairs: `kar.<X>` and `kar:<X>` must differ only in
    /// the tone-marker scalar (1037 vs 1038), nothing else.
    private static let symmetryPairs: [(dot: String, colon: String)] = [
        ("kar.a",     "kar:a"),
        ("kar.akar",  "kar:akar"),
        ("kar.apar",  "kar:apar"),
        ("kar.aung",  "kar:aung"),
        ("kar.aing",  "kar:aing"),
        ("thar.akar", "thar:akar"),
    ]

    /// Counter-examples that must continue to work unchanged.
    private static let counterExamples: [(buffer: String, expected: String)] = [
        // `:` followed by a consonant-onset syllable — no inherent-A.
        ("kar:tar", "\u{1000}\u{102C}\u{1038}\u{1010}\u{102C}"),
        // Creaky-tone variant — must continue to work.
        ("kar.akar", "\u{1000}\u{102C}\u{1037}\u{1021}\u{1000}\u{102C}"),
    ]

    /// Vowel-leading sub-rule (`-aung`, `-aing`, `-au`, `-ai`) cases
    /// must produce exactly ONE U+1021 in the suffix syllable, not
    /// the double-1021 surface the bug previously emitted.
    private static let singleAnchorAfterVisarga: [String] = [
        "kar:aung", "kar:aing", "kar:au", "kar:ai",
        "thar:aung", "tar:aing",
    ]

    public static let suite = TestSuite(name: "VisargaInherentA", cases: [

        TestCase("visarga_inherentA_emitsImplicitAAnchor") { ctx in
            let engine = emptyEngine()
            for entry in bugClassCases {
                let top = topSurface(engine, entry.buffer)
                ctx.assertTrue(
                    top == entry.expected,
                    entry.buffer,
                    detail: "top='\(top)' [\(hex(top))] expected='\(entry.expected)' [\(hex(entry.expected))]"
                )
            }
        },

        TestCase("visarga_dot_symmetricExceptToneMarker") { ctx in
            let engine = emptyEngine()
            for pair in symmetryPairs {
                let dotSurface = topSurface(engine, pair.dot)
                let colonSurface = topSurface(engine, pair.colon)
                let mappedDot = replacingScalar(dotSurface, from: 0x1037, to: 0x1038)
                ctx.assertTrue(
                    mappedDot == colonSurface,
                    "\(pair.dot) vs \(pair.colon)",
                    detail: "dot='\(dotSurface)' [\(hex(dotSurface))] colon='\(colonSurface)' [\(hex(colonSurface))] mappedDot='\(mappedDot)' [\(hex(mappedDot))]"
                )
            }
        },

        TestCase("visarga_vowelLeadingSubrule_singleImplicitA") { ctx in
            let engine = emptyEngine()
            for buffer in singleAnchorAfterVisarga {
                let top = topSurface(engine, buffer)
                let count = count1021(top)
                ctx.assertTrue(
                    count == 1,
                    buffer,
                    detail: "top='\(top)' [\(hex(top))] U+1021 count=\(count) expected exactly 1"
                )
            }
        },

        TestCase("visarga_counterExamples_unchanged") { ctx in
            let engine = emptyEngine()
            for entry in counterExamples {
                let top = topSurface(engine, entry.buffer)
                ctx.assertTrue(
                    top == entry.expected,
                    entry.buffer,
                    detail: "top='\(top)' [\(hex(top))] expected='\(entry.expected)' [\(hex(entry.expected))]"
                )
            }
        },
    ])
}
