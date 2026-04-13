/// The main composition engine for the Burmese IME.
///
/// Manages the composition buffer, generates candidates from grammar parsing
/// and lexicon lookup, and handles commit/cancel operations.
///
/// Ranking order: grammar validity > canonical alias cost > lexicon frequency > user history.
public final class BurmeseEngine: Sendable {

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

        var candidates: [Candidate] = []

        // 1. Grammar-based candidates from the parser
        let parses = parser.parse(normalized)
        for parse in parses {
            candidates.append(Candidate(
                surface: parse.output,
                reading: parse.reading,
                source: .grammar,
                score: Double(parse.legalityScore) * 1000.0
                    + Double(normalized.count) * 10.0
                    - Double(parse.aliasCost) * 5.0
            ))
        }

        // 2. Lexicon candidates
        let previousSurface = context.last
        let lexiconCandidates = candidateStore.lookup(
            prefix: normalized, previousSurface: previousSurface
        )
        for lc in lexiconCandidates {
            // Avoid duplicates with grammar candidates
            if !candidates.contains(where: { $0.surface == lc.surface }) {
                candidates.append(lc)
            }
        }

        // 3. Sort by score descending
        candidates.sort { $0.score > $1.score }

        // 4. Limit to page size
        if candidates.count > Self.candidatePageSize {
            candidates = Array(candidates.prefix(Self.candidatePageSize))
        }

        return CompositionState(
            rawBuffer: normalized,
            selectedCandidateIndex: 0,
            candidates: candidates,
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
}
