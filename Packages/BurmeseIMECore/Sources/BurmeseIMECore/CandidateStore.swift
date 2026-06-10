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

    /// TASK-084: candidates whose stored alias reading equals
    /// `aliasReading` VERBATIM — no compose-key fallback and no
    /// reading-variant expansion. This is the keystroke-faithful
    /// matched-alias set: a hit is returned exactly when the user's
    /// typed alias (separators and tone keys intact) is indexed for
    /// it, which covers builder-synthesized alias rows (`ah…`/`a…`
    /// U+1021 conventions, loanword cluster rewrites) that a
    /// canonical-reading reconstruction can never recognize. Callers
    /// that should also accept separator-stripped compose matches or
    /// the y↔r lookup rewrites keep using `lookupExact`.
    func lookupAliasExact(aliasReading: String) -> [Candidate]
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

    public func lookupAliasExact(aliasReading: String) -> [Candidate] {
        // Default: generic stores have no matched-alias channel — the
        // canonical-reading reconstruction is the best available
        // approximation (pre-TASK-084 semantics). The SQLite store
        // overrides with a direct equality probe on the alias index.
        let normalized = Romanization.aliasReading(aliasReading)
        return lookup(prefix: aliasReading, previousSurface: nil).filter {
            Romanization.aliasReading($0.reading) == normalized
        }
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

    public func lookupAliasExact(aliasReading: String) -> [Candidate] {
        []
    }
}
