import Foundation

/// A scorer that assigns a log-probability to a word given prior context.
///
/// Contexts are ordered oldest-to-newest: `context[0]` is the word farthest
/// back, `context.last` is the word immediately preceding the scored word.
/// Implementations are free to use only as much context as their order
/// supports (a trigram LM uses the last two, a bigram the last one).
///
/// The hot path is one `logProb` call per candidate per keystroke, so
/// implementations should be allocation-free and resolve surfaces to
/// internal ids up front when they can.
public protocol LanguageModel: Sendable {
    /// Log-probability of `surface` given `context`, using whatever
    /// backoff / smoothing the implementation provides. Must return a
    /// finite value — missing words should route through `<unk>` and
    /// missing contexts should back off.
    func logProb(surface: String, context: [String]) -> Double

    /// Score a candidate surface that may span multiple vocab words by
    /// decomposing it into known-word tokens and summing their
    /// contextual log-probs. Default implementation treats the surface
    /// as a single token and falls back to `logProb(surface:context:)`;
    /// a real LM should override to greedy-longest-match against its
    /// vocabulary so multi-word candidates like "ကျွန်တော်" don't all
    /// collapse to the same `<unk>` score.
    func scoreSurface(_ surface: String, context: [String]) -> Double

    /// Whether the LM has a word-level vocabulary that `scoreSurface`
    /// can meaningfully decompose against. `NullLanguageModel` returns
    /// false; the real trigram LM returns true. Callers that want to
    /// detect "no real LM loaded" can branch on this.
    var hasVocabulary: Bool { get }

    /// The unigram log-prob the LM assigns to a completely-unseen
    /// surface (routes through `<unk>`). Callers comparing candidate LM
    /// scores can use this to detect surfaces whose score equals the
    /// `<unk>` floor — a signal that the surface is effectively OOV even
    /// when `wordId` returns a valid vocab id (Kneser-Ney smoothing may
    /// assign tail words the same unigram prob as `<unk>`). Default
    /// returns `-Double.infinity` so OOV checks against this floor never
    /// fire on LMs that don't override.
    var unknownLogProb: Double { get }

    /// Whether `surface` is an exact vocabulary entry. This is separate from
    /// `scoreSurface`, which may decompose a multi-word surface into known
    /// pieces even when the full string is not a single LM token.
    func containsSurface(_ surface: String) -> Bool
}

extension LanguageModel {
    public func scoreSurface(_ surface: String, context: [String]) -> Double {
        logProb(surface: surface, context: context)
    }

    public var hasVocabulary: Bool { false }

    public var unknownLogProb: Double { -.infinity }

    public func containsSurface(_ surface: String) -> Bool { false }
}

/// A no-op language model: returns a small constant log-prob for every
/// query. Used when no real LM is loaded (tests, early bring-up).
/// Analogous to `EmptyCandidateStore`.
public struct NullLanguageModel: LanguageModel {
    private let constantLogProb: Double

    public init(constantLogProb: Double = -10.0) {
        self.constantLogProb = constantLogProb
    }

    public func logProb(surface: String, context: [String]) -> Double {
        constantLogProb
    }
}
