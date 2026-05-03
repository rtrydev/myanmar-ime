import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-038: Vowel-rule chaining can place medial scalars
/// (U+103B..U+103E) after dependent-vowel marks (U+102B..U+1032)
/// inside the same syllable cluster. That ordering violates Unicode
/// TUS storage order — medials must sit immediately after the
/// consonant base (and any kinzi / virama-stack continuation),
/// strictly before all dependent-vowel signs.
///
/// The bug shape is `<C> <dep-vowel(s)> <medial>` (e.g. `koon` →
/// `1000 102D 102F 103D 1014 103A`). The parser's `scanOutputLegality`
/// previously accepted these because `attachableMarkHasAnchor` walks
/// back through dep-vowels to find a consonant base — without
/// enforcing that medials specifically must NOT cross dep-vowels in
/// that walk.
///
/// The suite covers:
///   - The parser-level legality scan rejects the bad surface order.
///   - The engine never surfaces a medial-after-dep-vowel parse at
///     rank 0 across the documented `koon` family of inputs.
///   - Existing legitimate medial-bearing parses (`kway`, `kywa`,
///     `khywaung`, `kwown`, …) continue to surface unchanged.
public enum MedialPositionInvariantSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    /// True when the surface contains a medial scalar (U+103B..U+103E)
    /// at any position immediately preceded by a dep-vowel scalar
    /// (U+102B..U+1032), tone mark (U+1036..U+1038), or asat
    /// (U+103A) inside the same syllable cluster — i.e. without a
    /// consonant base or virama-stack appearing between.
    private static func surfaceHasMedialAfterDepVowel(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        for i in 1..<scalars.count {
            let v = scalars[i]
            let isMedial = v >= 0x103B && v <= 0x103E
            guard isMedial else { continue }
            // Walk back; if we encounter a dep-vowel before reaching
            // a consonant base or stack, the surface is illegal.
            var j = i - 1
            while j >= 0 {
                let w = scalars[j]
                let isConsonantBase = (w >= 0x1000 && w <= 0x1021) || w == 0x103F
                if isConsonantBase { break }
                let isDepVowel = (w >= 0x102B && w <= 0x1032)
                let isToneMark = (w >= 0x1036 && w <= 0x1038)
                if isDepVowel || isToneMark || w == 0x103A {
                    return true
                }
                j -= 1
            }
        }
        return false
    }

    public static let suite = TestSuite(name: "MedialPositionInvariant", cases: [

        // The parser's static legality scan must reject every
        // documented bad-order surface from the task body.
        TestCase("parser_legality_rejectsMedialAfterDepVowel") { ctx in
            let illegal: [(String, [UInt32])] = [
                ("koon",     [0x1000, 0x102D, 0x102F, 0x103D, 0x1014, 0x103A]),
                ("kio_n",    [0x1000, 0x102E, 0x103D, 0x1014, 0x103A]),
                ("akoon",    [0x1021, 0x1000, 0x102D, 0x102F, 0x103D, 0x1014, 0x103A]),
                ("kionk",    [0x1000, 0x102E, 0x103D, 0x1014, 0x103A, 0x1000]),
                ("thinkoon", [0x101E, 0x1004, 0x103A, 0x1039, 0x1000, 0x102D, 0x102F, 0x103D, 0x1014, 0x103A]),
            ]
            for (label, scalars) in illegal {
                var s = ""
                s.unicodeScalars.append(contentsOf: scalars.compactMap { Unicode.Scalar($0) })
                ctx.assertFalse(
                    SyllableParser.scanOutputLegality(s),
                    label,
                    detail: "scanOutputLegality accepted illegal surface '\(s)'"
                )
            }
        },

        // The parser's static legality scan must continue to accept
        // every legitimate medial placement we ship today.
        TestCase("parser_legality_acceptsLegalMedialPlacements") { ctx in
            let legal: [(String, [UInt32])] = [
                ("kway", [0x1000, 0x103D, 0x1031]),
                ("kywa", [0x1000, 0x103B, 0x103D]),
                ("kwown", [0x1000, 0x103D, 0x102F, 0x1014, 0x103A]),
                ("kywaung", [0x1000, 0x103B, 0x103D, 0x1031, 0x102C, 0x1004, 0x103A]),
                ("khywaung", [0x1001, 0x103B, 0x103D, 0x1031, 0x102C, 0x1004, 0x103A]),
                ("hmon", [0x101F, 0x103D, 0x102F, 0x1014, 0x103A]),
            ]
            for (label, scalars) in legal {
                var s = ""
                s.unicodeScalars.append(contentsOf: scalars.compactMap { Unicode.Scalar($0) })
                ctx.assertTrue(
                    SyllableParser.scanOutputLegality(s),
                    label,
                    detail: "scanOutputLegality regressed on legal surface '\(s)'"
                )
            }
        },

        // The engine must not surface a medial-after-dep-vowel parse
        // anywhere in the candidate panel for the documented input
        // family.
        TestCase("engine_medialAfterDepVowelNotInPanel") { ctx in
            let buffers = ["koon", "k+oon", "ka+oon", "akoon", "kionk", "kowwn",
                           "thinkoon", "ki+on"]
            for buffer in buffers {
                let candidates = emptyEngine()
                    .update(buffer: buffer, context: [])
                    .candidates
                for (i, c) in candidates.enumerated() {
                    ctx.assertFalse(
                        surfaceHasMedialAfterDepVowel(c.surface),
                        buffer,
                        detail: "rank-\(i) carries medial-after-dep-vowel: '\(c.surface)'"
                    )
                }
            }
        },

        // Existing canonical medial-bearing surfaces continue to
        // surface as the rank-0 candidate (regression guard).
        TestCase("engine_canonicalMedialPlacementsRegressionGuard") { ctx in
            let cases: [(String, [UInt32])] = [
                ("kway",      [0x1000, 0x103D, 0x1031]),
                ("kywa",      [0x1000, 0x103B, 0x103D]),
                ("khywaung",  [0x1001, 0x103B, 0x103D, 0x1031, 0x102C, 0x1004, 0x103A]),
                ("kwown",     [0x1000, 0x103D, 0x102F, 0x1014, 0x103A]),
                ("kown",      [0x1000, 0x102F, 0x1014, 0x103A]),
            ]
            for (buffer, scalars) in cases {
                var expected = ""
                expected.unicodeScalars.append(
                    contentsOf: scalars.compactMap { Unicode.Scalar($0) }
                )
                let actual = emptyEngine()
                    .update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertEqual(
                    actual,
                    expected,
                    buffer,
                    file: #file,
                    line: #line
                )
            }
        },
    ])
}
