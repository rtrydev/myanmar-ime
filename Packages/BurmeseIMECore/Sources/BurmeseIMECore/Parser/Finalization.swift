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
        /// Per-arc cumulative `(charEnd, scalarOffset)` boundaries from
        /// the materializer. Used downstream to map digit char offsets to
        /// scalar splice positions (TASK-002).
        let arcBoundaries: [SyllableParse.ArcBoundary]
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
            // TASK-047: when the user typed a `+` and every
            // min-tier candidate fails the post-finalize legality
            // scan (typically because the `+` was admitted as a
            // virama-`+` arc whose adjacent dep-vowel materialises
            // a virama-before-vowel sequence that
            // `scanOutputLegality` rejects), the min-tier filter
            // would silently drop the higher-syllableCount soft-`+`
            // sibling that DOES scan clean — leaving the panel
            // empty of any user-respecting form. Detect this by
            // materialising the min-tier states once and checking
            // whether at least one surface scans clean; if none do,
            // widen the filter to min+1 so the soft-`+` (and
            // similar) sibling reaches the materialize/sort path.
            // The narrow `chars.contains("+")` gate keeps single-
            // bare-vowel-rule shapes (`aw` → `‌ော်`,
            // `aing` → `‌ိုင်`) on the existing min-tier path —
            // those rules emit a structurally orphan dep-vowel
            // cluster that the engine's downstream
            // `promoteOrphanZwnjToImplicitA` post-process repairs;
            // widening would surface a competing onset+vowel sibling
            // (e.g. `aw` → `အဝ` from `a + w` parse) that displaces
            // the canonical bare-diphthong rendering.
            // TASK-047: when the user typed `+`, ALWAYS widen the
            // filter to min+1. `+`-bearing buffers admit both a
            // virama-`+` (1-syllable merge) parse and a soft-`+`
            // (2-syllable break) parse with different syllableCounts;
            // the strict min-tier filter would silently drop the
            // user-respecting soft-`+` sibling whenever the
            // virama-`+` form happens to be legal post-scan
            // (e.g. `k+ar` produces a legal `<k><virama><r>` 2-arc
            // sibling that the min-tier filter keeps to the exclusion
            // of the soft-`+` `<k><1021><ar>` 3-arc sibling). Widen so
            // both compete in the materialised sort.
            let bufferContainsPlus = requestedReading.contains("+")
            if (limit > 1 && minTier.count < 2) || bufferContainsPlus {
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
            let (output, reading, boundaries) = materialize(
                stateIdx: idx, arena: arena, promoteLeadingA: isFullBuffer
            )
            materialized.append(MaterializedState(
                state: arena[Int(idx)],
                output: output,
                reading: reading,
                adjustedOutput: adjustLeadingVowel(output),
                markerPenalty: penalty(for: reading),
                arcBoundaries: boundaries
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
            // `adjustLeadingVowel` may prefix a U+200C ZWNJ to the raw
            // output; if it did, every boundary's scalar offset shifts
            // by +1 in the adjusted surface. `remapEmptyToInherent` may
            // turn an empty surface into U+1021 — boundaries stay at 0
            // since no arc contributed scalars.
            let leadingShift = m.adjustedOutput.count - m.output.count > 0 ? 1 : 0
            let shiftedBoundaries = m.arcBoundaries.map {
                SyllableParse.ArcBoundary(
                    charEnd: $0.charEnd,
                    scalarOffset: $0.scalarOffset + leadingShift
                )
            }
            return SyllableParse(
                output: adjusted,
                reading: m.reading,
                aliasCost: m.state.aliasCost,
                legalityScore: legal ? m.state.legalityScore : 0,
                score: m.state.score,
                structureCost: m.state.structureCost,
                syllableCount: m.state.syllableCount,
                rarityPenalty: rarityFor[adjusted] ?? 0,
                arcBoundaries: shiftedBoundaries
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
        // Categorise dependent-vowel scalars so the anchor walk can
        // reject same-category duplicates without rejecting legitimate
        // multi-scalar shapes (`o` = U+102D + U+102F crosses categories
        // and is legal). Categories: aa / i / u / e / ai. Returns 0 for
        // scalars outside the dep-vowel range. See task 02.
        @inline(__always) func depVowelCategory(_ v: UInt32) -> Int {
            switch v {
            case 0x102B, 0x102C: return 1
            case 0x102D, 0x102E: return 2
            case 0x102F, 0x1030: return 3
            case 0x1031:        return 4
            case 0x1032:        return 5
            default:            return 0
            }
        }
        @inline(__always) func attachableMarkHasAnchor(at i: Int) -> Bool {
            let current = indices[i].value
            let currentCategory = depVowelCategory(current)
            // TASK-038: Unicode TUS storage order requires medials
            // (U+103B..U+103E) to appear immediately after the
            // consonant base (and any kinzi / virama-stack
            // continuation), strictly before every dependent-vowel
            // sign and every tone mark. Crossing a dep-vowel,
            // tone-mark, or syllable-closing asat during the
            // backward walk from a medial means the medial sits
            // on the wrong side of those scalars — an ordering
            // that no rendering engine accepts as valid. Reject
            // immediately. The narrowest-fix; the parser DP can
            // still produce these chains, but they no longer pass
            // the legality scan and so cannot land at rank 0 with
            // a positive `legalityScore`.
            let currentIsMedial = isMedial(current)
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
                if currentIsMedial, isDependentVowel(w) {
                    return false
                }
                if currentIsMedial, isToneMark(w) {
                    return false
                }
                if w == 0x1039 {
                    if j + 1 < n, isConsonantBase(indices[j + 1].value) {
                        j -= 1
                        continue
                    }
                    return false
                }
                // U+1031 (e-kar) must be the first dependent-vowel scalar
                // on its base — Unicode TUS storage order places it
                // immediately after the base (and any medials), before
                // every other dependent vowel. Walking back from a `1031`
                // and crossing any other dep-vowel scalar means the
                // e-kar is misplaced (e.g. `iaung` → `အီောင်` puts
                // `1031` after `102E`, making it an orphan with no base
                // of its own). Task 01.
                if current == 0x1031, isDependentVowel(w), w != 0x1031 {
                    return false
                }
                // U+1037 (creaky tone) and U+1038 (visarga / heavy tone)
                // close the syllable. Any attachable mark walked back
                // across them has no anchor in the syllable that
                // produced the tone marker — the user has typed a
                // following onset-less syllable whose dep-vowel /
                // medial would land on the previous base, producing
                // shapes like `သားီ` / `သားောင်`. Task 01.
                if w == 0x1037 || w == 0x1038 {
                    return false
                }
                if current == 0x1031 && w == 0x1031 {
                    return false
                }
                // Reject "dep vowel of category X stacked on a base
                // already carrying a dep vowel of category X" — no
                // Burmese syllable carries two `i`-family marks, two
                // `u`-family marks, etc. on the same consonant. The
                // multi-scalar `o` cluster (`102D 102F`) crosses
                // categories so it is unaffected. Task 02.
                if currentCategory != 0,
                   isDependentVowel(w),
                   depVowelCategory(w) == currentCategory {
                    return false
                }
                // Cross-category dep-vowel allow-list (TASK-028). On a
                // single consonant anchor Burmese permits exactly two
                // multi-scalar dep-vowel cluster shapes:
                //   - `102D 102F` (the "o" / "ou" cluster — i + u),
                //   - `1031 102B` / `1031 102C` (leading e-kar Unicode
                //     storage order for the `aw` / `aung` / `aing`
                //     family — only the aa-family scalars `102B` /
                //     `102C` may follow `1031` on the same anchor).
                //
                // TASK-053: the previous shape of this rule excluded
                // `currentCategory == 4` and `wCategory == 4` from the
                // walk, which permitted any non-aa dep-vowel to walk
                // back over an `1031` predecessor (`kayoo` →
                // `1000 1031 102D 102F`, `kayee` → `1000 1031 102E`,
                // …). Narrow the carve-out so only an aa-family
                // (cat 1) walking back over `1031` is admitted; every
                // other cross-category walk reaching a `1031`
                // predecessor must reject. Same-category dep-vowels
                // are already rejected by the rule above.
                if currentCategory != 0,
                   isDependentVowel(w),
                   depVowelCategory(w) != currentCategory,
                   depVowelCategory(w) != 0 {
                    let isOClusterUpstream = (w == 0x102D && current == 0x102F)
                    let isAungUpstream = (w == 0x1031 && currentCategory == 1)
                    if !(isOClusterUpstream || isAungUpstream) {
                        return false
                    }
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
                // TASK-055: a dependent vowel sitting between the asat
                // and the consonant base is NOT generally skippable.
                // The only legal `<C><dep-vowel><103A>` shape is the
                // `aw`-cluster `<C><1031><102B|102C><103A>` — every
                // other dep-vowel (short/long i, short/long u, the
                // o-cluster `102D 102F`, lone aa `102B|102C`, lone
                // e-kar `1031` without aa, the ai-vowel `1032`) does
                // not legitimately take a trailing asat. The walk
                // therefore handles dep-vowels via a structured
                // window check: peel the optional aw-cluster, then
                // continue through medials / U+1036 to the consonant
                // base.
                if j >= 0 {
                    let w0 = indices[j].value
                    if w0 >= 0x102B && w0 <= 0x1032 {
                        // Try the aw-cluster: `1031 (102B|102C) 103A`.
                        if (w0 == 0x102B || w0 == 0x102C),
                           j >= 1, indices[j - 1].value == 0x1031 {
                            // Walked across the aw-cluster; resume the
                            // medial/anusvara walk from before `1031`.
                            j -= 2
                        } else {
                            // Any other dep-vowel before the asat —
                            // including short/long i (102D/E),
                            // short/long u (102F/30), the o-cluster
                            // (102D 102F), bare aa (102B/C without
                            // 1031), bare e-kar (1031 with no aa),
                            // and the ai-vowel (1032) — yields a
                            // malformed `<C><dep-vowel><103A>` shape.
                            return false
                        }
                    }
                }
                while j >= 0 {
                    let w = indices[j].value
                    // Visarga U+1038 closes the syllable — its legal
                    // co-occurrence with asat is `<C> 103A 1038`
                    // (visarga AFTER asat, TASK-023). Encountering
                    // `1038 103A` in a backward walk means the asat
                    // is trailing a tone-closed cluster with no legal
                    // anchor (`1000 102C 1038 103A` / `ကား်`). Reject.
                    if w == 0x1038 {
                        return false
                    }
                    // Creaky U+1037 may legitimately precede the asat
                    // ONLY in the stop-coda shape `<C> 1037 103A`
                    // (TASK-023) — i.e. the scalar immediately before
                    // the creaky must be a consonant base. When the
                    // creaky follows a dep-vowel, medial, or other
                    // mark, the cluster has already received its
                    // closing tone and the trailing asat has no
                    // anchor (`1000 102C 1037 103A` / `ကာ့်` —
                    // tone-closed `kar.` cannot accept a trailing
                    // asat). The chained legal form `<C-base> <C-base>
                    // 1037 103A` (e.g. `kan.` → `1000 1014 1037
                    // 103A`) keeps working because j-1 is `1014`, a
                    // consonant base. Task 48.
                    if w == 0x1037 {
                        if j >= 1, isConsonantBase(indices[j - 1].value) {
                            j -= 1
                            continue
                        }
                        return false
                    }
                    // After the structured aw-cluster peel above,
                    // dep-vowels in the U+102B..U+1032 range cannot
                    // legitimately appear between the asat and the
                    // base. Reject any encountered here.
                    if w >= 0x102B && w <= 0x1032 {
                        return false
                    }
                    let isSkippable = w == 0x1036
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
                // TASK-041: reject `<dep-vowel><indep-vowel><bare-C>`
                // where the trailing consonant base is "bare" — at
                // the end of the surface or followed only by
                // another consonant base (no dep-vowel, medial,
                // virama, asat, or tone mark giving it a syllable
                // structure of its own). The `thoun` family
                // (`101E 102D 102F 1026 1014`) is the canonical
                // bug shape — `1014` is at the surface end with
                // no following scalar.
                //
                // Legitimate multi-syllable spellings whose trailing
                // consonant has its OWN dep-vowel / coda
                // (`rarthiu.tu` → `101B 102C 101E 102E 1025 1010
                // 1030` — the trailing `တ` is followed by `1030`
                // which makes it a real syllable) pass through
                // unchanged.
                //
                // Legitimate two-syllable shapes ending at the
                // indep-vowel (`thiu` → `101E 102E 1026`,
                // `rarthiu` → `101B 102C 101E 102E 1026`) also
                // pass: there is no consonant after the indep-vowel.
                if i >= 1, i + 1 < n {
                    let prev = indices[i - 1].value
                    let next = indices[i + 1].value
                    let prevIsDepVowel = prev >= 0x102B && prev <= 0x1032
                    let nextIsConsonantBase =
                        (next >= 0x1000 && next <= 0x1021) || next == 0x103F
                    if prevIsDepVowel && nextIsConsonantBase {
                        // Examine what follows the consonant. A
                        // dep-vowel, medial, virama, asat, or tone
                        // mark immediately after means the
                        // consonant is the base of a real
                        // (possibly closed) syllable — fine.
                        let hasFollowing = i + 2 < n
                        let followingIsAttachable: Bool
                        if hasFollowing {
                            let after = indices[i + 2].value
                            followingIsAttachable =
                                (after >= 0x102B && after <= 0x1032)
                                || (after >= 0x1036 && after <= 0x1038)
                                || (after >= 0x103B && after <= 0x103E)
                                || after == 0x103A
                                || after == 0x1039
                        } else {
                            followingIsAttachable = false
                        }
                        if !followingIsAttachable {
                            return false
                        }
                    }
                }
                // TASK-044: reject `<consonant-base><dep-vowel-run
                // length ≥ 2><indep-vowel>` whether or not anything
                // follows the indep-vowel. The TASK-041 rule above
                // requires `i + 1 < n` (a trailing scalar after the
                // indep-vowel) to gate against the legitimate
                // single-scalar dep-vowel + indep-vowel particle
                // ending (`thiu` → `101E 102E 1026`, `rarthiu` →
                // `101B 102C 101E 102E 1026`). The dep-vowel run
                // length distinguishes the bug class:
                //
                //   - run length 1 (`102E` long-i, `102C` aa, …):
                //     legitimate two-syllable particle ending where
                //     the previous syllable closes implicitly with
                //     the consonant + single dep-vowel before the
                //     fresh `ဦ` particle.
                //   - run length ≥ 2 (`102D 102F` `o`-cluster, the
                //     same shape that triggers TASK-041 mid-buffer):
                //     two base anchors (the consonant + the indep-
                //     vowel) joined only by a multi-scalar dep-vowel
                //     cluster on a single open syllable. No legal
                //     Burmese spelling produces this shape.
                //
                // Walks back from the indep-vowel skipping medials
                // (`103B..103E`) and tone marks (`1036..1038`); the
                // dep-vowel run ends on the first non-dep-vowel
                // scalar. The walk stops at U+103A asat (which
                // closes a cluster) or U+1039 virama (which
                // terminates the open cluster) — neither is reached
                // in the bug class because the consonant + dep-vowel
                // run is uninterrupted.
                if i >= 2 {
                    var depVowelCount = 0
                    var k = i - 1
                    var foundConsonantBase = false
                    while k >= 0 {
                        let w = indices[k].value
                        if w >= 0x102B && w <= 0x1032 {
                            depVowelCount += 1
                            k -= 1
                            continue
                        }
                        if (w >= 0x1036 && w <= 0x1038)
                            || (w >= 0x103B && w <= 0x103E) {
                            // Skip medials and tone marks; they don't
                            // count toward the dep-vowel run length
                            // but do not break the open cluster.
                            k -= 1
                            continue
                        }
                        if (w >= 0x1000 && w <= 0x1021) || w == 0x103F {
                            foundConsonantBase = true
                        }
                        // Any other scalar (asat, virama, indep-
                        // vowel, format control, …) breaks the open
                        // cluster.
                        break
                    }
                    if foundConsonantBase && depVowelCount >= 2 {
                        return false
                    }
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
    ///
    /// +5 per "aspirated digraph split": `<unaspirated-stop> 103A 101F`
    /// or `<unaspirated-stop> 1039 101F`. The user typed an aspirated
    /// digraph (`kh`, `gh`, `dh`, `ph`, `th`) and the parser materialised
    /// the closed-syllable + standalone-ha reading instead of the single
    /// aspirated consonant (`ခ`, `ဃ`, `ဓ`, `ဖ`, `သ`). When both readings
    /// score equally on the DP — common because the structural cost is
    /// identical — the rarity penalty tips the digraph sibling to the
    /// top of the panel. See task 02.
    internal static func computeRarityPenalty(_ output: String) -> Int {
        var penalty = 0
        let scalars = Array(output.unicodeScalars)
        for i in 0..<scalars.count {
            let v = scalars[i].value
            // Retroflex consonants: ဋ ဌ ဍ ဎ ဏ ဠ
            if v == 0x100B || v == 0x100C || v == 0x100D
                || v == 0x100E || v == 0x100F || v == 0x1020 {
                penalty += 1
            }
            // Aspirated-digraph split: stop + (asat|virama) + ha. Stops
            // listed are exactly the ones whose `<stop>+h` romanization
            // forms a single Myanmar consonant (`kh`→ခ, `gh`→ဃ, `th`→သ,
            // `dh`→ဓ, `ph`→ဖ). Other consonants (`m`, `n`, `l`, `r`,
            // `y`, `w`) have no such digraph rule, so a closed
            // <C>+asat+ha there is legitimate spelling and is left
            // unpenalised.
            if i + 2 < scalars.count,
               isAspiratedDigraphSplitStop(v),
               (scalars[i + 1].value == 0x103A || scalars[i + 1].value == 0x1039),
               scalars[i + 2].value == 0x101F {
                penalty += 5
            }
            // Doubled-nga artifact (task 02): `1004 103A 1004` (င် င)
            // appears when the parser splits a user's `aing<X>` into
            // `ai`-rule (which already supplies the nga-asat coda)
            // plus a stranded bare nga consonant from the trailing
            // `ng`. Real Burmese never spells two nga in succession
            // like this — the second nga is always either part of a
            // kinzi stack (1039 1004) or absent. Demote so the
            // diphthong-anchored sibling wins the rank-0 spot. Only
            // applies when the trailing nga is followed by a vowel
            // sign or end-of-string (so genuine 2-syllable shapes
            // like `<...>င် င<rest of word>` aren't penalised).
            if i + 2 < scalars.count,
               v == 0x1004,
               scalars[i + 1].value == 0x103A,
               scalars[i + 2].value == 0x1004 {
                let after = i + 3
                let nextValue: UInt32 = after < scalars.count ? scalars[after].value : 0
                let nextIsAttachableMark =
                    (nextValue >= 0x102B && nextValue <= 0x103E)
                if after >= scalars.count || nextIsAttachableMark {
                    penalty += 5
                }
            }
        }
        return penalty
    }

    @inline(__always)
    private static func isAspiratedDigraphSplitStop(_ v: UInt32) -> Bool {
        // ka(1000) → kha(1001), ga(1002) → gha(1003),
        // ta(1010) → sa(101E, the `th` digraph),
        // da(1012) → dha(1013), pa(1015) → pha(1016).
        return v == 0x1000 || v == 0x1002 || v == 0x1010
            || v == 0x1012 || v == 0x1015
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
    /// survive finalizing pre-filters. Also returns the per-arc cumulative
    /// `(charEnd, scalarOffset)` boundaries so downstream callers can map
    /// input character offsets to output scalar positions (TASK-002).
    internal func materialize(
        stateIdx: Int32,
        arena: [ParseState],
        promoteLeadingA: Bool = true
    ) -> (output: String, reading: String, arcBoundaries: [SyllableParse.ArcBoundary]) {
        var refs: [MatchRef] = []
        var charEnds: [Int] = []
        var cur = stateIdx
        while cur >= 0 {
            let state = arena[Int(cur)]
            refs.append(state.matchRef)
            charEnds.append(Int(state.charEnd))
            cur = state.parentIdx
        }
        refs.reverse()
        charEnds.reverse()

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
        // Pre-postprocess arc boundaries: tracks `(charEnd, scalarOffset)`
        // after each contributing arc against the raw `output` string.
        // Post-processing (`canonicalizeMedialOrder`,
        // `stripSpuriousAsatBeforeVirama`) is applied at the end and the
        // scalar offsets are then re-mapped through those passes so the
        // boundaries align with the returned (post-processed) surface.
        //
        // When the leading-A promotion fires inside a non-inherent-A arc,
        // the prepended U+1021 logically belongs to the *preceding*
        // inherent-`a` arc (whose empty output left the syllable
        // visually invisible). Bump the previous boundary's scalarOffset
        // to include the U+1021 so the user's mental model "char 1
        // emits `အ`" is preserved (otherwise `a1b` splices the digit at
        // the start of the surface — TASK-002 follow-up).
        var rawBoundaries: [SyllableParse.ArcBoundary] = []
        rawBoundaries.append(SyllableParse.ArcBoundary(charEnd: 0, scalarOffset: 0))
        for (refIndex, ref) in refs.enumerated() {
            switch ref {
            case .seed, .skip:
                continue
            case .onsetOnly(let onsetId):
                let entry = onsetTerminals[Int(onsetId)]
                if promoteLeadingA && !promotedLeadingA && output.isEmpty && sawLeadingA {
                    output.unicodeScalars.append(Unicode.Scalar(0x1021)!)
                    promotedLeadingA = true
                    Self.bumpLastInherentABoundary(&rawBoundaries)
                }
                output.append(entry.myanmar)
                reading.append(entry.canonicalRoman)
                reading.append("a")
                rawBoundaries.append(SyllableParse.ArcBoundary(
                    charEnd: charEnds[refIndex],
                    scalarOffset: output.unicodeScalars.count
                ))
            case .onsetVowel(let onsetId, let vowelId):
                let onset = onsetTerminals[Int(onsetId)]
                let vowel = vowelTerminals[Int(vowelId)]
                if promoteLeadingA && !promotedLeadingA && output.isEmpty && sawLeadingA {
                    output.unicodeScalars.append(Unicode.Scalar(0x1021)!)
                    promotedLeadingA = true
                    Self.bumpLastInherentABoundary(&rawBoundaries)
                }
                output.append(onset.myanmar)
                output.append(vowel.myanmar)
                reading.append(onset.canonicalRoman)
                reading.append(vowel.canonicalRoman)
                rawBoundaries.append(SyllableParse.ArcBoundary(
                    charEnd: charEnds[refIndex],
                    scalarOffset: output.unicodeScalars.count
                ))
            case .vowelOnly(let vowelId):
                let entry = vowelTerminals[Int(vowelId)]
                let isInherentA = entry.canonicalRoman == "a" && entry.myanmar.isEmpty
                if promoteLeadingA && !promotedLeadingA && output.isEmpty && !isInherentA {
                    // Existing case: a prior inherent-`a` ref ran (e.g.
                    // `aan`, `aaung`) and the next ref needs an `အ`
                    // anchor on top of the empty output. Extended case
                    // (task 02): the buffer enters a vowel-only rule
                    // directly with no preceding inherent-`a` and the
                    // rule's Myanmar output starts with a consonant
                    // base (`an` → `န်`, `in` → `င်`, `e` → `ယ်`).
                    // Standalone these are stranded codas — Burmese
                    // spells them with an `အ` base (အန်, အင်, အယ်).
                    let firstScalarIsConsonantBase = entry.myanmar
                        .unicodeScalars.first.map {
                            $0.value >= 0x1000 && $0.value <= 0x1021
                        } ?? false
                    if sawLeadingA || firstScalarIsConsonantBase {
                        output.unicodeScalars.append(Unicode.Scalar(0x1021)!)
                        promotedLeadingA = true
                        Self.bumpLastInherentABoundary(&rawBoundaries)
                    }
                }
                // TASK-046: orphan dep-vowel anchor on a chained
                // bare-diphthong-rule repetition. The previous-
                // syllable closer + new-syllable dep-vowel pattern
                // shows up when the user repeats a bare diphthong
                // rule (`aing` / `aung` / `ai`): syllable 1 lands
                // the rule's full dep-vowel cluster (with the
                // engine's `adjustLeadingVowel` ZWNJ prefix /
                // `promoteOrphanZwnjToImplicitA` post-process
                // covering the buffer head), and syllable 2's
                // `vowelOnly` arc lands directly after the prior
                // syllable's asat closer (U+103A). Without an
                // anchor injection, the dep-vowel cluster
                // concatenates onto the asat closer, producing
                // orthographically illegal shapes like
                // `အောင်ောင်ေါင်` (orphan e-kar after the first
                // syllable's asat).
                //
                // Trigger: previous arc's emission was a "diphthong
                // shape" — at least four scalars ending in
                // `<consonant base> 103A` with a dep-vowel scalar
                // inside the cluster — AND this `vowelOnly` arc
                // starts with a dep-vowel scalar. Narrowing to the
                // diphthong shape avoids firing on shorter
                // closed-syllable rules like `an` (`1014 103A`,
                // 2 scalars, no internal dep-vowel) where the
                // injected anchor would legalise an unintended
                // parse like `an+ar → အန်အာ` and displace the
                // user-respecting `a+nar → အနာ` interpretation.
                let outputScalars = output.unicodeScalars
                let firstScalarIsDepVowel = entry.myanmar
                    .unicodeScalars.first.map {
                        $0.value >= 0x102B && $0.value <= 0x1032
                    } ?? false
                let prevWasDiphthongShape = Self.outputEndsWithBareDiphthongShape(outputScalars)
                if prevWasDiphthongShape && firstScalarIsDepVowel && !isInherentA {
                    output.unicodeScalars.append(Unicode.Scalar(0x1021)!)
                }
                // TASK-047: a user-typed `+` between a syllable and a
                // following bare vowel-rule (`aung`, `aing`, `i`, …)
                // must materialise as a hard syllable boundary, not a
                // soft separator that silently lets the new rule
                // consume the previous syllable's onset / inherent
                // vowel as its own onset. The parser's soft-`+` arc
                // emits empty Myanmar surface, and the next bare
                // vowel-rule's dep-vowel cluster lands directly on
                // the previous consonant base — turning user input
                // `ka+aung` into a single-syllable `ကောင်` instead of
                // the two-syllable `ကအောင်` the user typed for.
                //
                // Inject U+1021 when the immediately-preceding arc
                // was the soft-`+` form (canonical roman `+`, empty
                // Myanmar emission) AND this `vowelOnly` arc starts
                // with a dep-vowel scalar. The buffer-head case is
                // governed by the existing leading-A promotion above
                // and is not affected by this rule.
                let prevWasSoftPlus: Bool = {
                    guard refIndex >= 1 else { return false }
                    if case let .vowelOnly(prevVowelId) = refs[refIndex - 1] {
                        return prevVowelId == softBoundaryViramaVowelId
                    }
                    return false
                }()
                if prevWasSoftPlus && firstScalarIsDepVowel && !isInherentA {
                    output.unicodeScalars.append(Unicode.Scalar(0x1021)!)
                }
                output.append(entry.myanmar)
                reading.append(entry.canonicalRoman)
                if isInherentA {
                    sawLeadingA = true
                }
                rawBoundaries.append(SyllableParse.ArcBoundary(
                    charEnd: charEnds[refIndex],
                    scalarOffset: output.unicodeScalars.count
                ))
            }
        }
        let canonicalized = Self.canonicalizeMedialOrder(output)
        let canonicalizedBoundaries = Self.remapBoundariesAfterCanonicalize(
            raw: output, processed: canonicalized, boundaries: rawBoundaries
        )
        let stripped = Self.stripSpuriousAsatBeforeVirama(canonicalized)
        let strippedBoundaries = Self.remapBoundariesAfterStripAsat(
            raw: canonicalized, processed: stripped, boundaries: canonicalizedBoundaries
        )
        let collapsed = Self.collapseDoubledAsat(stripped)
        let collapsedBoundaries = Self.remapBoundariesAfterStripAsat(
            raw: stripped, processed: collapsed, boundaries: strippedBoundaries
        )
        return (collapsed, reading, collapsedBoundaries)
    }

    /// TASK-046: true when `outputScalars` ends with a bare-diphthong
    /// shape — at least four scalars, ending with `<nga> 103A` (the
    /// nga-asat coda emitted by the `aing` / `aung` / `ai` family
    /// rules), with at least one dependent-vowel scalar
    /// (U+102B..U+1032) in the cluster before the nga base. The
    /// narrow `nga` (U+1004) check excludes shapes like `o2`
    /// (`102D 102F 101A 103A`) and `e2` (`101A 103A`) where the
    /// chain-boundary anchor injection would mis-interpret a
    /// ya-asat-coda variant as a fresh diphthong-syllable boundary.
    internal static func outputEndsWithBareDiphthongShape(
        _ outputScalars: String.UnicodeScalarView
    ) -> Bool {
        let arr = Array(outputScalars)
        guard arr.count >= 4 else { return false }
        guard arr[arr.count - 1].value == 0x103A else { return false }
        guard arr[arr.count - 2].value == 0x1004 else { return false }
        // Walk backward from arr.count - 3 looking for a dep-vowel
        // scalar in the syllable's cluster. A new syllable boundary
        // (consonant base, indep vowel, ZWNJ, virama) terminates
        // the scan.
        var i = arr.count - 3
        while i >= 0 {
            let v = arr[i].value
            if v >= 0x102B && v <= 0x1032 { return true }
            // Reached the syllable's onset / a previous syllable's
            // closer; bail out — no dep vowel in this syllable's
            // cluster.
            if (v >= 0x1000 && v <= 0x1021) || v == 0x103F { return false }
            if v >= 0x1023 && v <= 0x102A { return false }
            if v == 0x200C || v == 0x1039 { return false }
            i -= 1
        }
        return false
    }

    /// Collapse runs of consecutive U+103A asat scalars to a single
    /// asat. The DP can pair up an asat-bearing vowel rule (e.g.
    /// `aw` → `ော်` ending in `103A`, `aung` → `ောင်` ending in
    /// `103A`) with a redundant trailing `*` that the user typed,
    /// emitting `<C><…>103A 103A` in the materialised surface. Each
    /// `103A` past the first is structurally redundant — they all
    /// suppress the same inherent vowel — and the chain fails the
    /// post-finalize legality scan. Collapsing the run to a single
    /// asat preserves the user's syllable closure intent and lets
    /// the asat-after-asat-vowel-rule case (`naung*`, `kaw*`,
    /// `kyaw*ka`, `min*ka`) round-trip cleanly. The same collapse
    /// also handles the doubled-`*` (`ka**`) case the existing
    /// `RedundantExplicitAsatSuite` covered before TASK-055
    /// tightened `scanOutputLegality`.
    internal static func collapseDoubledAsat(_ text: String) -> String {
        // Fast path: scalar walk without array materialization. Most
        // surfaces never have a doubled asat — return the input
        // string verbatim with no allocation when the cheap scan
        // confirms no `103A 103A` adjacency.
        var sawDouble = false
        var prevWasAsat = false
        for scalar in text.unicodeScalars {
            if scalar.value == 0x103A {
                if prevWasAsat { sawDouble = true; break }
                prevWasAsat = true
            } else {
                prevWasAsat = false
            }
        }
        guard sawDouble else { return text }
        let scalars = Array(text.unicodeScalars)
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(scalars.count)
        for s in scalars {
            if s.value == 0x103A, output.last?.value == 0x103A {
                continue
            }
            output.append(s)
        }
        var result = ""
        result.unicodeScalars.reserveCapacity(output.count)
        for s in output {
            result.unicodeScalars.append(s)
        }
        return result
    }

    /// Used inside `materialize` when leading-A promotion fires: the
    /// prepended U+1021 belongs to the previous inherent-`a` arc (whose
    /// empty output rendered the syllable invisible). Bumping that arc's
    /// boundary scalarOffset by 1 keeps the per-char scalar count
    /// consistent with the user's mental model "the `a` produces `အ`".
    /// Walks back to the most recent boundary whose scalarOffset matches
    /// the previous boundary's (i.e. the empty-emission arc) and
    /// increments it.
    private static func bumpLastInherentABoundary(
        _ boundaries: inout [SyllableParse.ArcBoundary]
    ) {
        // The leading-A promotion only fires once. The U+1021 was
        // appended at the current end of `output`; the most recent
        // boundary records the scalarOffset *before* this appended
        // scalar. Increment it so the leading-A is attributed to the
        // preceding inherent-`a` arc.
        guard let last = boundaries.last else { return }
        boundaries[boundaries.count - 1] = SyllableParse.ArcBoundary(
            charEnd: last.charEnd,
            scalarOffset: last.scalarOffset + 1
        )
    }

    /// `canonicalizeMedialOrder` only re-orders / dedupes scalars within
    /// medial runs (U+103B..U+103E). It does not move scalars across arc
    /// boundaries: each arc emits its medials adjacent to its base, so a
    /// medial run that crosses an arc boundary is rare. The pre-/post-
    /// scalar-counts within each prefix range can drift by ±1 when a
    /// duplicate medial collapses, so we translate each boundary's
    /// scalar offset by tracking how many scalars the canonicalize pass
    /// dropped at or before that offset in the raw string.
    internal static func remapBoundariesAfterCanonicalize(
        raw: String,
        processed: String,
        boundaries: [SyllableParse.ArcBoundary]
    ) -> [SyllableParse.ArcBoundary] {
        if raw == processed { return boundaries }
        // The transformation only deletes (de-dupes) within medial runs.
        // Walk both strings, accumulate the per-prefix delete count, and
        // adjust each boundary's scalar offset.
        let rawScalars = Array(raw.unicodeScalars)
        let processedScalars = Array(processed.unicodeScalars)
        // Per-raw-offset, the number of scalars dropped at offsets
        // strictly before that offset. dropMap[i] = scalars dropped in
        // raw[0..<i]. Length = rawScalars.count + 1.
        var dropMap: [Int] = Array(repeating: 0, count: rawScalars.count + 1)
        var processedIdx = 0
        var dropped = 0
        for i in 0..<rawScalars.count {
            dropMap[i] = dropped
            if processedIdx < processedScalars.count,
               rawScalars[i] == processedScalars[processedIdx] {
                processedIdx += 1
            } else {
                dropped += 1
            }
        }
        dropMap[rawScalars.count] = dropped
        return boundaries.map {
            let offset = max(0, min($0.scalarOffset, rawScalars.count))
            return SyllableParse.ArcBoundary(
                charEnd: $0.charEnd,
                scalarOffset: $0.scalarOffset - dropMap[offset]
            )
        }
    }

    /// `stripSpuriousAsatBeforeVirama` removes asat (U+103A) scalars that
    /// precede a virama (U+1039) when the asat's base is not nga.
    /// Mirrors `remapBoundariesAfterCanonicalize` — pure deletion, so
    /// remapping is an offset-by-drop-count.
    internal static func remapBoundariesAfterStripAsat(
        raw: String,
        processed: String,
        boundaries: [SyllableParse.ArcBoundary]
    ) -> [SyllableParse.ArcBoundary] {
        if raw == processed { return boundaries }
        let rawScalars = Array(raw.unicodeScalars)
        let processedScalars = Array(processed.unicodeScalars)
        var dropMap: [Int] = Array(repeating: 0, count: rawScalars.count + 1)
        var processedIdx = 0
        var dropped = 0
        for i in 0..<rawScalars.count {
            dropMap[i] = dropped
            if processedIdx < processedScalars.count,
               rawScalars[i] == processedScalars[processedIdx] {
                processedIdx += 1
            } else {
                dropped += 1
            }
        }
        dropMap[rawScalars.count] = dropped
        return boundaries.map {
            let offset = max(0, min($0.scalarOffset, rawScalars.count))
            return SyllableParse.ArcBoundary(
                charEnd: $0.charEnd,
                scalarOffset: $0.scalarOffset - dropMap[offset]
            )
        }
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
        // Task 04: when every DP factor ties, prefer the parse whose
        // surface emits more scalars. The canonical case is the
        // `aing` competition where `ai + ng` (diphthong + bare nga →
        // 5 surface scalars) ties with `ain + g` (short-i + na-asat +
        // bare ga → 4 scalars) on consumed-vs-rule-count and alias
        // cost; without this tip, output-lexicographic ordering
        // arbitrarily picks the shorter `ain` decomposition. A richer
        // surface tends to mean the parser used a longer single
        // vowel arc and therefore matched a more specific
        // orthographic shape.
        let lhsScalarCount = lhs.output.unicodeScalars.count
        let rhsScalarCount = rhs.output.unicodeScalars.count
        if lhsScalarCount != rhsScalarCount {
            return lhsScalarCount > rhsScalarCount
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
        // See task 04 note in the marker-penalty overload above —
        // richer-surface tiebreak applies here too.
        let lhsScalarCount = lhs.output.unicodeScalars.count
        let rhsScalarCount = rhs.output.unicodeScalars.count
        if lhsScalarCount != rhsScalarCount {
            return lhsScalarCount > rhsScalarCount
        }
        if lhs.output != rhs.output {
            return lhs.output < rhs.output
        }
        return lhs.reading < rhs.reading
    }
}
