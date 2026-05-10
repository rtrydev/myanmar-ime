import Foundation
@_spi(Testing) import BurmeseIMECore

/// Regression suite for TASK-008: an explicit asat (`*`) typed after a
/// syllable that already terminates with asat (`-aung`, `-aing`, `-aw`,
/// `-an`, `-in`, `-own`, `-aik`, `-out`, `-an`, …) must not inject a
/// spurious `အ်` (`U+1021 U+103A`) at the position of the redundant `*`.
///
/// The bug surfaces in two structurally identical shapes:
///
/// 1. Single `*` after a vowel-rule-with-trailing-asat: scalar triple
///    `103A 1021 103A` inside the surface (`naung*` → `နောင်အ်`).
/// 2. Doubled `**`: scalar quadruple `103A 1021 103A` is the only
///    surface produced (`ka**` → `က်အ်` =
///    `[1000 103A 1021 103A]`).
///
/// Both shapes have the same pattern: `1021 103A` immediately follows
/// another `103A` in the surface. The fix rejects the redundant `*`
/// vowel-only transition at DP time when the predecessor state already
/// ends with asat — the orphan never reaches the post-rank sanitiser,
/// and `scanOutputLegality` quietly drops the bare-`103A` tail.
///
/// Counter-examples (`ka*`, `kyar*`, `kya*kar`) close a syllable that
/// did NOT already end on `103A`, so the `*` is structurally needed
/// and must continue to produce a single trailing asat.
public enum RedundantExplicitAsatSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func topSurface(_ engine: BurmeseEngine, _ input: String) -> String {
        engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
    }

    /// True when `surface` contains the scalar pattern `103A` immediately
    /// followed by `1021 103A` (the bug shape — orphan independent-A
    /// wedged between two asat closures).
    private static func hasSpuriousAOrphanAfterAsat(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 3 else { return false }
        for i in 0..<(scalars.count - 2) {
            if scalars[i] == 0x103A
                && scalars[i + 1] == 0x1021
                && scalars[i + 2] == 0x103A {
                return true
            }
        }
        return false
    }

    /// Bug-class table: redundant `*` after asat-closed syllable, or
    /// doubled `**`, must produce a clean surface with no spurious
    /// `1021 103A` injection.
    private static let bugClassCases: [(buffer: String, expected: String)] = [
        ("naung*",   "\u{1014}\u{1031}\u{102C}\u{1004}\u{103A}"),                          // နောင်
        ("naung*ka", "\u{1014}\u{1031}\u{102C}\u{1004}\u{103A}\u{1000}"),                  // နောင်က
        ("kyaw*",    "\u{1000}\u{103B}\u{1031}\u{102C}\u{103A}"),                          // ကျော်
        ("kyaw*ka",  "\u{1000}\u{103B}\u{1031}\u{102C}\u{103A}\u{1000}"),                  // ကျော်က
        ("min*",     "\u{1019}\u{1004}\u{103A}"),                                          // မင်
        ("min*ka",   "\u{1019}\u{1004}\u{103A}\u{1000}"),                                  // မင်က
        ("khaung*",  "\u{1001}\u{1031}\u{102B}\u{1004}\u{103A}"),                          // ခေါင်
        ("ka**",     "\u{1000}\u{103A}"),                                                  // က်
    ]

    /// Counter-examples that work today and must continue to work.
    /// `kyar*` updated for TASK-055: the malformed
    /// `<C><medial><dep-vowel><103A>` shape (`ကျာ်`) is rejected by
    /// the tightened legality scan, so the legitimate
    /// `<C><medial><consonant><103A>` sibling (`ကျရ်` =
    /// `1000 103B 101B 103A`) wins at rank 0.
    ///
    /// `kya*kar` updated for TASK-049: the malformed
    /// `<C><medial><103A>` shape (`ကျ်`) — medial directly followed
    /// by asat with no intervening coda consonant — is rejected by
    /// the tightened legality scan, so the parser falls back to a
    /// two-syllable parse `ကျ + ကာ` (medial + inherent + ka + aa)
    /// where the explicit `*` is dropped as redundant.
    private static let counterExamples: [(buffer: String, expected: String)] = [
        ("ka*",     "\u{1000}\u{103A}"),                                                    // က်
        ("kyar*",   "\u{1000}\u{103B}\u{101B}\u{103A}"),                                    // ကျရ်
        ("kya*kar", "\u{1000}\u{103B}\u{1000}\u{102C}"),                                    // ကျကာ
        ("ka***",   "\u{1000}\u{103A}"),                                                    // က်
    ]

    public static let suite = TestSuite(name: "RedundantExplicitAsat", cases: [

        TestCase("redundantAsat_dropsSpuriousIndependentA") { ctx in
            let engine = emptyEngine()
            for entry in bugClassCases {
                let top = topSurface(engine, entry.buffer)
                ctx.assertFalse(
                    hasSpuriousAOrphanAfterAsat(top),
                    entry.buffer,
                    detail: "top='\(top)' [\(hex(top))] contains spurious 103A 1021 103A"
                )
                ctx.assertTrue(
                    top == entry.expected,
                    entry.buffer,
                    detail: "top='\(top)' [\(hex(top))] expected='\(entry.expected)' [\(hex(entry.expected))]"
                )
            }
        },

        TestCase("singleAsat_counterExamplesUnchanged") { ctx in
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
