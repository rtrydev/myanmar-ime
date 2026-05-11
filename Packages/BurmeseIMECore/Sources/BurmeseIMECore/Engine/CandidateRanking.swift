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
        _ candidates: [RankedGrammarCandidate],
        preservingSurfaces: Set<String> = []
    ) -> [RankedGrammarCandidate] {
        guard candidates.count > 1 else { return candidates }
        var maxLm = -Double.infinity
        for candidate in candidates {
            if candidate.lmLogProb > maxLm { maxLm = candidate.lmLogProb }
        }
        guard maxLm.isFinite else { return candidates }
        let floor = maxLm - lmPruneMargin
        let filtered = candidates.filter {
            $0.lmLogProb >= floor
                || $0.candidate.score > Double($0.parserScore)
                || preservingSurfaces.contains($0.candidate.surface)
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
        // TASK-071: when two grammar candidates differ by exactly one
        // scalar substitution — one carrying an aa-family dependent
        // vowel (U+102B / U+102C) and the other carrying a bare
        // consonant base (U+1000..U+1021) at the same position — the
        // aa-family form is the user-respecting `<C>aa` parse and the
        // bare-base form is the unintended `<C> + <particle>`
        // re-segmentation. The pattern arises when the buffer types
        // `<C>ar'<X>`: the apostrophe boundary makes both parses
        // available, the lattice's LM composite favours the bare-base
        // form because high-frequency single-letter particles (`ရ`,
        // `င်`, `သ`) carry strong unigram mass, but the user's
        // typing intent is unambiguously the `<C>aa` form. Prefer the
        // aa-family side directly when the parser score AGREES
        // (`parserScore` is the per-arc DP score, which already
        // reflects the parser's structural preference for the
        // 2-syllable parse). Falling back to `parserScore` rather
        // than running the composite avoids the LM-driven flip; the
        // bare-base sibling stays in the panel at lower rank.
        if let prefer = Self.preferredAaOverBareBaseSubstitution(
            lhs: lhs.candidate.surface,
            rhs: rhs.candidate.surface
        ) {
            // `prefer == .lhs` means the lhs surface is the
            // aa-family form (the user-respecting parse).
            switch prefer {
            case .lhs:
                if lhs.parserScore >= rhs.parserScore { return true }
            case .rhs:
                if rhs.parserScore >= lhs.parserScore { return false }
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
        // TASK-073 / TASK-074: when EXACTLY one side carries a curated
        // alias absorption whose surface is intentionally OOV in the
        // LM vocab (`absorbedMissingFromLM == true`), the composite
        // tilt against the `<unk>` floor punishes the curated form
        // even though the lexicon row encodes a very high stored score
        // (the curated alias `u.` → `ဥ` at 745, `an:` → `အံး` at 850).
        // In that one-sided case, fall back to a direct score
        // comparison so the curated-alias surface wins rank 0 when it
        // dominates the parser's open-class sibling on stored score.
        // Both candidates remain in the panel; only top-1 changes.
        if lhs.absorbedMissingFromLM != rhs.absorbedMissingFromLM,
           lhs.candidate.score != rhs.candidate.score {
            return lhs.candidate.score > rhs.candidate.score
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

    /// TASK-072 helper. True when `surface` contains BOTH U+103B
    /// (ya-pin medial) and U+103C (ya-yit medial). Used by the
    /// post-sort consistency fix to detect mixed-medial top-1
    /// candidates produced by the lattice composite for buffers
    /// where the user typed the same cluster-alias keystrokes
    /// multiple times.
    internal static func surfaceHasMixedYapinYayit(_ surface: String) -> Bool {
        var sawYapin = false
        var sawYayit = false
        for scalar in surface.unicodeScalars {
            if scalar.value == 0x103B { sawYapin = true }
            else if scalar.value == 0x103C { sawYayit = true }
            if sawYapin && sawYayit { return true }
        }
        return false
    }

    /// TASK-072 helper. True when `buffer` contains an identical
    /// cluster-alias substring appearing at least twice. The
    /// detection probes the documented ya-pin-preferred cluster keys
    /// (`khwy`, `ghwy`, `khy`, `ghy`, `kwy`, `gwy`, `ky`, `gy`) plus
    /// the chy / phy / shy ya-yit-typical clusters; presence at two
    /// or more positions means the user typed the same keystrokes
    /// for the same cluster more than once. The post-sort
    /// consistency fix is gated on this signal so novel buffers with
    /// single-occurrence clusters keep the lattice's per-position
    /// medial choice.
    internal static func bufferHasRepeatedClusterAliasShape(_ buffer: String) -> Bool {
        // Cluster-alias keys whose Cy / Cwy spellings represent a
        // user-visible medial choice. Sorted longest-first so the
        // scanner doesn't double-count a `kwy` cluster as `ky`.
        let clusterKeys: [String] = [
            "khwy", "ghwy", "chwy", "phwy", "shwy",
            "khy", "ghy", "chy", "phy", "shy",
            "kwy", "gwy",
            "ky", "gy",
        ]
        let chars = Array(buffer)
        for key in clusterKeys {
            let keyChars = Array(key)
            guard keyChars.count <= chars.count else { continue }
            var occurrences = 0
            var i = 0
            while i + keyChars.count <= chars.count {
                var matched = true
                for j in 0..<keyChars.count where chars[i + j] != keyChars[j] {
                    matched = false
                    break
                }
                if matched {
                    occurrences += 1
                    if occurrences >= 2 { return true }
                    i += keyChars.count
                } else {
                    i += 1
                }
            }
        }
        return false
    }

    /// TASK-071 helper. When `lhs` and `rhs` differ by exactly one
    /// scalar at the same index — one carrying an aa-family dependent
    /// vowel (U+102B / U+102C) and the other carrying a bare consonant
    /// base (U+1000..U+1021), with the bare base NOT followed by any
    /// dep-vowel / medial / asat / virama (i.e. the base is a
    /// stand-alone single-letter syllable, the `<particle>` shape) —
    /// return which side is the aa-family form. Used by
    /// `grammarCandidateIsBetter` to prefer the user-respecting
    /// `<C>aa` parse over the lattice's LM-driven `<C> + <particle>`
    /// re-segmentation. Returns nil when the surfaces don't fit the
    /// pattern.
    internal enum AaBaseSubstitutionPreference {
        case lhs
        case rhs
    }
    internal static func preferredAaOverBareBaseSubstitution(
        lhs: String,
        rhs: String
    ) -> AaBaseSubstitutionPreference? {
        let a = Array(lhs.unicodeScalars).map(\.value)
        let b = Array(rhs.unicodeScalars).map(\.value)
        guard a.count == b.count, a.count >= 2 else { return nil }
        var diffIdx = -1
        for i in 0..<a.count where a[i] != b[i] {
            if diffIdx >= 0 { return nil }
            diffIdx = i
        }
        guard diffIdx >= 0 else { return nil }
        let va = a[diffIdx], vb = b[diffIdx]
        @inline(__always) func isAaDepVowel(_ v: UInt32) -> Bool {
            return v == 0x102B || v == 0x102C
        }
        @inline(__always) func isConsonantBase(_ v: UInt32) -> Bool {
            return v >= 0x1000 && v <= 0x1021
        }
        @inline(__always) func isAttachableMark(_ v: UInt32) -> Bool {
            return (v >= 0x102B && v <= 0x103E) || v == 0x1039
        }
        // Determine which side is the aa-family dep-vowel form.
        let lhsIsAa = isAaDepVowel(va) && isConsonantBase(vb)
        let rhsIsAa = isAaDepVowel(vb) && isConsonantBase(va)
        guard lhsIsAa || rhsIsAa else { return nil }
        // The aa-family scalar must attach to a consonant base
        // (previous scalar) — confirms the substitution is a
        // legitimate aa-vowel attached to the prior onset, not a
        // stray dep-vowel.
        guard diffIdx >= 1 else { return nil }
        let prev = (lhsIsAa ? a : b)[diffIdx - 1]
        guard isConsonantBase(prev) else { return nil }
        // The bare-base side must be a stand-alone single-letter
        // syllable: NOT followed by any dep-vowel / medial / asat /
        // virama. If it carries a follow-on mark, it is a legitimate
        // syllable in its own right (not a stranded particle) and
        // the preference does not apply.
        let bareSurface = lhsIsAa ? b : a
        if diffIdx + 1 < bareSurface.count {
            let follower = bareSurface[diffIdx + 1]
            if isAttachableMark(follower) { return nil }
        }
        return lhsIsAa ? .lhs : .rhs
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

    /// Replaced by `yaPinPreferredOnsetClusters` (task 02). The earlier
    /// per-buffer carve-out collapsed once the cluster-driven rule
    /// landed — kept as an empty set so anything that referenced it
    /// (e.g. the property suite's invariant check) keeps compiling.
    package static let yapinPrimaryBareBuffers: Set<String> = []

    /// Onset cluster keys whose lexicon weight is dominantly ya-pin.
    /// Counted on the curated lexicon (task 02): `ကျ` 1.95M vs `ကြ`
    /// 531k, `ကျော်` 275k vs `ကြော်` 30k, `ဂျပန်` 87k vs `ဂြပန်` 0,
    /// `ချင်` 142k vs `ခြင်` 36k, `ဃျ` family 0.16k vs `ဃြ` 0. Buffers
    /// whose first onset is one of these clusters get their ya-pin
    /// sibling promoted to rank 0 even when the parser's structural
    /// `Cy` → ya-yit rule and the absorbed lexicon score would otherwise
    /// tie or favour ya-yit.
    ///
    /// `chy` / `phy` / `shy` are intentionally omitted: lexicon evidence
    /// is mixed for those (e.g. `ဆျ` rare; `ရှ` is the canonical sh-
    /// cluster anyway) and the structural `Cy` → ya-yit rule there
    /// matches user expectation.
    ///
    /// The medial-w-first typing variants (`khwy`, `ghwy`, `kwy`, `gwy`)
    /// are listed alongside their `Cy…` counterparts because the parser
    /// canonicalises medial typing order before trie lookup
    /// (`canonicalizeOnsetProbes` in `Parser/Matching.swift`) — both
    /// `Cyw…` and `Cwy…` typings produce the same canonical onset
    /// (`<C> 103B 103D` for ya-pin, `<C> 103C 103D` for ya-yit), so the
    /// promotion gate must recognise both spellings of the same onset
    /// (TASK-058). Excluded clusters and their `Cwy` typings
    /// (`chwy` / `phwy` / `shwy`) remain unlisted and stay on the
    /// existing structural `Cy` → ya-yit rule. Keys are listed longest-
    /// first so `khwy` / `ghwy` are preferred over `kwy` / `gwy`, and
    /// 3-char clusters over 2-char `ky` / `gy`.
    internal static let yaPinPreferredOnsetClusters: [String] = [
        "khwy", "ghwy",
        "khy", "ghy", "kwy", "gwy",
        "ky", "gy",
    ]

    /// Typing-intent promotion for ya-pin readings: when the user buffer
    /// starts with one of `yaPinPreferredOnsetClusters`, move the
    /// lowest-aliasCost ya-pin sibling whose digit-stripped reading
    /// matches the user buffer to rank 0 (task 02). Generalises the
    /// earlier exact-bare-buffer carve-out (`yapinPrimaryBareBuffers`)
    /// to every word that starts with one of these clusters — the
    /// underlying parser-level alias asymmetry treats ya-yit as cheaper
    /// at aliasCost 0 vs ya-pin at aliasCost 1, and even with explicit
    /// cluster aliases at aliasCost 0 the lexicon-absorbed composite
    /// can still favour ya-yit when its row is in-vocab and ya-pin's is
    /// not. The promotion is the data-driven tie-breaker that surfaces
    /// the corpus-dominant medial choice; the ya-yit sibling stays in
    /// the panel as a lower-ranked option.
    internal static func promoteYapinForExactBareReading(
        _ candidates: [RankedGrammarCandidate],
        userBuffer: String
    ) -> [RankedGrammarCandidate] {
        guard let idx = yapinPromotionIndex(in: candidates, userBuffer: userBuffer) else {
            return candidates
        }
        var reordered = candidates
        let yapin = reordered.remove(at: idx)
        reordered.insert(yapin, at: 0)
        return reordered
    }

    internal static func isYapinPromotionBuffer(_ userBuffer: String) -> Bool {
        bufferStartsWithYaPinCluster(userBuffer)
    }

    internal static func yapinPromotionPreservedSurface(
        in candidates: [RankedGrammarCandidate],
        userBuffer: String
    ) -> String? {
        guard let idx = yapinPromotionIndex(in: candidates, userBuffer: userBuffer) else {
            return nil
        }
        return candidates[idx].candidate.surface
    }

    private static func yapinPromotionIndex(
        in candidates: [RankedGrammarCandidate],
        userBuffer: String
    ) -> Int? {
        guard candidates.count >= 2 else { return nil }
        guard bufferStartsWithYaPinCluster(userBuffer) else { return nil }
        // Match a ya-pin sibling against the top candidate's reading
        // (digit-stripped + tone-stripped) rather than the user buffer
        // — the parser inserts an implicit `a` for inherent-vowel
        // syllables, so e.g. `gypan` becomes `gyapan` / `gy2apan`
        // canonically. Comparing to the user buffer would miss those.
        // Iterate from 0 because ya-pin can already win the comparator
        // (cluster alias paths reach aliasCost 0); we still need to
        // pick the best ya-pin sibling among them.
        let topReading = candidates[0].candidate.reading
        let topAliasRoot = strippingTrailingToneMarkers(
            from: Romanization.aliasReading(topReading)
        )
        let bareRoot = strippingTrailingToneMarkers(from: userBuffer)
        let bareRootMatchKey = promotionMatchKey(bareRoot)
        var bestIndex: Int?
        var bestAliasCost = Int.max
        for i in 0..<candidates.count {
            let reading = candidates[i].candidate.reading
            guard isYapinReading(reading) else { continue }
            let aliasReading = Romanization.aliasReading(reading)
            let aliasRoot = strippingTrailingToneMarkers(from: aliasReading)
            guard aliasReading == userBuffer
                    || aliasRoot == bareRoot
                    || promotionMatchKey(aliasRoot) == bareRootMatchKey
                    || aliasRoot == topAliasRoot
            else { continue }
            if candidates[i].aliasCost < bestAliasCost {
                bestAliasCost = candidates[i].aliasCost
                bestIndex = i
            }
        }
        // Best ya-pin already at index 0 — nothing to do.
        if bestIndex == 0 { return nil }
        return bestIndex
    }

    private static func strippingTrailingToneMarkers(from buffer: String) -> String {
        var stripped = buffer
        while let last = stripped.last, last == ":" || last == "." {
            stripped.removeLast()
        }
        return stripped
    }

    /// Returns true if `buffer`'s first onset cluster is in
    /// `yaPinPreferredOnsetClusters`. The cluster keys are listed
    /// longest-first so `khwy` / `ghwy` are preferred over the 3-char
    /// variants, and 3-char clusters over `ky` / `gy` when both would
    /// prefix the buffer. The parser interprets the cluster as the
    /// first onset regardless of what follows it (consonant, vowel,
    /// digit, or end of buffer), so the prefix match alone is the
    /// correct trigger — buffers like `gypan` (`gy` onset + `pan` next
    /// syllable), `kyaw` (`ky` onset + `aw` vowel), and `kwyantaw`
    /// (`kwy` medial-w-first onset + `antaw`) all qualify.
    private static func bufferStartsWithYaPinCluster(_ buffer: String) -> Bool {
        for cluster in yaPinPreferredOnsetClusters where buffer.hasPrefix(cluster) {
            return true
        }
        return false
    }

    /// If `input` begins with a `yaPinPreferredOnsetClusters` entry,
    /// return the input rewritten to force the parser onto the ya-pin
    /// disambiguator path (e.g. `kwyantaw…` → `kwy2antaw…`). Returns
    /// `nil` when the prefix does not match a promotion cluster, so
    /// callers can early-out without re-parsing.
    ///
    /// Why we need this: the parser's `Cy` / `Cwy` rules canonicalise
    /// to ya-yit (alias-cost 0); the ya-pin variant is reachable only
    /// via the digit-suffixed form (`Cy2`, `Cwy2`, alias-cost 1). The
    /// DP comparator `isBetterDP` ranks states primarily by aliasCost,
    /// so once enough syllables stack up the ya-pin sibling is
    /// pruned out of the N-best beam — the engine never sees a ya-pin
    /// candidate to feed `promoteYapinForExactBareReading`. Re-running
    /// `parseCandidates` with the rewritten input forces the ya-pin
    /// path through the DP and makes the candidate pool symmetric.
    /// The rewrite preserves byte length exactly at the cluster-end
    /// position (one inserted `2`) and leaves the rest of the buffer
    /// untouched, so trailing syllables parse identically to the
    /// original input.
    internal static func yaPinDisambiguatedInput(_ input: String) -> String? {
        for cluster in yaPinPreferredOnsetClusters where input.hasPrefix(cluster) {
            let endIndex = input.index(input.startIndex, offsetBy: cluster.count)
            return cluster + "2" + input[endIndex...]
        }
        return nil
    }

    private static func promotionMatchKey(_ buffer: String) -> String {
        strippingTrailingToneMarkers(from: buffer)
            .replacingOccurrences(of: "yw", with: "wy")
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
