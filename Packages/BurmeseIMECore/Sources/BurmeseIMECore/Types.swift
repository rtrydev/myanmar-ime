/// Input mode for the IME.
public enum InputMode: Sendable {
    case compose
    case roman
}

/// Source of a candidate suggestion.
public enum CandidateSource: Sendable {
    case grammar
    case lexicon
    case history
}

/// A single candidate displayed to the user.
public struct Candidate: Sendable, Equatable {
    public let surface: String
    public let reading: String
    public let source: CandidateSource
    public let score: Double

    public init(surface: String, reading: String, source: CandidateSource, score: Double) {
        self.surface = surface
        self.reading = reading
        self.source = source
        self.score = score
    }
}

/// The composition state at any point during input.
public struct CompositionState: Sendable {
    public var rawBuffer: String
    public var selectedCandidateIndex: Int
    public var candidates: [Candidate]
    public var committedContext: [String]

    public init(
        rawBuffer: String = "",
        selectedCandidateIndex: Int = 0,
        candidates: [Candidate] = [],
        committedContext: [String] = []
    ) {
        self.rawBuffer = rawBuffer
        self.selectedCandidateIndex = selectedCandidateIndex
        self.candidates = candidates
        self.committedContext = committedContext
    }

    /// Whether there is an active composition.
    public var isActive: Bool { !rawBuffer.isEmpty }
}

/// Result of parsing a single syllable from the roman buffer.
public struct SyllableParse: Sendable, Equatable {
    public let output: String
    public let reading: String
    public let aliasCost: Int
    public let legalityScore: Int
    public let score: Int
    public let structureCost: Int

    public init(
        output: String,
        reading: String,
        aliasCost: Int = 0,
        legalityScore: Int = 0,
        score: Int = 0,
        structureCost: Int = 0
    ) {
        self.output = output
        self.reading = reading
        self.aliasCost = aliasCost
        self.legalityScore = legalityScore
        self.score = score
        self.structureCost = structureCost
    }
}
