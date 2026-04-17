import Foundation
import BurmeseIMECore

/// Generators for property/fuzz tests. All generators take a `SeededRandom`
/// so failures are reproducible from the printed seed.
public enum BurmeseGenerators {

    /// ASCII alphabet the engine treats as composing input: lowercase a–z,
    /// plus `+` (syllable separator) and `:` (used as a vowel disambiguator
    /// and cluster-reading hint).
    public static let composingAlphabet: [Character] = Array("abcdefghijklmnopqrstuvwxyz+:")

    /// A grammar-legal (onset, medials, vowel) tuple enumerable from the
    /// static Romanization + Grammar tables. Used by Property #1 (round-trip
    /// stability) which prefers exhaustive enumeration over random sampling
    /// because the legal space is small enough to iterate completely.
    public struct LegalSyllable: Hashable, Sendable {
        public let consonant: Character
        public let medials: [Character]
        public let vowelRoman: String
        public let onsetRoman: String
    }

    public static func enumerateLegalSyllables() -> [LegalSyllable] {
        var results: [LegalSyllable] = []
        for cons in Romanization.consonants {
            // Bare consonant + each vowel.
            for vowel in Romanization.vowels {
                let score = Grammar.validateSyllable(
                    onset: cons.myanmar,
                    medials: [],
                    vowelRoman: vowel.roman
                )
                guard score > 0 else { continue }
                results.append(LegalSyllable(
                    consonant: cons.myanmar,
                    medials: [],
                    vowelRoman: vowel.roman,
                    onsetRoman: cons.roman
                ))
            }
            // Each legal medial combo + each vowel.
            for combo in Grammar.medialCombinations {
                var allLegal = true
                for m in combo where !Grammar.canConsonantTakeMedial(cons.myanmar, m) {
                    allLegal = false
                    break
                }
                guard allLegal else { continue }
                for vowel in Romanization.vowels {
                    let score = Grammar.validateSyllable(
                        onset: cons.myanmar,
                        medials: combo,
                        vowelRoman: vowel.roman
                    )
                    guard score > 0 else { continue }
                    let hasH = combo.contains(Myanmar.medialHa)
                    let hasW = combo.contains(Myanmar.medialWa)
                    let hasY = combo.contains(Myanmar.medialRa)
                    let hasY2 = combo.contains(Myanmar.medialYa)
                    let onsetRoman =
                        (hasH ? "h" : "") +
                        cons.roman +
                        (hasW ? "w" : "") +
                        (hasY ? "y" : "") +
                        (hasY2 ? "y2" : "")
                    results.append(LegalSyllable(
                        consonant: cons.myanmar,
                        medials: combo,
                        vowelRoman: vowel.roman,
                        onsetRoman: onsetRoman
                    ))
                }
            }
        }
        return results
    }

    /// Render a `LegalSyllable` to its Myanmar surface form using the same
    /// ordering as `SyllableParser` (onset → ya-yit → ya-pin → wa-hswe →
    /// ha-htoe → vowel). Matches the output emitted by the parser for the
    /// same legal input.
    public static func render(_ syl: LegalSyllable) -> String {
        var output = String(syl.consonant)
        if syl.medials.contains(Myanmar.medialRa) { output += String(Myanmar.medialRa) }
        if syl.medials.contains(Myanmar.medialYa) { output += String(Myanmar.medialYa) }
        if syl.medials.contains(Myanmar.medialWa) { output += String(Myanmar.medialWa) }
        if syl.medials.contains(Myanmar.medialHa) { output += String(Myanmar.medialHa) }
        if let vowel = Romanization.romanToVowel[syl.vowelRoman] {
            output += vowel.myanmar
        }
        return output
    }

    /// Random ASCII buffer of length `length`. Used for fuzz properties
    /// (#2 no illegal surfaces, #3 no Latin leakage, #5 anchor monotonicity).
    public static func randomBuffer(
        length: Int,
        rng: inout SeededRandom
    ) -> String {
        var chars: [Character] = []
        chars.reserveCapacity(length)
        for _ in 0..<length {
            chars.append(rng.pick(composingAlphabet))
        }
        return String(chars)
    }

    /// Lazily shrink a failing buffer by repeatedly halving it. Useful for
    /// reporting minimal reproducers. Returns the shortest buffer for which
    /// `predicate` still fails; stops at length 1.
    public static func shrink(
        _ buffer: String,
        while predicate: (String) -> Bool
    ) -> String {
        var current = buffer
        while current.count > 1 {
            let half = String(current.prefix(max(current.count / 2, 1)))
            if predicate(half) {
                current = half
            } else {
                break
            }
        }
        return current
    }
}
