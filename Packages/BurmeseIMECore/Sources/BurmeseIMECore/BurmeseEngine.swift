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
        let normalized = Romanization.normalize(buffer)
        guard !normalized.isEmpty else {
            return CompositionState()
        }

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

        return CompositionState(
            rawBuffer: normalized,
            selectedCandidateIndex: 0,
            candidates: merged,
            committedContext: context
        )
    }

    /// Commit the currently selected candidate.
    /// Returns the committed surface text.
    public func commit(state: CompositionState) -> String {
        guard !state.candidates.isEmpty,
              state.selectedCandidateIndex < state.candidates.count else {
            // No candidates: commit raw buffer as-is
            return state.rawBuffer
        }
        return state.candidates[state.selectedCandidateIndex].surface
    }

    /// Cancel composition: return the raw buffer unchanged.
    public func cancel(state: CompositionState) -> String {
        state.rawBuffer
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
