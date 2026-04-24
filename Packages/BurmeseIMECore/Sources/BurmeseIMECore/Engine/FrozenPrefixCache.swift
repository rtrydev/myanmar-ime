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

        let parses = parser.parseCandidates(prefix, maxResults: Self.frozenPrefixCandidatePool)
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
            var scored: [(branch: FrozenPrefixBranch, isOOV: Bool)] = []
            let unkFloor = languageModel.unknownLogProb
            let oovEpsilon = 0.01
            for parse in parses where seen.insert(parse.output).inserted {
                let lm = scoreSurfaceCached(parse.output, context: baseContext, cache: &lmCache)
                let isOOV = unkFloor.isFinite && abs(lm - unkFloor) < oovEpsilon
                scored.append((FrozenPrefixBranch(
                    output: parse.output,
                    reading: parse.reading,
                    lmScore: lm,
                    contextWords: baseContext + [parse.output]
                ), isOOV))
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
            scored.sort { lhs, rhs in
                if lhs.isOOV != rhs.isOOV { return !lhs.isOOV }
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
        var split = target
        while split >= scanLimit {
            let prefix = String(chars[0..<split])
            if let parse = parser.parseCandidates(prefix, maxResults: 1).first,
               parse.legalityScore > 0,
               !Self.isUnsafeFrozenSplit(chars: chars, split: split) {
                return split
            }
            split -= 1
        }
        return target
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
    /// Finally, reject boundaries inside roman onset digraphs / cluster
    /// aliases. `...s` parses legally as စ, but when followed by `h` the
    /// intended tail onset may be `sh` → ရှ; freezing after `s` would make
    /// that cluster unreachable.
    internal static func isUnsafeFrozenSplit(chars: [Character], split: Int) -> Bool {
        guard split > 0, split < chars.count else { return false }
        if chars[split - 1] == "a", chars[split].isLetter {
            return true
        }
        if isOnsetDigraphSplit(chars: chars, split: split) {
            return true
        }
        return isImplicitNCodaSplit(chars: chars, split: split)
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
