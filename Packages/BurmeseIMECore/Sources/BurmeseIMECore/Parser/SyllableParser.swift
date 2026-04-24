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
///
/// The implementation is split across topic-focused files under `Parser/`:
///
/// - `NBestDP.swift` — the DP hot loop (`runDP`, `nBestParse`), DP-internal
///   scoring / comparator, and the virama / soft-boundary context helpers.
/// - `Matching.swift` — onset / vowel trie walks, medial-order canonicalizer,
///   per-position precomputation.
/// - `Finalization.swift` — `MaterializedState`, `finalizeStates`,
///   output-scalar post-processing (asat/virama cleanup, medial-order
///   canonicalisation, leading-vowel adjustment), and the materialized
///   ranking comparators.
public final class SyllableParser: Sendable {

    /// How a state extends its parent. Replaces per-state `output`/`reading`
    /// strings — the full surface is reconstructed only for the final top-K
    /// in `finalizeStates` by walking the `parentIdx` chain.
    internal enum MatchRef: Hashable, Sendable {
        case seed
        case skip
        case onsetOnly(onsetId: Int32)
        case onsetVowel(onsetId: Int32, vowelId: Int32)
        case vowelOnly(vowelId: Int32)
    }

    /// DP state. Holds only scalars + a back-pointer; the `output` and
    /// `reading` strings are derived on demand from the `matchRef` chain.
    internal struct ParseState: Sendable {
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

    internal typealias OnsetMatch = (end: Int, entry: OnsetEntry)
    internal typealias VowelMatch = (end: Int, entry: VowelMatchEntry)

    /// Flat ASCII trie used to match onsets/vowels without per-lookup string
    /// slicing. Parser input is normalized to lowercase ASCII composing
    /// characters plus numeric alias markers (`2`/`3`), so a fixed 128-wide
    /// children table covers every character the walker can encounter.
    /// Nodes with terminal payloads store a half-open range into a per-trie
    /// payload array — one trie for onsets, one for vowels.
    internal struct AsciiTrieTable: Sendable {
        /// `children[node * 128 + byte] = childNode` (`-1` if absent).
        let children: [Int32]
        /// Per-node half-open terminal range: `terminalStart[n]..<terminalStart[n+1]`
        /// indexes into the payload array of the owning trie.
        let terminalStart: [Int32]
        /// Deepest path in the trie — bounds the walk.
        let maxDepth: Int
    }

    internal let onsetTrie: AsciiTrieTable
    internal let onsetTerminals: [OnsetEntry]

    internal let vowelTrie: AsciiTrieTable
    internal let vowelTerminals: [VowelMatchEntry]

    /// Pre-computed `Grammar.validateSyllable` result for each onset entry
    /// paired with vowelRoman = "a" (the inherent vowel used by onset-only
    /// transitions). Indexed by `OnsetEntry.id`.
    internal let onsetBareLegality: [Int]

    /// Pre-computed `Grammar.validateSyllable` result for each standalone-vowel
    /// transition (onset: nil). Indexed by `VowelMatchEntry.id`.
    internal let vowelOnlyLegality: [Int]

    /// `VowelMatchEntry.id` of the virama connector (`+`), or `-1` if the
    /// vowel table has no virama entry. Used in the hot DP loop to detect
    /// stack contexts with an integer compare rather than a string compare.
    internal let viramaVowelId: Int32

    /// `VowelMatchEntry.id` of the empty-emission `+` fallback — a "soft
    /// syllable boundary" emitted in two disjoint cases:
    ///
    ///   1. Digraph-collision after a kinzi/asat-ending vowel:
    ///      `pyin+thit` → the `t` of `th` shouldn't be consumed as
    ///      subscript, leaving an orphan `h`. Gated on a legal short
    ///      stack + unstackable long onset both existing.
    ///   2. Syllable-break after a plain vowel: `ka+ta+pa` and similar
    ///      chains where `+` can't form a valid stack (cross-class or
    ///      depth-capped). Gated on the next onset being either
    ///      cross-class-illegal or subject to the digraph collision.
    ///
    /// A bare `onsetOnly(X)` parent is never a soft-boundary site — the
    /// user has typed no vowel, so a virama stack is the natural reading
    /// (e.g. `k+ya` stays illegal rather than collapsing to `ကယ`).
    /// Only emitted when gating in the DP succeeds.
    internal let softBoundaryViramaVowelId: Int32

    /// Per-vowel: non-zero when the vowel's rendered Myanmar ends with
    /// U+103A (asat) and contains at least two scalars; the value is the
    /// scalar immediately preceding the trailing asat. Used by the
    /// kinzi rule (`U+103A` is only legal before a virama when the
    /// preceding base is nga, U+1004). Zero when the vowel does not
    /// end with asat, or ends with a lone asat (the `*` vowel) — callers
    /// fall through to the parent state's chunk in that case.
    internal let vowelPreAsatScalar: [UInt32]

    /// Per-vowel: true iff the vowel's rendered Myanmar ends with U+103A.
    internal let vowelEndsWithAsat: [Bool]

    /// Per-onset: the last scalar in the onset's rendered Myanmar. Used
    /// to recover the base when a lone-asat vowel follows (`.onsetVowel`
    /// with the `*` vowel), so the kinzi check has a base to inspect.
    internal let onsetLastScalar: [UInt32]

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
                let baseAliasCost = cons.aliasCost + (allLegal ? 0 : 100)

                appendOnset(
                    canonicalRoman: canonicalRoman,
                    myanmar: myanmarOutput,
                    onset: cons.myanmar,
                    medials: combo,
                    baseAliasCost: baseAliasCost
                )

                // Natural-order medial permutations are handled at lookup
                // time by `matchOnsets`, which canonicalizes any
                // post-consonant run of `{y, w, h}` letters (and the
                // two-char `y2` = ya-pin form) into the `h + cons + w
                // + y + y2` canonical order before probing the trie.
                // The trie only stores canonical entries; the lookup
                // step covers every permutation the previous
                // init-time expansion materialized. See
                // `canonicalizeOnsetProbes` below for the `h`-digraph
                // disambiguation rule ported from here.
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
        var foundSoftBoundaryId: Int32 = -1
        var vowelEndsAsat = [Bool](repeating: false, count: builtVowelTrie.terminals.count)
        var vowelPreAsat = [UInt32](repeating: 0, count: builtVowelTrie.terminals.count)
        for (idx, entry) in builtVowelTrie.terminals.enumerated() {
            vowelOnlyLegalities[idx] = Grammar.validateSyllable(
                onset: nil,
                medials: [],
                vowelRoman: entry.canonicalRoman
            )
            if entry.canonicalRoman == "+" {
                if entry.myanmar.isEmpty {
                    if foundSoftBoundaryId < 0 { foundSoftBoundaryId = entry.id }
                } else if foundViramaId < 0 {
                    foundViramaId = entry.id
                }
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
        self.softBoundaryViramaVowelId = foundSoftBoundaryId
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

    /// Normalize a reading into the parser's internal byte set: lowercase
    /// it and strip anything that is neither a composing character nor a
    /// numeric alias marker. Exposed so the lattice decoder can align its
    /// per-position arc enumeration against the same buffer the DP sees.
    public static func normalizeForParser(_ input: String) -> String {
        String(input.lowercased().filter {
            Romanization.composingCharacters.contains($0) || Romanization.isNumericAliasMarker($0)
        })
    }

    /// Parse a romanized buffer into its best Burmese output.
    public func parse(_ input: String) -> [SyllableParse] {
        parseCandidates(input, maxResults: 1)
    }

    /// Parse a romanized buffer into multiple Burmese candidates.
    ///
    /// - Parameter isFullBuffer: when `true`, a leading empty-output
    ///   standalone `a` before further content is promoted to an explicit
    ///   U+1021 (independent vowel) so buffers like `atar` render as
    ///   အတာ rather than consuming the `a` silently into the next onset.
    ///   When `false` (e.g. a sliding-window active-tail parse), the
    ///   promotion is suppressed so the tail does not spuriously inject
    ///   an independent vowel in the middle of the user's buffer.
    public func parseCandidates(
        _ input: String,
        maxResults: Int = 8,
        isFullBuffer: Bool = true
    ) -> [SyllableParse] {
        parseCandidates(
            input,
            maxResults: maxResults,
            isFullBuffer: isFullBuffer,
            allowLiberalStacks: false
        )
    }

    internal func parseCandidates(
        _ input: String,
        maxResults: Int,
        isFullBuffer: Bool,
        allowLiberalStacks: Bool
    ) -> [SyllableParse] {
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
            maxResults: beamWidth,
            allowLiberalStacks: allowLiberalStacks
        )
        return finalizeStates(
            arena: arena,
            finalIndices: finalIndices,
            limit: maxResults,
            requestedReading: normalized,
            isFullBuffer: isFullBuffer
        )
    }

    /// Single-syllable placement anchored at a concrete character span of
    /// the normalized reading. Used by the lattice decoder as the fallback
    /// arc set when no lexicon entry covers a position — one call to
    /// `syllableArcs` produces every legal (onset + optional vowel) and
    /// every standalone-vowel syllable that fits inside the buffer, so the
    /// decoder can traverse arbitrary readings without per-position
    /// re-parsing.
    public struct SyllableArc: Sendable {
        public let start: Int
        public let end: Int
        public let output: String
        public let reading: String
        public let aliasCost: Int
        /// Parser DP score for a single match (consumed-chars minus rule
        /// count minus aliasCost; illegal arcs carry a heavy negative
        /// penalty — mirrors `scoreMatch`).
        public let score: Int
        public let isLegal: Bool
    }

    /// Enumerate every single-syllable placement reachable inside the
    /// normalized reading. Each arc consumes `chars[start..<end]` and
    /// produces the corresponding Myanmar `output`. Covers:
    ///
    /// - Onset-only transitions (inherent-vowel syllable, e.g. `t` → `တ`).
    /// - Onset + vowel pairs (e.g. `tar` → `တာ`).
    /// - Standalone vowels / independent-vowel entries (e.g. `a` → `အ`).
    ///
    /// No soft-boundary virama or stack-inference arcs are emitted — those
    /// are engine-level compound rewrites; the lattice leaves stacks to
    /// the curated lexicon, which already holds the correct surfaces.
    ///
    /// The reading span is sliced from the *normalized* input, so callers
    /// that work off the original buffer must normalize first if they
    /// need positional alignment. The character range is inclusive on
    /// `start`, exclusive on `end`, in character units (not bytes).
    public func syllableArcs(_ input: String) -> [SyllableArc] {
        let normalized = Self.normalizeForParser(input)
        guard !normalized.isEmpty else { return [] }
        let chars = Array(normalized)
        let onsetMatchesByStart = precomputeOnsetMatches(chars)
        let vowelMatchesByStart = precomputeVowelMatches(chars)
        var pairLegality: [UInt64: Int] = [:]

        var arcs: [SyllableArc] = []
        arcs.reserveCapacity(chars.count * 8)

        for i in 0..<chars.count {
            // Onset-only: bare consonant takes the inherent 'a'. Skip
            // zero-length onsets.
            for (onsetEnd, onsetEntry) in onsetMatchesByStart[i] where onsetEnd > i {
                let onsetLegality = onsetBareLegality[Int(onsetEntry.id)]
                let onsetReading = String(chars[i..<onsetEnd])
                let onsetScore = (onsetEnd - i) - 1 - onsetEntry.aliasCost
                    + (onsetLegality > 0 ? 0 : -10000)
                arcs.append(SyllableArc(
                    start: i,
                    end: onsetEnd,
                    output: onsetEntry.myanmar,
                    reading: onsetReading,
                    aliasCost: onsetEntry.aliasCost,
                    score: onsetScore,
                    isLegal: onsetLegality > 0
                ))

                // Onset + vowel pairs.
                for (vowelEnd, vowelEntry) in vowelMatchesByStart[onsetEnd] {
                    // Skip the soft-boundary virama marker — it is a DP
                    // connector, not a user-facing syllable.
                    if vowelEntry.id == softBoundaryViramaVowelId { continue }
                    let key = Self.packPair(onsetEntry.id, vowelEntry.id)
                    let legality: Int
                    if let cached = pairLegality[key] {
                        legality = cached
                    } else {
                        let raw = Grammar.validateSyllable(
                            onset: onsetEntry.onset,
                            medials: onsetEntry.medials,
                            vowelRoman: vowelEntry.canonicalRoman
                        )
                        pairLegality[key] = raw
                        legality = raw
                    }
                    let reading = String(chars[i..<vowelEnd])
                    let score = (vowelEnd - i) - 2 - (onsetEntry.aliasCost + vowelEntry.aliasCost)
                        + (legality > 0 ? 0 : -10000)
                    arcs.append(SyllableArc(
                        start: i,
                        end: vowelEnd,
                        output: onsetEntry.myanmar + vowelEntry.myanmar,
                        reading: reading,
                        aliasCost: onsetEntry.aliasCost + vowelEntry.aliasCost,
                        score: score,
                        isLegal: legality > 0
                    ))
                }
            }

            // Standalone vowels / independent-vowel entries.
            for (vowelEnd, vowelEntry) in vowelMatchesByStart[i]
            where vowelEntry.isStandalone && vowelEnd > i {
                if vowelEntry.id == softBoundaryViramaVowelId { continue }
                let legality = vowelOnlyLegality[Int(vowelEntry.id)]
                let reading = String(chars[i..<vowelEnd])
                let score = (vowelEnd - i) - 1 - vowelEntry.aliasCost
                    + (legality > 0 ? 0 : -10000)
                arcs.append(SyllableArc(
                    start: i,
                    end: vowelEnd,
                    output: vowelEntry.myanmar,
                    reading: reading,
                    aliasCost: vowelEntry.aliasCost,
                    score: score,
                    isLegal: legality > 0
                ))
            }
        }
        return arcs
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
        let finalizationLimit = chars.count > 20
            ? max(maxResults, 32)
            : max(maxResults, 4)
        let beamWidth = max(finalizationLimit * 16, 128)
        let onsetMatchesByStart = precomputeOnsetMatches(chars)
        let vowelMatchesByStart = precomputeVowelMatches(chars)
        var (arena, dp) = runDP(
            chars,
            onsetMatchesByStart: onsetMatchesByStart,
            vowelMatchesByStart: vowelMatchesByStart,
            maxResults: beamWidth
        )

        // Walk buckets backward with a scalar-only probe: at each position
        // pick the best legal and best illegal state via `isBetterDP`,
        // materialize only those (at most two string reconstructions per
        // bucket), and test acceptability. `finalizeStates` — which
        // materializes every surviving candidate, builds a marker-penalty
        // map, and runs multiple sorts — is deferred until a bucket has
        // committed to acceptance, so long garbage inputs pay scalar work
        // per bucket instead of the full ranking cost. The illegal-state
        // probe is only useful when an asat-virama clean-stack rescue could
        // apply, which requires `+` somewhere in the reading; when the
        // buffer has no `+` we skip that path entirely.
        let hasViramaInBuffer = chars.contains("+")
        for k in stride(from: chars.count, through: 1, by: -1) {
            if dp[k].needsPrune {
                pruneBucket(&dp[k], arena: arena, limit: beamWidth)
            }

            var bestLegal: Int32 = -1
            var bestIllegal: Int32 = -1
            for idx in dp[k].stateIndices {
                let s = arena[Int(idx)]
                guard s.syllableCount > 0 else { continue }
                if s.isLegal {
                    if bestLegal < 0 || isBetterDP(s, than: arena[Int(bestLegal)]) {
                        bestLegal = idx
                    }
                } else if hasViramaInBuffer {
                    if bestIllegal < 0 || isBetterDP(s, than: arena[Int(bestIllegal)]) {
                        bestIllegal = idx
                    }
                }
            }
            if bestLegal < 0 && bestIllegal < 0 { continue }

            var probeAccepted = false
            for idx in [bestLegal, bestIllegal] where idx >= 0 {
                let s = arena[Int(idx)]
                let (output, reading) = materialize(stateIdx: idx, arena: arena)
                let probe = SyllableParse(
                    output: adjustLeadingVowel(output),
                    reading: reading,
                    aliasCost: s.aliasCost,
                    legalityScore: s.isLegal ? s.legalityScore : 0,
                    score: s.score,
                    structureCost: s.structureCost,
                    syllableCount: s.syllableCount,
                    rarityPenalty: 0
                )
                if acceptable(probe) {
                    probeAccepted = true
                    break
                }
            }
            guard probeAccepted else { continue }

            let parses = finalizeStates(
                arena: arena,
                finalIndices: dp[k].stateIndices,
                limit: finalizationLimit,
                requestedReading: String(chars.prefix(k))
            )
            if parses.contains(where: acceptable) {
                return (k, Array(parses.prefix(maxResults)))
            }
            if probeAccepted {
                return (k, Array(parses.prefix(maxResults)))
            }
        }
        return (0, [])
    }
}
