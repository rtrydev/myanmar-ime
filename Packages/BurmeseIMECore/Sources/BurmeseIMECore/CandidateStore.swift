/// Protocol for looking up candidates from a backing store (lexicon, history, etc.).
public protocol CandidateStore: Sendable {
    /// Look up candidates matching the compose buffer prefix, optionally considering previous context.
    /// Implementations may ignore numeric markers and optional syllable separators.
    func lookup(prefix: String, previousSurface: String?) -> [Candidate]

    /// Look up candidates whose alias / compose reading exactly equals the
    /// supplied reading. Used by the lattice decoder to enumerate word-arcs
    /// that consume exactly `reading.count` chars of the composition buffer.
    /// Default implementation filters the prefix lookup — real stores should
    /// override with an indexed equality query for O(log n) access.
    func lookupExact(reading: String, previousSurface: String?) -> [Candidate]

    /// Lattice-oriented variant of `lookupExact`. Each match returns the
    /// candidate's raw rank_score (as emitted by the corpus builder,
    /// roughly `log(frequency)`) alongside its `aliasPenalty` as a
    /// separate int. The lattice decoder does *not* subtract the alias
    /// penalty from the rank: it lets the LM vote on variants via
    /// context, and baking `-1000 × alias_penalty` into the arc score
    /// overwhelms a trigram signal that is at most ~15 nats wide.
    /// Single-word / short-buffer callers should keep using
    /// `lookupExact` — its pre-penalised score is what the panel
    /// ranker already expects.
    func lookupExactForLattice(reading: String) -> [(candidate: Candidate, aliasPenalty: Int)]
}

extension CandidateStore {
    public func lookupExact(reading: String, previousSurface: String?) -> [Candidate] {
        let normalized = Romanization.aliasReading(reading)
        return lookup(prefix: reading, previousSurface: previousSurface).filter {
            Romanization.aliasReading($0.reading) == normalized
        }
    }

    public func lookupExactForLattice(reading: String) -> [(candidate: Candidate, aliasPenalty: Int)] {
        // Default: alias-penalty info is unavailable in generic stores —
        // fall back to treating every hit as alias_penalty 0. Real stores
        // (SQLite) override to read the column.
        lookupExact(reading: reading, previousSurface: nil).map { ($0, 0) }
    }
}

/// A no-op candidate store that returns no results.
/// Used when no lexicon is loaded.
public struct EmptyCandidateStore: CandidateStore {
    public init() {}

    public func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
        []
    }

    public func lookupExact(reading: String, previousSurface: String?) -> [Candidate] {
        []
    }

    public func lookupExactForLattice(reading: String) -> [(candidate: Candidate, aliasPenalty: Int)] {
        []
    }
}
