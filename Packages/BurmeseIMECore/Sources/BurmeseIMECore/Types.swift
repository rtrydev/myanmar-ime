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
    public let syllableCount: Int
    public let rarityPenalty: Int
    /// Cumulative arc-boundary map for this parse's segmentation.
    /// `arcBoundaries[i] = (charEnd, scalarOffset)` says: after the i-th
    /// non-skip arc consumed `chars[0..<charEnd]` of the normalized
    /// reading, the parse's `output` had emitted `scalarOffset` scalars.
    /// `arcBoundaries[0]` is always `(0, 0)`. The terminal entry covers
    /// the entire reading. Used by mid-buffer-digit splicing to map a
    /// digit's input-character offset to the matching scalar splice
    /// offset in `output` (TASK-002). Empty for parses constructed
    /// outside the parser's materializer (e.g. engine fallbacks).
    public let arcBoundaries: [ArcBoundary]

    public struct ArcBoundary: Sendable, Equatable {
        public let charEnd: Int
        public let scalarOffset: Int
        public init(charEnd: Int, scalarOffset: Int) {
            self.charEnd = charEnd
            self.scalarOffset = scalarOffset
        }
    }

    public init(
        output: String,
        reading: String,
        aliasCost: Int = 0,
        legalityScore: Int = 0,
        score: Int = 0,
        structureCost: Int = 0,
        syllableCount: Int = 0,
        rarityPenalty: Int = 0,
        arcBoundaries: [ArcBoundary] = []
    ) {
        self.output = output
        self.reading = reading
        self.aliasCost = aliasCost
        self.legalityScore = legalityScore
        self.score = score
        self.structureCost = structureCost
        self.syllableCount = syllableCount
        self.rarityPenalty = rarityPenalty
        self.arcBoundaries = arcBoundaries
    }
}
