import Foundation

extension SyllableParser {

    // MARK: - Finalization

    /// A fully materialized candidate: scalar fields plus the reconstructed
    /// `output`/`reading` strings. Only produced for states that survive
    /// pre-filtering in `finalizeStates` — materialization cost is amortized
    /// over a handful of candidates rather than every DP transition.
    internal struct MaterializedState {
        let state: ParseState
        let output: String
        let reading: String
        /// `adjustLeadingVowel(output)` — precomputed because dedup, the
        /// final sort comparator, and the demotion-window map all reference
        /// it; without the cache each MaterializedState would pay 3+ adjust
        /// calls, and the sort amplifies that by the comparator count.
        let adjustedOutput: String
        /// Cached marker penalty so the dedup pass and the final sort can
        /// skip the dictionary lookup per comparison.
        var markerPenalty: Int
    }

    internal func finalizeStates(
        arena: [ParseState],
        finalIndices: [Int32],
        limit: Int,
        requestedReading: String,
        isFullBuffer: Bool = true
    ) -> [SyllableParse] {
        // "Non-empty" under the legacy code meant `!output.isEmpty`; here that
        // is precisely `syllableCount > 0` because every emitted output
        // fragment is attached to a syllable-bearing transition. Skip-only
        // paths accumulate syllableCount = 0 with no output.
        var nonEmptyIndices: [Int32] = []
        nonEmptyIndices.reserveCapacity(finalIndices.count)
        for idx in finalIndices where arena[Int(idx)].syllableCount > 0 {
            nonEmptyIndices.append(idx)
        }

        var legalIndices: [Int32] = []
        for idx in nonEmptyIndices where arena[Int(idx)].isLegal {
            legalIndices.append(idx)
        }

        let filteredIndices: [Int32]
        if !legalIndices.isEmpty {
            var minimumLegalSyllables = Int.max
            for idx in legalIndices {
                let c = arena[Int(idx)].syllableCount
                if c < minimumLegalSyllables { minimumLegalSyllables = c }
            }
            let minTier = legalIndices.filter {
                arena[Int($0)].syllableCount == minimumLegalSyllables
            }
            if limit > 1 && minTier.count < 2 {
                filteredIndices = legalIndices.filter {
                    arena[Int($0)].syllableCount <= minimumLegalSyllables + 1
                }
            } else {
                filteredIndices = minTier
            }
        } else {
            filteredIndices = nonEmptyIndices
        }

        // Materialize strings once per surviving candidate. This is the only
        // place output/reading are ever built.
        var materialized: [MaterializedState] = []
        materialized.reserveCapacity(filteredIndices.count)
        // Fast-path: if the requested reading has no numeric alias markers
        // (the common case for plain Roman input like "mingal"), every
        // candidate's marker penalty is 0 and we can skip placement math.
        // When markers are present, precompute `requestedPlacements` once
        // instead of rebuilding it per candidate, and memoize by reading.
        let requestedHasMarkers = requestedReading.contains { Romanization.isNumericAliasMarker($0) }
        let requestedPlacements: Set<NumericMarkerPlacement>
        if requestedHasMarkers {
            requestedPlacements = Self.numericMarkerPlacements(in: requestedReading)
        } else {
            requestedPlacements = []
        }
        var penaltyByReading: [String: Int] = [:]
        @inline(__always) func penalty(for reading: String) -> Int {
            if !requestedHasMarkers { return 0 }
            if let cached = penaltyByReading[reading] { return cached }
            let cand = Self.numericMarkerPlacements(in: reading)
            let p = requestedPlacements.symmetricDifference(cand).count
            penaltyByReading[reading] = p
            return p
        }
        for idx in filteredIndices {
            let (output, reading) = materialize(stateIdx: idx, arena: arena, promoteLeadingA: isFullBuffer)
            materialized.append(MaterializedState(
                state: arena[Int(idx)],
                output: output,
                reading: reading,
                adjustedOutput: adjustLeadingVowel(output),
                markerPenalty: penalty(for: reading)
            ))
        }

        // Sort + dedup by `adjustedOutput`, matching legacy.
        materialized.sort {
            isBetter($0, markerPenalty: $0.markerPenalty,
                     than: $1, markerPenalty: $1.markerPenalty)
        }

        var deduplicated: [String: MaterializedState] = [:]
        for m in materialized {
            if let existing = deduplicated[m.adjustedOutput] {
                if isBetter(m, markerPenalty: m.markerPenalty,
                            than: existing, markerPenalty: existing.markerPenalty) {
                    deduplicated[m.adjustedOutput] = m
                }
            } else {
                deduplicated[m.adjustedOutput] = m
            }
        }

        // Rank with rarity penalty baked in so rare-codepoint parses fall
        // below their common counterparts even when DP-time scalar fields
        // tie. Retroflex onsets (Pali; correctly romanized with the "2"
        // marker) and non-initial independent vowels each add a penalty;
        // see `computeRarityPenalty` for the exact weights.
        let rarityFor = deduplicated.mapValues { Self.computeRarityPenalty($0.output) }
        let sortedFinal = deduplicated.values.sorted { lhs, rhs in
            isBetter(
                lhs,
                rarity: rarityFor[lhs.adjustedOutput] ?? 0,
                markerPenalty: lhs.markerPenalty,
                than: rhs,
                rarity: rarityFor[rhs.adjustedOutput] ?? 0,
                markerPenalty: rhs.markerPenalty
            )
        }
        // Materialize SyllableParse for the top window (oversampled so a
        // post-DP legality demotion — virama/asat/indep-vowel checks below
        // — can still surface a clean alternative when the score-best
        // parse is illegal after demotion).
        let demotionWindow = max(limit, 4)
        let mapped: [SyllableParse] = sortedFinal.prefix(demotionWindow).map { m in
            let adjusted = Self.remapEmptyToInherent(m.adjustedOutput, reading: m.reading)
            let legal = m.state.isLegal && Self.scanOutputLegality(adjusted)
            return SyllableParse(
                output: adjusted,
                reading: m.reading,
                aliasCost: m.state.aliasCost,
                legalityScore: legal ? m.state.legalityScore : 0,
                score: m.state.score,
                structureCost: m.state.structureCost,
                syllableCount: m.state.syllableCount,
                rarityPenalty: rarityFor[adjusted] ?? 0
            )
        }
        // Stable re-sort: legal parses (legalityScore > 0) outrank demoted
        // ones; original DP-rank order is preserved within each tier.
        let legalFirst = mapped.enumerated().sorted { lhs, rhs in
            let lhsLegal = lhs.element.legalityScore > 0
            let rhsLegal = rhs.element.legalityScore > 0
            if lhsLegal != rhsLegal { return lhsLegal }
            return lhs.offset < rhs.offset
        }.map { $0.element }
        return Array(legalFirst.prefix(limit))
    }

    /// If `output` is empty, returns U+1021 (`အ`) so a bare-vowel reading
    /// like `a` / `aa` / `aaa` produces a visible inherent-consonant
    /// candidate instead of an empty surface. Empty surfaces would
    /// otherwise reach the candidate panel as blank entries.
    ///
    /// Connector-only readings (`'`, `+`, `*` with no real vowel or
    /// consonant alongside them) are the exception: the user typed pure
    /// syllable-separator characters, so synthesising an `အ` here would
    /// inject content they never asked for (see task 08).
    internal static func remapEmptyToInherent(_ output: String, reading: String) -> String {
        if output.isEmpty {
            let isConnectorOnly = !reading.isEmpty && reading.allSatisfy {
                $0 == "'" || $0 == "+" || $0 == "*"
            }
            if isConnectorOnly { return "" }
            return String(Unicode.Scalar(0x1021)!)
        }
        return output
    }

    /// Bundles the scalar-level orthographic checks the parser runs at
    /// materialize time. Replaces four separate scans (malformed virama
    /// stack, asat without consonant base, dependent vowel after
    /// independent vowel, triple virama stack) with a single pass that
    /// allocates the scalar array once. Short-circuits once any flag is
    /// set since downstream callers only inspect `isLegal`.
    @_spi(Testing) public static func scanOutputLegality(_ output: String) -> Bool {
        // Reuse the scalars view directly — materializing an Array is pure
        // overhead when most outputs never hit any of the guarded scalar
        // values. The asat backward-walk uses the indices() view, which
        // supports random access without an intermediate allocation.
        let scalars = output.unicodeScalars
        if scalars.isEmpty { return true }
        let indices = Array(scalars)
        let n = indices.count
        @inline(__always) func isConsonantBase(_ v: UInt32) -> Bool {
            return (v >= 0x1000 && v <= 0x1021) || v == 0x103F
        }
        @inline(__always) func isIndependentVowel(_ v: UInt32) -> Bool {
            return v >= 0x1023 && v <= 0x102A
        }
        @inline(__always) func isDependentVowel(_ v: UInt32) -> Bool {
            return v >= 0x102B && v <= 0x1032
        }
        @inline(__always) func isToneMark(_ v: UInt32) -> Bool {
            return v >= 0x1036 && v <= 0x1038
        }
        @inline(__always) func isMedial(_ v: UInt32) -> Bool {
            return v >= 0x103B && v <= 0x103E
        }
        @inline(__always) func isAttachableMark(_ v: UInt32) -> Bool {
            return isDependentVowel(v) || isToneMark(v) || isMedial(v)
        }
        @inline(__always) func attachableMarkHasAnchor(at i: Int) -> Bool {
            let current = indices[i].value
            var j = i - 1
            while j >= 0 {
                let w = indices[j].value
                if isConsonantBase(w) { return true }
                // U+1038 after U+1026 is the standard ဦး spelling, and
                // existing independent-vowel tone variants intentionally
                // stay legal. Dependent vowels and medials still require a
                // consonant base.
                if isToneMark(current), isIndependentVowel(w) { return true }
                if w == 0x103A {
                    if isToneMark(current) {
                        j -= 1
                        continue
                    }
                    return false
                }
                if w == 0x200C {
                    return j == 0
                }
                if isIndependentVowel(w) {
                    return false
                }
                if w == 0x1039 {
                    if j + 1 < n, isConsonantBase(indices[j + 1].value) {
                        j -= 1
                        continue
                    }
                    return false
                }
                if current == 0x1031 && w == 0x1031 {
                    return false
                }
                if isAttachableMark(w) {
                    j -= 1
                    continue
                }
                return false
            }
            return false
        }
        for i in 0..<n {
            let v = indices[i].value
            // Fast path: only independent vowels, dependent marks, medials,
            // and virama/asat need inspection.
            // Skip scalars outside those ranges with a single range test.
            if v < 0x1023 || v > 0x103E { continue }
            if v == 0x1039 {
                guard i >= 1 else { return false }
                let prev = indices[i - 1]
                if prev.value == 0x103A {
                    let twoBack = i >= 2 ? indices[i - 2].value : 0
                    if twoBack != 0x1004 { return false }
                } else if !isConsonantBase(prev.value) {
                    return false
                }
                guard i + 1 < n else { return false }
                if !isConsonantBase(indices[i + 1].value) { return false }
                // Triple-stack guard: two viramas separated by one consonant.
                if i >= 2
                    && indices[i - 2].value == 0x1039
                    && isConsonantBase(indices[i - 1].value) {
                    return false
                }
            } else if v == 0x103A {
                var j = i - 1
                while j >= 0 {
                    let w = indices[j].value
                    let isSkippable = (w >= 0x102B && w <= 0x1032)
                        || (w >= 0x1036 && w <= 0x1038)
                        || (w >= 0x103B && w <= 0x103E)
                    if isSkippable { j -= 1 } else { break }
                }
                guard j >= 0 else { return false }
                if !isConsonantBase(indices[j].value) { return false }
            } else if v >= 0x1023 && v <= 0x102A {
                if i + 1 < n {
                    let next = indices[i + 1].value
                    if next >= 0x102B && next <= 0x1032 { return false }
                }
            } else if isAttachableMark(v) {
                if !attachableMarkHasAnchor(at: i) { return false }
            }
        }
        return true
    }

    /// Count rare-codepoint usages in an output surface so the final
    /// ranker can downweight parses the user did not explicitly spell.
    /// +1 per Pali retroflex consonant (these are correctly selected with
    /// "t2" / "d2" / "n2" / "l2" — their appearance under a bare onset is
    /// user-unexpected). Independent vowels are not penalized: the user
    /// already pays `aliasCost` for picking an independent-vowel variant,
    /// and explicit disambiguators like "u2." specifically request them.
    internal static func computeRarityPenalty(_ output: String) -> Int {
        var penalty = 0
        for scalar in output.unicodeScalars {
            let v = scalar.value
            // Retroflex consonants: ဋ ဌ ဍ ဎ ဏ ဠ
            if v == 0x100B || v == 0x100C || v == 0x100D
                || v == 0x100E || v == 0x100F || v == 0x1020 {
                penalty += 1
            }
        }
        return penalty
    }

    internal struct NumericMarkerPlacement: Hashable {
        let offset: Int
        let marker: Character
    }

    internal static func numericMarkerPlacements(in reading: String) -> Set<NumericMarkerPlacement> {
        var placements: Set<NumericMarkerPlacement> = []
        var offset = 0
        for character in reading {
            if Romanization.isNumericAliasMarker(character) {
                placements.insert(NumericMarkerPlacement(offset: offset, marker: character))
            } else {
                offset += 1
            }
        }
        return placements
    }

    /// Walk the `parentIdx` chain backward to the seed, collect each
    /// transition's contribution, then concatenate forward into a single
    /// `output`/`reading` pair. Only called for the handful of states that
    /// survive finalizing pre-filters.
    internal func materialize(
        stateIdx: Int32,
        arena: [ParseState],
        promoteLeadingA: Bool = true
    ) -> (output: String, reading: String) {
        var refs: [MatchRef] = []
        var cur = stateIdx
        while cur >= 0 {
            let state = arena[Int(cur)]
            refs.append(state.matchRef)
            cur = state.parentIdx
        }
        refs.reverse()

        var output = ""
        var reading = ""
        // Rough pre-sizing: Myanmar output is usually short enough that
        // reservations a bit above refs.count × 2 avoid reallocation.
        output.reserveCapacity(refs.count * 4)
        reading.reserveCapacity(refs.count * 4)

        // A leading `a` standalone vowel emits empty output by design so
        // that bare `a` / `aa` fall into `remapEmptyToInherent`. When more
        // composable material follows, the empty emission is silently
        // absorbed into the next syllable (`atar` → တာ instead of အတာ).
        // Promote the first empty-output inherent-`a` run to U+1021 when
        // there is any downstream non-skip ref. Suppressed for
        // sliding-window tail parses — the tail does not start at the
        // user's buffer origin, so injecting U+1021 there would appear
        // mid-output as a spurious independent vowel.
        var sawLeadingA = false
        var promotedLeadingA = false
        for ref in refs {
            switch ref {
            case .seed, .skip:
                continue
            case .onsetOnly(let onsetId):
                let entry = onsetTerminals[Int(onsetId)]
                if promoteLeadingA && !promotedLeadingA && output.isEmpty && sawLeadingA {
                    output.unicodeScalars.append(Unicode.Scalar(0x1021)!)
                    promotedLeadingA = true
                }
                output.append(entry.myanmar)
                reading.append(entry.canonicalRoman)
                reading.append("a")
            case .onsetVowel(let onsetId, let vowelId):
                let onset = onsetTerminals[Int(onsetId)]
                let vowel = vowelTerminals[Int(vowelId)]
                if promoteLeadingA && !promotedLeadingA && output.isEmpty && sawLeadingA {
                    output.unicodeScalars.append(Unicode.Scalar(0x1021)!)
                    promotedLeadingA = true
                }
                output.append(onset.myanmar)
                output.append(vowel.myanmar)
                reading.append(onset.canonicalRoman)
                reading.append(vowel.canonicalRoman)
            case .vowelOnly(let vowelId):
                let entry = vowelTerminals[Int(vowelId)]
                if promoteLeadingA && !promotedLeadingA && output.isEmpty && sawLeadingA
                    && !(entry.canonicalRoman == "a" && entry.myanmar.isEmpty) {
                    output.unicodeScalars.append(Unicode.Scalar(0x1021)!)
                    promotedLeadingA = true
                }
                output.append(entry.myanmar)
                reading.append(entry.canonicalRoman)
                if entry.canonicalRoman == "a" && entry.myanmar.isEmpty {
                    sawLeadingA = true
                }
            }
        }
        return (Self.stripSpuriousAsatBeforeVirama(Self.canonicalizeMedialOrder(output)), reading)
    }

    /// Strip U+103A (asat) immediately before U+1039 (virama) when the
    /// scalar preceding the asat is not U+1004 (nga). Only kinzi
    /// (nga + asat + virama + consonant) is a legal asat/virama
    /// adjacency in Myanmar orthography; other bases must use the
    /// virama-only stacked form without the visible asat. The DP
    /// penalizes these parses but cannot avoid them when no
    /// asat-free alternative exists in the beam (e.g. the "ate"
    /// vowel always emits a trailing asat), so the surface is
    /// sanitized here as a last step.
    internal static func stripSpuriousAsatBeforeVirama(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 3 else { return text }
        var needsWork = false
        var i = 0
        while i + 1 < scalars.count {
            if scalars[i].value == 0x103A && scalars[i + 1].value == 0x1039 {
                let base = i >= 1 ? scalars[i - 1].value : 0
                if base != 0x1004 {
                    needsWork = true
                    break
                }
            }
            i += 1
        }
        guard needsWork else { return text }
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(scalars.count)
        i = 0
        while i < scalars.count {
            if i + 1 < scalars.count,
               scalars[i].value == 0x103A,
               scalars[i + 1].value == 0x1039 {
                let base = i >= 1 ? scalars[i - 1].value : 0
                if base != 0x1004 {
                    i += 1
                    continue
                }
            }
            output.append(scalars[i])
            i += 1
        }
        var result = ""
        result.unicodeScalars.reserveCapacity(output.count)
        for scalar in output {
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    /// Sort each run of consecutive medial scalars (U+103B..U+103E) into
    /// ascending codepoint order and collapse adjacent duplicates. The
    /// onset table emits medials in a fixed order and each vowel entry
    /// stores its own medial prefix; at the join (e.g. onset ending in
    /// ှ U+103E followed by a vowel starting with ွ U+103D for "hmon") the
    /// run can land out of order, and when onset and vowel both contribute
    /// the same medial scalar it must appear only once in the surface.
    internal static func canonicalizeMedialOrder(_ text: String) -> String {
        let input = Array(text.unicodeScalars)
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(input.count)
        var i = 0
        while i < input.count {
            let v = input[i].value
            guard v >= 0x103B && v <= 0x103E else {
                output.append(input[i])
                i += 1
                continue
            }
            var j = i + 1
            while j < input.count {
                let w = input[j].value
                guard w >= 0x103B && w <= 0x103E else { break }
                j += 1
            }
            let sorted = input[i..<j].sorted { $0.value < $1.value }
            var lastValue: UInt32 = 0
            var haveLast = false
            for scalar in sorted {
                if haveLast && scalar.value == lastValue { continue }
                output.append(scalar)
                lastValue = scalar.value
                haveLast = true
            }
            i = j
        }
        guard output.count != input.count || zip(output, input).contains(where: { $0.value != $1.value }) else {
            return text
        }
        var result = ""
        result.unicodeScalars.reserveCapacity(output.count)
        for scalar in output {
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    // MARK: - Leading Vowel Adjustment

    internal func adjustLeadingVowel(_ text: String) -> String {
        guard let first = text.unicodeScalars.first else { return text }

        // Every dependent sign in the Myanmar block — dependent vowels
        // (U+102B–U+1032), tone/shaping marks and virama/asat
        // (U+1036–U+103A), and medials (U+103B–U+103E) — must attach to a
        // preceding base. When the parser accepts an onset-less surface
        // that begins with one, prefix U+200C so the mark has a
        // display-safe base.
        switch first.value {
        case 0x102B...0x1032, 0x1036...0x103E:
            return "\u{200C}" + text
        default:
            return text
        }
    }

    // MARK: - Materialized Ranking

    /// Final ranking — uses materialized strings for the legacy lex
    /// tiebreakers so the user-visible top-K order matches pre-refactor.
    ///
    /// `syllableCount` sits above `aliasCost` so that when `finalizeStates`
    /// widens the admitted set to `min+1` (for thin min-tiers), an extended
    /// parse with lower alias cost cannot displace the canonical min-tier
    /// parse at the top. Within a single tier all counts match, so this
    /// has no effect on pre-widening behavior.
    internal func isBetter(
        _ lhs: MaterializedState,
        markerPenalty lhsMarkerPenalty: Int,
        than rhs: MaterializedState,
        markerPenalty rhsMarkerPenalty: Int
    ) -> Bool {
        if lhs.state.isLegal != rhs.state.isLegal {
            return lhs.state.isLegal
        }
        if lhs.state.syllableCount != rhs.state.syllableCount {
            return lhs.state.syllableCount < rhs.state.syllableCount
        }
        if lhsMarkerPenalty != rhsMarkerPenalty {
            return lhsMarkerPenalty < rhsMarkerPenalty
        }
        if lhs.state.aliasCost != rhs.state.aliasCost {
            return lhs.state.aliasCost < rhs.state.aliasCost
        }
        if lhs.state.score != rhs.state.score {
            return lhs.state.score > rhs.state.score
        }
        if lhs.state.legalityScore != rhs.state.legalityScore {
            return lhs.state.legalityScore > rhs.state.legalityScore
        }
        if lhs.state.structureCost != rhs.state.structureCost {
            return lhs.state.structureCost < rhs.state.structureCost
        }
        if lhs.output != rhs.output {
            return lhs.output < rhs.output
        }
        return lhs.reading < rhs.reading
    }

    /// Rarity-aware ordering for the final top-K step. Legality remains
    /// the hard filter. `rarityPenalty` then sits above `syllableCount` so
    /// a 2-syllable common parse (e.g. တဦ) outranks a 1-syllable retroflex
    /// parse (ဋူ) even though the retroflex is "shorter" — users who did
    /// not type the "2" disambiguator rarely want the retroflex up front.
    internal func isBetter(
        _ lhs: MaterializedState,
        rarity lhsRarity: Int,
        markerPenalty lhsMarkerPenalty: Int,
        than rhs: MaterializedState,
        rarity rhsRarity: Int,
        markerPenalty rhsMarkerPenalty: Int
    ) -> Bool {
        if lhs.state.isLegal != rhs.state.isLegal {
            return lhs.state.isLegal
        }
        if lhsRarity != rhsRarity {
            return lhsRarity < rhsRarity
        }
        if lhs.state.syllableCount != rhs.state.syllableCount {
            return lhs.state.syllableCount < rhs.state.syllableCount
        }
        if lhsMarkerPenalty != rhsMarkerPenalty {
            return lhsMarkerPenalty < rhsMarkerPenalty
        }
        if lhs.state.aliasCost != rhs.state.aliasCost {
            return lhs.state.aliasCost < rhs.state.aliasCost
        }
        if lhs.state.score != rhs.state.score {
            return lhs.state.score > rhs.state.score
        }
        if lhs.state.legalityScore != rhs.state.legalityScore {
            return lhs.state.legalityScore > rhs.state.legalityScore
        }
        if lhs.state.structureCost != rhs.state.structureCost {
            return lhs.state.structureCost < rhs.state.structureCost
        }
        if lhs.output != rhs.output {
            return lhs.output < rhs.output
        }
        return lhs.reading < rhs.reading
    }
}
