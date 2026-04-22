/// Converts Myanmar Unicode text to its canonical Hybrid Burmese romanized reading.
///
/// This is the inverse of `SyllableParser`: given Burmese text like "မင်္ဂလာပါ",
/// it produces the romanized reading "min+galarpar2".
///
/// The reverse romanizer walks Myanmar Unicode scalars and recognizes:
/// - Consonants → roman base (e.g., က → "k")
/// - Medials → onset prefix/suffix (h for ha-htoe prefix, y/y2/w suffix)
/// - Virama + consonant → "+" stacking
/// - Asat → "*" or implicit in vowel patterns
/// - Vowel sign sequences → roman vowel key (e.g., ာ → "ar")
/// - Independent vowels → roman key (e.g., ဧ → "ay2")
public enum ReverseRomanizer {

    /// Reverse-romanize a Myanmar string to its canonical reading.
    public static func romanize(_ myanmar: String) -> String {
        let scalars = Array(myanmar.unicodeScalars)
        var result = ""
        var i = 0

        while i < scalars.count {
            let s = scalars[i]

            // Skip U+200C (ZWNJ) — added for leading vowels
            if s.value == 0x200C {
                i += 1
                continue
            }

            // Try to match an onsetless `အ` (U+1021) + combining-mark
            // compound against canonical forward readings (`an`, `ar`,
            // …). Without this fast-path the consonant branch below
            // emits `ah` + vowel-sequence, which produces readings like
            // `ahan3` / `ahar` that the forward engine cannot consume.
            if let (roman, consumed) = matchOnsetlessA(scalars, from: i) {
                result += roman
                i += consumed
                continue
            }

            // Try to match an independent vowel
            if let (roman, consumed) = matchIndependentVowel(scalars, from: i) {
                result += roman
                i += consumed
                continue
            }

            // Consonant
            if Myanmar.isConsonant(s) {
                let consonantChar = Character(s)

                // Check for virama stacking: consonant + ္ + next consonant
                if i + 2 < scalars.count && scalars[i + 1].value == 0x1039 && Myanmar.isConsonant(scalars[i + 2]) {
                    // This consonant is stacked onto the next: emit consonant + "+"
                    if let roman = Romanization.consonantToRoman[consonantChar] {
                        result += roman
                    }
                    result += "+"
                    i += 2 // advance past virama; next iteration handles the subscript consonant
                    continue
                }

                // Collect medials following this consonant
                var medials: [Unicode.Scalar] = []
                var j = i + 1
                while j < scalars.count && Myanmar.isMedial(scalars[j]) {
                    medials.append(scalars[j])
                    j += 1
                }

                // Build the onset roman key: [h]<base>[w][y|y2]
                let hasH = medials.contains { $0.value == 0x103E }  // ှ ha-htoe
                let hasW = medials.contains { $0.value == 0x103D }  // ွ wa-hswe
                let hasY = medials.contains { $0.value == 0x103C }  // ြ ya-yit
                let hasY2 = medials.contains { $0.value == 0x103B } // ျ ya-pin

                var onset = ""
                if hasH { onset += "h" }
                if let roman = Romanization.consonantToRoman[consonantChar] {
                    onset += roman
                }
                if hasW { onset += "w" }
                if hasY { onset += "y" }
                if hasY2 { onset += "y2" }

                result += onset

                // Now match the vowel/final sequence after onset+medials
                if let (vowelRoman, consumed) = matchVowelSequence(scalars, from: j) {
                    result += vowelRoman
                    i = j + consumed
                } else {
                    // Inherent vowel 'a'. Emitted even for `အ` (roman `ah`)
                    // because the trailing `a` serves as a syllable-boundary
                    // anchor downstream: without it, compound buffers like
                    // `ahphayahainhmarhri.te` become parser-ambiguous between
                    // `ah+ph+ay` and `a+hph+ay`.
                    result += "a"
                    i = j
                }
                continue
            }

            // Standalone vowel signs (no consonant onset) — shouldn't normally happen
            // in well-formed Myanmar text, but handle gracefully
            if let (vowelRoman, consumed) = matchVowelSequence(scalars, from: i) {
                result += vowelRoman
                i += consumed
                continue
            }

            // Unrecognized scalar — skip
            i += 1
        }

        return result
    }

    // MARK: - Internal Matching

    /// Try to match an independent vowel at position.
    private static func matchIndependentVowel(_ scalars: [Unicode.Scalar], from start: Int) -> (String, Int)? {
        guard start < scalars.count else { return nil }
        for entry in independentVowelPatterns {
            guard entry.pattern.count <= scalars.count - start else { continue }
            var matches = true
            for k in 0..<entry.pattern.count {
                if scalars[start + k].value != entry.pattern[k] {
                    matches = false
                    break
                }
            }
            if matches {
                return (entry.roman, entry.pattern.count)
            }
        }
        return nil
    }

    /// Independent-vowel entries (U+1023–U+102A) sourced from
    /// `Romanization.vowels`. Sorted by pattern length descending so
    /// multi-scalar forms like `ဦး` (u2:) match before their prefix `ဦ`.
    ///
    /// `ဣ` (U+1023) and `ဥ` (U+1025) are remapped to their digit-less
    /// canonical readings (`i.` / `u`) so reverse aliases agree with
    /// what a typist actually produces — see tasks/ 04. The other
    /// independent-vowel rows carry the same roman the forward table
    /// uses.
    private static let independentVowelPatterns: [VowelPattern] = {
        let canonicalOverrides: [UInt32: String] = [
            0x1023: "i.",
            0x1025: "u",
        ]
        var patterns: [VowelPattern] = []
        for entry in Romanization.vowels {
            guard entry.isStandalone else { continue }
            let scalarValues = Array(entry.myanmar.unicodeScalars.map(\.value))
            guard let first = scalarValues.first,
                  first >= 0x1023 && first <= 0x102A else { continue }
            let roman: String
            if scalarValues.count == 1, let override = canonicalOverrides[first] {
                roman = override
            } else {
                roman = entry.roman
            }
            patterns.append(VowelPattern(roman: roman, pattern: scalarValues))
        }
        patterns.sort { $0.pattern.count > $1.pattern.count }
        return patterns
    }()

    /// Onsetless-a compounds: a leading `အ` (U+1021) followed by a
    /// vowel-mark sequence that spells a canonical forward reading.
    /// The consonant branch below would otherwise emit `ah` + vowel,
    /// producing `ahan3` / `ahar` / etc., which the forward parser
    /// cannot round-trip because `an` / `ar` forward-map straight to
    /// these surfaces via the onsetless-anusvara override and the
    /// ZWNJ-promotion fallback in `BurmeseEngine`.
    ///
    /// Patterns are matched longest-first so `အား` is picked before
    /// `အာ`.
    private static let onsetlessAPatterns: [VowelPattern] = {
        let raw: [(String, String)] = [
            // Onsetless anusvara (forward rule pair in BurmeseEngine).
            ("an:",  "\u{1021}\u{1036}\u{1038}"),
            ("an.",  "\u{1021}\u{1036}\u{1037}"),
            ("an",   "\u{1021}\u{1036}"),
            // Onsetless aa family (forward default rule `ar` / `ar:` /
            // `ar.`, promoted to implicit-အ onset for the bare buffer).
            ("ar:",  "\u{1021}\u{102C}\u{1038}"),
            ("ar.",  "\u{1021}\u{102C}\u{1037}"),
            ("ar",   "\u{1021}\u{102C}"),
        ]
        var patterns = raw.map { (roman, myanmar) in
            VowelPattern(
                roman: roman,
                pattern: Array(myanmar.unicodeScalars.map(\.value))
            )
        }
        patterns.sort { $0.pattern.count > $1.pattern.count }
        return patterns
    }()

    /// Match a leading U+1021 followed by a canonical combining-mark
    /// compound. Returns the canonical reading and the total scalars
    /// consumed (including the leading U+1021), or nil when no
    /// onsetless-a compound applies at this position.
    private static func matchOnsetlessA(_ scalars: [Unicode.Scalar], from start: Int) -> (String, Int)? {
        guard start < scalars.count, scalars[start].value == 0x1021 else { return nil }
        for entry in onsetlessAPatterns {
            let pattern = entry.pattern
            guard pattern.count <= scalars.count - start else { continue }
            var matches = true
            for k in 0..<pattern.count {
                if scalars[start + k].value != pattern[k] {
                    matches = false
                    break
                }
            }
            if matches {
                return (entry.roman, pattern.count)
            }
        }
        return nil
    }

    /// Match a vowel/final sequence starting at position.
    /// Returns the roman key and number of scalars consumed.
    ///
    /// The `2` suffix on aa-shape vowels (`ar2`, `aw2`, `out2`, `aung2`,
    /// and their tonal siblings) is stripped from the emitted roman:
    /// those digits just disambiguate tall-aa (U+102B) from short-aa
    /// (U+102C), which `BurmeseEngine.correctAaShape` resolves from the
    /// preceding consonant at render time. The reading the user types
    /// has no `2`, so the reverse form must agree.
    private static func matchVowelSequence(_ scalars: [Unicode.Scalar], from start: Int) -> (String, Int)? {
        guard start < scalars.count else { return nil }

        // Try longest matches first by checking multi-scalar patterns.
        // Build a sequence of up to 6 scalars to match against known vowel patterns.
        let remaining = min(6, scalars.count - start)
        let slice = Array(scalars[start..<start + remaining])

        // Match against known vowel output patterns (reverse of Romanization.vowels)
        // Check longest patterns first
        let tallAa: UInt32 = 0x102B
        for entry in vowelPatterns {
            let pattern = entry.pattern
            if pattern.count <= slice.count {
                var matches = true
                for k in 0..<pattern.count {
                    if slice[k].value != pattern[k] {
                        matches = false
                        break
                    }
                }
                if matches {
                    let roman: String
                    if pattern.contains(tallAa) {
                        roman = entry.roman.filter { $0 != "2" }
                    } else {
                        roman = entry.roman
                    }
                    return (roman, pattern.count)
                }
            }
        }

        return nil
    }

    /// Pre-computed reverse vowel patterns, sorted by pattern length descending.
    private struct VowelPattern {
        let roman: String
        let pattern: [UInt32]  // Unicode scalar values
    }

    /// All vowel patterns sorted by length descending for longest-match.
    private static let vowelPatterns: [VowelPattern] = {
        // Build patterns from Romanization.vowels
        var patterns: [VowelPattern] = []

        for entry in Romanization.vowels {
            guard !entry.myanmar.isEmpty else { continue }  // skip empty (', a)
            let scalarValues = Array(entry.myanmar.unicodeScalars.map(\.value))
            patterns.append(VowelPattern(roman: entry.roman, pattern: scalarValues))
        }

        // Sort by pattern length descending for longest-match
        patterns.sort { $0.pattern.count > $1.pattern.count }
        return patterns
    }()
}
