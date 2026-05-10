import Foundation

extension BurmeseEngine {

    /// Top-K LM-scored renderings of the frozen prefix. Caching K branches
    /// (instead of a single rendering) lets the engine surface alternative
    /// interpretations of the locked-in prefix in the candidate panel:
    /// each branch combines with each tail parse, and the overall LM score
    /// of (branch + tail) decides ranking.
    internal struct FrozenPrefixBranch {
        let output: String
        let reading: String
        let lmScore: Double
        /// Pre-tokenized branch words used as LM context for the tail.
        let contextWords: [String]
    }

    internal struct FrozenPrefixCache {
        var input: String
        var branches: [FrozenPrefixBranch]
    }

    /// Anchor remembered across `update()` calls to keep the rendered
    /// prefix stable. When the new normalized buffer extends the anchor's
    /// `normalized`, any candidate whose surface starts with the anchor's
    /// `surface` is promoted to the top — so the already-visible rendering
    /// of the typed-so-far portion doesn't drift as the user adds more
    /// characters. Cleared when the buffer no longer extends the anchor
    /// (e.g. backspace past it, or a new composition).
    internal struct PrefixAnchor {
        let normalized: String
        let surface: String
        let reading: String
    }

    /// Call-scoped memo key for LM `scoreSurface` lookups.
    internal struct LMScoreKey: Hashable {
        let surface: String
        let context: [String]
    }

    internal static let frozenPrefixCacheCapacity = 8

    /// Number of frozen-prefix branches kept and combined with each
    /// tail parse. Higher = more chances to recover from a parser-favored
    /// but LM-disfavored prefix; cost scales linearly in tail-merge work.
    internal static let frozenPrefixBranchCount = 1

    /// Pool of parser N-best parses considered for the frozen prefix
    /// before LM-rescoring picks the top-K branches.
    internal static let frozenPrefixCandidatePool = 16

    internal func renderFrozenPrefixBranches(
        _ prefix: String,
        baseContext: [String],
        lmCache: inout [LMScoreKey: Double]
    ) -> [FrozenPrefixBranch] {
        cacheLock.lock()
        if let hitIdx = prefixCache.firstIndex(where: { $0.input == prefix }) {
            let entry = prefixCache.remove(at: hitIdx)
            prefixCache.insert(entry, at: 0)
            let branches = entry.branches
            cacheLock.unlock()
            return branches
        }
        cacheLock.unlock()

        var parses = parser.parseCandidates(prefix, maxResults: Self.frozenPrefixCandidatePool)
        // Ya-pin disambiguator alt-parse for the frozen prefix. Mirrors
        // the engine-level merge in `BurmeseEngine.update`: once the
        // buffer crosses `compositionWindowSize` the user-visible
        // rendering is single-best from this prefix's parse pool, and
        // the DP's aliasCost-first ordering prunes ya-pin out of the
        // N-best (`kwy2…` carries an extra alias-cost digit). Forcing
        // a parallel parse with the digit-suffixed form lifts the
        // ya-pin onset back into the pool so the LM rescoring below
        // can pick the corpus-dominant rendering. Without this,
        // `kwyantawkahtamin:masar:` and similar "I…" sentences lock
        // the wrong cluster (`ကြွ`) into every windowed candidate.
        if let disambiguated = Self.yaPinDisambiguatedInput(prefix) {
            let disambiguatedParses = parser.parseCandidates(
                disambiguated,
                maxResults: Self.frozenPrefixCandidatePool
            )
            let existingOutputs = Set(parses.map(\.output))
            for parse in disambiguatedParses where !existingOutputs.contains(parse.output) {
                parses.append(parse)
            }
        }
        // Apply the same orphan-mark promotions the main pipeline runs on
        // its grammar parses (BurmeseEngine.swift ~700-717). Without this,
        // a frozen prefix composed entirely of bare-vowel syllables whose
        // parser surface starts with U+200C (or carries a mid-surface
        // orphan mark) leaks ZWNJ into every windowed candidate — the
        // downstream `sanitizeOrphanZwnj` filter is a no-op when no clean
        // sibling exists, so the promotion has to happen here, before
        // branches are LM-scored and fanned out across tail parses.
        // See task 03.
        let originalCount = parses.count
        for i in 0..<originalCount {
            let parent = parses[i]
            let zwnjPromoted = Self.promoteOrphanZwnjToImplicitA(parent)
            if let zwnjPromoted {
                parses.append(zwnjPromoted)
            }
            if let promoted = Self.promoteOrphanInternalMarks(parent) {
                parses.append(promoted)
            }
            if let zwnjPromoted,
               let promoted = Self.promoteOrphanInternalMarks(zwnjPromoted) {
                parses.append(promoted)
            }
        }
        var strictInferredStackOutputs: Set<String> = []
        if let inferred = Self.inferImplicitStackMarkers(prefix) {
            let existingOutputs = Set(parses.map(\.output))
            var liberalKinziOutputs: Set<String> = []
            ingestInferredParses(
                input: inferred.input,
                insertions: inferred.insertions,
                liberalInsertions: inferred.liberalInsertions,
                vowelRuleLiberalInsertions: inferred.vowelRuleLiberalInsertions,
                isFullBuffer: true,
                grammarParses: &parses,
                existingOutputs: existingOutputs,
                strictInferredStackOutputs: &strictInferredStackOutputs,
                liberalKinziOutputs: &liberalKinziOutputs
            )
            if let strictOnly = inferred.strictOnlyInput {
                let outputsAfterFull = Set(parses.map(\.output))
                ingestInferredParses(
                    input: strictOnly,
                    insertions: inferred.strictOnlyInsertions,
                    liberalInsertions: 0,
                    vowelRuleLiberalInsertions: 0,
                    isFullBuffer: true,
                    grammarParses: &parses,
                    existingOutputs: outputsAfterFull,
                    strictInferredStackOutputs: &strictInferredStackOutputs,
                    liberalKinziOutputs: &liberalKinziOutputs
                )
            }
            // TASK-006: also inject the promotable-only sibling so a
            // frozen prefix carrying both a kinzi site and a bug-class
            // N+T site (e.g. `thingyantar...`) keeps the kinzi-bearing
            // surface in `strictInferredStackOutputs` for downstream
            // rank-0 promotion.
            if let promotableOnly = inferred.promotableOnlyInput {
                let outputsAfterStrict = Set(parses.map(\.output))
                ingestInferredParses(
                    input: promotableOnly,
                    insertions: inferred.promotableOnlyInsertions,
                    liberalInsertions: 0,
                    vowelRuleLiberalInsertions: 0,
                    isFullBuffer: true,
                    grammarParses: &parses,
                    existingOutputs: outputsAfterStrict,
                    strictInferredStackOutputs: &strictInferredStackOutputs,
                    liberalKinziOutputs: &liberalKinziOutputs
                )
            }
            // liberalKinziOutputs is intentionally not merged into
            // strictInferredStackOutputs here — the frozen prefix renders
            // the open form as its single best surface; liberal kinzi
            // demotion via rarityPenalty achieves that without promotion.
        }
        let branches: [FrozenPrefixBranch]
        if parses.isEmpty {
            branches = [FrozenPrefixBranch(
                output: prefix,
                reading: prefix,
                lmScore: scoreSurfaceCached(prefix, context: baseContext, cache: &lmCache),
                contextWords: [prefix]
            )]
        } else {
            // Dedup parses by output (different parses can render identically),
            // score each via the LM, sort high-to-low, keep top K.
            var seen: Set<String> = []
            var scored: [(branch: FrozenPrefixBranch, isOOV: Bool, isStrictInferredStack: Bool, isYaPinPromoted: Bool)] = []
            let unkFloor = languageModel.unknownLogProb
            let oovEpsilon = 0.01
            // When the prefix starts with a `yaPinPreferredOnsetClusters`
            // entry, the cluster table (CandidateRanking.swift) treats
            // ya-pin as the corpus-dominant rendering. Mark the
            // disambiguator-injected ya-pin parses so the sort below can
            // tiebreak in their favor — without it, two-syllable cold-
            // start prefixes (e.g. `kwyan`) tie on isOOV/lmScore because
            // both `ကြွန်` and `ကျွန်` are partial words, and the
            // arbitrary tied-sort order can lock the wrong cluster
            // into the windowed candidate render.
            let prefersYaPin = Self.yaPinDisambiguatedInput(prefix) != nil
            for parse in parses where seen.insert(parse.output).inserted {
                let lm = scoreSurfaceCached(parse.output, context: baseContext, cache: &lmCache)
                let isOOV = unkFloor.isFinite && abs(lm - unkFloor) < oovEpsilon
                let isYaPinPromoted = prefersYaPin && Self.isYapinReading(parse.reading)
                scored.append((FrozenPrefixBranch(
                    output: parse.output,
                    reading: parse.reading,
                    lmScore: lm,
                    contextWords: baseContext + [parse.output]
                ), isOOV, strictInferredStackOutputs.contains(parse.output), isYaPinPromoted))
            }
            // OOV-aware ordering (task 04): an in-vocab parse always beats an
            // OOV parse regardless of raw LM score. The LM `<unk>` floor is
            // higher than the real log-prob of many rare-but-real Burmese
            // words, so a garbled walk that lands entirely on `<unk>` would
            // otherwise outscore the correct rare word and lock in a junk
            // frozen prefix on every subsequent keystroke. Among same-bucket
            // parses (both OOV or both in-vocab) the raw LM score still
            // decides — for in-vocab parses it is the real signal, and for
            // OOV parses it just falls through to parser order via the
            // shared floor.
            // Drop ZWNJ-prefixed branches when at least one anchored
            // sibling exists (task 03). Mirrors `sanitizeOrphanZwnj` for
            // the windowed path: with `frozenPrefixBranchCount = 1`
            // only the top-ranked branch survives, so a higher-LM
            // orphan would otherwise be the sole branch even though a
            // legality-positive promoted sibling is present.
            let hasAnchoredBranch = scored.contains { branch in
                branch.branch.output.unicodeScalars.first.map { $0.value != 0x200C } ?? false
            }
            if hasAnchoredBranch {
                scored.removeAll { branch in
                    branch.branch.output.unicodeScalars.first.map { $0.value == 0x200C } ?? false
                }
            }
            scored.sort { lhs, rhs in
                if lhs.isOOV != rhs.isOOV { return !lhs.isOOV }
                // Promotion-cluster prefixes prefer ya-pin over ya-yit
                // before falling through to the LM signal. The cluster
                // table is the authoritative ranking source for these
                // eight clusters; the LM is only a secondary tiebreaker.
                if lhs.isYaPinPromoted != rhs.isYaPinPromoted {
                    return lhs.isYaPinPromoted
                }
                if lhs.isStrictInferredStack != rhs.isStrictInferredStack {
                    return lhs.isStrictInferredStack
                }
                return lhs.branch.lmScore > rhs.branch.lmScore
            }
            // Drop branches whose LM score is far below the leader before
            // fanning out — otherwise weak prefix interpretations multiply
            // across every tail parse and flood the candidate panel.
            if let topScore = scored.first?.branch.lmScore {
                scored = scored.filter { topScore - $0.branch.lmScore <= lmPruneMargin }
            }
            branches = Array(scored.prefix(Self.frozenPrefixBranchCount).map(\.branch))
        }

        cacheLock.lock()
        prefixCache.removeAll(where: { $0.input == prefix })
        prefixCache.insert(FrozenPrefixCache(input: prefix, branches: branches), at: 0)
        if prefixCache.count > Self.frozenPrefixCacheCapacity {
            prefixCache.removeLast(prefixCache.count - Self.frozenPrefixCacheCapacity)
        }
        cacheLock.unlock()
        return branches
    }

    internal func scoreSurfaceCached(
        _ surface: String,
        context: [String],
        cache: inout [LMScoreKey: Double]
    ) -> Double {
        let key = LMScoreKey(surface: surface, context: context)
        if let hit = cache[key] { return hit }
        let score = languageModel.scoreSurface(surface, context: context)
        cache[key] = score
        return score
    }

    /// Find a character index in `normalized` that is safe to use as the
    /// frozen-prefix / active-tail boundary. The split is "safe" when the
    /// prefix `normalized[..<split]` parses fully legally on its own —
    /// guaranteeing it ends at a syllable boundary so the tail re-parse
    /// doesn't miss letters or invent garbage parses.
    ///
    /// Starts at `normalized.count - targetTail` and scans backward up to
    /// `targetTail` characters. If no legal split is found, returns the
    /// initial target so the engine still windows (the tail will absorb
    /// any boundary artifact).
    internal static func findSyllableSafeSplit(
        in normalized: String,
        parser: SyllableParser,
        targetTail: Int,
        lowerBound: Int = 0
    ) -> Int {
        let total = normalized.count
        let target = min(total - 1, max(total - targetTail, lowerBound))
        guard target > 0 else { return 0 }
        let chars = Array(normalized)
        // Never let the split regress below `lowerBound` — that keeps a
        // previously committed prefix from shrinking when we're forced
        // to recompute because the tail outgrew its budget.
        var scanFloor = max(1, lowerBound)
        if Self.isUnsafeFrozenSplit(chars: chars, split: scanFloor) {
            scanFloor = max(1, scanFloor - 1)
        }
        // Cap the walk-back to one syllable's worth of characters. No legal
        // syllable boundary spans more than `maxOnsetLen + maxVowelLen`, so
        // if we don't find a legal prefix within that window the buffer is
        // unparseable (garbage / keyboard bashing) — walking further just
        // burns N-best parses against a string the user isn't going to
        // keep typing. Give up and return the target split unchanged.
        let maxWalkBack = parser.maxOnsetLen + parser.maxVowelLen
        let scanLimit = max(scanFloor, target - maxWalkBack)
        if let safe = scanForSafeSplit(
            chars: chars,
            from: target,
            downTo: scanLimit,
            parser: parser
        ) {
            return safe
        }
        // TASK-005: before walking the split below the floor, try
        // walking it UP. Backward fallback can land on a split as
        // shallow as 1 (`m` for `minkyaungtharminkya`), which strands
        // the kinzi-able pair `min+ky` at the prefix-tail boundary —
        // the prefix is too short to fire `inferImplicitStackMarkers`
        // for the boundary syllable, and the tail's inference can't
        // see the upper consonant in the prefix. Scanning forward
        // from `target` (capped at one window's worth ahead) looks
        // for a larger split where the kinzi syllable lands fully
        // inside the prefix, restoring the kinzi-bearing rendering
        // for the leading syllables. Take the SMALLEST forward split
        // that is safe — minimising the active-tail size while still
        // including the boundary-stranded kinzi pair inside the
        // prefix keeps a downstream tail-internal kinzi site (e.g.
        // the second `min+ky` in `minkyaungtharminkya`) intact too.
        let forwardLimit = min(chars.count - 1, target + maxWalkBack)
        if forwardLimit > target {
            for splitCandidate in (target + 1)...forwardLimit {
                if let safe = scanForSafeSplit(
                    chars: chars,
                    from: splitCandidate,
                    downTo: splitCandidate,
                    parser: parser
                ) {
                    return safe
                }
            }
        }
        // No safe split honoured the lowerBound floor. Returning the
        // unsafe `target` would produce a structurally broken windowed
        // surface (e.g. a stray U+1021 between the prefix's trailing
        // consonant and the active tail's leading dep-vowel — TASK-002).
        // Prefer a safe split below the floor over a broken one above
        // it: any cached-prefix re-use that depended on the floor is
        // already invalid because the chosen split would corrupt the
        // candidate. Sweep down to split=1 looking for any safe site.
        if scanLimit > 1,
           let safe = scanForSafeSplit(
                chars: chars,
                from: scanLimit - 1,
                downTo: 1,
                parser: parser
           ) {
            return safe
        }
        return target
    }

    /// Walk `from` (inclusive) down to `downTo` (inclusive) looking for
    /// the first split that satisfies all three safety predicates:
    /// prefix-parses-legally, isn't an unsafe split, and produces a
    /// stable merge. Returns nil when none in the range qualify. Helper
    /// used by `findSyllableSafeSplit` so the floor and the
    /// floor-relaxed sweep share one implementation.
    private static func scanForSafeSplit(
        chars: [Character],
        from: Int,
        downTo: Int,
        parser: SyllableParser
    ) -> Int? {
        guard from >= downTo, downTo >= 1, from <= chars.count else { return nil }
        var split = from
        while split >= downTo {
            let prefix = String(chars[0..<split])
            if let parse = parser.parseCandidates(prefix, maxResults: 1).first,
               parse.legalityScore > 0,
               !Self.isUnsafeFrozenSplit(chars: chars, split: split),
               Self.splitProducesStableMerge(
                    chars: chars,
                    split: split,
                    parser: parser
               ) {
                return split
            }
            split -= 1
        }
        return nil
    }

    /// Compose-and-compare safety check (task 05). The local-legality
    /// probe in `findSyllableSafeSplit` rejects splits where the prefix
    /// alone fails to parse, but it accepts any locally-legal split —
    /// including sites that cut a clean `<onset><vowel>` syllable
    /// (e.g. `parth|ar`) the un-windowed DP would render as a single
    /// unit. When prefix and tail are then re-merged, the prefix
    /// renders the partial onset (`...သ`) and the tail re-parses the
    /// orphaned vowel (`အာ` via ZWNJ promotion), producing surfaces
    /// like `သအာ` instead of the intended `သာ`.
    ///
    /// The check parses a small window around `split` three times:
    ///   - the prefix slice,
    ///   - the tail slice,
    ///   - the full window (prefix + tail).
    /// The split is "stable" when concatenating the slice parses
    /// reproduces the full-window parse. Window size is capped at
    /// `maxOnsetLen + maxVowelLen` on each side so the work is
    /// constant per split candidate.
    private static func splitProducesStableMerge(
        chars: [Character],
        split: Int,
        parser: SyllableParser
    ) -> Bool {
        let halfWindow = parser.maxOnsetLen + parser.maxVowelLen
        let lo = max(0, split - halfWindow)
        let hi = min(chars.count, split + halfWindow)
        let prefixSlice = String(chars[lo..<split])
        let tailSlice = String(chars[split..<hi])
        let full = prefixSlice + tailSlice
        // `isFullBuffer: false` on the slice parses suppresses the
        // bare-vowel `အ` orphan-promotion — which is exactly the
        // post-process that would inject the spurious `အာ` if the
        // tail starts with a stranded vowel rule. Comparing against
        // the full-window parse run with the same flag keeps the
        // comparison meaningful.
        let fullParse = parser.parseCandidates(
            full,
            maxResults: 1,
            isFullBuffer: false
        ).first
        let prefixParse = parser.parseCandidates(
            prefixSlice,
            maxResults: 1,
            isFullBuffer: false
        ).first
        let tailParse = parser.parseCandidates(
            tailSlice,
            maxResults: 1,
            isFullBuffer: false
        ).first
        guard let fullParse, let prefixParse, let tailParse else {
            // Any of the three failing means the boundary doesn't
            // sit inside a parseable region — fall through and let
            // local legality drive the decision (i.e. accept).
            return true
        }
        if prefixParse.output + tailParse.output == fullParse.output {
            return true
        }
        // TASK-046 gap fix: bare-onset vowel rules (`aing`, `aung`,
        // `ai`, `aw`, etc.) parsed with `isFullBuffer: false` emit a
        // leading U+200C ZWNJ — the parser's standard placeholder
        // for an onsetless vowel rule that needs an independent-vowel
        // anchor injected at finalize time. When such a rule begins
        // the tail slice and the prefix slice is non-empty, the
        // concatenated `prefixOutput + tailOutput` carries a
        // mid-surface ZWNJ at the boundary where the full-buffer
        // parse emits U+1021 (the parser injects the anchor between
        // adjacent bare-diphthong arcs at full-buffer scope per
        // TASK-046). The engine's downstream
        // `promoteOrphanZwnjToImplicitA` rewrite normalizes that
        // mid-surface ZWNJ to U+1021, producing exactly the
        // full-buffer parse. Without this carve-out, every
        // syllable-aligned split through a chain of repeated
        // bare-onset diphthong rules (`aung × N` for N ≥ 7,
        // `aing × N` for N ≥ 7) is rejected as "unstable", forcing
        // `findSyllableSafeSplit` to fall through to the unsafe
        // target — which lands mid-rule and produces the
        // trailing-collapse `အူငေါင်` / `ငိန်ဂိုင်` shapes the
        // task documents.
        //
        // Cheap precondition: the boundary-orphan-promotion case
        // can only apply when the tail slice's parse begins with
        // U+200C (the orphan-vowel-rule placeholder). Skip the
        // scalar-walk normalization unless that signal is present —
        // every non-bare-vowel windowed buffer pays only the cost
        // of one scalar inspection.
        if let firstTail = tailParse.output.unicodeScalars.first,
           firstTail.value == 0x200C,
           Self.mergedDiffersOnlyByBoundaryOrphanPromotion(
               prefix: prefixParse.output,
               tail: tailParse.output,
               full: fullParse.output
           ) {
            return true
        }
        return false
    }

    /// True when `prefix + tail` and `full` differ ONLY by `tail`'s
    /// leading `U+200C` ZWNJ standing where `full` has `U+1021`.
    /// The engine's downstream `promoteOrphanZwnjToImplicitA`
    /// post-process rewrites that single mid-surface ZWNJ to
    /// `1021`, so the merge is stable once that promotion fires.
    ///
    /// Walks the three strings via `unicodeScalars.makeIterator`
    /// without materialising the concatenated `merged` string or
    /// allocating scalar arrays — `splitProducesStableMerge` runs
    /// once per walk-back iteration and per forward-sweep iteration
    /// in `findSyllableSafeSplit`, and the `vowel_rule_chain_*`
    /// benchmarks pick up any per-iteration allocation.
    private static func mergedDiffersOnlyByBoundaryOrphanPromotion(
        prefix: String,
        tail: String,
        full: String
    ) -> Bool {
        let pScalars = prefix.unicodeScalars
        let tScalars = tail.unicodeScalars
        let fScalars = full.unicodeScalars
        // Total merged scalar count must equal `full`'s scalar count
        // for the divergence to be exactly one boundary-position
        // scalar swap.
        if pScalars.count + tScalars.count != fScalars.count { return false }
        guard !pScalars.isEmpty, !tScalars.isEmpty else { return false }
        // Prefix must match `full`'s leading scalars exactly.
        var pIter = pScalars.makeIterator()
        var fIter = fScalars.makeIterator()
        while let p = pIter.next() {
            guard let f = fIter.next(), p == f else { return false }
        }
        // Boundary: tail's first scalar must be `200C`, `full`'s
        // matching position must be `1021`.
        var tIter = tScalars.makeIterator()
        guard let tBoundary = tIter.next(), tBoundary.value == 0x200C,
              let fBoundary = fIter.next(), fBoundary.value == 0x1021 else {
            return false
        }
        // Remainder of tail must match `full`'s remaining scalars.
        while let t = tIter.next() {
            guard let f = fIter.next(), t == f else { return false }
        }
        return fIter.next() == nil
    }

    /// Avoid freezing a connector-like `a` into the prefix when the next
    /// active-tail letter may need it as an onsetless `a...` word start
    /// (`...phaya` + `hain...` should remain able to form `...ဖေအိမ်...`).
    ///
    /// Also reject boundaries immediately before a plausible `n` coda /
    /// implicit-stack site. A prefix ending in `...mi` parses legally on its
    /// own, but if the full buffer has `...min<C>`, cutting before the `n`
    /// forces the prefix to render `မီ` and the tail to render a fresh `င`,
    /// corrupting repeated words like `mingalarpar`.
    ///
    /// Reject boundaries inside roman onset digraphs / cluster
    /// aliases. `...s` parses legally as စ, but when followed by `h` the
    /// intended tail onset may be `sh` → ရှ; freezing after `s` would make
    /// that cluster unreachable.
    ///
    /// Finally, reject boundaries that strand a vowel-leading rule at the
    /// head of the active tail when the prefix's last character is a
    /// consonant letter. The active-tail parse of e.g. `aungtawkyaw`
    /// produces a ZWNJ+dep-vowel surface (the standard parser emission
    /// for a bare vowel rule), which the engine's orphan-ZWNJ promoter
    /// then rewrites to `အောင်...`. Concatenated onto a prefix ending in
    /// a consonant, the result is `<consonant>အ<dep-vowel>...` — a
    /// stray independent vowel `အ` wedged between the consonant and the
    /// dep-vowel that should attach directly to it (TASK-002). The fix
    /// is to refuse the split so the windowing path advances the
    /// boundary forward (or back) until the active tail starts with a
    /// consonant or with the original buffer head — keeping the
    /// `<consonant><dep-vowel>` cluster intact through the parse.
    internal static func isUnsafeFrozenSplit(chars: [Character], split: Int) -> Bool {
        guard split > 0, split < chars.count else { return false }
        if chars[split - 1] == "a", chars[split].isLetter {
            return true
        }
        if isOnsetDigraphSplit(chars: chars, split: split) {
            return true
        }
        if isImplicitNCodaSplit(chars: chars, split: split) {
            return true
        }
        return isConsonantVowelSplit(chars: chars, split: split)
    }

    /// True when the prefix ends with a consonant letter and the active
    /// tail starts with a multi-letter vowel rule that the parser can
    /// only render via a leading ZWNJ + dep-vowel sign (the standard
    /// orphan-mark emission for a bare-vowel run). The engine's
    /// orphan-promoter then rewrites the ZWNJ to `အ`, producing a
    /// `<consonant>U+1021<dep-vowel>` triple — a stray independent vowel
    /// wedged between the prefix's trailing consonant and the
    /// dep-vowel that should attach directly to it (TASK-002).
    ///
    /// The set of triggering prefixes is the subset of vowel rules in
    /// `Romanization.swift` whose surface output is a dep-vowel sign
    /// (U+102B–U+1032 / U+1036–U+1038) without an inherent base — i.e.
    /// rules that would orphan-promote when parsed standalone. A
    /// single bare `a` is excluded because the parser maps it to the
    /// inherent vowel (no surface emission) and lets it merge with the
    /// next consonant; only multi-letter vowel-onset rules (`au-`,
    /// `aw-`, `ai-`, `ay-`, `ee`, `oo`, `ow-`, `ey`, etc.) actually
    /// trigger the orphan-promotion path.
    private static func isConsonantVowelSplit(chars: [Character], split: Int) -> Bool {
        guard split > 0, split < chars.count else { return false }
        let prev = chars[split - 1]
        guard prev.isLetter, !isVowelLetter(prev) else { return false }
        return startsWithOrphaningVowelRule(chars: chars, at: split)
    }

    private static func isVowelLetter(_ c: Character) -> Bool {
        switch c {
        case "a", "e", "i", "o", "u":
            return true
        default:
            return false
        }
    }

    /// True when the substring starting at `chars[at...]` begins with a
    /// multi-letter Romanization vowel rule that, when parsed in
    /// isolation, would emit a leading orphan dep-vowel sign (which the
    /// engine then rewrites to `အ`). The check does not need to be
    /// exhaustive for the entire vowel-rule table — the bug only fires
    /// for tail prefixes that produce the ZWNJ-orphan parse, and those
    /// all start with `a` followed by a non-vowel letter (`au-`, `aw-`,
    /// `ai-`, `ay-`, `an-`, `ar-`, `at-`) or with one of the long-vowel
    /// rules (`ee`, `oo`, `ow-`, `ey-`). A single `a<vowel>` prefix
    /// (e.g. `alarpar`) is parsed as inherent + next consonant and is
    /// safe.
    private static func startsWithOrphaningVowelRule(chars: [Character], at start: Int) -> Bool {
        guard start < chars.count else { return false }
        let c0 = chars[start]
        guard isVowelLetter(c0) else { return false }
        // Single-letter `a` followed by another vowel letter (`alar`,
        // `aerial`) parses as inherent + next syllable; safe.
        if c0 == "a" {
            guard start + 1 < chars.count else { return false }
            let c1 = chars[start + 1]
            // `a<vowel>` is safe because the parser merges the leading
            // `a` as inherent into the next consonant cluster.
            if isVowelLetter(c1) { return false }
            // `a` followed by a non-letter (`+`, digit, `'`) is also
            // safe — the parser will treat them as connectors.
            guard c1.isLetter else { return false }
            // `a<consonant>` (e.g. `alarpar`, `apyar`) is safe — the `a`
            // is inherent on the next consonant.
            // Only `a` followed by a multi-letter VOWEL-RULE prefix
            // triggers the orphan parse. Those start with `u`, `w`, `y`,
            // `i` after `a` — the diphthong/finals (`au`, `aw`, `ay`,
            // `ai`).
            switch c1 {
            case "u", "w", "y", "i":
                return true
            default:
                return false
            }
        }
        // Long-vowel rules whose first scalar is themselves a vowel
        // letter and whose standalone parse produces an orphan: `ee`,
        // `oo`, `ow`, `ey`. Each is two letters, the second of which is
        // a vowel that doubles the first or pairs with a glide.
        //
        // Closed-vowel rules (`in`, `an`, `on`, `un`, `am`, `im`, `om`,
        // `um`, `aw`, `ar`, `ay`, `ai`, `aing`, `aung`) are also
        // orphaning when standalone — the parser emits a leading
        // ZWNJ + dep-vowel/nga-asat surface, which the engine then
        // rewrites to `အ + ...` (an independent-vowel anchor wedged
        // between the prefix's consonant and the dep-vowel cluster
        // that should attach directly to it). Reject the split so
        // the windowing path advances forward (or back) until the
        // active-tail head is a consonant that anchors the vowel
        // rule. TASK-005: this also keeps the full vowel-rule
        // syllable inside one of the two slices, so the kinzi
        // inference (`<vowel>n + <C>`) sees both upper and lower at
        // the same site.
        if start + 1 < chars.count {
            let pair = String([chars[start], chars[start + 1]])
            switch pair {
            case "ee", "oo", "ow", "ey":
                return true
            case "an", "in", "on", "un", "am", "im", "om", "um",
                 "aw", "ar", "ay", "ai":
                return true
            default:
                break
            }
        }
        return false
    }

    private static func isOnsetDigraphSplit(chars: [Character], split: Int) -> Bool {
        switch (chars[split - 1], chars[split]) {
        case ("c", "h"), ("d", "h"), ("g", "h"), ("g", "y"),
             ("k", "h"), ("l", "l"), ("p", "h"), ("s", "h"),
             ("t", "h"):
            return true
        default:
            return false
        }
    }

    private static func isImplicitNCodaSplit(chars: [Character], split: Int) -> Bool {
        guard split + 1 < chars.count, chars[split] == "n" else { return false }
        let next = chars[split + 1]
        guard isNCodaVowelLetter(chars[split - 1]),
              next.isLetter,
              !isNCodaVowelLetter(next),
              next != "n"
        else { return false }

        return true
    }

    private static func isNCodaVowelLetter(_ char: Character) -> Bool {
        switch char {
        case "a", "e", "i", "o", "u", "w":
            return true
        default:
            return false
        }
    }

    /// Length of a previously cached frozen prefix if it still applies to
    /// `normalized` — i.e. it is still a prefix of the current buffer.
    /// Returns nil otherwise (buffer shortened or diverged).
    internal func stableCachedPrefixLength(for normalized: String) -> Int? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        var best: Int? = nil
        for entry in prefixCache {
            guard !entry.input.isEmpty,
                  normalized.hasPrefix(entry.input) else { continue }
            if best == nil || entry.input.count > best! {
                best = entry.input.count
            }
        }
        return best
    }
}
