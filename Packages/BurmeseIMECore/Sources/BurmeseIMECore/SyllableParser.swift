import Foundation

/// Grammar-aware incremental syllable parser for Hybrid Burmese romanization.
///
/// The Hybrid Burmese romanization scheme encodes consonant+medial combinations
/// as a single unit: prefix 'h' for ha-htoe, suffix 'y' for ya-yit, 'y2' for
/// ya-pin, 'w' for wa-hswe. For example:
///   - "ky" = က + ြ (ka + medial ra/ya-yit)
///   - "hk" = က + ှ (ka + medial ha-htoe)
///   - "hkwy2" = က + ျ + ွ + ှ (ka + all four medials)
///
/// The parser uses a Viterbi-style best-path DP search over the buffer,
/// matching pre-computed consonant+medial combinations followed by vowel suffixes.
public final class SyllableParser: Sendable {

    struct ParseNode {
        let output: String
        let score: Int
        let syllableCount: Int
        let isLegal: Bool
    }

    /// Pre-computed consonant+medial combinations mapped from roman key to Myanmar output.
    struct OnsetEntry: Sendable {
        let roman: String
        let myanmar: String       // consonant + medials as Myanmar string
        let onset: Character      // the base consonant
        let medials: [Character]  // medial characters used
        let aliasCost: Int
    }

    /// All possible onset entries (consonant + optional medials).
    private let onsetEntries: [String: [OnsetEntry]]

    /// Vowel entries by roman key.
    private let vowelEntries: [String: Romanization.VowelEntry]

    /// Vowel keys sorted by descending length for longest-match.
    private let vowelKeysSorted: [String]

    /// Maximum onset key length for bounded search.
    private let maxOnsetLen: Int

    public init() {
        var entries: [String: [OnsetEntry]] = [:]

        // Generate all consonant + medial combinations (matching the legacy engine)
        for cons in Romanization.consonants {
            // Base consonant alone
            let baseEntry = OnsetEntry(
                roman: cons.roman,
                myanmar: String(cons.myanmar),
                onset: cons.myanmar,
                medials: [],
                aliasCost: cons.aliasCost
            )
            entries[cons.roman, default: []].append(baseEntry)

            // Generate medial combinations matching the legacy engine's scheme:
            // h prefix → ha-htoe (ှ), w suffix → wa-hswe (ွ),
            // y suffix → ya-yit (ြ), y2 suffix → ya-pin (ျ)
            for combo in Grammar.medialCombinations {
                let hasH = combo.contains(Myanmar.medialHa)
                let hasW = combo.contains(Myanmar.medialWa)
                let hasY = combo.contains(Myanmar.medialRa)   // ြ = ya-yit, roman "y"
                let hasY2 = combo.contains(Myanmar.medialYa)  // ျ = ya-pin, roman "y2"

                // Check legality of each medial with this consonant
                var allLegal = true
                for medial in combo {
                    if !Grammar.canConsonantTakeMedial(cons.myanmar, medial) {
                        allLegal = false
                        break
                    }
                }

                // Build roman key: [h]<consonant_base>[w][y|y2]
                let romanKey =
                    (hasH ? "h" : "") +
                    cons.roman +
                    (hasW ? "w" : "") +
                    (hasY ? "y" : "") +
                    (hasY2 ? "y2" : "")

                // Build Myanmar output: consonant + medials in canonical order
                // Canonical order: ျ (U+103B) < ြ (U+103C) < ွ (U+103D) < ှ (U+103E)
                var myanmarOutput = String(cons.myanmar)
                if hasY  { myanmarOutput += String(Myanmar.medialRa) }   // ြ
                if hasY2 { myanmarOutput += String(Myanmar.medialYa) }   // ျ
                if hasW  { myanmarOutput += String(Myanmar.medialWa) }   // ွ
                if hasH  { myanmarOutput += String(Myanmar.medialHa) }   // ှ

                let entry = OnsetEntry(
                    roman: romanKey,
                    myanmar: myanmarOutput,
                    onset: cons.myanmar,
                    medials: combo,
                    aliasCost: allLegal ? cons.aliasCost : cons.aliasCost + 100
                )
                entries[romanKey, default: []].append(entry)
            }
        }

        self.onsetEntries = entries
        self.maxOnsetLen = entries.keys.map(\.count).max() ?? 1

        self.vowelEntries = Romanization.romanToVowel
        self.vowelKeysSorted = Romanization.vowelKeysByLength
    }

    // MARK: - Public API

    /// Parse a romanized buffer into Burmese output.
    public func parse(_ input: String) -> [SyllableParse] {
        let normalized = Romanization.normalize(input)
        guard !normalized.isEmpty else { return [] }

        let bestPath = viterbiParse(normalized)
        guard !bestPath.output.isEmpty else { return [] }

        let adjusted = adjustLeadingVowel(bestPath.output)
        return [SyllableParse(
            output: adjusted,
            reading: normalized,
            aliasCost: 0,
            legalityScore: bestPath.isLegal ? bestPath.score : 0
        )]
    }

    // MARK: - Viterbi DP Parse

    private func viterbiParse(_ input: String) -> ParseNode {
        let chars = Array(input)
        let n = chars.count
        var dp = [ParseNode?](repeating: nil, count: n + 1)
        dp[0] = ParseNode(output: "", score: 0, syllableCount: 0, isLegal: true)

        var i = 0
        while i < n {
            guard let prev = dp[i] else { i += 1; continue }

            var anyMatch = false

            // 1. Try onset (consonant + optional medials) followed by optional vowel
            let onsetMatches = matchOnsets(chars, from: i)
            for (onsetEnd, onsetEntry) in onsetMatches {
                // Consonant alone (inherent 'a' vowel): counts as 1 rule
                do {
                    let out = prev.output + onsetEntry.myanmar
                    let legality = Grammar.validateSyllable(
                        onset: onsetEntry.onset, medials: onsetEntry.medials, vowelRoman: "a"
                    )
                    // Score: consumed - 1 (one rule)
                    let score = prev.score + scoreMatch(
                        consumed: onsetEnd - i, ruleCount: 1, legality: legality,
                        aliasCost: onsetEntry.aliasCost
                    )
                    updateDP(&dp, at: onsetEnd, node: ParseNode(
                        output: out, score: score,
                        syllableCount: prev.syllableCount + 1,
                        isLegal: prev.isLegal && legality > 0
                    ))
                    anyMatch = true
                }

                // Consonant + explicit vowel suffix: counts as 2 rules
                let vowelMatches = matchVowels(chars, from: onsetEnd)
                for (vowEnd, vowEntry) in vowelMatches {
                    let out = prev.output + onsetEntry.myanmar + vowEntry.myanmar
                    let legality = Grammar.validateSyllable(
                        onset: onsetEntry.onset, medials: onsetEntry.medials,
                        vowelRoman: vowEntry.roman
                    )
                    // Score: consumed - 2 (two rules: onset + vowel)
                    let score = prev.score + scoreMatch(
                        consumed: vowEnd - i, ruleCount: 2, legality: legality,
                        aliasCost: onsetEntry.aliasCost + vowEntry.aliasCost
                    )
                    updateDP(&dp, at: vowEnd, node: ParseNode(
                        output: out, score: score,
                        syllableCount: prev.syllableCount + 1,
                        isLegal: prev.isLegal && legality > 0
                    ))
                    anyMatch = true
                }
            }

            // 2. Try standalone vowel/final (no consonant onset): counts as 1 rule
            let standaloneVowels = matchVowels(chars, from: i)
            for (vowEnd, vowEntry) in standaloneVowels {
                let out = prev.output + vowEntry.myanmar
                let legality = Grammar.validateSyllable(
                    onset: nil, medials: [], vowelRoman: vowEntry.roman
                )
                let score = prev.score + scoreMatch(
                    consumed: vowEnd - i, ruleCount: 1, legality: legality,
                    aliasCost: vowEntry.aliasCost
                )
                updateDP(&dp, at: vowEnd, node: ParseNode(
                    output: out, score: score,
                    syllableCount: prev.syllableCount + 1,
                    isLegal: prev.isLegal && legality > 0
                ))
                anyMatch = true
            }

            // 3. Fallback: unmatched character is skipped (not emitted)
            // to prevent Latin/digit leakage into Myanmar output
            if !anyMatch {
                let out = prev.output
                let score = prev.score - 100
                updateDP(&dp, at: i + 1, node: ParseNode(
                    output: out, score: score,
                    syllableCount: prev.syllableCount,
                    isLegal: false
                ))
            }

            i += 1
        }

        return dp[n] ?? ParseNode(output: input, score: -1000, syllableCount: 0, isLegal: false)
    }

    // MARK: - Matching

    /// Match onset entries (consonant + optional medials) at position.
    private func matchOnsets(_ chars: [Character], from start: Int) -> [(end: Int, entry: OnsetEntry)] {
        var results: [(Int, OnsetEntry)] = []
        let remaining = chars.count - start
        guard remaining > 0 else { return results }

        let maxLen = min(maxOnsetLen, remaining)
        for len in stride(from: maxLen, through: 1, by: -1) {
            let key = String(chars[start..<start+len])
            if let entries = onsetEntries[key] {
                for entry in entries {
                    results.append((start + len, entry))
                }
            }
        }
        return results
    }

    /// Match vowel/final at position.
    private func matchVowels(_ chars: [Character], from start: Int) -> [(end: Int, entry: Romanization.VowelEntry)] {
        var results: [(Int, Romanization.VowelEntry)] = []
        let remaining = chars.count - start
        guard remaining > 0 else { return results }

        for key in vowelKeysSorted {
            guard key.count <= remaining else { continue }
            let slice = String(chars[start..<start+key.count])
            if slice == key, let entry = vowelEntries[key] {
                results.append((start + key.count, entry))
            }
        }
        return results
    }

    // MARK: - Leading Vowel Adjustment

    private func adjustLeadingVowel(_ text: String) -> String {
        guard let first = text.unicodeScalars.first else { return text }

        let leadingVowelSigns: Set<UInt32> = [
            0x1031,  // ေ
            0x1032,  // ဲ
            0x102D,  // ိ
            0x102E,  // ီ
            0x102F,  // ု
            0x1030,  // ူ
            0x103E,  // ှ
        ]

        if leadingVowelSigns.contains(first.value) {
            return "\u{200C}" + text
        }
        return text
    }

    // MARK: - Scoring

    /// Score a match. Mirrors the legacy engine: score = sum(pronunciation_lengths) - rule_count.
    /// `ruleCount` is how many atomic rules this match represents (1 for onset-only or vowel-only,
    /// 2 for onset+vowel combined).
    private func scoreMatch(consumed: Int, ruleCount: Int, legality: Int, aliasCost: Int) -> Int {
        var score = consumed - ruleCount
        if legality <= 0 {
            score -= 10000
        }
        score -= aliasCost
        return score
    }

    private func updateDP(_ dp: inout [ParseNode?], at index: Int, node: ParseNode) {
        guard index < dp.count else { return }
        if let existing = dp[index] {
            if node.isLegal && !existing.isLegal {
                dp[index] = node
            } else if node.isLegal == existing.isLegal && node.score > existing.score {
                dp[index] = node
            }
        } else {
            dp[index] = node
        }
    }
}
