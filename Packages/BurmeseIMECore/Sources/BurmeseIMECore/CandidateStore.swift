/// Protocol for looking up candidates from a backing store (lexicon, history, etc.).
public protocol CandidateStore: Sendable {
    /// Look up candidates matching a reading prefix, optionally considering previous context.
    func lookup(prefix: String, previousSurface: String?) -> [Candidate]
}

/// A no-op candidate store that returns no results.
/// Used when no lexicon is loaded.
public struct EmptyCandidateStore: CandidateStore {
    public init() {}

    public func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
        []
    }
}
