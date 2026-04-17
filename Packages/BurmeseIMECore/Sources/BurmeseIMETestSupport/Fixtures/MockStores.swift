import Foundation
import BurmeseIMECore

/// A `CandidateStore` backed by a `[prefix: [Candidate]]` map. Handy for
/// wiring fixture data in engine-level tests without spinning up SQLite.
public struct FixedCandidateStore: CandidateStore {
    public var byPrefix: [String: [Candidate]]

    public init(byPrefix: [String: [Candidate]] = [:]) {
        self.byPrefix = byPrefix
    }

    public func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
        byPrefix[prefix] ?? []
    }
}

/// A `CandidateStore` that returns the same list of candidates for every
/// prefix — useful when the test only cares about ranking within the lexicon
/// bucket, not lookup matching.
public struct AnyPrefixCandidateStore: CandidateStore {
    public var results: [Candidate]

    public init(results: [Candidate]) {
        self.results = results
    }

    public func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
        results
    }
}

/// A `LanguageModel` whose surface log-probs come from a table, with
/// `fallback` for any missing entry.
public struct FixedLanguageModel: LanguageModel {
    public var scores: [String: Double]
    public var fallback: Double
    public var vocabulary: Bool

    public init(scores: [String: Double] = [:], fallback: Double = -10.0, hasVocabulary: Bool = true) {
        self.scores = scores
        self.fallback = fallback
        self.vocabulary = hasVocabulary
    }

    public func logProb(surface: String, context: [String]) -> Double {
        scores[surface] ?? fallback
    }

    public var hasVocabulary: Bool { vocabulary }
}
