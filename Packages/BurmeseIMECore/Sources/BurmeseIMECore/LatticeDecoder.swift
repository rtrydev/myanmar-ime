import Foundation

/// Word-segmentation decoder for multi-word composition buffers.
///
/// The syllable parser's DP is syllable-accurate but not word-accurate:
/// its beam ranks by alias cost, so across multiple syllables the correct
/// surface (`အိမ်မှာအလုပ်လုပ်နေတယ်`) — which pays one alias unit per
/// variant coda — gets pruned in favour of the all-canonical sibling
/// (`အိန်မှာအလုတ်လုတ်နေတယ်`) long before the ranker can vote. The LM
/// re-rank is then a no-op because the correct surface was never
/// emitted.
///
/// This decoder closes the gap by building an arc lattice over the
/// reading and Viterbi-decoding it with the LM in-the-loop:
///
/// 1. **Word arcs** — at every position, `CandidateStore.lookupExact`
///    yields every lexicon entry whose alias / compose reading equals
///    the buffer substring starting there. The bundled lexicon already
///    carries the alias variants (`ahain2 → အိမ်`, `ahalote2 → အလုပ်`,
///    `ky2aung:pyi: → ကျောင်းပြီး`), so the lattice picks them up
///    without further data work.
/// 2. **Syllable arcs** — `SyllableParser.syllableArcs` emits every
///    legal single-syllable placement. These fill gaps the lexicon does
///    not cover (proper names, rare inputs) and stabilise the lattice
///    across buffers that have no compound entry.
/// 3. **Viterbi** — each Lattice state carries a trigram context
///    (`prev`, `last`) and a cumulative score `Σ log(arc.base) +
///    α · lm.logProb(surface | prev, last)`. The top-K states per
///    endpoint are retained (deduped by context so a single wrong-word
///    history doesn't crowd out alternatives).
///
/// The decoder is side-effect free and reusable across keystrokes. It
/// returns at most `maxOutputs` full-coverage surfaces; the engine
/// merges them into the normal candidate pool where the existing
/// comparators finish ranking.
public final class WordLatticeDecoder: @unchecked Sendable {

    private let parser: SyllableParser
    private let candidateStore: any CandidateStore
    private let languageModel: any LanguageModel
    private let tuning: RankingTuning

    /// Maximum reading length any single lexicon arc may consume. Mirrors
    /// the `MAX_LEN` in the corpus builder's curated-compound merge pass
    /// (24 chars covers the longest real compound entry with headroom).
    public static let maxLexiconArcLen = 24

    /// Top-K distinct (prev, last) contexts retained at each endpoint.
    /// Smaller = faster but more aggressive pruning; on long sentences
    /// the wanted surface often shares a (prev, last) context with the
    /// current leader, so keeping enough slots for the LM-runner-up
    /// context is what preserves it for the final bucket.
    public static let beamPerEndpoint = 12

    /// Max outputs materialised from the final endpoint. The caller
    /// picks the best of these via its own (LM + lexicon + grammar)
    /// comparator, so a handful of diverse surfaces is enough — the
    /// engine does not page through 16 lattice outputs.
    public static let maxOutputs = 12

    /// Arcs that come from the lexicon carry a substantial rank-score
    /// contribution (the lexicon rank_score is `log(freq)`-ish and
    /// ranges into the thousands, which would otherwise dominate the LM
    /// signal). We scale it down before feeding it into the composite
    /// score so α · lmLogProb and the lexicon weight remain commensurate
    /// at the trigram-score scale (roughly -5 to -15 nats per word).
    public static let lexiconRankScale = 0.002

    /// Per-alias-penalty-unit cost added to a lexicon arc's base score.
    /// Kept small (same scale as `syllableAliasCostPenalty`) so a strong
    /// trigram signal (say +4 nats in the wanted direction, multiplied
    /// by α=0.4 ≈ 1.6 nats on the composite) can still flip the alias
    /// 0 pick to the alias 1 pick when the LM is confident. The heavy
    /// `-1000 · alias_penalty` baked into the non-lattice lookup score
    /// is deliberately NOT applied here.
    public static let lexiconAliasPenaltyCost: Double = -0.5

    /// Syllable-arc score, converted from the parser's integer scale
    /// (`consumed - ruleCount - aliasCost`, roughly 0..8 for a normal
    /// syllable) into a small log-prob-shaped penalty the Viterbi can
    /// add without disturbing the LM-dominant ranking. Each alias unit
    /// costs the same amount as one lexicon alias_penalty point.
    public static let syllableAliasCostPenalty: Double = -1.0

    /// Penalty applied to syllable (non-lexicon) arcs relative to
    /// lexicon arcs. Prefers lexicon coverage; set low enough that a
    /// long lexicon-less stretch still finds a path rather than
    /// dropping out of the lattice entirely.
    public static let syllablePathCost: Double = -3.0

    /// Penalty for illegal syllable arcs. Keeps illegally-parsed
    /// fallbacks reachable (so the lattice always produces a path) but
    /// ranks them below any legal alternative.
    public static let illegalArcCost: Double = -12.0

    /// BOS sentinels for the trigram context at position 0.
    private static let bosToken = "<s>"

    public init(
        parser: SyllableParser,
        candidateStore: any CandidateStore,
        languageModel: any LanguageModel,
        tuning: RankingTuning = .default
    ) {
        self.parser = parser
        self.candidateStore = candidateStore
        self.languageModel = languageModel
        self.tuning = tuning
    }

    /// A materialised lattice output. `surface` is the concatenation of
    /// every arc's Myanmar output in traversal order; `reading` is the
    /// concatenation of the reading slices consumed. `lmLogProb` is the
    /// sum of the arc LM log-probs (useful for the engine's comparator).
    public struct LatticeCandidate: Sendable {
        public let surface: String
        public let reading: String
        /// Sum of per-arc base scores + α · LM log-probs along the path.
        public let compositeScore: Double
        /// Sum of LM log-probs only, for downstream comparator handoff.
        public let lmLogProb: Double
        /// True if every arc on the path is a lexicon arc. The engine
        /// can use this as a confidence signal (all-lexicon paths are
        /// essentially curated multi-word translations).
        public let allLexicon: Bool
        /// Number of arcs in the path.
        public let arcCount: Int
    }

    public func decode(
        reading: String,
        baseContext: [String]
    ) -> [LatticeCandidate] {
        let normalized = SyllableParser.normalizeForParser(reading)
        guard !normalized.isEmpty else { return [] }
        let chars = Array(normalized)
        let n = chars.count
        guard n > 0 else { return [] }

        // --- Build arcs ---
        var arcsByStart: [[LatticeArc]] = Array(repeating: [], count: n)

        // Lexicon arcs. Uses `lookupExactForLattice` which returns the
        // raw rank_score and the alias_penalty separately so the decoder
        // can keep its own policy (LM decides variants; alias_penalty
        // only applies a soft, LM-comparable cost).
        //
        // `lookupExactForLattice` normalises both sides through
        // `aliasReading` / `composeLookupKey`, so a query `kwyantaw`
        // can match both `ကျွန်တော်` (canonical `kwyantaw`) and
        // `ကျွန်တော့်` (canonical `kwyantaw.` in some corpora — the
        // trailing dot is a tone mark the user did NOT type here).
        // Dropping arcs whose canonical reading carries MORE tone-mark
        // diacritics (`.`, `:`) than the slice we're looking up keeps
        // the lattice from injecting unrequested tone-variant surfaces.
        for start in 0..<n {
            let maxLen = min(Self.maxLexiconArcLen, n - start)
            for len in 1...maxLen {
                let sub = String(chars[start..<(start + len)])
                let queryToneMarks = Self.toneMarkCount(sub)
                let hits = candidateStore.lookupExactForLattice(reading: sub)
                for (cand, aliasPenalty) in hits
                where !cand.surface.isEmpty
                    && Self.surfaceIsLexicallyClean(cand.surface)
                    && Self.toneMarkCount(cand.reading) <= queryToneMarks {
                    let aliasCost = Double(aliasPenalty) * Self.lexiconAliasPenaltyCost
                    arcsByStart[start].append(LatticeArc(
                        start: start,
                        end: start + len,
                        surface: cand.surface,
                        reading: cand.reading,
                        isLexicon: true,
                        aliasCost: aliasPenalty,
                        baseScore: Self.lexiconRankScale * cand.score + aliasCost
                    ))
                }
            }
        }

        // Syllable fallback arcs. These are needed so every position has
        // at least one outgoing arc (otherwise Viterbi cannot traverse
        // gaps in the lexicon).
        let syllableArcs = parser.syllableArcs(normalized)
        for arc in syllableArcs where !arc.output.isEmpty && !Self.surfaceContainsLatin(arc.output) {
            let legalPenalty = arc.isLegal ? 0.0 : Self.illegalArcCost
            let aliasPenalty = Double(arc.aliasCost) * Self.syllableAliasCostPenalty
            arcsByStart[arc.start].append(LatticeArc(
                start: arc.start,
                end: arc.end,
                surface: arc.output,
                reading: arc.reading,
                isLexicon: false,
                aliasCost: arc.aliasCost,
                baseScore: Self.syllablePathCost + aliasPenalty + legalPenalty
            ))
        }

        // Positions that no arc ends at — or starts at — are fine, as
        // long as Viterbi can still thread a path from 0 to `n` through
        // the available arcs. We don't need a per-position outgoing-arc
        // guarantee: syllables naturally span several character
        // positions (e.g. `ahain` emits a 5-wide arc from 0 to 5, so
        // positions 1..4 need no outgoing arcs of their own for the
        // lattice to reach 5 cleanly). The final `table[n]` emptiness
        // check below is the authoritative "unreachable" signal.

        // --- Viterbi ---

        // Seed the table with a BOS-context state at position 0 carrying
        // the caller's trailing committed context (so a cross-sentence
        // LM signal still applies to the first arc emitted here).
        let seedPrev: String
        let seedLast: String
        switch baseContext.count {
        case 0:
            seedPrev = Self.bosToken
            seedLast = Self.bosToken
        case 1:
            seedPrev = Self.bosToken
            seedLast = baseContext[0]
        default:
            seedPrev = baseContext[baseContext.count - 2]
            seedLast = baseContext[baseContext.count - 1]
        }
        let seedState = ViterbiState(
            cumScore: 0,
            cumLM: 0,
            contextPrev: seedPrev,
            contextLast: seedLast,
            backpointer: nil
        )

        var table: [[ViterbiState]] = Array(repeating: [], count: n + 1)
        table[0] = [seedState]

        // In-call LM memo: same (surface, context) is scored many times
        // across states that share prefix contexts.
        var lmCache: [LMKey: Double] = [:]
        let alpha = tuning.alpha

        for start in 0..<n {
            // Prune table[start] to the beam before fanning out. Dedupe
            // by (contextPrev, contextLast) so a single wrong-word
            // history doesn't hog the whole beam.
            pruneStates(&table[start])
            guard !table[start].isEmpty else { continue }

            for arc in arcsByStart[start] {
                for (parentIdx, parent) in table[start].enumerated() {
                    let ctx = [parent.contextPrev, parent.contextLast]
                    let lmKey = LMKey(surface: arc.surface, prev: parent.contextPrev, last: parent.contextLast)
                    let lmScore: Double
                    if let cached = lmCache[lmKey] {
                        lmScore = cached
                    } else {
                        lmScore = languageModel.logProb(surface: arc.surface, context: ctx)
                        lmCache[lmKey] = lmScore
                    }
                    let arcScore = arc.baseScore + alpha * lmScore
                    let newCum = parent.cumScore + arcScore
                    let newLM = parent.cumLM + lmScore

                    let newState = ViterbiState(
                        cumScore: newCum,
                        cumLM: newLM,
                        contextPrev: parent.contextLast,
                        contextLast: arc.surface,
                        backpointer: Backpointer(
                            arc: arc,
                            parentPosition: start,
                            parentIndex: parentIdx
                        )
                    )
                    table[arc.end].append(newState)
                }
            }
        }

        // Prune the final bucket and extract top-K surfaces.
        pruneStates(&table[n])
        guard !table[n].isEmpty else { return [] }

        var outputs: [LatticeCandidate] = []
        outputs.reserveCapacity(min(Self.maxOutputs, table[n].count))

        for state in table[n].prefix(Self.maxOutputs) {
            let (surface, reading, allLexicon, arcCount) = backtrace(state: state, table: table)
            outputs.append(LatticeCandidate(
                surface: surface,
                reading: reading,
                compositeScore: state.cumScore,
                lmLogProb: state.cumLM,
                allLexicon: allLexicon,
                arcCount: arcCount
            ))
        }
        return outputs
    }

    // MARK: - Viterbi helpers

    private func pruneStates(_ states: inout [ViterbiState]) {
        guard states.count > 1 else { return }
        states.sort { $0.cumScore > $1.cumScore }
        var seen: Set<String> = []
        var deduped: [ViterbiState] = []
        deduped.reserveCapacity(Self.beamPerEndpoint)
        for s in states {
            let key = s.contextPrev + "\u{1F}" + s.contextLast
            if seen.insert(key).inserted {
                deduped.append(s)
                if deduped.count >= Self.beamPerEndpoint { break }
            }
        }
        states = deduped
    }

    private func backtrace(
        state: ViterbiState,
        table: [[ViterbiState]]
    ) -> (surface: String, reading: String, allLexicon: Bool, arcCount: Int) {
        var arcs: [LatticeArc] = []
        var allLexicon = true
        var currentPos: Int? = nil
        var currentIdx: Int? = nil
        var current = state
        while let bp = current.backpointer {
            arcs.append(bp.arc)
            if !bp.arc.isLexicon { allLexicon = false }
            currentPos = bp.parentPosition
            currentIdx = bp.parentIndex
            guard let p = currentPos, let i = currentIdx else { break }
            current = table[p][i]
        }
        arcs.reverse()
        let surface = arcs.map(\.surface).joined()
        let reading = arcs.map(\.reading).joined()
        return (surface, reading, allLexicon, arcs.count)
    }

    private static func surfaceContainsLatin(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) { return true }
        }
        return false
    }

    /// Count the tone-mark diacritics (`.` creaky, `:` high) in a
    /// romanized reading. Used by the arc filter to reject lexicon
    /// entries whose canonical reading carries MORE tone marks than the
    /// user's buffer slice — these are tone-variant surfaces
    /// (`ကျွန်တော့်` vs `ကျွန်တော်`) the user did not ask for.
    private static func toneMarkCount(_ reading: String) -> Int {
        var count = 0
        for ch in reading {
            if ch == "." || ch == ":" { count += 1 }
        }
        return count
    }

    /// Reject lexicon surfaces that contain non-Myanmar scalars (ASCII
    /// punctuation, smart quotes, em dashes, ellipses, digits, etc.).
    /// These entries exist because the corpus-level tokenizer sometimes
    /// captures a trailing punctuation mark along with a word (e.g.
    /// `တယ်”`, `တယ်..`, `မှာ(၁)`) — fine for whole-buffer lookup where
    /// the engine strips punctuation, lethal in the lattice where every
    /// such arc permanently taints the concatenated surface. Keep
    /// U+200C / U+200D since some legitimate compositions carry ZWNJ.
    private static func surfaceIsLexicallyClean(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v == 0x200C || v == 0x200D { continue }
            // Myanmar (U+1000..U+109F) + Myanmar Extended (U+AA60..U+AA7F,
            // U+A9E0..U+A9FF) cover everything the lexicon should emit.
            let inMyanmar = (0x1000...0x109F).contains(v)
                || (0xAA60...0xAA7F).contains(v)
                || (0xA9E0...0xA9FF).contains(v)
            if !inMyanmar { return false }
        }
        return true
    }
}

// MARK: - Internal types

struct LatticeArc: Sendable {
    let start: Int
    let end: Int
    let surface: String
    let reading: String
    let isLexicon: Bool
    let aliasCost: Int
    let baseScore: Double
}

private struct ViterbiState {
    let cumScore: Double
    let cumLM: Double
    let contextPrev: String
    let contextLast: String
    let backpointer: Backpointer?
}

private struct Backpointer {
    let arc: LatticeArc
    let parentPosition: Int
    let parentIndex: Int
}

private struct LMKey: Hashable {
    let surface: String
    let prev: String
    let last: String
}
