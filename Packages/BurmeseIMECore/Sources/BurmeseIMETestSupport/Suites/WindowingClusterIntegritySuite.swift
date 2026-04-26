import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-002: when a long composable buffer triggers the
/// sliding-window path AND the frozen prefix is kinzi-anchored, the
/// active-tail re-parse can split a single syllable like `naung`
/// (= `နောင်`) into a consonant + bare-vowel pair (`န` + `အောင်`),
/// rendering as `နအောင်` — a stray U+1021 (`အ`) wedged between a real
/// consonant and the dep-vowel sign that should have attached to it.
///
/// This suite asserts the structural invariant that a top-ranked
/// candidate must never contain `<consonant base>U+1021<dep-vowel>`
/// adjacency. Burmese orthography requires dep-vowel signs to attach
/// to the immediately preceding base consonant; an independent vowel
/// `အ` cannot legitimately sit between them.
public enum WindowingClusterIntegritySuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    /// Returns true when the surface contains a
    /// `<consonant base>U+1021<dep-vowel sign>` adjacency.
    /// Consonant range: 0x1000–0x1021 (covers the independent vowel
    /// 0x1021 itself; the test still returns true, but the only way
    /// to hit a `1021 1021 102B-1032` pattern is if two independent
    /// vowels precede a dep sign — equally illegal).
    /// Dep-vowel sign range: 0x102B–0x1032.
    private static func hasConsonantImplicitADepVowelPattern(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 3 else { return false }
        for i in 1..<(scalars.count - 1) {
            guard scalars[i] == 0x1021 else { continue }
            let prev = scalars[i - 1]
            let next = scalars[i + 1]
            let prevIsBase = prev >= 0x1000 && prev <= 0x1021
            let nextIsDepVowel = next >= 0x102B && next <= 0x1032
            if prevIsBase && nextIsDepVowel { return true }
        }
        return false
    }

    /// General-class inputs: long buffers (>16 chars) where the
    /// frozen-prefix carries a kinzi anchor and the active-tail
    /// begins with a vowel-leading roman cluster.
    private static let windowingInputs: [String] = [
        "minkyawnaungtawkyaw",          // 19 chars — original repro
        "minkyawnaungtawkyawnaungtaw",  // 27 chars
        "thinaikkyawnaungtaw",          // 19 chars — second repro
        "minkyawkyawkyawnaung",         // 20 chars
        "minkyawthawnay",               // 14 chars (sub-threshold control)
    ]

    /// Counter-examples that already render cleanly today — these must
    /// stay clean (regression guard).
    private static let cleanInputs: [String] = [
        "kyawnaungtawkyaw",
        "kyawnaungtawkyawnaungtawkyaw",
        "naungtawkyaw",
    ]

    public static let suite = TestSuite(name: "WindowingClusterIntegrity", cases: [

        TestCase("kinziWindowed_topHasNoStrayImplicitA") { ctx in
            let engine = emptyEngine()
            for input in windowingInputs {
                let top = engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
                ctx.assertFalse(
                    hasConsonantImplicitADepVowelPattern(top),
                    input,
                    detail: "top '\(top)' contains <consonant>U+1021<dep-vowel> stray-implicit-A pattern"
                )
            }
        },

        TestCase("nonKinziLong_remainsClean") { ctx in
            let engine = emptyEngine()
            for input in cleanInputs {
                let top = engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
                ctx.assertFalse(
                    hasConsonantImplicitADepVowelPattern(top),
                    input,
                    detail: "top '\(top)' contains stray-implicit-A pattern"
                )
            }
        },
    ])
}
