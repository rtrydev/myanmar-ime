import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for task 02: surfaces in which the same dependent-vowel
/// category (e.g. `u`, `i`, `o`) is stacked back-to-back on a single
/// consonant base must NOT reach the candidate panel. The legitimate
/// top — independent-vowel surfaces like `အူ`, `ဤ`, `ဩ` — stays
/// reachable; only the polluting duplicates are filtered.
public enum RepeatedDepVowelSuite {

    private static func defaultEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static let depVowelRange: ClosedRange<UInt32> = 0x102B...0x1032
    private static let baseRanges: [ClosedRange<UInt32>] = [
        0x1000...0x1021,         // consonants
        0x1023...0x102A,         // independent vowels
    ]
    private static let baseExtras: Set<UInt32> = [0x103F]

    private static func categoryOf(_ scalar: UInt32) -> Int {
        switch scalar {
        case 0x102B, 0x102C: return 1   // aa family
        case 0x102D, 0x102E: return 2   // i family
        case 0x102F, 0x1030: return 3   // u family
        case 0x1031:        return 4   // e family
        case 0x1032:        return 5   // ai family
        default:            return 0
        }
    }

    private static func isBase(_ value: UInt32) -> Bool {
        if baseExtras.contains(value) { return true }
        for range in baseRanges where range.contains(value) { return true }
        return false
    }

    /// Detect surfaces where the same dependent-vowel category appears
    /// twice within one base run (no intervening consonant or
    /// independent vowel between them).
    private static func hasRepeatedDepVowelOnSameBase(_ surface: String) -> Bool {
        var seenCategories: Set<Int> = []
        for scalar in surface.unicodeScalars {
            let v = scalar.value
            if isBase(v) {
                seenCategories.removeAll(keepingCapacity: true)
                continue
            }
            guard depVowelRange.contains(v) else { continue }
            let category = categoryOf(v)
            if category != 0, !seenCategories.insert(category).inserted {
                return true
            }
        }
        return false
    }

    public static let suite = TestSuite(name: "RepeatedDepVowel", cases: [

        // Polluting surfaces from the task spec must not appear in the
        // candidate panel for any of the listed buffers.
        TestCase("repeatedDepVowel_pollutersAbsentFromPanel") { ctx in
            let engine = defaultEngine()
            let pollutersByBuffer: [String: [String]] = [
                // `uu` family — two U+1030 stacked on `အ`.
                "uu":   ["\u{1021}\u{1030}\u{1030}"],
                // `ii` family — two U+102E stacked on `အ`.
                "ii":   ["\u{1021}\u{102E}\u{102E}"],
                // `oo` family — two `102D 102F` clusters stacked on `အ`.
                "oo":   ["\u{1021}\u{102D}\u{102F}\u{102D}\u{102F}"],
                // `auau` exercises the bare-vowel re-entry.
                "auau": ["\u{1021}\u{1030}\u{1030}"],
                // After a real consonant — duplicated `u` on `က`.
                "kuu":  ["\u{1000}\u{1030}\u{1030}"],
                // Duplicated `i` on `က`.
                "kii":  ["\u{1000}\u{102E}\u{102E}"],
                // Duplicated `o` cluster on `က`.
                "koo":  ["\u{1000}\u{102D}\u{102F}\u{102D}\u{102F}"],
            ]
            for (buffer, polluters) in pollutersByBuffer {
                let state = engine.update(buffer: buffer, context: [])
                let surfaces = state.candidates.map(\.surface)
                for polluter in polluters {
                    ctx.assertFalse(
                        surfaces.contains(polluter),
                        buffer,
                        detail: "polluter '\(polluter)' present in panel: \(surfaces)"
                    )
                }
            }
        },

        // Property-style: no candidate in the panel for any of the
        // listed bare-vowel-repeat buffers should carry a same-category
        // dependent-vowel duplicate within a single base run.
        TestCase("repeatedDepVowel_noCandidateHasSameCategoryDuplicate") { ctx in
            let engine = defaultEngine()
            for buffer in ["uu", "ii", "oo", "auau", "kuu", "kii", "koo", "uuu"] {
                let state = engine.update(buffer: buffer, context: [])
                for candidate in state.candidates {
                    ctx.assertFalse(
                        hasRepeatedDepVowelOnSameBase(candidate.surface),
                        buffer,
                        detail: "candidate '\(candidate.surface)' carries a same-category dep-vowel duplicate"
                    )
                }
            }
        },

        // Regression: the legitimate independent-vowel tops survive.
        TestCase("repeatedDepVowel_legitimateTopReached") { ctx in
            let engine = defaultEngine()
            let cases: [(buffer: String, expected: String)] = [
                ("uu", "\u{1021}\u{1030}"),                 // အူ
                ("ii", "\u{1024}"),                          // ဤ
                ("oo", "\u{1029}"),                          // ဩ
            ]
            for (buffer, expected) in cases {
                let top = engine.update(buffer: buffer, context: []).candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top == expected,
                    buffer,
                    detail: "expected top='\(expected)'; got='\(top)'"
                )
            }
        },

        // Regression: legitimate multi-scalar dep vowels are not
        // mistaken for duplicates. `o` = U+102D + U+102F is a single
        // multi-scalar dep-vowel cluster; the two scalars belong to
        // different categories (i + u) so the rule must not reject it.
        TestCase("repeatedDepVowel_multiScalarOClusterAllowed") { ctx in
            let engine = defaultEngine()
            for (buffer, expectedTop) in [
                ("ko", "\u{1000}\u{102D}\u{102F}"),     // ကို
                ("o", "\u{1021}\u{102D}\u{102F}"),      // အို
            ] {
                let top = engine.update(buffer: buffer, context: []).candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top == expectedTop,
                    buffer,
                    detail: "expected top='\(expectedTop)'; got='\(top)'"
                )
            }
        },

        // Regression: scanOutputLegality must keep accepting plain
        // single-vowel surfaces (`အူ`, `အီ`, `အို`, `ka` ...).
        TestCase("repeatedDepVowel_singleVowelSurfacesStillLegal") { ctx in
            let surfaces = [
                "\u{1021}\u{1030}",                    // အူ
                "\u{1021}\u{102E}",                    // အီ
                "\u{1021}\u{102D}\u{102F}",            // အို
                "\u{1000}\u{102C}",                    // ကာ
                "\u{1000}\u{102D}\u{102F}",            // ကို
                "\u{1019}\u{102D}\u{102F}\u{1000}\u{103A}",   // မိုက် (mok closed)
            ]
            for surface in surfaces {
                ctx.assertTrue(
                    SyllableParser.scanOutputLegality(surface),
                    surface,
                    detail: "scanOutputLegality rejected legal surface"
                )
            }
        },

        // Direct unit on the parser-level guard.
        TestCase("repeatedDepVowel_scanOutputLegalityRejectsDuplicates") { ctx in
            let illegal = [
                "\u{1021}\u{1030}\u{1030}",                          // အူူ
                "\u{1021}\u{102E}\u{102E}",                          // အီီ
                "\u{1000}\u{1030}\u{1030}",                          // ကူူ
                "\u{1021}\u{102D}\u{102F}\u{102D}\u{102F}",          // အိုို
            ]
            for surface in illegal {
                ctx.assertFalse(
                    SyllableParser.scanOutputLegality(surface),
                    surface,
                    detail: "scanOutputLegality admitted polluting duplicate"
                )
            }
        },
    ])
}
