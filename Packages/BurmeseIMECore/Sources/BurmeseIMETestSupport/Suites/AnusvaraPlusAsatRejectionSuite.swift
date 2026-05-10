import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-048: an asat (`U+103A`) directly following an
/// anusvara (`U+1036`) is orthographically invalid Burmese. Anusvara is
/// a final nasal vowel-mark; placing a vowel-killer after a nasal mark
/// produces a structurally meaningless syllable. The pre-fix engine
/// emitted `<C> 1036 103A` shapes (e.g. `kan*` → `ကံ်`, `pan*` → `ပံ်`)
/// for the digit-stripped `<C>an*` family because the parser's
/// legality scan walked back through anusvara as a "skippable" mark
/// before reaching the consonant base.
///
/// Burmese rule reference: anusvara `ံ` (U+1036) closes the syllable
/// as a nasal vowel-mark — its phonetic role is the syllable-final /m/
/// sound. Asat `်` (U+103A) is the vowel-killer; it attaches to a
/// closure consonant (e.g. `1014 103A` na-asat → `န်`). The two
/// scalars cannot coexist in adjacency. Per CLAUDE.md §1: "asat after
/// tone, after a digit, or after an incompatible dependent vowel"
/// must be rejected. Anusvara is the canonical incompatible dep-mark.
public enum AnusvaraPlusAsatRejectionSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// True when `surface` contains the two-scalar window `1036 103A`
    /// anywhere in its scalar sequence.
    private static func surfaceHasAnusvaraPlusAsat(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 2 else { return false }
        for i in 1..<scalars.count {
            if scalars[i - 1] == 0x1036 && scalars[i] == 0x103A {
                return true
            }
        }
        return false
    }

    /// Bug reproduction matrix from the task: full standard consonant
    /// onset cross-product with `an*`. Every entry must produce a
    /// candidate panel free of the `1036 103A` adjacency.
    private static let bugInputs: [String] = [
        "kan*", "khan*", "gan*", "ngan*",
        "san*", "hsan*", "zan*",
        "tan*", "htan*", "dan*", "dhan*", "nan*",
        "pan*", "phan*", "ban*", "bhan*", "man*",
        "yan*", "ran*", "lan*", "van*",
        "than*", "han*",
    ]

    /// Mid-buffer occurrences from the task's "mid-buffer impact" note.
    private static let midBufferInputs: [String] = [
        "ka+kan*", "paksan*", "kan*sa", "kankan*",
    ]

    public static let suite = TestSuite(name: "AnusvaraPlusAsatRejection", cases: [

        // Acceptance Criterion 1: NO candidate in the panel may carry
        // the `1036 103A` adjacency. The bug shape must be filtered
        // entirely, not merely demoted.
        TestCase("noCandidateSurface_carriesAnusvaraPlusAsat") { ctx in
            let engine = emptyEngine()
            for buffer in bugInputs {
                let state = engine.update(buffer: buffer, context: [])
                for c in state.candidates {
                    ctx.assertFalse(
                        surfaceHasAnusvaraPlusAsat(c.surface),
                        buffer,
                        detail: "candidate '\(c.surface)' [\(hex(c.surface))] contains 1036 103A"
                    )
                }
            }
        },

        // Acceptance Criterion 2: same invariant for mid-buffer
        // occurrences.
        TestCase("noCandidateSurface_carriesAnusvaraPlusAsat_midBuffer") { ctx in
            let engine = emptyEngine()
            for buffer in midBufferInputs {
                let state = engine.update(buffer: buffer, context: [])
                for c in state.candidates {
                    ctx.assertFalse(
                        surfaceHasAnusvaraPlusAsat(c.surface),
                        buffer,
                        detail: "candidate '\(c.surface)' [\(hex(c.surface))] contains 1036 103A"
                    )
                }
            }
        },

        // Acceptance Criterion 3: the clean `<C>န်` (`<C> 1014 103A`)
        // surface remains reachable in the panel for every tested
        // buffer. The bug shape disappearing must not also remove the
        // legitimate `na-asat` reading.
        TestCase("naAsatSibling_remainsReachable") { ctx in
            let engine = emptyEngine()
            // Map of romanization onset → expected `<C>` consonant base.
            let onsetBase: [(String, UInt32)] = [
                ("k", 0x1000), ("kh", 0x1001), ("g", 0x1002), ("ng", 0x1004),
                ("s", 0x1005), ("hs", 0x1006), ("z", 0x1007),
                ("t", 0x1010), ("ht", 0x1011), ("d", 0x1012),
                ("dh", 0x1013), ("n", 0x1014),
                ("p", 0x1015), ("ph", 0x1016), ("b", 0x1018),
                ("m", 0x1019), ("y", 0x101A), ("r", 0x101B),
                ("l", 0x101C),
                ("th", 0x101E), ("h", 0x101F),
            ]
            for (onset, base) in onsetBase {
                let buffer = "\(onset)an*"
                let state = engine.update(buffer: buffer, context: [])
                let expectedSurface = String(
                    [base, 0x1014, 0x103A]
                        .compactMap(Unicode.Scalar.init)
                        .map(Character.init)
                )
                let surfaces = state.candidates.map(\.surface)
                ctx.assertTrue(
                    surfaces.contains(expectedSurface),
                    buffer,
                    detail: "expected '\(expectedSurface)' [\(hex(expectedSurface))] in panel; got \(surfaces.prefix(5))"
                )
            }
        },

        // Direct legality-scan predicate: scalar sequences with
        // `1036 103A` adjacency must be rejected.
        TestCase("scanOutputLegality_rejectsAnusvaraPlusAsat") { ctx in
            let cases: [(label: String, scalars: [UInt32])] = [
                ("kan*",   [0x1000, 0x1036, 0x103A]),
                ("khan*",  [0x1001, 0x1036, 0x103A]),
                ("ngan*",  [0x1004, 0x1036, 0x103A]),
                ("san*",   [0x1005, 0x1036, 0x103A]),
                ("nan*",   [0x1014, 0x1036, 0x103A]),
                ("pan*",   [0x1015, 0x1036, 0x103A]),
                ("ban*",   [0x1018, 0x1036, 0x103A]),
                ("man*",   [0x1019, 0x1036, 0x103A]),
                ("yan*",   [0x101A, 0x1036, 0x103A]),
                ("lan*",   [0x101C, 0x1036, 0x103A]),
                ("than*",  [0x101E, 0x1036, 0x103A]),
                ("han*",   [0x101F, 0x1036, 0x103A]),
                ("dan*",   [0x1012, 0x1036, 0x103A]),
                ("tan*",   [0x1010, 0x1036, 0x103A]),
            ]
            for c in cases {
                let s = String(c.scalars.compactMap(Unicode.Scalar.init).map(Character.init))
                let legal = SyllableParser.scanOutputLegality(s)
                ctx.assertFalse(
                    legal,
                    c.label,
                    detail: "scanOutputLegality returned true for malformed scalars '\(hex(s))'"
                )
            }
        },

        // Counter-examples that must REMAIN legal: anusvara without
        // trailing asat, and na-asat without anusvara, and the legal
        // creaky-after-anusvara `<C> 1036 1037` shape (creaky tone CAN
        // attach to anusvara in some renders — e.g. `kan.` / `ကံ့`).
        TestCase("scanOutputLegality_acceptsLegalAnusvaraShapes") { ctx in
            let cases: [(label: String, scalars: [UInt32])] = [
                ("kan",   [0x1000, 0x1036]),                 // ကံ
                ("man",   [0x1019, 0x1036]),                 // မံ
                ("kan*_naAsat", [0x1000, 0x1014, 0x103A]),   // ကန်
                ("kan.",  [0x1000, 0x1036, 0x1037]),         // ကံ့ (creaky+anusvara)
                ("kan:",  [0x1000, 0x1036, 0x1038]),         // ကံး
            ]
            for c in cases {
                let s = String(c.scalars.compactMap(Unicode.Scalar.init).map(Character.init))
                let legal = SyllableParser.scanOutputLegality(s)
                ctx.assertTrue(
                    legal,
                    c.label,
                    detail: "scanOutputLegality wrongly rejected legal scalars '\(hex(s))'"
                )
            }
        },
    ])
}
