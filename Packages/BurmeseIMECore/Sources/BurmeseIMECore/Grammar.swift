/// Burmese syllable grammar and orthographic legality tables.
///
/// A legal Burmese syllable has the structure:
///   [ေ] + Consonant + [Medial(s)] + [Vowel Sign(s)] + [Final(s)]
///
/// This module encodes which combinations are legal, replacing the
/// permissive flat rule table of the legacy web engine.
public enum Grammar {

    // MARK: - Medial Legality

    /// Which consonants can legally take each medial.
    /// Based on standard Burmese orthography.

    /// Consonants that can take medial ya-yit (ြ U+103C).
    public static let canTakeMedialRa: Set<Character> = [
        Myanmar.ka, Myanmar.kha, Myanmar.ga, Myanmar.gha,
        Myanmar.ca, Myanmar.cha, Myanmar.ja,
        Myanmar.ta, Myanmar.tha, Myanmar.da, Myanmar.dha, Myanmar.na,
        Myanmar.pa, Myanmar.pha, Myanmar.ba, Myanmar.bha, Myanmar.ma,
        Myanmar.ha,
        Myanmar.la,
    ]

    /// Consonants that can take medial ya-pin (ျ U+103B).
    public static let canTakeMedialYa: Set<Character> = [
        Myanmar.ka, Myanmar.kha, Myanmar.ga, Myanmar.gha,
        Myanmar.ca, Myanmar.cha, Myanmar.ja, Myanmar.nya,
        Myanmar.ta, Myanmar.tha, Myanmar.da, Myanmar.dha, Myanmar.na,
        Myanmar.pa, Myanmar.pha, Myanmar.ba, Myanmar.bha, Myanmar.ma,
        Myanmar.ya, Myanmar.la, Myanmar.ha,
    ]

    /// Consonants that can take medial wa-hswe (ွ U+103D).
    public static let canTakeMedialWa: Set<Character> = [
        Myanmar.ka, Myanmar.kha, Myanmar.ga, Myanmar.gha, Myanmar.nga,
        Myanmar.ca, Myanmar.cha, Myanmar.ja, Myanmar.nya,
        Myanmar.ta, Myanmar.tha, Myanmar.da, Myanmar.dha, Myanmar.na,
        Myanmar.pa, Myanmar.pha, Myanmar.ba, Myanmar.bha, Myanmar.ma,
        Myanmar.ya, Myanmar.ra, Myanmar.la, Myanmar.wa,
        Myanmar.sa, Myanmar.ha,
    ]

    /// Consonants that can take medial ha-htoe (ှ U+103E).
    public static let canTakeMedialHa: Set<Character> = [
        Myanmar.ka, Myanmar.kha, Myanmar.ga, Myanmar.gha, Myanmar.nga,
        Myanmar.ca, Myanmar.cha, Myanmar.ja, Myanmar.nya,
        Myanmar.ta, Myanmar.tha, Myanmar.da, Myanmar.dha, Myanmar.na, Myanmar.nna,
        Myanmar.pa, Myanmar.pha, Myanmar.ba, Myanmar.bha, Myanmar.ma,
        Myanmar.ya, Myanmar.ra, Myanmar.la, Myanmar.wa,
        Myanmar.sa,
    ]

    /// Check if a consonant can legally take a specific medial.
    public static func canConsonantTakeMedial(_ consonant: Character, _ medial: Character) -> Bool {
        switch medial {
        case Myanmar.medialRa:  return canTakeMedialRa.contains(consonant)
        case Myanmar.medialYa:  return canTakeMedialYa.contains(consonant)
        case Myanmar.medialWa:  return canTakeMedialWa.contains(consonant)
        case Myanmar.medialHa:  return canTakeMedialHa.contains(consonant)
        default: return false
        }
    }

    // MARK: - Medial Combinations

    /// The 11 legal medial combinations (matching the legacy engine's generated set).
    /// Each is an ordered array of medial characters.
    /// Unicode canonical order: ျ (U+103B) < ြ (U+103C) < ွ (U+103D) < ှ (U+103E)
    public static let medialCombinations: [[Character]] = [
        [Myanmar.medialRa],                                         // ြ  (y)
        [Myanmar.medialYa],                                         // ျ  (y2)
        [Myanmar.medialWa],                                         // ွ  (w)
        [Myanmar.medialHa],                                         // ှ  (h)
        [Myanmar.medialRa, Myanmar.medialWa],                       // ြွ (yw) — rare
        [Myanmar.medialRa, Myanmar.medialHa],                       // ြှ (yh)
        [Myanmar.medialYa, Myanmar.medialWa],                       // ျွ (y2w)
        [Myanmar.medialYa, Myanmar.medialHa],                       // ျှ (y2h)
        [Myanmar.medialWa, Myanmar.medialHa],                       // ွှ (wh)
        [Myanmar.medialRa, Myanmar.medialWa, Myanmar.medialHa],     // ြွှ (ywh)
        [Myanmar.medialYa, Myanmar.medialWa, Myanmar.medialHa],     // ျွှ (y2wh)
    ]

    // MARK: - Stacking (Virama / Kinzi)

    /// Consonants commonly seen as the subscript in a virama stack (္ + consonant).
    /// This is not exhaustive but covers the standard Pali/Sanskrit stacks used in Burmese.
    public static let stackableConsonants: Set<Character> = [
        Myanmar.ka, Myanmar.kha, Myanmar.ga, Myanmar.gha, Myanmar.nga,
        Myanmar.ca, Myanmar.cha, Myanmar.ja, Myanmar.nya,
        Myanmar.tta, Myanmar.ttha, Myanmar.dda, Myanmar.ddha, Myanmar.nna,
        Myanmar.ta, Myanmar.tha, Myanmar.da, Myanmar.dha, Myanmar.na,
        Myanmar.pa, Myanmar.pha, Myanmar.ba, Myanmar.bha, Myanmar.ma,
        Myanmar.ya, Myanmar.ra, Myanmar.la, Myanmar.wa,
        Myanmar.sa, Myanmar.ha,
    ]

    /// Kinzi is formed by: consonant + ္ + င  (where the first consonant becomes superscript).
    /// In practice, kinzi is almost always င + ္ + next consonant, written as
    /// the next consonant with a superscript င.
    /// The romanization uses '+' between syllables to trigger virama stacking.

    // MARK: - Syllable Validation

    /// Validates whether a parsed syllable structure is legal Burmese.
    /// Returns a legality score: higher is better, 0 means illegal.
    public static func validateSyllable(
        onset: Character?,
        medials: [Character],
        vowelRoman: String
    ) -> Int {
        // No onset: standalone vowels are preferred, but dependent vowels
        // are still legal (they get U+200C prefix in output). Low score
        // ensures onset+vowel paths win when available.
        guard let onset = onset else {
            if let entry = Romanization.romanToVowel[vowelRoman] {
                return entry.isStandalone ? 100 : 10
            }
            // Bare vowel suffix without onset
            return vowelRoman.isEmpty ? 0 : 10
        }

        // Validate onset is a real consonant
        guard Myanmar.isConsonant(onset.unicodeScalars.first!) else {
            return 0
        }

        // Validate each medial against this consonant
        for medial in medials {
            if !canConsonantTakeMedial(onset, medial) {
                return 0
            }
        }

        // Validate medial ordering (must follow Unicode canonical order)
        if medials.count > 1 {
            for i in 1..<medials.count {
                guard let prev = medials[i-1].unicodeScalars.first?.value,
                      let curr = medials[i].unicodeScalars.first?.value,
                      prev < curr else {
                    return 0
                }
            }
        }

        // Base score: legal
        var score = 100

        // Bonus for common/canonical forms
        if medials.isEmpty {
            score += 10
        }

        return score
    }
}
