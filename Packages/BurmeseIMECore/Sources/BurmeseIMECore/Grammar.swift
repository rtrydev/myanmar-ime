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

    // MARK: - Tall/Short Aa Legality

    /// Consonants with descenders that require tall aa (ါ U+102B) instead of
    /// short aa (ာ U+102C). The engine post-processes candidate surfaces to
    /// force the orthographically-correct aa shape based on the preceding
    /// consonant — the user never sees the wrong-shape sibling.
    public static let requiresTallAa: Set<Character> = [
        Myanmar.kha, Myanmar.ga, Myanmar.nga,
        Myanmar.da, Myanmar.pa, Myanmar.wa,
    ]

    // MARK: - Vowel / Medial Compatibility

    /// Medial ha-htoe (ှ) combined with the long-i (ီ) or long-u (ူ) vowel
    /// signs is not used in modern Burmese orthography. Reject these
    /// pairings so their parses drop below the legality threshold.
    private static let forbiddenVowelsWithMedialHa: Set<String> = [
        "i:", "i2:", "u:", "u2:",
    ]

    /// Triple-medial onsets (3 medials, e.g. ြွှ / ျွှ) are rare and only
    /// legitimately combine with the inherent vowel or aa in real text.
    /// Other vowels on a triple-medial onset produce orthographic shapes
    /// that native writers would never spell.
    private static let tripleMedialPermittedVowels: Set<String> = [
        "a", "ar", "ar:", "ar2", "ar2:",
    ]

    // MARK: - Pali / Retroflex Onset Restrictions

    /// Pali-derived retroflex consonants that appear almost exclusively in
    /// Sanskrit/Pali loanwords with a restricted vowel inventory (inherent
    /// a, ar*, i*, u*, ay*, plus asat/anusvara finals). Native-Burmese
    /// diphthong finals on these onsets produce orthographic garbage.
    public static let palaRestrictedOnsets: Set<Character> = [
        Myanmar.tta, Myanmar.ttha, Myanmar.dda, Myanmar.ddha,
        Myanmar.nna, Myanmar.lla,
    ]

    /// Native-Burmese compound/diphthong finals that never occur on Pali
    /// retroflex onsets in real text.
    private static let forbiddenVowelsOnPalaOnsets: Set<String> = [
        "own", "own:", "own.",
        "ote", "ate", "ain", "ite", "ai",
    ]

    // MARK: - Connector Vowels

    /// Vowel keys that function as inter-syllable connectors rather than
    /// true vowel sounds. Having an onset paired with one of these is
    /// usually a mis-parse — the onset character should instead be part
    /// of the previous syllable's vowel/final.
    private static let connectorVowels: Set<String> = ["+", "*", "'"]

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

        // Tall/short aa is not gated here — the engine auto-corrects the
        // aa sign to match the onset's descender requirement during
        // candidate post-processing, so the parser can emit either shape.

        // Reject medial ha-htoe + long-i/long-u combinations (not used in
        // modern orthography).
        if medials.contains(Myanmar.medialHa) && forbiddenVowelsWithMedialHa.contains(vowelRoman) {
            return 0
        }

        // Reject triple-medial onsets paired with anything other than the
        // inherent vowel or aa.
        if medials.count >= 3 && !tripleMedialPermittedVowels.contains(vowelRoman) {
            return 0
        }

        // Reject Pali/retroflex onsets paired with native-Burmese
        // diphthong finals.
        if palaRestrictedOnsets.contains(onset) && forbiddenVowelsOnPalaOnsets.contains(vowelRoman) {
            return 0
        }

        // Base score: legal
        var score = 100

        // Bonus for common/canonical forms
        if medials.isEmpty {
            score += 10
        }

        // Connector vowels (virama, asat, separator) are inter-syllable
        // glue — they should not receive a scoring boost from having an
        // onset, because an onset paired with a connector consumes a
        // consonant that typically belongs to the adjacent syllable. For
        // example, in "min+ga" the virama must be standalone so that
        // "in" stays as the vowel of "m"; if the virama were parsed as
        // "n" + virama, the "in" vowel would be split into "i" + "n".
        if connectorVowels.contains(vowelRoman) && onset != nil {
            score -= 10
        }

        return score
    }
}
