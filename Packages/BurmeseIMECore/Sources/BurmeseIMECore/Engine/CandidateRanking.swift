import Foundation

extension BurmeseEngine {

    internal struct RankedGrammarCandidate {
        var candidate: Candidate
        let legalityScore: Int
        let aliasCost: Int
        let parserScore: Int
        let structureCost: Int
        let syllableCount: Int
        let rarityPenalty: Int
        var lmLogProb: Double
        var absorbedMissingFromLM: Bool
    }

    internal struct RankedLexiconCandidate {
        let candidate: Candidate
        let aliasPenalty: Int
        let aliasReading: String
        let composeReading: String
        let lmLogProb: Double
    }

    /// Drop candidates whose LM log-prob trails the best by more than
    /// `lmPruneMargin`. Preserves input order (callers pre-sort), and always
    /// keeps the top candidate so the panel never ends up empty.
    internal func pruneByLmMargin<T>(
        _ candidates: [T],
        keyPath: KeyPath<T, Double>
    ) -> [T] {
        guard candidates.count > 1 else { return candidates }
        var maxLm = -Double.infinity
        for c in candidates {
            let lp = c[keyPath: keyPath]
            if lp > maxLm { maxLm = lp }
        }
        guard maxLm.isFinite else { return candidates }
        let floor = maxLm - lmPruneMargin
        let filtered = candidates.filter { $0[keyPath: keyPath] >= floor }
        return filtered.isEmpty ? [candidates[0]] : filtered
    }

    /// Grammar candidates that absorbed a lexicon row are attested surfaces,
    /// so keep them in the panel even if a stale or pruned LM charges a low
    /// OOV-like score. The comparator still decides their final order.
    internal func pruneGrammarByLmMargin(
        _ candidates: [RankedGrammarCandidate]
    ) -> [RankedGrammarCandidate] {
        guard candidates.count > 1 else { return candidates }
        var maxLm = -Double.infinity
        for candidate in candidates {
            if candidate.lmLogProb > maxLm { maxLm = candidate.lmLogProb }
        }
        guard maxLm.isFinite else { return candidates }
        let floor = maxLm - lmPruneMargin
        let filtered = candidates.filter {
            $0.lmLogProb >= floor || $0.candidate.score > Double($0.parserScore)
        }
        return filtered.isEmpty ? [candidates[0]] : filtered
    }

    /// Composite ranking score `log(rank_score) + α · lmLogProb`. Used by
    /// both comparators in place of the earlier 1.0-nat threshold gate on
    /// LM log-prob. Keeps frequency and LM linear without cliff effects;
    /// α is sourced from `RankingTuning`. `rank_score` is clamped to ≥ 1
    /// before the log so zero / penalty-driven-negative scores degrade
    /// gracefully to a flat frequency floor rather than exploding.
    internal func compositeScore(rankScore: Double, lmLogProb: Double) -> Double {
        log(max(rankScore, 1.0)) + tuning.alpha * lmLogProb
    }

    internal func grammarCandidateIsBetter(_ lhs: RankedGrammarCandidate, than rhs: RankedGrammarCandidate) -> Bool {
        // Legality is a hard filter — orthographically legal syllables
        // always beat illegal ones.
        let lhsLegal = lhs.legalityScore > 0
        let rhsLegal = rhs.legalityScore > 0
        if lhsLegal != rhsLegal {
            return lhsLegal
        }
        // Character-class rarity sits above `syllableCount` so a longer
        // common-consonant parse outranks a shorter retroflex one when
        // the user did not type the "2" disambiguator. Rare parses stay
        // in the panel — they just aren't top-1.
        if lhs.rarityPenalty != rhs.rarityPenalty {
            return lhs.rarityPenalty < rhs.rarityPenalty
        }
        // Prefer fewer syllables before legality magnitude: when the
        // parser's min+1 widening admits extended parses, the per-syllable
        // sum in `legalityScore` mechanically favors the longer parse
        // even though the canonical (min-tier) parse is what the user
        // expects as top-1. Anchor stability depends on this.
        if lhs.syllableCount != rhs.syllableCount {
            return lhs.syllableCount < rhs.syllableCount
        }
        if lhs.legalityScore != rhs.legalityScore {
            return lhs.legalityScore > rhs.legalityScore
        }
        // Coda-only tiebreaker (task 10): when two surfaces differ by a
        // single scalar in the coda set {U+103A asat, U+1036 anusvara,
        // U+100A nnya, U+1037 dot-below, U+1009 nya}, the choice is a
        // frequency call — the LM log-prob decides directly even if the
        // composite score below would flip on lexicon absorption. Guards
        // the `စဉ်` vs `စည်` / `န်း` vs `မ်း` / `ဖတ်` vs `ဖတ` picks
        // where the DP / absorption and the LM disagree by a narrow
        // margin.
        if Self.isCodaOnlySingleScalarDifference(
            lhs.candidate.surface,
            rhs.candidate.surface
        ) {
            if lhs.lmLogProb != rhs.lmLogProb {
                return lhs.lmLogProb > rhs.lmLogProb
            }
        }
        // LM dominance: when BOTH candidates have real (non-OOV) LM
        // scores AND the log-prob gap exceeds `lmDominanceThreshold`,
        // trust LM and skip the composite score check. This prevents a
        // lexicon-absorbed surface from overriding a strong LM preference
        // for a sibling with no lexicon entry — e.g. buffer `khyin` has
        // lexicon entry `ခြင်` (ya-yit, score ~622) but not `ချင်`
        // (ya-pin); LM prefers ya-pin by 1.75 nat, so the ya-pin sibling
        // must win despite the +622 boost absorb-before-sort gives
        // ya-yit's composite. For tight LM gaps (< 1 nat, e.g. `an`'s
        // `အံ` vs `မ်` at 0.55 nat apart) the composite still decides,
        // so lexicon absorption can tip the balance toward the
        // lexicon-anchored surface.
        //
        // The OOV guard matters for buffers like `an.` where the rare
        // coda `န့်` has the same unigram log-prob as `<unk>` (it's in
        // vocab but at the tail of the distribution) while `အံ့` has a
        // genuine lower unigram score. Treating the OOV-floor score as
        // "strong LM signal" would wrongly demote the real word.
        let unkFloor = languageModel.unknownLogProb
        let oovEpsilon = 0.01
        let lhsIsOOV = unkFloor.isFinite
            && abs(lhs.lmLogProb - unkFloor) < oovEpsilon
        let rhsIsOOV = unkFloor.isFinite
            && abs(rhs.lmLogProb - unkFloor) < oovEpsilon
        // In-vocab beats OOV when both parses are otherwise equivalent
        // on aliasCost (task 03b). The LM `<unk>` floor (≈ −7.16)
        // sits above the real log-prob of many rare-but-real Burmese
        // words, so an OOV parser walk would otherwise win the
        // composite over the correct in-vocab sibling that the LM
        // does know. Gating on equal `aliasCost` keeps the rule
        // targeted at variant pairs (e.g. ya-yit vs ya-pin, both at
        // alias=1) and avoids demoting an alias=0 primary parse that
        // happens to be OOV in favour of a noisier alias>0 sibling
        // (e.g. `ကြီ` for `kyi`, where the alias=0 primary must stay
        // reachable in the panel even if `ကြည်` is in-vocab).
        // When either side carries lexicon absorption
        // (`candidate.score > parserScore` means a lexicon row bumped the
        // grammar candidate's rank_score), the composite comparison
        // below already accounts for that contribution — the OOV guard
        // must not fire, or it would override a legitimately-promoted
        // in-vocab orphan like `အံး` (buffer `an:`) that wins on
        // absorption despite sitting at the OOV floor (task 09).
        let lhsAbsorbed = lhs.candidate.score > Double(lhs.parserScore)
        let rhsAbsorbed = rhs.candidate.score > Double(rhs.parserScore)
        if lhsIsOOV != rhsIsOOV
            && lhs.aliasCost == rhs.aliasCost
            && !lhsAbsorbed
            && !rhsAbsorbed {
            return !lhsIsOOV
        }
        let lmGap = lhs.lmLogProb - rhs.lmLogProb
        if !lhs.absorbedMissingFromLM && !rhs.absorbedMissingFromLM
            && !lhsIsOOV && !rhsIsOOV
            && abs(lmGap) > Self.lmDominanceThreshold {
            return lmGap > 0
        }
        // Composite score combines rank_score and LM log-prob. For
        // grammar candidates, `candidate.score` = raw parser DP score +
        // any absorbed lexicon frequency (see the merge loop in `update`),
        // so it captures both "how well-formed the parse is" and "how
        // frequent this surface is in the lexicon" — the `rank_score`
        // analog called out in migration plan §17. Replacing the 1.0-nat
        // threshold gate lets the two signals trade off linearly: a
        // candidate with a lexicon-anchored high score can still beat one
        // with slightly better LM when the LM gap is narrow.
        let lhsComposite = compositeScore(rankScore: lhs.candidate.score, lmLogProb: lhs.lmLogProb)
        let rhsComposite = compositeScore(rankScore: rhs.candidate.score, lmLogProb: rhs.lmLogProb)
        if lhsComposite != rhsComposite {
            return lhsComposite > rhsComposite
        }
        // Alias / structural costs are the final tiebreakers (after the
        // composite, per migration plan §17b — this is what
        // `absorbedExactAliasTop` was compensating for).
        if lhs.aliasCost != rhs.aliasCost {
            return lhs.aliasCost < rhs.aliasCost
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

    internal func lexiconCandidateIsBetter(
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
        // Composite score: `log(rank_score) + α · lmLogProb`. The stored
        // `candidate.score` has alias + separator penalties already
        // subtracted (see SQLiteCandidateStore); undoing the aliasPenalty
        // recovers the core frequency-derived rank_score the plan calls
        // out. Separator penalty is left folded in — compose-path entries
        // are legitimately ranked lower anyway.
        let lhsRank = lhs.candidate.score + Double(lhs.aliasPenalty) * 1000.0
        let rhsRank = rhs.candidate.score + Double(rhs.aliasPenalty) * 1000.0
        let lhsComposite = compositeScore(rankScore: lhsRank, lmLogProb: lhs.lmLogProb)
        let rhsComposite = compositeScore(rankScore: rhsRank, lmLogProb: rhs.lmLogProb)
        if lhsComposite != rhsComposite {
            return lhsComposite > rhsComposite
        }
        // Alias penalty is the final structural tiebreaker after the
        // composite — not a primary signal that can flip the winner.
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

    internal func lexiconMatchQuality(
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

    internal func lexiconCandidateKey(_ candidate: RankedLexiconCandidate) -> String {
        "\(candidate.candidate.surface)\u{0}\(candidate.candidate.reading)"
    }

    /// True when `lhs` and `rhs` differ by exactly one scalar from the
    /// coda-mark set {U+103A asat, U+1036 anusvara, U+100A nnya,
    /// U+1037 dot-below, U+1009 nya}, with everything else equal —
    /// including same length, or off-by-one with the differing position
    /// being a coda-mark insertion. Used by `grammarCandidateIsBetter`
    /// as a targeted LM tiebreaker for `စဉ်` vs `စည်` / `န်း` vs `မ်း`
    /// / `ဖတ်` vs `ဖတ` style pairs (task 10).
    internal static let codaMarkScalars: Set<UInt32> = [
        0x103A, 0x1036, 0x100A, 0x1037, 0x1009,
    ]

    /// Approximate count of Burmese syllables in a surface string.
    /// Counts base consonants (U+1000–U+1021) and independent vowels
    /// (U+1023–U+1027, U+1029–U+102A) as syllable anchors, excluding
    /// positions where the base is attached to another syllable
    /// rather than starting one:
    ///
    /// - **Virama subscript**: a base immediately preceded by U+1039
    ///   (virama) is the lower half of a stack (`က + ္ + ဿ`) or the
    ///   subscript consonant after a kinzi's asat+virama — attaches
    ///   to the preceding syllable, not a new one.
    /// - **Coda consonant**: a base immediately followed by U+103A
    ///   (asat) is a syllable-final consonant (`မ` in `မင်`, `န` in
    ///   `ကျွန်`). Counting it would turn `ကျွန်တော်ကထမင်` into 7
    ///   syllables instead of 5 and let a spurious parser split like
    ///   `ကထမီန` (6 syllables under that same rule — the final `န`
    ///   is not coda-marked there) win the `syllableCount < rhs`
    ///   tiebreaker in `grammarCandidateIsBetter`.
    ///
    /// Must stay in lockstep with the parser's own `syllableCount`:
    /// the DP counts one syllable per emitted onset / onset+vowel
    /// transition, not per Unicode scalar, so lattice candidates
    /// assigned an over-count here would systematically lose ties.
    internal static func approximateSyllableCount(_ surface: String) -> Int {
        var count = 0
        let scalars = Array(surface.unicodeScalars)
        var previousWasVirama = false
        for (i, scalar) in scalars.enumerated() {
            let v = scalar.value
            let isBase = (0x1000...0x1021).contains(v)
                || (0x1023...0x1027).contains(v)
                || (0x1029...0x102A).contains(v)
            if isBase && !previousWasVirama {
                let followedByAsat = (i + 1 < scalars.count)
                    && scalars[i + 1].value == 0x103A
                if !followedByAsat {
                    count += 1
                }
            }
            previousWasVirama = (v == 0x1039)
        }
        return count
    }

    internal static func isCodaOnlySingleScalarDifference(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.unicodeScalars)
        let b = Array(rhs.unicodeScalars)
        if abs(a.count - b.count) > 1 { return false }
        if a.count == b.count {
            // Substitution: exactly one differing index, and at least
            // one of the two differing scalars is a coda mark.
            var diffIdx = -1
            for i in 0..<a.count where a[i] != b[i] {
                if diffIdx >= 0 { return false }
                diffIdx = i
            }
            guard diffIdx >= 0 else { return false }
            let va = a[diffIdx].value, vb = b[diffIdx].value
            return codaMarkScalars.contains(va) || codaMarkScalars.contains(vb)
        }
        // Insertion / deletion: one side has one extra scalar that is a
        // coda mark, and the rest aligns.
        let longer = a.count > b.count ? a : b
        let shorter = a.count > b.count ? b : a
        var i = 0, j = 0, extra = 0
        while i < longer.count && j < shorter.count {
            if longer[i] == shorter[j] {
                i += 1; j += 1
            } else {
                if extra > 0 { return false }
                if !codaMarkScalars.contains(longer[i].value) { return false }
                i += 1
                extra += 1
            }
        }
        if i < longer.count {
            // Trailing extra — must be a coda mark and the only extra.
            return extra == 0 && i == longer.count - 1
                && codaMarkScalars.contains(longer[i].value)
        }
        return true
    }

    /// True when `reading` contains a ya-pin medial marker — a `y2`
    /// digraph anchored by a preceding consonant letter (e.g. `ky2`,
    /// `khy2`, `gy2`, `hsy2`). Mirrors the classifier in
    /// `LexiconBuilder/main.swift` so engine-side and SQLite-side
    /// ya-pin detection stay in lockstep.
    internal static func isYapinReading(_ reading: String) -> Bool {
        guard reading.contains("y2") else { return false }
        let chars = Array(reading)
        guard chars.count >= 3 else { return false }
        for i in 1..<(chars.count - 1) where chars[i] == "y" && chars[i + 1] == "2" {
            let prev = chars[i - 1]
            if prev.isLetter && prev != "y" {
                return true
            }
        }
        return false
    }

    /// Bare buffers whose Burmese typographic convention resolves to
    /// ya-pin despite the lexicon-absorbed ya-yit sibling winning the
    /// default comparator composite (task 07). The set is narrow by
    /// design: siblings differ per final vowel (`kyay` → ya-pin but
    /// `kya` → ya-yit, `khyin` → ya-pin but `kyaw:` → ya-yit) so a
    /// consonant-only rule would over-promote. Grows only when a new
    /// `task13_yapin_*` top-1 target lands.
    internal static let yapinPrimaryBareBuffers: Set<String> = [
        "kywan", "kyay", "kyi", "khyay", "khyin",
    ]

    /// Typing-intent promotion for bare ya-pin readings: when the
    /// user buffer is exactly one of the known-primary ya-pin bare
    /// readings, move the lowest-aliasCost ya-pin sibling whose
    /// digit-stripped reading matches to rank 0 (task 07).
    ///
    /// For short readings like `kyay` / `kyi`, the default comparator
    /// picks ya-yit on composite score because the ya-yit sibling is
    /// often lexicon-absorbed while the ya-pin is not — that +frequency
    /// offset beats the ya-pin's narrow LM advantage. But the bare
    /// digit-less buffer is itself the canonical user signal for ya-pin
    /// in Burmese typing convention, so we flip the pick when the
    /// buffer expresses that intent exactly. Longer buffers or buffers
    /// with any additional tone / coda markers fall through to the
    /// default comparator untouched.
    internal static func promoteYapinForExactBareReading(
        _ candidates: [RankedGrammarCandidate],
        userBuffer: String
    ) -> [RankedGrammarCandidate] {
        guard candidates.count >= 2 else { return candidates }
        guard yapinPrimaryBareBuffers.contains(userBuffer) else { return candidates }
        // Already ya-pin on top? Nothing to do.
        if isYapinReading(candidates[0].candidate.reading) { return candidates }
        // Among candidates whose digit-stripped reading is exactly
        // the user buffer, pick the ya-pin sibling with the smallest
        // aliasCost (prefers `ky2i` → ကျီ over the double-alias
        // `ky2i2` → ကျည် when the user typed bare `kyi`).
        var bestIndex: Int?
        var bestAliasCost = Int.max
        for i in 1..<candidates.count {
            let reading = candidates[i].candidate.reading
            guard isYapinReading(reading) else { continue }
            guard Romanization.aliasReading(reading) == userBuffer else { continue }
            if candidates[i].aliasCost < bestAliasCost {
                bestAliasCost = candidates[i].aliasCost
                bestIndex = i
            }
        }
        guard let idx = bestIndex else { return candidates }
        var reordered = candidates
        let yapin = reordered.remove(at: idx)
        reordered.insert(yapin, at: 0)
        return reordered
    }

    internal func promoteAliasAlternate(_ candidates: [RankedGrammarCandidate]) -> [RankedGrammarCandidate] {
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
