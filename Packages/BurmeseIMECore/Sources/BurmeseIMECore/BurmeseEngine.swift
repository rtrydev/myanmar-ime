/// The main composition engine for the Burmese IME.
///
/// Manages the composition buffer, generates candidates from grammar parsing
/// and lexicon lookup, and handles commit/cancel operations.
///
/// Ranking order: grammar legality > alias cost > parser score > lexicon frequency.
public final class BurmeseEngine: Sendable {

    private struct RankedGrammarCandidate {
        var candidate: Candidate
        let legalityScore: Int
        let aliasCost: Int
        let parserScore: Int
        let structureCost: Int
    }

    private struct RankedLexiconCandidate {
        let candidate: Candidate
        let aliasPenalty: Int
        let aliasReading: String
        let composeReading: String
    }

    private static let grammarCandidateBudget = 16

    private let parser: SyllableParser
    private let candidateStore: any CandidateStore

    /// Page size for candidate display.
    public static let candidatePageSize = 5

    public init(candidateStore: any CandidateStore = EmptyCandidateStore()) {
        self.parser = SyllableParser()
        self.candidateStore = candidateStore
    }

    /// Update the composition state based on the current buffer and context.
    /// Called on every keystroke that modifies the buffer.
    public func update(buffer: String, context: [String]) -> CompositionState {
        guard !buffer.isEmpty else {
            return CompositionState(committedContext: context)
        }
        let displayBuffer = buffer.lowercased()
        // Candidates are generated only from the leading run of composing
        // characters. Anything after the first non-composing character
        // (punctuation, whitespace, etc.) is held aside and emitted verbatim
        // on commit — this lets the user freely mix Burmese-convertible text
        // with literal content without the IME swallowing either.
        let (composable, literalTail) = Self.splitComposablePrefix(displayBuffer)
        let initialNormalized = Romanization.normalize(composable)
        guard !initialNormalized.isEmpty else {
            return CompositionState(
                rawBuffer: displayBuffer,
                selectedCandidateIndex: 0,
                candidates: [],
                committedContext: context
            )
        }

        // Shrink from the right until the parser produces a fully legal
        // parse that doesn't begin with a standalone tall-aa vowel (ar2,
        // aw2, out2, aung2). The dropped suffix joins `literalTail`, so
        // "min:123" emits မင်း + "123" and "ar2" emits ာ + "2" — the
        // tall-aa variant remains reachable only when a descender onset is
        // actually present in the buffer.
        var normalized = initialNormalized
        var droppedTail = ""
        while !normalized.isEmpty {
            let probe = parser.parseCandidates(normalized, maxResults: 1)
            if probe.contains(where: { Self.isAcceptableParse($0) }) { break }
            droppedTail = String(normalized.removeLast()) + droppedTail
        }

        guard !normalized.isEmpty else {
            return CompositionState(
                rawBuffer: displayBuffer,
                selectedCandidateIndex: 0,
                candidates: [],
                committedContext: context
            )
        }

        let effectiveTail = droppedTail + literalTail

        let grammarParses = parser.parseCandidates(normalized, maxResults: Self.grammarCandidateBudget)
        var grammarCandidates = grammarParses.map { parse in
            RankedGrammarCandidate(
                candidate: Candidate(
                    surface: parse.output,
                    reading: parse.reading,
                    source: .grammar,
                    score: Double(parse.score)
                ),
                legalityScore: parse.legalityScore,
                aliasCost: parse.aliasCost,
                parserScore: parse.score,
                structureCost: parse.structureCost
            )
        }
        grammarCandidates.sort { lhs, rhs in
            grammarCandidateIsBetter(lhs, than: rhs)
        }
        grammarCandidates = promoteAliasAlternate(grammarCandidates)

        let previousSurface = context.last
        let aliasPrefix = Romanization.aliasReading(normalized)
        let composePrefix = Romanization.composeLookupKey(normalized)
        let lexiconCandidates = candidateStore.lookup(
            prefix: aliasPrefix,
            previousSurface: previousSurface
        )

        var grammarSurfaceIndex: [String: Int] = [:]
        for (index, candidate) in grammarCandidates.enumerated() {
            grammarSurfaceIndex[candidate.candidate.surface] = index
        }

        var uniqueLexiconCandidates: [RankedLexiconCandidate] = []
        var seenLexiconSurfaces: Set<String> = []

        for lexiconCandidate in lexiconCandidates {
            if let grammarIndex = grammarSurfaceIndex[lexiconCandidate.surface] {
                grammarCandidates[grammarIndex].candidate = Candidate(
                    surface: grammarCandidates[grammarIndex].candidate.surface,
                    reading: grammarCandidates[grammarIndex].candidate.reading,
                    source: .grammar,
                    score: grammarCandidates[grammarIndex].candidate.score + lexiconCandidate.score
                )
                continue
            }

            if seenLexiconSurfaces.insert(lexiconCandidate.surface).inserted {
                uniqueLexiconCandidates.append(
                    RankedLexiconCandidate(
                        candidate: lexiconCandidate,
                        aliasPenalty: Romanization.aliasPenaltyCount(for: lexiconCandidate.reading),
                        aliasReading: Romanization.aliasReading(lexiconCandidate.reading),
                        composeReading: Romanization.composeLookupKey(lexiconCandidate.reading)
                    )
                )
            }
        }

        uniqueLexiconCandidates.sort { lhs, rhs in
            lexiconCandidateIsBetter(lhs, than: rhs, aliasPrefix: aliasPrefix, composePrefix: composePrefix)
        }

        let primaryGrammar = Array(grammarCandidates.prefix(3))
        let remainingGrammar = Array(grammarCandidates.dropFirst(3))
        let exactAliasLexicon = uniqueLexiconCandidates.filter { $0.aliasReading == aliasPrefix }
        let exactComposeLexicon = uniqueLexiconCandidates.filter {
            $0.aliasReading != aliasPrefix && $0.composeReading == composePrefix
        }
        let prioritizedLexicon = Array(
            (exactAliasLexicon.isEmpty ? exactComposeLexicon : exactAliasLexicon)
                .prefix(2)
        )
        let prioritizedKeys = Set(prioritizedLexicon.map(lexiconCandidateKey))
        let trailingLexicon = uniqueLexiconCandidates.filter { !prioritizedKeys.contains(lexiconCandidateKey($0)) }

        var merged: [Candidate] = prioritizedLexicon.map(\.candidate)

        for grammarCandidate in primaryGrammar where merged.count < Self.candidatePageSize {
            merged.append(grammarCandidate.candidate)
        }

        for lexiconCandidate in trailingLexicon where merged.count < Self.candidatePageSize {
            merged.append(lexiconCandidate.candidate)
        }

        for grammarCandidate in remainingGrammar where merged.count < Self.candidatePageSize {
            merged.append(grammarCandidate.candidate)
        }

        merged = Self.expandAaVariants(merged)

        let mergedWithTail: [Candidate] = effectiveTail.isEmpty
            ? merged
            : merged.map { candidate in
                Candidate(
                    surface: candidate.surface + effectiveTail,
                    reading: candidate.reading,
                    source: candidate.source,
                    score: candidate.score
                )
            }

        return CompositionState(
            rawBuffer: displayBuffer,
            selectedCandidateIndex: 0,
            candidates: mergedWithTail,
            committedContext: context
        )
    }

    /// Commit the currently selected candidate.
    /// Returns the committed surface text: the selected candidate for the
    /// convertible prefix, followed by any unconverted tail from the raw
    /// buffer emitted verbatim.
    public func commit(state: CompositionState) -> String {
        guard !state.candidates.isEmpty,
              state.selectedCandidateIndex < state.candidates.count else {
            return state.rawBuffer
        }
        // Candidate surfaces already include the literal tail (appended in
        // update()), so committing the selection emits both parts together.
        return state.candidates[state.selectedCandidateIndex].surface
    }

    /// Cancel composition: return the raw buffer unchanged.
    public func cancel(state: CompositionState) -> String {
        state.rawBuffer
    }

    /// For each candidate whose surface contains ာ (U+102C) or ါ (U+102B),
    /// emit the opposite-aa variant as a sibling candidate so the user can
    /// pick between short- and tall-aa forms in the candidate window.
    private static func expandAaVariants(_ candidates: [Candidate]) -> [Candidate] {
        let shortAa: Character = "\u{102C}"
        let tallAa: Character = "\u{102B}"
        var result: [Candidate] = []
        var seen: Set<String> = []
        for candidate in candidates {
            if seen.insert(candidate.surface).inserted {
                result.append(candidate)
            }
            let swapped: String
            if candidate.surface.contains(shortAa) {
                swapped = String(candidate.surface.map { $0 == shortAa ? tallAa : $0 })
            } else if candidate.surface.contains(tallAa) {
                swapped = String(candidate.surface.map { $0 == tallAa ? shortAa : $0 })
            } else {
                continue
            }
            if seen.insert(swapped).inserted {
                result.append(Candidate(
                    surface: swapped,
                    reading: candidate.reading,
                    source: candidate.source,
                    score: candidate.score - 1
                ))
            }
        }
        return result
    }

    /// Tall-aa vowel keys that only make sense after a descender consonant.
    /// When a parse's reading *starts* with one of these, it means the parser
    /// consumed the token as a standalone dependent vowel — which the engine
    /// rejects so the trailing "2" falls out as a literal tail instead.
    private static let standaloneTallAaReadings: [String] = [
        "ar2", "aw2", "out2", "aung2",
    ]

    private static func isAcceptableParse(_ parse: SyllableParse) -> Bool {
        guard parse.legalityScore > 0 else { return false }
        for reading in standaloneTallAaReadings where parse.reading.hasPrefix(reading) {
            return false
        }
        return true
    }

    /// Split a buffer into its leading run of composing characters and the
    /// remainder (starting at the first non-composing character). The
    /// composing prefix is what gets parsed into Burmese candidates; the
    /// remainder is preserved as literal text during commit.
    private static func splitComposablePrefix(_ buffer: String) -> (composable: String, literal: String) {
        let composingSet = Romanization.composingCharacters
        if let firstNonComposing = buffer.firstIndex(where: { !composingSet.contains($0) }) {
            return (String(buffer[..<firstNonComposing]), String(buffer[firstNonComposing...]))
        }
        return (buffer, "")
    }

    private func grammarCandidateIsBetter(_ lhs: RankedGrammarCandidate, than rhs: RankedGrammarCandidate) -> Bool {
        if lhs.legalityScore != rhs.legalityScore {
            return lhs.legalityScore > rhs.legalityScore
        }
        if lhs.aliasCost != rhs.aliasCost {
            return lhs.aliasCost < rhs.aliasCost
        }
        if lhs.parserScore != rhs.parserScore {
            return lhs.parserScore > rhs.parserScore
        }
        if lhs.structureCost != rhs.structureCost {
            return lhs.structureCost < rhs.structureCost
        }
        if lhs.candidate.score != rhs.candidate.score {
            return lhs.candidate.score > rhs.candidate.score
        }
        if lhs.candidate.surface != rhs.candidate.surface {
            return lhs.candidate.surface < rhs.candidate.surface
        }
        return lhs.candidate.reading < rhs.candidate.reading
    }

    private func lexiconCandidateIsBetter(
        _ lhs: RankedLexiconCandidate,
        than rhs: RankedLexiconCandidate,
        aliasPrefix: String,
        composePrefix: String
    ) -> Bool {
        let lhsMatch = lexiconMatchQuality(lhs, aliasPrefix: aliasPrefix, composePrefix: composePrefix)
        let rhsMatch = lexiconMatchQuality(rhs, aliasPrefix: aliasPrefix, composePrefix: composePrefix)
        if lhsMatch != rhsMatch {
            return lhsMatch > rhsMatch
        }
        if lhs.aliasPenalty != rhs.aliasPenalty {
            return lhs.aliasPenalty < rhs.aliasPenalty
        }
        if lhs.candidate.score != rhs.candidate.score {
            return lhs.candidate.score > rhs.candidate.score
        }
        if lhs.candidate.surface != rhs.candidate.surface {
            return lhs.candidate.surface < rhs.candidate.surface
        }
        return lhs.candidate.reading < rhs.candidate.reading
    }

    private func lexiconMatchQuality(
        _ candidate: RankedLexiconCandidate,
        aliasPrefix: String,
        composePrefix: String
    ) -> Int {
        if candidate.aliasReading == aliasPrefix {
            return 2
        }
        if candidate.composeReading == composePrefix {
            return 1
        }
        return 0
    }

    private func lexiconCandidateKey(_ candidate: RankedLexiconCandidate) -> String {
        "\(candidate.candidate.surface)\u{0}\(candidate.candidate.reading)"
    }

    private func promoteAliasAlternate(_ candidates: [RankedGrammarCandidate]) -> [RankedGrammarCandidate] {
        guard candidates.count > 2 else { return candidates }

        let topReading = candidates[0].candidate.reading

        // Among alias candidates ranked beyond position 2, prefer the one
        // whose reading shares the longest common prefix with the top
        // candidate. This selects the terminal-syllable alternate (e.g.
        // "par2" over "lar2") which is what the user most likely wants.
        var bestIndex: Int?
        var bestPrefixLen = -1
        for i in 2..<candidates.count where candidates[i].aliasCost > 0 {
            let reading = candidates[i].candidate.reading
            let commonLen = topReading.commonPrefix(with: reading).count
            if commonLen > bestPrefixLen {
                bestPrefixLen = commonLen
                bestIndex = i
            }
        }

        guard let aliasIndex = bestIndex, aliasIndex > 2 else {
            return candidates
        }

        var reordered = candidates
        let aliasCandidate = reordered.remove(at: aliasIndex)
        reordered.insert(aliasCandidate, at: min(2, reordered.count))
        return reordered
    }
}
