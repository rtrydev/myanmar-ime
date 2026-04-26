import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for task 02: vowel rules whose Myanmar output begins with
/// a consonant scalar (`an`, `in`, `e` and their tone variants) must
/// produce an `အ`-anchored independent-vowel form when typed
/// standalone, not the bare consonant-asat coda the parser emits.
///
/// `kan` / `min` / `ke` exercise the consonant-onset path that must
/// stay unchanged — the fix only fires when the vowel rule is parsed
/// without a preceding onset.
public enum StandaloneCodaVowelSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func topSurface(_ engine: BurmeseEngine, _ input: String) -> String {
        engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
    }

    private static func describe(_ candidates: [Candidate]) -> String {
        String(describing: candidates.prefix(5).map(\.surface))
    }

    /// Each entry: user-typed buffer → expected top surface (one of
    /// `expected` is acceptable, accommodating tone-mark order
    /// variation, but every option must start with U+1021).
    private static let standaloneCases: [(buffer: String, expected: [String])] = [
        // Plain
        ("an",  ["\u{1021}\u{1014}\u{103A}"]),                    // အန်
        ("in",  ["\u{1021}\u{1004}\u{103A}"]),                    // အင်
        ("e",   ["\u{1021}\u{101A}\u{103A}"]),                    // အယ်
        // Creaky tone (.)
        ("an.", ["\u{1021}\u{1014}\u{1037}\u{103A}",              // အန့်
                 "\u{1021}\u{1014}\u{103A}\u{1037}"]),
        ("in.", ["\u{1021}\u{1004}\u{1037}\u{103A}",              // အင့်
                 "\u{1021}\u{1004}\u{103A}\u{1037}"]),
        ("e.",  ["\u{1021}\u{101A}\u{1037}\u{103A}",              // အယ့်
                 "\u{1021}\u{101A}\u{103A}\u{1037}"]),
        // Visarga (:)
        ("an:", ["\u{1021}\u{1014}\u{103A}\u{1038}"]),            // အန်း
        ("in:", ["\u{1021}\u{1004}\u{103A}\u{1038}"]),            // အင်း
    ]

    /// Onset-bearing siblings: must NOT acquire a leading `အ`.
    private static let onsetSiblings: [(buffer: String, expected: String)] = [
        ("kan", "\u{1000}\u{1014}\u{103A}"),       // ကန်
        ("min", "\u{1019}\u{1004}\u{103A}"),       // မင်
        ("ke",  "\u{1000}\u{101A}\u{103A}"),       // ကယ်
        ("pan", "\u{1015}\u{1014}\u{103A}"),       // ပန်
        ("tin", "\u{1010}\u{1004}\u{103A}"),       // တင်
    ]

    public static let suite = TestSuite(name: "StandaloneCodaVowel", cases: [

        // Standalone vowel-rule entry must produce an `အ`-anchored
        // top candidate. The bare-coda parser output (`န်`, `င်`,
        // `ယ်`) is not orthographic Burmese.
        TestCase("standaloneVowelRule_anchorsToImplicitA") { ctx in
            let engine = emptyEngine()
            for entry in standaloneCases {
                let state = engine.update(buffer: entry.buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                let firstScalar = top.unicodeScalars.first.map(\.value) ?? 0
                ctx.assertTrue(
                    firstScalar == 0x1021,
                    entry.buffer,
                    detail: "top='\(top)' first=\(String(format: "%04X", firstScalar)) expected to start with 1021; all=\(describe(state.candidates))"
                )
                ctx.assertTrue(
                    entry.expected.contains(top),
                    entry.buffer,
                    detail: "top='\(top)' not in expected \(entry.expected); all=\(describe(state.candidates))"
                )
            }
        },

        // Consonant-onset siblings must NOT acquire a leading `အ`:
        // the fix only applies when the vowel rule has no preceding
        // onset.
        TestCase("onsetVowel_unchangedByFix") { ctx in
            let engine = emptyEngine()
            for entry in onsetSiblings {
                let top = topSurface(engine, entry.buffer)
                ctx.assertTrue(
                    top == entry.expected,
                    entry.buffer,
                    detail: "top='\(top)' expected='\(entry.expected)' (must not gain leading 1021)"
                )
            }
        },

        // Internal-variant `an2`, `in2`, etc. typed by the user as a
        // digit-bearing buffer must keep the digit at the typed
        // position and still anchor the consonant-base coda.
        TestCase("internalVariant_userDigit_keepsAnchor") { ctx in
            let engine = emptyEngine()
            // Each entry: buffer → must contain U+1021 at index 0
            for buffer in ["an2", "an3", "in2", "in3"] {
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                let firstScalar = top.unicodeScalars.first.map(\.value) ?? 0
                ctx.assertTrue(
                    firstScalar == 0x1021,
                    buffer,
                    detail: "top='\(top)' first=\(String(format: "%04X", firstScalar)) expected to start with 1021"
                )
            }
        },
    ])
}
