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
/// The parser uses an N-best Viterbi-style DP search over the buffer, matching
/// pre-computed consonant+medial combinations followed by vowel suffixes.
public final class SyllableParser: Sendable {

    struct ParseState: Sendable {
        let output: String
        let reading: String
        let score: Int
        let legalityScore: Int
        let aliasCost: Int
        let syllableCount: Int
        let structureCost: Int
        let isLegal: Bool
    }

    /// Pre-computed consonant+medial combinations mapped from roman key to Myanmar output.
    struct OnsetEntry: Sendable {
        let canonicalRoman: String
        let myanmar: String       // consonant + medials as Myanmar string
        let onset: Character      // the base consonant
        let medials: [Character]  // medial characters used
        let aliasCost: Int
        let structureCost: Int
    }

    struct VowelMatchEntry: Sendable {
        let canonicalRoman: String
        let myanmar: String
        let aliasCost: Int
    }

    private typealias OnsetMatch = (end: Int, entry: OnsetEntry)
    private typealias VowelMatch = (end: Int, entry: VowelMatchEntry)

    /// All possible onset entries (consonant + optional medials), keyed by the
    /// exact match string or its digitless alias.
    private let onsetEntries: [String: [OnsetEntry]]

    /// Vowel entries keyed by the exact match string or its digitless alias.
    private let vowelEntries: [String: [VowelMatchEntry]]

    /// Vowel keys sorted by descending length for longest-match.
    private let vowelKeysSorted: [String]

    /// Maximum onset key length for bounded search.
    public let maxOnsetLen: Int

    /// Maximum vowel key length for bounded search.
    public let maxVowelLen: Int

    public init() {
        var onsetLookup: [String: [OnsetEntry]] = [:]

        func appendOnset(
            canonicalRoman: String,
            myanmar: String,
            onset: Character,
            medials: [Character],
            baseAliasCost: Int
        ) {
            for variant in Romanization.aliasVariants(for: canonicalRoman, baseAliasCost: baseAliasCost) {
                onsetLookup[variant.key, default: []].append(OnsetEntry(
                    canonicalRoman: canonicalRoman,
                    myanmar: myanmar,
                    onset: onset,
                    medials: medials,
                    aliasCost: variant.aliasCost,
                    structureCost: medials.count
                ))
            }
        }

        // Generate all consonant + medial combinations (matching the legacy engine)
        for cons in Romanization.consonants {
            appendOnset(
                canonicalRoman: cons.roman,
                myanmar: String(cons.myanmar),
                onset: cons.myanmar,
                medials: [],
                baseAliasCost: cons.aliasCost
            )

            // Generate medial combinations matching the legacy engine's scheme:
            // h prefix → ha-htoe (ှ), w suffix → wa-hswe (ွ),
            // y suffix → ya-yit (ြ), y2 suffix → ya-pin (ျ)
            for combo in Grammar.medialCombinations {
                let hasH = combo.contains(Myanmar.medialHa)
                let hasW = combo.contains(Myanmar.medialWa)
                let hasY = combo.contains(Myanmar.medialRa)   // ြ = ya-yit, roman "y"
                let hasY2 = combo.contains(Myanmar.medialYa)  // ျ = ya-pin, roman "y2"

                var allLegal = true
                for medial in combo where !Grammar.canConsonantTakeMedial(cons.myanmar, medial) {
                    allLegal = false
                    break
                }

                let canonicalRoman =
                    (hasH ? "h" : "") +
                    cons.roman +
                    (hasW ? "w" : "") +
                    (hasY ? "y" : "") +
                    (hasY2 ? "y2" : "")

                var myanmarOutput = String(cons.myanmar)
                if hasY  { myanmarOutput += String(Myanmar.medialRa) }
                if hasY2 { myanmarOutput += String(Myanmar.medialYa) }
                if hasW  { myanmarOutput += String(Myanmar.medialWa) }
                if hasH  { myanmarOutput += String(Myanmar.medialHa) }

                appendOnset(
                    canonicalRoman: canonicalRoman,
                    myanmar: myanmarOutput,
                    onset: cons.myanmar,
                    medials: combo,
                    baseAliasCost: cons.aliasCost + (allLegal ? 0 : 100)
                )
            }
        }

        // Phonetic cluster shortcuts (`j`, `ch`, `gy`, `sh`, + `w` variants).
        // Inserted directly under the shortcut key so canonical aliasVariants
        // handling for other onsets is unaffected.
        for alias in Romanization.clusterAliases {
            var myanmarOutput = String(alias.consonant)
            for medial in alias.medials {
                myanmarOutput.append(medial)
            }

            let hasH  = alias.medials.contains(Myanmar.medialHa)
            let hasW  = alias.medials.contains(Myanmar.medialWa)
            let hasY  = alias.medials.contains(Myanmar.medialRa)
            let hasY2 = alias.medials.contains(Myanmar.medialYa)
            let baseRoman = Romanization.consonantToRoman[alias.consonant] ?? ""
            let canonical =
                (hasH ? "h" : "") +
                baseRoman +
                (hasW ? "w" : "") +
                (hasY ? "y" : "") +
                (hasY2 ? "y2" : "")

            onsetLookup[alias.roman, default: []].append(OnsetEntry(
                canonicalRoman: canonical,
                myanmar: myanmarOutput,
                onset: alias.consonant,
                medials: alias.medials,
                aliasCost: alias.aliasCost,
                structureCost: alias.medials.count
            ))
        }

        self.onsetEntries = onsetLookup
        self.maxOnsetLen = onsetLookup.keys.map(\.count).max() ?? 1

        var vowelLookup: [String: [VowelMatchEntry]] = [:]
        for entry in Romanization.vowels {
            for variant in Romanization.aliasVariants(for: entry.roman, baseAliasCost: entry.aliasCost) {
                vowelLookup[variant.key, default: []].append(VowelMatchEntry(
                    canonicalRoman: entry.roman,
                    myanmar: entry.myanmar,
                    aliasCost: variant.aliasCost
                ))
            }
        }
        self.vowelEntries = vowelLookup
        self.maxVowelLen = vowelLookup.keys.map(\.count).max() ?? 1
        self.vowelKeysSorted = vowelLookup.keys.sorted { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs < rhs
        }
    }

    // MARK: - Public API

    /// Parse a romanized buffer into its best Burmese output.
    public func parse(_ input: String) -> [SyllableParse] {
        parseCandidates(input, maxResults: 1)
    }

    /// Parse a romanized buffer into multiple Burmese candidates.
    public func parseCandidates(_ input: String, maxResults: Int = 8) -> [SyllableParse] {
        let normalized = Romanization.normalize(input)
        guard !normalized.isEmpty, maxResults > 0 else { return [] }

        let chars = Array(normalized)
        let beamWidth = max(maxResults * 16, 64)
        let onsetMatchesByStart = precomputeOnsetMatches(chars)
        let vowelMatchesByStart = precomputeVowelMatches(chars)
        let states = finalizeStates(
            nBestParse(
                chars,
                onsetMatchesByStart: onsetMatchesByStart,
                vowelMatchesByStart: vowelMatchesByStart,
                maxResults: beamWidth
            ),
            limit: maxResults
        )
        return states.map { state in
            SyllableParse(
                output: adjustLeadingVowel(state.output),
                reading: state.reading,
                aliasCost: state.aliasCost,
                legalityScore: state.isLegal ? 100 : 0,
                score: state.score,
                structureCost: state.structureCost
            )
        }
    }

    // MARK: - N-best DP Parse

    /// Bucket at a single DP position. Uses a dictionary for O(1) dedup
    /// and defers sorting until all transitions into this position are done.
    private struct DPBucket {
        /// Best state for each (output, reading) key.
        var index: [StateKey: Int] = [:]
        var states: [ParseState] = []
        var needsPrune = false
    }

    private struct StateKey: Hashable {
        let output: String
        let reading: String
    }

    private func nBestParse(
        _ chars: [Character],
        onsetMatchesByStart: [[OnsetMatch]],
        vowelMatchesByStart: [[VowelMatch]],
        maxResults: Int
    ) -> [ParseState] {
        let n = chars.count
        var dp = [DPBucket](repeating: DPBucket(), count: n + 1)
        let seed = ParseState(
            output: "",
            reading: "",
            score: 0,
            legalityScore: 0,
            aliasCost: 0,
            syllableCount: 0,
            structureCost: 0,
            isLegal: true
        )
        dp[0].states.append(seed)
        dp[0].index[StateKey(output: "", reading: "")] = 0

        for i in 0..<n {
            guard !dp[i].states.isEmpty else { continue }

            // Prune the current bucket before expanding, if it grew large.
            if dp[i].needsPrune {
                pruneBucket(&dp[i], limit: maxResults)
            }

            let onsetMatches = onsetMatchesByStart[i]
            let standaloneVowels = vowelMatchesByStart[i]
            for previous in dp[i].states {
                var matched = false

                for (onsetEnd, onsetEntry) in onsetMatches {
                    let onsetReading = onsetEntry.canonicalRoman + "a"
                    let onsetLegality = Grammar.validateSyllable(
                        onset: onsetEntry.onset,
                        medials: onsetEntry.medials,
                        vowelRoman: "a"
                    )
                    insertState(
                        &dp,
                        at: onsetEnd,
                        state: ParseState(
                            output: previous.output + onsetEntry.myanmar,
                            reading: previous.reading + onsetReading,
                            score: previous.score + scoreMatch(
                                consumed: onsetEnd - i,
                                ruleCount: 1,
                                legality: onsetLegality,
                                aliasCost: onsetEntry.aliasCost
                            ),
                            legalityScore: previous.legalityScore + max(onsetLegality, 0),
                            aliasCost: previous.aliasCost + onsetEntry.aliasCost,
                            syllableCount: previous.syllableCount + 1,
                            structureCost: previous.structureCost + onsetEntry.structureCost,
                            isLegal: previous.isLegal && onsetLegality > 0
                        ),
                        limit: maxResults
                    )
                    matched = true

                    let vowelMatches = vowelMatchesByStart[onsetEnd]
                    for (vowelEnd, vowelEntry) in vowelMatches {
                        let legality = Grammar.validateSyllable(
                            onset: onsetEntry.onset,
                            medials: onsetEntry.medials,
                            vowelRoman: vowelEntry.canonicalRoman
                        )
                        insertState(
                            &dp,
                            at: vowelEnd,
                            state: ParseState(
                                output: previous.output + onsetEntry.myanmar + vowelEntry.myanmar,
                                reading: previous.reading + onsetEntry.canonicalRoman + vowelEntry.canonicalRoman,
                                score: previous.score + scoreMatch(
                                    consumed: vowelEnd - i,
                                    ruleCount: 2,
                                    legality: legality,
                                    aliasCost: onsetEntry.aliasCost + vowelEntry.aliasCost
                                ),
                                legalityScore: previous.legalityScore + max(legality, 0),
                                aliasCost: previous.aliasCost + onsetEntry.aliasCost + vowelEntry.aliasCost,
                                syllableCount: previous.syllableCount + 1,
                                structureCost: previous.structureCost + onsetEntry.structureCost,
                                isLegal: previous.isLegal && legality > 0
                            ),
                            limit: maxResults
                        )
                        matched = true
                    }
                }

                for (vowelEnd, vowelEntry) in standaloneVowels {
                    let legality = Grammar.validateSyllable(
                        onset: nil,
                        medials: [],
                        vowelRoman: vowelEntry.canonicalRoman
                    )
                    insertState(
                        &dp,
                        at: vowelEnd,
                        state: ParseState(
                            output: previous.output + vowelEntry.myanmar,
                            reading: previous.reading + vowelEntry.canonicalRoman,
                            score: previous.score + scoreMatch(
                                consumed: vowelEnd - i,
                                ruleCount: 1,
                                legality: legality,
                                aliasCost: vowelEntry.aliasCost
                            ),
                            legalityScore: previous.legalityScore + max(legality, 0),
                            aliasCost: previous.aliasCost + vowelEntry.aliasCost,
                            syllableCount: previous.syllableCount + 1,
                            structureCost: previous.structureCost,
                            isLegal: previous.isLegal && legality > 0
                        ),
                        limit: maxResults
                    )
                    matched = true
                }

                if !matched {
                    insertState(
                        &dp,
                        at: i + 1,
                        state: ParseState(
                            output: previous.output,
                            reading: previous.reading,
                            score: previous.score - 100,
                            legalityScore: previous.legalityScore,
                            aliasCost: previous.aliasCost,
                            syllableCount: previous.syllableCount,
                            structureCost: previous.structureCost,
                            isLegal: false
                        ),
                        limit: maxResults
                    )
                }
            }
        }

        if dp[n].needsPrune {
            pruneBucket(&dp[n], limit: maxResults)
        }
        return dp[n].states
    }

    // MARK: - Matching

    /// Match onset entries (consonant + optional medials) at position.
    private func matchOnsets(_ chars: [Character], from start: Int) -> [(end: Int, entry: OnsetEntry)] {
        var results: [OnsetMatch] = []
        let remaining = chars.count - start
        guard remaining > 0 else { return results }

        let maxLen = min(maxOnsetLen, remaining)
        for len in stride(from: maxLen, through: 1, by: -1) {
            let key = String(chars[start..<start + len])
            if let entries = onsetEntries[key] {
                for entry in entries {
                    results.append((start + len, entry))
                }
            }
        }
        return results
    }

    /// Match vowel/final at position.
    private func matchVowels(_ chars: [Character], from start: Int) -> [(end: Int, entry: VowelMatchEntry)] {
        var results: [VowelMatch] = []
        let remaining = chars.count - start
        guard remaining > 0 else { return results }

        for key in vowelKeysSorted {
            guard key.count <= remaining else { continue }
            let slice = String(chars[start..<start + key.count])
            if slice == key, let entries = vowelEntries[key] {
                for entry in entries {
                    results.append((start + key.count, entry))
                }
            }
        }
        return results
    }

    private func precomputeOnsetMatches(_ chars: [Character]) -> [[OnsetMatch]] {
        var matches = Array(repeating: [OnsetMatch](), count: chars.count + 1)
        guard !chars.isEmpty else { return matches }

        for index in 0..<chars.count {
            matches[index] = matchOnsets(chars, from: index)
        }
        return matches
    }

    private func precomputeVowelMatches(_ chars: [Character]) -> [[VowelMatch]] {
        var matches = Array(repeating: [VowelMatch](), count: chars.count + 1)
        guard !chars.isEmpty else { return matches }

        for index in 0..<chars.count {
            matches[index] = matchVowels(chars, from: index)
        }
        return matches
    }

    // MARK: - Finalization

    private func finalizeStates(_ states: [ParseState], limit: Int) -> [ParseState] {
        let nonEmptyStates = states.filter { !$0.output.isEmpty }
        let legalStates = nonEmptyStates.filter(\.isLegal)

        let filteredStates: [ParseState]
        if let minimumLegalSyllables = legalStates.map(\.syllableCount).min() {
            filteredStates = legalStates.filter { $0.syllableCount == minimumLegalSyllables }
        } else {
            filteredStates = nonEmptyStates
        }

        var deduplicated: [String: ParseState] = [:]

        for state in sortedStates(filteredStates) {
            let adjustedOutput = adjustLeadingVowel(state.output)
            if let existing = deduplicated[adjustedOutput] {
                if isBetter(state, than: existing) {
                    deduplicated[adjustedOutput] = state
                }
            } else {
                deduplicated[adjustedOutput] = state
            }
        }

        return Array(sortedStates(Array(deduplicated.values)).prefix(limit))
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

    private func insertState(
        _ dp: inout [DPBucket],
        at index: Int,
        state: ParseState,
        limit: Int
    ) {
        guard index < dp.count else { return }

        let key = StateKey(output: state.output, reading: state.reading)
        if let existingIdx = dp[index].index[key] {
            if isBetter(state, than: dp[index].states[existingIdx]) {
                dp[index].states[existingIdx] = state
            }
        } else {
            dp[index].index[key] = dp[index].states.count
            dp[index].states.append(state)
            if dp[index].states.count > limit * 2 {
                dp[index].needsPrune = true
            }
        }
    }

    private func pruneBucket(_ bucket: inout DPBucket, limit: Int) {
        guard bucket.states.count > limit else {
            bucket.needsPrune = false
            return
        }
        bucket.states = Array(sortedStates(bucket.states).prefix(limit))
        bucket.index.removeAll(keepingCapacity: true)
        for (i, state) in bucket.states.enumerated() {
            bucket.index[StateKey(output: state.output, reading: state.reading)] = i
        }
        bucket.needsPrune = false
    }

    private func sortedStates(_ states: [ParseState]) -> [ParseState] {
        states.sorted { lhs, rhs in
            isBetter(lhs, than: rhs)
        }
    }

    private func isBetter(_ lhs: ParseState, than rhs: ParseState) -> Bool {
        if lhs.isLegal != rhs.isLegal {
            return lhs.isLegal
        }
        if lhs.aliasCost != rhs.aliasCost {
            return lhs.aliasCost < rhs.aliasCost
        }
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        if lhs.syllableCount != rhs.syllableCount {
            return lhs.syllableCount < rhs.syllableCount
        }
        if lhs.structureCost != rhs.structureCost {
            return lhs.structureCost < rhs.structureCost
        }
        if lhs.output != rhs.output {
            return lhs.output < rhs.output
        }
        return lhs.reading < rhs.reading
    }
}
