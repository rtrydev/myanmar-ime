import Foundation

/// The main composition engine for the Burmese IME.
///
/// Manages the composition buffer, generates candidates from grammar parsing
/// and lexicon lookup, and handles commit/cancel operations.
///
/// Ranking order: grammar legality > alias cost > parser score > lexicon frequency.
public final class BurmeseEngine: @unchecked Sendable {

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

    /// Sliding-window threshold for the full N-best parse. When the
    /// normalized buffer exceeds this, everything before the trailing
    /// window is rendered once via a cheap single-best parse and cached;
    /// only the tail is re-parsed on each keystroke. The window covers
    /// `maxOnsetLen + maxVowelLen` plus a safety margin so no rule can
    /// span the prefix/tail boundary.
    private let compositionWindowSize: Int

    /// Single-slot cache for the frozen prefix. Protected by `cacheLock`.
    private struct FrozenPrefixCache {
        var input: String
        var output: String
        var reading: String
    }
    private var prefixCache: FrozenPrefixCache?
    private let cacheLock = NSLock()

    /// Page size for candidate display.
    public static let candidatePageSize = 5

    public init(candidateStore: any CandidateStore = EmptyCandidateStore()) {
        let parser = SyllableParser()
        self.parser = parser
        self.candidateStore = candidateStore
        self.compositionWindowSize = parser.maxOnsetLen + parser.maxVowelLen + 4
    }

    private func renderFrozenPrefix(_ prefix: String) -> (output: String, reading: String) {
        cacheLock.lock()
        if let cached = prefixCache, cached.input == prefix {
            cacheLock.unlock()
            return (cached.output, cached.reading)
        }
        cacheLock.unlock()

        let parsed = parser.parseCandidates(prefix, maxResults: 1).first
        let output = parsed?.output ?? prefix
        let reading = parsed?.reading ?? prefix

        cacheLock.lock()
        prefixCache = FrozenPrefixCache(input: prefix, output: output, reading: reading)
        cacheLock.unlock()
        return (output, reading)
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
        //
        // For long buffers only the trailing window needs probing: the
        // frozen prefix cannot contribute a standalone tall-aa prefix to
        // the overall parse, and shrinking only ever trims tail chars.
        var normalized = initialNormalized
        var droppedTail = ""
        while !normalized.isEmpty {
            let probeInput: String
            if normalized.count > compositionWindowSize {
                probeInput = String(normalized.suffix(compositionWindowSize))
            } else {
                probeInput = normalized
            }
            let probe = parser.parseCandidates(probeInput, maxResults: 1)
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

        // Split off the frozen prefix if the buffer is longer than the
        // sliding window. The prefix is rendered once via a cached
        // single-best parse; only the active tail gets the expensive
        // N-best treatment each keystroke.
        let windowed: (prefixOutput: String, prefixReading: String, tail: String)?
        let parseInput: String
        if normalized.count > compositionWindowSize {
            let splitIndex = normalized.index(normalized.endIndex, offsetBy: -compositionWindowSize)
            let frozenPrefix = String(normalized[..<splitIndex])
            let activeTail = String(normalized[splitIndex...])
            let rendered = renderFrozenPrefix(frozenPrefix)
            windowed = (rendered.output, rendered.reading, activeTail)
            parseInput = activeTail
        } else {
            windowed = nil
            parseInput = normalized
        }

        let grammarParses = parser.parseCandidates(parseInput, maxResults: Self.grammarCandidateBudget)
        var grammarCandidates = grammarParses.map { parse in
            let surface = windowed.map { $0.prefixOutput + parse.output } ?? parse.output
            let reading = windowed.map { $0.prefixReading + parse.reading } ?? parse.reading
            return RankedGrammarCandidate(
                candidate: Candidate(
                    surface: surface,
                    reading: reading,
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

        // Skip lexicon lookup entirely when a frozen prefix is in play:
        // multi-word lexicon hits past the window boundary aren't useful,
        // and the prefix lookup would be dominated by the cached output.
        let previousSurface = context.last
        let aliasPrefix = Romanization.aliasReading(normalized)
        let composePrefix = Romanization.composeLookupKey(normalized)
        let lexiconCandidates: [Candidate] = windowed == nil
            ? candidateStore.lookup(prefix: aliasPrefix, previousSurface: previousSurface)
            : []

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

    /// Auto-correct the aa sign in each candidate surface to match the
    /// descender requirement of its preceding consonant: descender onsets
    /// (kha, ga, nga, da, pa, wa) take tall ါ (U+102B); others take short
    /// ာ (U+102C). Previously both shapes were emitted as siblings, which
    /// roughly doubled the candidate panel with orthographically wrong
    /// forms. Collapsing to the single correct shape removes that noise.
    private static func expandAaVariants(_ candidates: [Candidate]) -> [Candidate] {
        var result: [Candidate] = []
        var seen: Set<String> = []
        for candidate in candidates {
            let corrected = correctAaShape(candidate.surface)
            let surface = corrected == candidate.surface ? candidate.surface : corrected
            guard seen.insert(surface).inserted else { continue }
            if surface == candidate.surface {
                result.append(candidate)
            } else {
                result.append(Candidate(
                    surface: surface,
                    reading: candidate.reading,
                    source: candidate.source,
                    score: candidate.score
                ))
            }
        }
        return result
    }

    /// Walk a surface string and rewrite each ာ/ါ to the shape appropriate
    /// for its preceding consonant. Medials and signs between the
    /// consonant and the aa sign are skipped over.
    private static func correctAaShape(_ text: String) -> String {
        let shortAa: Character = "\u{102C}"
        let tallAa: Character = "\u{102B}"
        var chars = Array(text)
        for i in 0..<chars.count where chars[i] == shortAa || chars[i] == tallAa {
            var j = i - 1
            while j >= 0 {
                let prev = chars[j]
                if let scalar = prev.unicodeScalars.first, Myanmar.isConsonant(scalar) {
                    let wantsTall = Grammar.requiresTallAa.contains(prev)
                    chars[i] = wantsTall ? tallAa : shortAa
                    break
                }
                j -= 1
            }
        }
        return String(chars)
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
