import Foundation

/// Grammar-aware incremental syllable parser for Hybrid Burmese romanization.
///
/// The Hybrid Burmese romanization scheme encodes consonant+medial combinations
/// as a single unit: prefix 'h' for ha-htoe, suffix 'y' for ya-yit, 'y2' for
/// ya-pin, 'w' for wa-hswe. For example:
///   - "ky" = က + ြ (ka + medial ra/ya-yit)
///   - "hk" = က + ှ (ka + medial ha-htoe)
///   - "hkwy2" = က + ျ + ွ + ှ (ka + all four medials)
///
/// The parser uses an N-best Viterbi-style DP search over the buffer, matching
/// pre-computed consonant+medial combinations followed by vowel suffixes.
public final class SyllableParser: Sendable {

    /// How a state extends its parent. Replaces per-state `output`/`reading`
    /// strings — the full surface is reconstructed only for the final top-K
    /// in `finalizeStates` by walking the `parentIdx` chain.
    private enum MatchRef: Hashable, Sendable {
        case seed
        case skip
        case onsetOnly(onsetId: Int32)
        case onsetVowel(onsetId: Int32, vowelId: Int32)
        case vowelOnly(vowelId: Int32)
    }

    /// DP state. Holds only scalars + a back-pointer; the `output` and
    /// `reading` strings are derived on demand from the `matchRef` chain.
    private struct ParseState: Sendable {
        let parentIdx: Int32       // `-1` for the seed state
        let matchRef: MatchRef
        let charEnd: Int32
        let score: Int
        let legalityScore: Int
        let aliasCost: Int
        let syllableCount: Int
        let structureCost: Int
        let isLegal: Bool
    }

    /// Pre-computed consonant+medial combinations mapped from roman key to Myanmar output.
    struct OnsetEntry: Sendable {
        let id: Int32             // index into the parser's flat onset table
        let canonicalRoman: String
        let myanmar: String       // consonant + medials as Myanmar string
        let onset: Character      // the base consonant
        let medials: [Character]  // medial characters used
        let aliasCost: Int
        let structureCost: Int
    }

    struct VowelMatchEntry: Sendable {
        let id: Int32             // index into the parser's flat vowel table
        let canonicalRoman: String
        let myanmar: String
        let aliasCost: Int
        let isStandalone: Bool

        var isPureMedial: Bool {
            !myanmar.isEmpty && myanmar.unicodeScalars.allSatisfy {
                (0x103B...0x103E).contains($0.value)
            }
        }
    }

    private typealias OnsetMatch = (end: Int, entry: OnsetEntry)
    private typealias VowelMatch = (end: Int, entry: VowelMatchEntry)

    /// Flat ASCII trie used to match onsets/vowels without per-lookup string
    /// slicing. Parser input is normalized to lowercase ASCII composing
    /// characters plus numeric alias markers (`2`/`3`), so a fixed 128-wide
    /// children table covers every character the walker can encounter.
    /// Nodes with terminal payloads store a half-open range into a per-trie
    /// payload array — one trie for onsets, one for vowels.
    private struct AsciiTrieTable {
        /// `children[node * 128 + byte] = childNode` (`-1` if absent).
        let children: [Int32]
        /// Per-node half-open terminal range: `terminalStart[n]..<terminalStart[n+1]`
        /// indexes into the payload array of the owning trie.
        let terminalStart: [Int32]
        /// Deepest path in the trie — bounds the walk.
        let maxDepth: Int
    }

    private let onsetTrie: AsciiTrieTable
    private let onsetTerminals: [OnsetEntry]

    private let vowelTrie: AsciiTrieTable
    private let vowelTerminals: [VowelMatchEntry]

    /// Pre-computed `Grammar.validateSyllable` result for each onset entry
    /// paired with vowelRoman = "a" (the inherent vowel used by onset-only
    /// transitions). Indexed by `OnsetEntry.id`.
    private let onsetBareLegality: [Int]

    /// Pre-computed `Grammar.validateSyllable` result for each standalone-vowel
    /// transition (onset: nil). Indexed by `VowelMatchEntry.id`.
    private let vowelOnlyLegality: [Int]

    /// `VowelMatchEntry.id` of the virama connector (`+`), or `-1` if the
    /// vowel table has no virama entry. Used in the hot DP loop to detect
    /// stack contexts with an integer compare rather than a string compare.
    private let viramaVowelId: Int32

    /// Per-vowel: non-zero when the vowel's rendered Myanmar ends with
    /// U+103A (asat) and contains at least two scalars; the value is the
    /// scalar immediately preceding the trailing asat. Used by the
    /// kinzi rule (`U+103A` is only legal before a virama when the
    /// preceding base is nga, U+1004). Zero when the vowel does not
    /// end with asat, or ends with a lone asat (the `*` vowel) — callers
    /// fall through to the parent state's chunk in that case.
    private let vowelPreAsatScalar: [UInt32]

    /// Per-vowel: true iff the vowel's rendered Myanmar ends with U+103A.
    private let vowelEndsWithAsat: [Bool]

    /// Per-onset: the last scalar in the onset's rendered Myanmar. Used
    /// to recover the base when a lone-asat vowel follows (`.onsetVowel`
    /// with the `*` vowel), so the kinzi check has a base to inspect.
    private let onsetLastScalar: [UInt32]

    /// Maximum onset key length for bounded search.
    public let maxOnsetLen: Int

    /// Maximum vowel key length for bounded search.
    public let maxVowelLen: Int

    /// - Parameter useClusterAliases: when `false`, the phonetic cluster
    ///   shortcuts (`j`, `ch`, `gy`, `sh`, and their `w` variants) are not
    ///   inserted into the onset table. Every other onset, vowel, medial,
    ///   and canonical alias is loaded unconditionally.
    public init(useClusterAliases: Bool = true) {
        var onsetLookup: [String: [OnsetEntry]] = [:]

        func appendOnset(
            canonicalRoman: String,
            myanmar: String,
            onset: Character,
            medials: [Character],
            baseAliasCost: Int
        ) {
            for variant in Romanization.aliasVariants(for: canonicalRoman, baseAliasCost: baseAliasCost) {
                // `id` is rewritten by `buildTrie` during flattening.
                onsetLookup[variant.key, default: []].append(OnsetEntry(
                    id: -1,
                    canonicalRoman: canonicalRoman,
                    myanmar: myanmar,
                    onset: onset,
                    medials: medials,
                    aliasCost: variant.aliasCost,
                    structureCost: medials.count
                ))
            }
        }

        // Generate all consonant + medial combinations (matching the legacy engine)
        for cons in Romanization.consonants {
            appendOnset(
                canonicalRoman: cons.roman,
                myanmar: String(cons.myanmar),
                onset: cons.myanmar,
                medials: [],
                baseAliasCost: cons.aliasCost
            )

            // Generate medial combinations matching the legacy engine's scheme:
            // h prefix → ha-htoe (ှ), w suffix → wa-hswe (ွ),
            // y suffix → ya-yit (ြ), y2 suffix → ya-pin (ျ)
            for combo in Grammar.medialCombinations {
                let hasH = combo.contains(Myanmar.medialHa)
                let hasW = combo.contains(Myanmar.medialWa)
                let hasY = combo.contains(Myanmar.medialRa)   // ြ = ya-yit, roman "y"
                let hasY2 = combo.contains(Myanmar.medialYa)  // ျ = ya-pin, roman "y2"

                var allLegal = true
                for medial in combo where !Grammar.canConsonantTakeMedial(cons.myanmar, medial) {
                    allLegal = false
                    break
                }

                let canonicalRoman =
                    (hasH ? "h" : "") +
                    cons.roman +
                    (hasW ? "w" : "") +
                    (hasY ? "y" : "") +
                    (hasY2 ? "y2" : "")

                let myanmarOutput = Grammar.composeOnset(consonant: cons.myanmar, medials: combo)

                appendOnset(
                    canonicalRoman: canonicalRoman,
                    myanmar: myanmarOutput,
                    onset: cons.myanmar,
                    medials: combo,
                    baseAliasCost: cons.aliasCost + (allLegal ? 0 : 100)
                )
            }
        }

        // Phonetic cluster shortcuts (`j`, `ch`, `gy`, `sh`, + `w` variants).
        // Inserted directly under the shortcut key so canonical aliasVariants
        // handling for other onsets is unaffected. Gated by the init flag
        // so users who prefer structural typing can opt out.
        if useClusterAliases {
            for alias in Romanization.clusterAliases {
                let myanmarOutput = Grammar.composeOnset(consonant: alias.consonant, medials: alias.medials)

                let hasH  = alias.medials.contains(Myanmar.medialHa)
                let hasW  = alias.medials.contains(Myanmar.medialWa)
                let hasY  = alias.medials.contains(Myanmar.medialRa)
                let hasY2 = alias.medials.contains(Myanmar.medialYa)
                let baseRoman = Romanization.consonantToRoman[alias.consonant] ?? ""
                let canonical =
                    (hasH ? "h" : "") +
                    baseRoman +
                    (hasW ? "w" : "") +
                    (hasY ? "y" : "") +
                    (hasY2 ? "y2" : "")

                onsetLookup[alias.roman, default: []].append(OnsetEntry(
                    id: -1,
                    canonicalRoman: canonical,
                    myanmar: myanmarOutput,
                    onset: alias.consonant,
                    medials: alias.medials,
                    aliasCost: alias.aliasCost,
                    structureCost: alias.medials.count
                ))
            }
        }

        let builtOnsetTrie = Self.buildTrie(from: onsetLookup) { entry, id in
            OnsetEntry(
                id: id,
                canonicalRoman: entry.canonicalRoman,
                myanmar: entry.myanmar,
                onset: entry.onset,
                medials: entry.medials,
                aliasCost: entry.aliasCost,
                structureCost: entry.structureCost
            )
        }
        self.onsetTrie = builtOnsetTrie.table
        self.onsetTerminals = builtOnsetTrie.terminals
        self.maxOnsetLen = builtOnsetTrie.table.maxDepth

        var vowelLookup: [String: [VowelMatchEntry]] = [:]
        for entry in Romanization.vowels {
            for variant in Romanization.aliasVariants(for: entry.roman, baseAliasCost: entry.aliasCost) {
                vowelLookup[variant.key, default: []].append(VowelMatchEntry(
                    id: -1,
                    canonicalRoman: entry.roman,
                    myanmar: entry.myanmar,
                    aliasCost: variant.aliasCost,
                    isStandalone: entry.isStandalone
                ))
            }
        }
        let builtVowelTrie = Self.buildTrie(from: vowelLookup) { entry, id in
            VowelMatchEntry(
                id: id,
                canonicalRoman: entry.canonicalRoman,
                myanmar: entry.myanmar,
                aliasCost: entry.aliasCost,
                isStandalone: entry.isStandalone
            )
        }
        self.vowelTrie = builtVowelTrie.table
        self.vowelTerminals = builtVowelTrie.terminals
        self.maxVowelLen = builtVowelTrie.table.maxDepth

        // Pre-compute syllable legality for every bare onset (vowelRoman = "a")
        // and every standalone vowel. Paired (onset, vowel) legality is
        // memoized lazily during parse — the Cartesian product is large but
        // real inputs touch only a small slice of it.
        var bareOnsetLegalities = [Int](repeating: 0, count: builtOnsetTrie.terminals.count)
        for (idx, entry) in builtOnsetTrie.terminals.enumerated() {
            bareOnsetLegalities[idx] = Grammar.validateSyllable(
                onset: entry.onset,
                medials: entry.medials,
                vowelRoman: "a"
            )
        }
        self.onsetBareLegality = bareOnsetLegalities

        var vowelOnlyLegalities = [Int](repeating: 0, count: builtVowelTrie.terminals.count)
        var foundViramaId: Int32 = -1
        var vowelEndsAsat = [Bool](repeating: false, count: builtVowelTrie.terminals.count)
        var vowelPreAsat = [UInt32](repeating: 0, count: builtVowelTrie.terminals.count)
        for (idx, entry) in builtVowelTrie.terminals.enumerated() {
            vowelOnlyLegalities[idx] = Grammar.validateSyllable(
                onset: nil,
                medials: [],
                vowelRoman: entry.canonicalRoman
            )
            if foundViramaId < 0 && entry.canonicalRoman == "+" {
                foundViramaId = entry.id
            }
            let scalars = Array(entry.myanmar.unicodeScalars)
            if let last = scalars.last, last.value == 0x103A {
                vowelEndsAsat[idx] = true
                if scalars.count >= 2 {
                    vowelPreAsat[idx] = scalars[scalars.count - 2].value
                }
            }
        }
        self.vowelOnlyLegality = vowelOnlyLegalities
        self.viramaVowelId = foundViramaId
        self.vowelEndsWithAsat = vowelEndsAsat
        self.vowelPreAsatScalar = vowelPreAsat

        var onsetLast = [UInt32](repeating: 0, count: builtOnsetTrie.terminals.count)
        for (idx, entry) in builtOnsetTrie.terminals.enumerated() {
            if let last = entry.myanmar.unicodeScalars.last {
                onsetLast[idx] = last.value
            }
        }
        self.onsetLastScalar = onsetLast
    }

    /// Compact a `[String: [Entry]]` map into an ASCII trie + flat terminal
    /// payloads. Only keys consisting of characters < 128 are indexed — in
    /// practice the romanization tables include digit-bearing canonical
    /// forms (e.g. "ay2") which `Romanization.normalize` never produces,
    /// so skipping those saves nodes and never affects matching.
    private static func buildTrie<Entry>(
        from lookup: [String: [Entry]],
        assignId: (Entry, Int32) -> Entry
    ) -> (table: AsciiTrieTable, terminals: [Entry]) {
        // Stage 1: build mutable children + per-node terminal lists as
        // parallel flat arrays (Swift forbids nested types inside generic
        // functions, so we avoid a BuildNode struct).
        var children: [Int32] = Array(repeating: -1, count: 128) // root
        var nodeTerminals: [[Entry]] = [[]]
        var maxDepth = 0

        func allocateNode() -> Int32 {
            let idx = Int32(nodeTerminals.count)
            children.append(contentsOf: repeatElement(Int32(-1), count: 128))
            nodeTerminals.append([])
            return idx
        }

        for (key, entries) in lookup {
            // Accept the key only if every character fits in one ASCII byte.
            // Other keys (digit disambiguators) are unreachable from a
            // normalized composing buffer, so dropping them is safe.
            var bytes: [UInt8] = []
            bytes.reserveCapacity(key.count)
            var ok = true
            for scalar in key.unicodeScalars {
                if scalar.value < 128 {
                    bytes.append(UInt8(scalar.value))
                } else {
                    ok = false
                    break
                }
            }
            guard ok, !bytes.isEmpty else { continue }

            var current: Int32 = 0
            for byte in bytes {
                let slotIndex = Int(current) * 128 + Int(byte)
                let existing = children[slotIndex]
                if existing < 0 {
                    let newIdx = allocateNode()
                    children[slotIndex] = newIdx
                    current = newIdx
                } else {
                    current = existing
                }
            }
            nodeTerminals[Int(current)].append(contentsOf: entries)
            if bytes.count > maxDepth { maxDepth = bytes.count }
        }

        // Stage 2: flatten per-node terminal lists into a packed array.
        let nodeCount = nodeTerminals.count
        var terminalStart = [Int32](repeating: 0, count: nodeCount + 1)
        var terminals: [Entry] = []
        terminals.reserveCapacity(nodeTerminals.reduce(0) { $0 + $1.count })
        for index in 0..<nodeCount {
            terminalStart[index] = Int32(terminals.count)
            for entry in nodeTerminals[index] {
                let id = Int32(terminals.count)
                terminals.append(assignId(entry, id))
            }
        }
        terminalStart[nodeCount] = Int32(terminals.count)

        return (
            AsciiTrieTable(
                children: children,
                terminalStart: terminalStart,
                maxDepth: max(maxDepth, 1)
            ),
            terminals
        )
    }

    // MARK: - Public API

    private static func normalizeForParser(_ input: String) -> String {
        String(input.lowercased().filter {
            Romanization.composingCharacters.contains($0) || Romanization.isNumericAliasMarker($0)
        })
    }

    /// Parse a romanized buffer into its best Burmese output.
    public func parse(_ input: String) -> [SyllableParse] {
        parseCandidates(input, maxResults: 1)
    }

    /// Parse a romanized buffer into multiple Burmese candidates.
    public func parseCandidates(_ input: String, maxResults: Int = 8) -> [SyllableParse] {
        let normalized = Self.normalizeForParser(input)
        guard !normalized.isEmpty, maxResults > 0 else { return [] }

        let chars = Array(normalized)
        let beamWidth = max(maxResults * 16, 64)
        let onsetMatchesByStart = precomputeOnsetMatches(chars)
        let vowelMatchesByStart = precomputeVowelMatches(chars)
        let (arena, finalIndices) = nBestParse(
            chars,
            onsetMatchesByStart: onsetMatchesByStart,
            vowelMatchesByStart: vowelMatchesByStart,
            maxResults: beamWidth
        )
        return finalizeStates(
            arena: arena,
            finalIndices: finalIndices,
            limit: maxResults,
            requestedReading: normalized
        )
    }

    /// Find the longest prefix of `input` whose top-`maxResults` parses pass
    /// the caller's `acceptable` predicate, and return that prefix length
    /// together with its top parses. Equivalent to repeatedly calling
    /// `parseCandidates` on `input[0..<k]` from `k = n` down to `1` and
    /// stopping at the first acceptable result — but runs a single DP and
    /// walks its bucket array backward, so the cost is linear rather than
    /// quadratic in the buffer length. Returns `(0, [])` when no prefix has
    /// an acceptable parse.
    ///
    /// DP states at bucket `k` only depend on `chars[0..<k]`, so each
    /// bucket's best parse at position `k` matches what a fresh parse of
    /// the length-`k` prefix would produce. This property is what makes
    /// the single-pass walk semantically equivalent to the per-length loop.
    public func parseLongestAcceptablePrefix(
        _ input: String,
        maxResults: Int = 1,
        acceptable: (SyllableParse) -> Bool
    ) -> (length: Int, parses: [SyllableParse]) {
        let normalized = Self.normalizeForParser(input)
        guard !normalized.isEmpty, maxResults > 0 else { return (0, []) }

        let chars = Array(normalized)
        let beamWidth = max(maxResults * 16, 64)
        let onsetMatchesByStart = precomputeOnsetMatches(chars)
        let vowelMatchesByStart = precomputeVowelMatches(chars)
        var (arena, dp) = runDP(
            chars,
            onsetMatchesByStart: onsetMatchesByStart,
            vowelMatchesByStart: vowelMatchesByStart,
            maxResults: beamWidth
        )

        // Walk buckets backward and finalize the candidate list at each
        // position until one of the surfaced parses satisfies the caller's
        // acceptability predicate. This keeps the acceptability walk aligned
        // with the same string-aware ranking and cleanup used by
        // `parseCandidates`, which matters for cleaned virama stacks and
        // explicit digit-disambiguated readings.
        for k in stride(from: chars.count, through: 1, by: -1) {
            if dp[k].needsPrune {
                pruneBucket(&dp[k], arena: arena, limit: beamWidth)
            }
            let parses = finalizeStates(
                arena: arena,
                finalIndices: dp[k].stateIndices,
                limit: maxResults,
                requestedReading: String(chars.prefix(k))
            )
            if parses.contains(where: acceptable) {
                return (k, parses)
            }
        }
        return (0, [])
    }

    // MARK: - N-best DP Parse

    /// Bucket at a single DP position. Holds arena indices only — the arena
    /// (shared across all buckets in one parse) is where `ParseState` values
    /// live. Buckets grow until they exceed `limit * 2`, at which point
    /// `pruneBucket` drops everything below the top `limit` by score.
    private struct DPBucket {
        var stateIndices: [Int32] = []
        var needsPrune = false
    }

    /// Pack two 32-bit ids into a single dictionary key. Callers are
    /// responsible for treating each half as unsigned.
    @inline(__always)
    private static func packPair(_ a: Int32, _ b: Int32) -> UInt64 {
        (UInt64(UInt32(bitPattern: a)) << 32) | UInt64(UInt32(bitPattern: b))
    }

    private func nBestParse(
        _ chars: [Character],
        onsetMatchesByStart: [[OnsetMatch]],
        vowelMatchesByStart: [[VowelMatch]],
        maxResults: Int
    ) -> (arena: [ParseState], finalIndices: [Int32]) {
        var (arena, dp) = runDP(
            chars,
            onsetMatchesByStart: onsetMatchesByStart,
            vowelMatchesByStart: vowelMatchesByStart,
            maxResults: maxResults
        )
        let n = chars.count
        if dp[n].needsPrune {
            pruneBucket(&dp[n], arena: arena, limit: maxResults)
        }
        return (arena, dp[n].stateIndices)
    }

    /// Run the N-best DP and return the raw arena + per-position buckets.
    /// Callers that only need the final bucket should use `nBestParse`;
    /// callers that walk intermediate positions (e.g.
    /// `parseLongestAcceptablePrefix`) use this variant.
    private func runDP(
        _ chars: [Character],
        onsetMatchesByStart: [[OnsetMatch]],
        vowelMatchesByStart: [[VowelMatch]],
        maxResults: Int
    ) -> (arena: [ParseState], dp: [DPBucket]) {
        let n = chars.count
        var arena: [ParseState] = []
        arena.reserveCapacity(max(n * maxResults / 4, 64))
        var dp = [DPBucket](repeating: DPBucket(), count: n + 1)

        // Seed
        let seedIdx = Int32(arena.count)
        arena.append(ParseState(
            parentIdx: -1,
            matchRef: .seed,
            charEnd: 0,
            score: 0,
            legalityScore: 0,
            aliasCost: 0,
            syllableCount: 0,
            structureCost: 0,
            isLegal: true
        ))
        dp[0].stateIndices.append(seedIdx)

        // Lazy legality cache for paired (onsetId, vowelId). Bare-onset and
        // standalone-vowel cases are already pre-computed at init time.
        var pairLegality: [UInt64: Int] = [:]

        // Virama-stack validation can only fire if the buffer contains a
        // "+" connector. Precompute this once so the common case (plain
        // buffers, including the worst-case "garbage" scenario) skips the
        // per-state match-ref inspection entirely.
        let hasViramaInBuffer = chars.contains("+")

        for i in 0..<n {
            guard !dp[i].stateIndices.isEmpty else { continue }

            if dp[i].needsPrune {
                pruneBucket(&dp[i], arena: arena, limit: maxResults)
            }

            let onsetMatches = onsetMatchesByStart[i]
            let standaloneVowels = vowelMatchesByStart[i]
            // Snapshot — the bucket's stateIndices is mutated by insertState
            // into downstream buckets, but we only read dp[i] here.
            let prevIndices = dp[i].stateIndices
            for prevIdx in prevIndices {
                let previous = arena[Int(prevIdx)]
                var matched = false

                // If the previous syllable ended with a virama connector
                // ("+"), the next onset is the subscript of a virama stack
                // and must be validated against the upper consonant.
                // Cross-class stacks (e.g. က္ယ, က္ဝ, က္ဿ) fall outside the
                // native subscript model; force their onset legality to 0
                // so the resulting parse drops below the legality
                // threshold. Two shapes reach here because the DP admits
                // both a glued `.onsetVowel(upper, +)` and a split
                // `.onsetOnly(upper)` → `.vowelOnly(+)` path.
                let viramaUpper: Character?
                if hasViramaInBuffer {
                    switch previous.matchRef {
                    case let .onsetVowel(onsetId, vowelId) where vowelId == viramaVowelId:
                        viramaUpper = onsetTerminals[Int(onsetId)].onset
                    case let .vowelOnly(vowelId)
                        where vowelId == viramaVowelId && previous.parentIdx >= 0:
                        // The "upper" in the stack is the scalar immediately
                        // before the virama, not the parent syllable's onset.
                        // For asat-ending parent vowels (kinzi `in`, `mut`,
                        // `kan`, ...), that scalar is the consonant embedded
                        // in the vowel's render, tracked as
                        // `vowelPreAsatScalar`. For vowels without an asat
                        // (inherent `a`), the upper is the onset itself.
                        switch arena[Int(previous.parentIdx)].matchRef {
                        case let .onsetOnly(onsetId):
                            viramaUpper = onsetTerminals[Int(onsetId)].onset
                        case let .onsetVowel(onsetId, parentVowelId):
                            if vowelEndsWithAsat[Int(parentVowelId)] {
                                let pre = vowelPreAsatScalar[Int(parentVowelId)]
                                let scalar = pre != 0 ? pre : onsetLastScalar[Int(onsetId)]
                                viramaUpper = Unicode.Scalar(scalar).map(Character.init)
                            } else {
                                viramaUpper = onsetTerminals[Int(onsetId)].onset
                            }
                        case let .vowelOnly(parentVowelId)
                            where vowelEndsWithAsat[Int(parentVowelId)]:
                            let pre = vowelPreAsatScalar[Int(parentVowelId)]
                            viramaUpper = pre != 0
                                ? Unicode.Scalar(pre).map(Character.init)
                                : nil
                        default:
                            viramaUpper = nil
                        }
                    default:
                        viramaUpper = nil
                    }
                } else {
                    viramaUpper = nil
                }

                for (onsetEnd, onsetEntry) in onsetMatches {
                    let stackLegal = viramaUpper.map {
                        Grammar.isValidStack(upper: $0, lower: onsetEntry.onset)
                    } ?? true
                    let onsetLegality = stackLegal
                        ? onsetBareLegality[Int(onsetEntry.id)]
                        : 0
                    let newState = ParseState(
                        parentIdx: prevIdx,
                        matchRef: .onsetOnly(onsetId: onsetEntry.id),
                        charEnd: Int32(onsetEnd),
                        score: previous.score + scoreMatch(
                            consumed: onsetEnd - i,
                            ruleCount: 1,
                            legality: onsetLegality,
                            aliasCost: onsetEntry.aliasCost
                        ),
                        legalityScore: previous.legalityScore + max(onsetLegality, 0),
                        aliasCost: previous.aliasCost + onsetEntry.aliasCost,
                        syllableCount: previous.syllableCount + 1,
                        structureCost: previous.structureCost + onsetEntry.structureCost,
                        isLegal: previous.isLegal && onsetLegality > 0
                    )
                    insertState(&arena, &dp, at: onsetEnd, state: newState, limit: maxResults)
                    matched = true

                    let vowelMatches = vowelMatchesByStart[onsetEnd]
                    for (vowelEnd, vowelEntry) in vowelMatches {
                        let key = Self.packPair(onsetEntry.id, vowelEntry.id)
                        let pairLegalityRaw: Int
                        if let cached = pairLegality[key] {
                            pairLegalityRaw = cached
                        } else {
                            pairLegalityRaw = Grammar.validateSyllable(
                                onset: onsetEntry.onset,
                                medials: onsetEntry.medials,
                                vowelRoman: vowelEntry.canonicalRoman
                            )
                            pairLegality[key] = pairLegalityRaw
                        }
                        let legality = stackLegal ? pairLegalityRaw : 0
                        let pairState = ParseState(
                            parentIdx: prevIdx,
                            matchRef: .onsetVowel(onsetId: onsetEntry.id, vowelId: vowelEntry.id),
                            charEnd: Int32(vowelEnd),
                            score: previous.score + scoreMatch(
                                consumed: vowelEnd - i,
                                ruleCount: 2,
                                legality: legality,
                                aliasCost: onsetEntry.aliasCost + vowelEntry.aliasCost
                            ),
                            legalityScore: previous.legalityScore + max(legality, 0),
                            aliasCost: previous.aliasCost + onsetEntry.aliasCost + vowelEntry.aliasCost,
                            syllableCount: previous.syllableCount + 1,
                            structureCost: previous.structureCost + onsetEntry.structureCost,
                            isLegal: previous.isLegal && legality > 0
                        )
                        insertState(&arena, &dp, at: vowelEnd, state: pairState, limit: maxResults)
                        matched = true
                    }
                }

                let previousEndedWithVowel: Bool
                switch previous.matchRef {
                case .onsetVowel, .vowelOnly: previousEndedWithVowel = true
                default: previousEndedWithVowel = false
                }

                for (vowelEnd, vowelEntry) in standaloneVowels where !vowelEntry.isPureMedial {
                    var legality = vowelOnlyLegality[Int(vowelEntry.id)]

                    // Kinzi rule: U+103A (asat) immediately before U+1039
                    // (virama) is legal only when the character two positions
                    // back is U+1004 (nga). Anything else is a stacking
                    // artifact from the DP combining an asat-final vowel with
                    // a virama vowel. Zero legality so the virama-only
                    // alternative wins when the beam holds both.
                    if vowelEntry.id == viramaVowelId {
                        var prevTrailsAsat = false
                        var prevPreAsat: UInt32 = 0
                        switch previous.matchRef {
                        case .onsetVowel(let onsetId, let vowelId):
                            if vowelEndsWithAsat[Int(vowelId)] {
                                prevTrailsAsat = true
                                let pre = vowelPreAsatScalar[Int(vowelId)]
                                prevPreAsat = pre != 0 ? pre : onsetLastScalar[Int(onsetId)]
                            }
                        case .vowelOnly(let vowelId):
                            if vowelEndsWithAsat[Int(vowelId)] {
                                prevTrailsAsat = true
                                prevPreAsat = vowelPreAsatScalar[Int(vowelId)]
                            }
                        default:
                            break
                        }
                        if prevTrailsAsat && prevPreAsat != 0x1004 {
                            legality = 0
                        }
                    }
                    // Stacking a dependent vowel sign onto a syllable that
                    // already carries a vowel is orthographically unusual,
                    // but legal — the glyph exists and users occasionally
                    // want it. Add an aliasCost penalty at the final
                    // transition so a standalone-vowel alternative (e.g.
                    // ဥ via `u2.`) outranks it when both are available.
                    let stackedFinal =
                        !vowelEntry.isStandalone
                        && previousEndedWithVowel
                        && vowelEnd == n
                    let aliasCostAdj = vowelEntry.aliasCost + (stackedFinal ? 2 : 0)
                    let newState = ParseState(
                        parentIdx: prevIdx,
                        matchRef: .vowelOnly(vowelId: vowelEntry.id),
                        charEnd: Int32(vowelEnd),
                        score: previous.score + scoreMatch(
                            consumed: vowelEnd - i,
                            ruleCount: 1,
                            legality: legality,
                            aliasCost: aliasCostAdj
                        ),
                        legalityScore: previous.legalityScore + max(legality, 0),
                        aliasCost: previous.aliasCost + aliasCostAdj,
                        syllableCount: previous.syllableCount + 1,
                        structureCost: previous.structureCost,
                        isLegal: previous.isLegal && legality > 0
                    )
                    insertState(&arena, &dp, at: vowelEnd, state: newState, limit: maxResults)
                    matched = true
                }

                if !matched {
                    let newState = ParseState(
                        parentIdx: prevIdx,
                        matchRef: .skip,
                        charEnd: Int32(i + 1),
                        score: previous.score - 100,
                        legalityScore: previous.legalityScore,
                        aliasCost: previous.aliasCost,
                        syllableCount: previous.syllableCount,
                        structureCost: previous.structureCost,
                        isLegal: false
                    )
                    insertState(&arena, &dp, at: i + 1, state: newState, limit: maxResults)
                }
            }
        }

        return (arena, dp)
    }

    // MARK: - Matching

    /// Match onset entries (consonant + optional medials) at position.
    private func matchOnsets(_ chars: [Character], from start: Int) -> [(end: Int, entry: OnsetEntry)] {
        var results: [OnsetMatch] = []
        let remaining = chars.count - start
        guard remaining > 0 else { return results }
        let maxLen = min(onsetTrie.maxDepth, remaining)

        var nodeIdx: Int32 = 0
        for offset in 0..<maxLen {
            guard let byte = chars[start + offset].asciiValue else { break }
            let child = onsetTrie.children[Int(nodeIdx) * 128 + Int(byte)]
            if child < 0 { break }
            nodeIdx = child
            let startRange = onsetTrie.terminalStart[Int(nodeIdx)]
            let endRange = onsetTrie.terminalStart[Int(nodeIdx) + 1]
            if startRange < endRange {
                let end = start + offset + 1
                for i in Int(startRange)..<Int(endRange) {
                    results.append((end, onsetTerminals[i]))
                }
            }
        }
        return results
    }

    /// Match vowel/final at position.
    private func matchVowels(_ chars: [Character], from start: Int) -> [(end: Int, entry: VowelMatchEntry)] {
        var results: [VowelMatch] = []
        let remaining = chars.count - start
        guard remaining > 0 else { return results }
        let maxLen = min(vowelTrie.maxDepth, remaining)

        var nodeIdx: Int32 = 0
        for offset in 0..<maxLen {
            guard let byte = chars[start + offset].asciiValue else { break }
            let child = vowelTrie.children[Int(nodeIdx) * 128 + Int(byte)]
            if child < 0 { break }
            nodeIdx = child
            let startRange = vowelTrie.terminalStart[Int(nodeIdx)]
            let endRange = vowelTrie.terminalStart[Int(nodeIdx) + 1]
            if startRange < endRange {
                let end = start + offset + 1
                for i in Int(startRange)..<Int(endRange) {
                    results.append((end, vowelTerminals[i]))
                }
            }
        }
        return results
    }

    private func precomputeOnsetMatches(_ chars: [Character]) -> [[OnsetMatch]] {
        var matches = Array(repeating: [OnsetMatch](), count: chars.count + 1)
        guard !chars.isEmpty else { return matches }

        for index in 0..<chars.count {
            matches[index] = matchOnsets(chars, from: index)
        }
        return matches
    }

    private func precomputeVowelMatches(_ chars: [Character]) -> [[VowelMatch]] {
        var matches = Array(repeating: [VowelMatch](), count: chars.count + 1)
        guard !chars.isEmpty else { return matches }

        for index in 0..<chars.count {
            matches[index] = matchVowels(chars, from: index)
        }
        return matches
    }

    // MARK: - Finalization

    /// A fully materialized candidate: scalar fields plus the reconstructed
    /// `output`/`reading` strings. Only produced for states that survive
    /// pre-filtering in `finalizeStates` — materialization cost is amortized
    /// over a handful of candidates rather than every DP transition.
    private struct MaterializedState {
        let state: ParseState
        let output: String
        let reading: String
    }

    private func finalizeStates(
        arena: [ParseState],
        finalIndices: [Int32],
        limit: Int,
        requestedReading: String
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
        for idx in filteredIndices {
            let (output, reading) = materialize(stateIdx: idx, arena: arena)
            materialized.append(MaterializedState(
                state: arena[Int(idx)],
                output: output,
                reading: reading
            ))
        }

        var markerPenaltyForReading: [String: Int] = [:]
        for state in materialized {
            markerPenaltyForReading[state.reading] = Self.explicitMarkerPenalty(
                requested: requestedReading,
                candidate: state.reading
            )
        }

        // Sort + dedup by `adjustLeadingVowel(output)`, matching legacy.
        materialized.sort {
            isBetter(
                $0,
                markerPenalty: markerPenaltyForReading[$0.reading] ?? Int.max,
                than: $1,
                markerPenalty: markerPenaltyForReading[$1.reading] ?? Int.max
            )
        }

        var deduplicated: [String: MaterializedState] = [:]
        for m in materialized {
            let adjustedOutput = adjustLeadingVowel(m.output)
            if let existing = deduplicated[adjustedOutput] {
                if isBetter(
                    m,
                    markerPenalty: markerPenaltyForReading[m.reading] ?? Int.max,
                    than: existing,
                    markerPenalty: markerPenaltyForReading[existing.reading] ?? Int.max
                ) {
                    deduplicated[adjustedOutput] = m
                }
            } else {
                deduplicated[adjustedOutput] = m
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
                rarity: rarityFor[adjustLeadingVowel(lhs.output)] ?? 0,
                markerPenalty: markerPenaltyForReading[lhs.reading] ?? Int.max,
                than: rhs,
                rarity: rarityFor[adjustLeadingVowel(rhs.output)] ?? 0,
                markerPenalty: markerPenaltyForReading[rhs.reading] ?? Int.max
            )
        }
        return sortedFinal.prefix(limit).map { m in
            let adjusted = adjustLeadingVowel(m.output)
            let viramaClean = !Self.hasMalformedViramaStack(adjusted)
            return SyllableParse(
                output: adjusted,
                reading: m.reading,
                aliasCost: m.state.aliasCost,
                legalityScore: (m.state.isLegal && viramaClean) ? m.state.legalityScore : 0,
                score: m.state.score,
                structureCost: m.state.structureCost,
                syllableCount: m.state.syllableCount,
                rarityPenalty: rarityFor[adjusted] ?? 0
            )
        }
    }

    /// Returns true if `output` contains a U+1039 (virama) whose left
    /// neighbour is not a base consonant and is not the asat-half of a
    /// kinzi marker (U+1004 U+103A U+1039). Virama orthographically only
    /// bonds consonant-to-consonant; attaching it to a vowel sign,
    /// independent vowel, or anusvara produces a scalar run no Myanmar
    /// shaper renders sensibly. Parses that contain such a sequence are
    /// demoted to `legalityScore = 0` so cleaner alternatives win.
    private static func hasMalformedViramaStack(_ output: String) -> Bool {
        let scalars = Array(output.unicodeScalars)
        for i in 0..<scalars.count where scalars[i].value == 0x1039 {
            guard i >= 1 else { return true }
            let prev = scalars[i - 1]
            if prev.value == 0x103A {
                let twoBack = i >= 2 ? scalars[i - 2].value : 0
                if twoBack != 0x1004 { return true }
                continue
            }
            if Romanization.consonantToRoman[Character(prev)] == nil {
                return true
            }
        }
        return false
    }

    /// Count rare-codepoint usages in an output surface so the final
    /// ranker can downweight parses the user did not explicitly spell.
    /// +1 per Pali retroflex consonant (these are correctly selected with
    /// "t2" / "d2" / "n2" / "l2" — their appearance under a bare onset is
    /// user-unexpected). Independent vowels are not penalized: the user
    /// already pays `aliasCost` for picking an independent-vowel variant,
    /// and explicit disambiguators like "u2." specifically request them.
    private static func computeRarityPenalty(_ output: String) -> Int {
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

    private struct NumericMarkerPlacement: Hashable {
        let offset: Int
        let marker: Character
    }

    private static func numericMarkerPlacements(in reading: String) -> Set<NumericMarkerPlacement> {
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

    private static func explicitMarkerPenalty(requested: String, candidate: String) -> Int {
        guard requested.contains(where: { Romanization.isNumericAliasMarker($0) }) else {
            return 0
        }
        let requestedPlacements = numericMarkerPlacements(in: requested)
        let candidatePlacements = numericMarkerPlacements(in: candidate)
        return requestedPlacements.symmetricDifference(candidatePlacements).count
    }

    /// Walk the `parentIdx` chain backward to the seed, collect each
    /// transition's contribution, then concatenate forward into a single
    /// `output`/`reading` pair. Only called for the handful of states that
    /// survive finalizing pre-filters.
    private func materialize(stateIdx: Int32, arena: [ParseState]) -> (output: String, reading: String) {
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

        for ref in refs {
            switch ref {
            case .seed, .skip:
                continue
            case .onsetOnly(let onsetId):
                let entry = onsetTerminals[Int(onsetId)]
                output.append(entry.myanmar)
                reading.append(entry.canonicalRoman)
                reading.append("a")
            case .onsetVowel(let onsetId, let vowelId):
                let onset = onsetTerminals[Int(onsetId)]
                let vowel = vowelTerminals[Int(vowelId)]
                output.append(onset.myanmar)
                output.append(vowel.myanmar)
                reading.append(onset.canonicalRoman)
                reading.append(vowel.canonicalRoman)
            case .vowelOnly(let vowelId):
                let entry = vowelTerminals[Int(vowelId)]
                output.append(entry.myanmar)
                reading.append(entry.canonicalRoman)
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
    private static func stripSpuriousAsatBeforeVirama(_ text: String) -> String {
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
    private static func canonicalizeMedialOrder(_ text: String) -> String {
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

    private func adjustLeadingVowel(_ text: String) -> String {
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

    // MARK: - Scoring

    /// Score a match. Mirrors the legacy engine: score = sum(pronunciation_lengths) - rule_count.
    /// `ruleCount` is how many atomic rules this match represents (1 for onset-only or vowel-only,
    /// 2 for onset+vowel combined).
    private func scoreMatch(consumed: Int, ruleCount: Int, legality: Int, aliasCost: Int) -> Int {
        var score = consumed - ruleCount
        if legality <= 0 {
            score -= 10000
        }
        score -= aliasCost
        return score
    }

    private func insertState(
        _ arena: inout [ParseState],
        _ dp: inout [DPBucket],
        at index: Int,
        state: ParseState,
        limit: Int
    ) {
        guard index < dp.count else { return }
        let stateIdx = Int32(arena.count)
        arena.append(state)
        dp[index].stateIndices.append(stateIdx)
        if dp[index].stateIndices.count > limit * 2 {
            dp[index].needsPrune = true
        }
    }

    private func pruneBucket(_ bucket: inout DPBucket, arena: [ParseState], limit: Int) {
        guard bucket.stateIndices.count > limit else {
            bucket.needsPrune = false
            return
        }
        bucket.stateIndices.sort { lhsIdx, rhsIdx in
            isBetterDP(arena[Int(lhsIdx)], than: arena[Int(rhsIdx)])
        }
        bucket.stateIndices.removeLast(bucket.stateIndices.count - limit)
        bucket.needsPrune = false
    }

    /// DP-internal ranking — operates on scalar fields only. The top-K
    /// surfaced to callers is re-sorted with the full string-aware tiebreak
    /// in `finalizeStates`, so DP-time order ties don't affect output.
    @inline(__always)
    private func isBetterDP(_ lhs: ParseState, than rhs: ParseState) -> Bool {
        if lhs.isLegal != rhs.isLegal {
            return lhs.isLegal
        }
        if lhs.aliasCost != rhs.aliasCost {
            return lhs.aliasCost < rhs.aliasCost
        }
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        if lhs.syllableCount != rhs.syllableCount {
            return lhs.syllableCount < rhs.syllableCount
        }
        if lhs.structureCost != rhs.structureCost {
            return lhs.structureCost < rhs.structureCost
        }
        return lhs.charEnd < rhs.charEnd
    }

    /// Final ranking — uses materialized strings for the legacy lex
    /// tiebreakers so the user-visible top-K order matches pre-refactor.
    ///
    /// `syllableCount` sits above `aliasCost` so that when `finalizeStates`
    /// widens the admitted set to `min+1` (for thin min-tiers), an extended
    /// parse with lower alias cost cannot displace the canonical min-tier
    /// parse at the top. Within a single tier all counts match, so this
    /// has no effect on pre-widening behavior.
    private func isBetter(
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
    private func isBetter(
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
        if lhs.state.structureCost != rhs.state.structureCost {
            return lhs.state.structureCost < rhs.state.structureCost
        }
        if lhs.output != rhs.output {
            return lhs.output < rhs.output
        }
        return lhs.reading < rhs.reading
    }
}
