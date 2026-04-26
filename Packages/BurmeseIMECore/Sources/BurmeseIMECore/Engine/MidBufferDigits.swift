import Foundation

extension BurmeseEngine {

    /// Returns true when the string contains at least one ASCII digit.
    internal static func containsDigit(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value >= 0x30 && $0.value <= 0x39 }
    }

    internal static func isAsciiDigit(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
            return false
        }
        return scalar.value >= 0x30 && scalar.value <= 0x39
    }

    internal static func isAsciiLowerLetter(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
            return false
        }
        return scalar.value >= 0x61 && scalar.value <= 0x7A
    }

    /// Strip ASCII digit runs that sit between two composable letters, so
    /// the surrounding letters parse as a unified syllable rather than
    /// being severed at the digit. Each stripped digit is recorded with
    /// the character offset into the cleaned buffer where it was found;
    /// the caller splices it back into the composed surface at the
    /// scalar position corresponding to that prefix.
    ///
    /// A digit run is "mid-buffer" only when framed by `a`–`z` letters on
    /// both sides. Trailing-digit shapes (`u2`, `pa2`) and digits sitting
    /// beside non-letter composables (`u2:`, `u.2`, `min2+ga`) keep the
    /// existing literal-tail behaviour.
    static func extractMidBufferDigits(
        _ buffer: String
    ) -> (cleaned: String, insertions: [(offset: Int, digit: Character)]) {
        // Quick exit: no ASCII digits means nothing to extract, no
        // allocation, no char-array walk.
        var hasDigit = false
        for scalar in buffer.unicodeScalars
        where scalar.value >= 0x30 && scalar.value <= 0x39 {
            hasDigit = true
            break
        }
        guard hasDigit else { return (buffer, []) }
        let chars = Array(buffer)
        var cleaned: [Character] = []
        cleaned.reserveCapacity(chars.count)
        var insertions: [(Int, Character)] = []
        var i = 0
        while i < chars.count {
            if isAsciiDigit(chars[i]) {
                var j = i
                while j < chars.count, isAsciiDigit(chars[j]) { j += 1 }
                let precededByLetter = i >= 1 && isAsciiLowerLetter(chars[i - 1])
                let followedByLetter = j < chars.count && isAsciiLowerLetter(chars[j])
                if precededByLetter && followedByLetter {
                    for k in i..<j {
                        insertions.append((cleaned.count, chars[k]))
                    }
                } else {
                    cleaned.append(contentsOf: chars[i..<j])
                }
                i = j
            } else {
                cleaned.append(chars[i])
                i += 1
            }
        }
        return (String(cleaned), insertions)
    }

    /// Splice mid-buffer digits back into candidate surfaces. For each
    /// insertion, computes a scalar splice position from the cleaned-
    /// buffer parse's character-to-scalar provenance map (TASK-002). The
    /// previous implementation re-parsed only the letter prefix
    /// `chars[0..<K]` standalone and counted its output scalars — that
    /// works only when the cleaned-buffer parse leaves the prefix
    /// unchanged, but breaks when the cleaned-buffer parse re-segments
    /// the prefix's tail letter with the suffix's head (e.g. `tar1ar`
    /// where the suffix `ar` makes the cleaned `tarar` parse merge `r`
    /// into a `ra` consonant: `တရာ`, with the prefix's `တာ` gone).
    ///
    /// The new approach: re-parse the full cleaned buffer with N-best,
    /// inspect each parse's `arcBoundaries`, and prefer parses whose
    /// char-segmentation has an arc boundary at every digit offset.
    /// Among the engine's candidates, find one whose surface matches
    /// such a "boundary-aligned" parse and promote it to rank 0. The
    /// splice positions for that candidate come from the parse's own
    /// boundary map, so the digit always lands at the user's intended
    /// syllable break. Non-aligned candidates keep the legacy
    /// prefix-only-parse splice with the snap-forward heuristic so
    /// existing safety nets (kinzi, medial, asat) still apply.
    ///
    /// Emits a Myanmar-digit primary and ASCII-digit secondary variant
    /// per candidate, matching trailing-digit behaviour.
    internal func spliceMidBufferDigits(
        into candidates: [Candidate],
        cleaned: String,
        insertions: [(offset: Int, digit: Character)]
    ) -> [Candidate] {
        guard !insertions.isEmpty else { return candidates }
        let cleanedChars = Array(cleaned)
        let insertionOffsets = insertions.map(\.offset)
        let uniqueOffsets = Array(Set(insertionOffsets)).sorted()

        // Pull top-K cleaned-buffer parses with their per-arc boundaries.
        // Each parser parse is run through the same surface-adjusting
        // post-processing the engine applies before exposing candidates
        // (`promoteOrphanZwnjToImplicitA`, `promoteOrphanInternalMarks`,
        // `correctAaShape`), and the arc boundaries are remapped through
        // those transformations so the per-(charEnd, scalarOffset)
        // mapping aligns with the engine's user-visible candidate
        // surface. We then look up engine candidates by surface and use
        // the matching parse's provenance map for the splice.
        let normalizedCleaned = Self.normalizeForParser(cleaned)
        var boundaryAlignedSurfaces: [String: [Int: Int]] = [:]
        if !normalizedCleaned.isEmpty {
            let topParses = parser.parseCandidates(normalizedCleaned, maxResults: 16)
            for parse in topParses where !parse.arcBoundaries.isEmpty {
                // Try every surface variant the engine can yield from
                // this parse: raw, orphan-internal-promoted,
                // zwnj-promoted, and zwnj-then-internal-promoted. Each
                // variant carries its own (possibly remapped) boundary
                // list. We register all of them so a candidate
                // surface lookup can find the matching variant.
                var surfaceVariants: [(SyllableParse, [SyllableParse.ArcBoundary])] = []
                surfaceVariants.append((parse, parse.arcBoundaries))
                if let zwnj = Self.promoteOrphanZwnjToImplicitA(parse) {
                    surfaceVariants.append((zwnj, zwnj.arcBoundaries))
                    if let zwnjThenInternal = Self.promoteOrphanInternalMarks(zwnj) {
                        surfaceVariants.append((zwnjThenInternal, zwnjThenInternal.arcBoundaries))
                    }
                }
                if let internalOnly = Self.promoteOrphanInternalMarks(parse) {
                    surfaceVariants.append((internalOnly, internalOnly.arcBoundaries))
                }
                for (variant, boundaries) in surfaceVariants {
                    let boundaryMap = Dictionary(
                        uniqueKeysWithValues: boundaries.map { ($0.charEnd, $0.scalarOffset) }
                    )
                    // A parse is "boundary-aligned" iff every digit char
                    // offset falls on an arc boundary in this parse.
                    guard uniqueOffsets.allSatisfy({ boundaryMap[$0] != nil }) else {
                        continue
                    }
                    let surface = Self.correctAaShape(variant.output)
                    if boundaryAlignedSurfaces[surface] == nil {
                        var perOffset: [Int: Int] = [:]
                        for off in uniqueOffsets {
                            perOffset[off] = boundaryMap[off]!
                        }
                        boundaryAlignedSurfaces[surface] = perOffset
                    }
                }
            }
        }

        // Compute fallback splice positions via the legacy prefix-only
        // parse. Used for non-aligned candidates and as the splice for
        // boundary-aligned candidates whose surface dictionary lookup
        // misses (defensive — should not happen given `correctAaShape`).
        var fallbackPositionByOffset: [Int: Int] = [:]
        for offset in uniqueOffsets {
            let prefixChars = cleanedChars.prefix(offset)
            let prefix = String(prefixChars)
            let normalized = Self.normalizeForParser(prefix)
            let position: Int
            if normalized.isEmpty {
                position = 0
            } else if let parse = parser.parseCandidates(normalized, maxResults: 1).first {
                position = parse.output.unicodeScalars.count
            } else {
                position = prefix.unicodeScalars.count
            }
            fallbackPositionByOffset[offset] = position
        }

        let burmeseDigits: [Unicode.Scalar] = insertions.map { insertion in
            let raw = insertion.digit.unicodeScalars.first!.value
            return Unicode.Scalar(0x1040 + (raw - 0x30))!
        }
        let asciiDigits: [Unicode.Scalar] = insertions.map {
            $0.digit.unicodeScalars.first!
        }

        // Promote candidates whose surface matches a boundary-aligned
        // parse before the rest. Within each tier the original engine
        // ranking is preserved. When at least one aligned candidate
        // exists, drop the unaligned ones — their splice would land
        // mid-cluster and produce a `<digit><dep-vowel>` adjacency that
        // breaks the prefix syllable (TASK-002 acceptance criteria).
        // Unaligned candidates are kept only when no aligned sibling
        // survives.
        let aligned = candidates.filter {
            boundaryAlignedSurfaces[$0.surface] != nil
        }
        let unaligned = candidates.filter {
            boundaryAlignedSurfaces[$0.surface] == nil
        }
        let orderedCandidates = aligned.isEmpty ? unaligned : aligned

        var result: [Candidate] = []
        var seen: Set<String> = []
        for candidate in orderedCandidates {
            // Pick splice positions per-candidate: aligned candidates use
            // their own parse's provenance map; unaligned candidates use
            // the legacy fallback, with `insertScalars`'s snap-forward
            // heuristic correcting the worst boundary mistakes.
            let splicePositions: [Int]
            if let perOffset = boundaryAlignedSurfaces[candidate.surface] {
                splicePositions = insertionOffsets.map { perOffset[$0]! }
            } else {
                splicePositions = insertionOffsets.map { fallbackPositionByOffset[$0]! }
            }
            let burmese = Self.insertScalars(
                into: candidate.surface,
                scalars: burmeseDigits,
                at: splicePositions
            )
            if seen.insert(burmese).inserted {
                result.append(Candidate(
                    surface: burmese,
                    reading: candidate.reading,
                    source: candidate.source,
                    score: candidate.score
                ))
            }
            let ascii = Self.insertScalars(
                into: candidate.surface,
                scalars: asciiDigits,
                at: splicePositions
            )
            if ascii != burmese, seen.insert(ascii).inserted {
                result.append(Candidate(
                    surface: ascii,
                    reading: candidate.reading,
                    source: candidate.source,
                    score: candidate.score
                ))
            }
        }
        return result
    }

    /// Insert `scalars[i]` at scalar offset `positions[i]` in `surface`.
    /// Each position is snapped forward past any virama-stack cluster in
    /// the candidate surface — the prefix parse used to compute splice
    /// offsets can disagree with the full-buffer parse when stack
    /// inference fires (e.g. `brahm` parses as 4 scalars in isolation but
    /// the full `brahma` parse renders 5 scalars with an internal virama).
    /// Without the snap the digit lands between the virama and its lower
    /// consonant, shattering the cluster.
    ///
    /// Adjacent digits in a single mid-buffer run share the same splice
    /// offset (e.g. all four insertions for `kar1234kar` carry the same
    /// `position`). Inserting them one at a time at a fixed position
    /// reverses the run — each new insertion at `p` pushes the previously
    /// inserted scalar to `p+1`, so the first inserted ends up rightmost.
    /// Group insertions by snapped position and splice each group with a
    /// single `insert(contentsOf:)` call, preserving the within-group
    /// typed order without depending on sort stability (TASK-001).
    internal static func insertScalars(
        into surface: String,
        scalars: [Unicode.Scalar],
        at positions: [Int]
    ) -> String {
        precondition(scalars.count == positions.count)
        var working = Array(surface.unicodeScalars)
        let snapped = positions.map { snapSpliceForward(working.map(\.value), position: $0) }
        // Bucket scalars by splice position, preserving the original
        // order within each bucket. Then walk distinct positions in
        // descending order so earlier offsets remain valid as later
        // splices shift the array right.
        var groups: [Int: [Unicode.Scalar]] = [:]
        var positionOrder: [Int] = []
        for (pos, scalar) in zip(snapped, scalars) {
            if groups[pos] == nil {
                groups[pos] = [scalar]
                positionOrder.append(pos)
            } else {
                groups[pos]!.append(scalar)
            }
        }
        for pos in positionOrder.sorted(by: >) {
            let clamped = max(0, min(pos, working.count))
            working.insert(contentsOf: groups[pos]!, at: clamped)
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: working)
        return String(view)
    }

    /// Returns the smallest position ≥ `pos` that does not sit inside a
    /// Myanmar virama-stack cluster or between a consonant base and one
    /// of its medial scalars. Snaps past:
    ///
    /// - A leading virama (and the lower consonant that must follow it).
    /// - Any consonant whose preceding scalar is a virama (i.e. the lower
    ///   of a stacked pair — inserting before it would leave a dangling
    ///   virama).
    /// - Any medial scalar (U+103B–U+103E) that follows a consonant base
    ///   on the left side of the splice. Medials physically attach to the
    ///   base in Unicode storage order; no romanization rule emits an
    ///   isolated medial without a preceding consonant, so the user
    ///   cannot have meaningfully intended a digit between them.
    /// - An asat (U+103A) that closes the cluster on its left side, when
    ///   the preceding scalar is itself part of the same cluster (a
    ///   consonant base, medial, dep-vowel sign, or anusvara U+1036).
    ///   The asat is the syllable terminator — placing a digit between
    ///   it and the rest of the cluster would split base+vowel from its
    ///   closing mark, an orthographic-ordering violation. This snap
    ///   compensates for splice positions computed from a digit-stripped
    ///   prefix's standalone parse that does not see the kinzi virama
    ///   the full-buffer parse infers (TASK-001).
    ///
    /// Dependent vowels (U+102B–U+1032) and tone marks (U+1037 / U+1038)
    /// themselves are NOT snapped: the mid-buffer-digit design
    /// intentionally allows the digit to act as a hard syllable break
    /// across those (see `RankingSuite.task10_midDigitTop_*`).
    internal static func snapSpliceForward(_ scalars: [UInt32], position pos: Int) -> Int {
        var p = max(0, min(pos, scalars.count))
        while p < scalars.count {
            let cur = scalars[p]
            let prev: UInt32 = p > 0 ? scalars[p - 1] : 0
            if cur == 0x1039 {
                p += 1
                if p < scalars.count { p += 1 }
                continue
            }
            if prev == 0x1039 {
                p += 1
                continue
            }
            if cur >= 0x103B && cur <= 0x103E,
               (prev >= 0x1000 && prev <= 0x1021) || (prev >= 0x103B && prev <= 0x103E) {
                p += 1
                continue
            }
            // Snap past a closing asat that is bound to the cluster on
            // its left. `prev` belonging to the cluster means: a
            // consonant base, medial, dep-vowel sign, or anusvara.
            // Without this the digit would land between (vowel | medial)
            // and the asat that closes the same syllable.
            if cur == 0x103A,
               (prev >= 0x1000 && prev <= 0x1021)
                || (prev >= 0x102B && prev <= 0x1032)
                || (prev >= 0x1036 && prev <= 0x1036)
                || (prev >= 0x103B && prev <= 0x103E) {
                p += 1
                continue
            }
            break
        }
        return p
    }

    /// True when the tail begins with an ASCII digit. Digits at the very
    /// start of the tail signal "digit-separator mode" — letter runs
    /// sandwiched between digits should still compose. Other punctuation
    /// at the tail head means the user has committed to a literal tail
    /// and any following letters stay verbatim.
    internal func tailStartsWithDigit(_ literalTail: String, dropped droppedTail: String) -> Bool {
        if let first = droppedTail.first { return Self.isAsciiDigit(first) }
        if let first = literalTail.first { return Self.isAsciiDigit(first) }
        return false
    }

    /// Compose any letter-runs embedded in the tail via single-best parse.
    /// Non-letter characters (digits, already-mapped punctuation) pass
    /// through unchanged; the caller handles digit→Myanmar conversion on
    /// the primary candidate variant.
    internal func composeLetterRunsInTail(_ tail: String) -> String {
        guard !tail.isEmpty else { return tail }
        var result = ""
        var letterRun = ""
        for ch in tail {
            if Romanization.composingCharacters.contains(ch) {
                letterRun.append(ch)
            } else {
                if !letterRun.isEmpty {
                    result += composedLetterRunSurface(letterRun)
                    letterRun = ""
                }
                result.append(ch)
            }
        }
        if !letterRun.isEmpty {
            result += composedLetterRunSurface(letterRun)
        }
        return result
    }

    internal func composedLetterRunSurface(_ run: String) -> String {
        let normalized = Self.normalizeForParser(run)
        guard !normalized.isEmpty else { return run }
        // The composed run is concatenated onto whatever surviving prefix
        // the right-shrink probe produced — it does not start at the
        // user's buffer origin. Suppress the leading-`အ` promotion so
        // the tail doesn't double-anchor onto a prefix that already has
        // its own leading vowel base (`ace` → `အ` + `e`-tail must stay
        // `အယ်`, not `အအယ်`).
        let parses = parser.parseCandidates(normalized, maxResults: 4, isFullBuffer: false)
        guard !parses.isEmpty else { return run }
        // Pick the highest-ranked parse whose surface is orthographically
        // clean. We accept legality 0 here (the tail couldn't be DP-legal
        // anyway, otherwise it wouldn't be in the dropped tail), but the
        // surface itself must not contain malformed virama, chained
        // virama, asat-without-base, or dep-sign-after-independent-vowel
        // patterns — otherwise we'd silently splice broken Myanmar in
        // place of the original ASCII run.
        for parse in parses {
            if let promoted = Self.promoteOrphanZwnjToImplicitA(parse) {
                let s = Self.correctAaShape(promoted.output)
                if Self.tailFallbackOutputIsClean(s) { return s }
            }
            let s = Self.correctAaShape(parse.output)
            if Self.isOrphanZwnjMark(s) { continue }
            if Self.tailFallbackOutputIsClean(s) { return s }
        }
        return ""
    }

    /// Orthographic check used by `composedLetterRunSurface` when picking
    /// a fallback surface for a tail run. Stricter than legality scoring
    /// because it inspects the rendered scalar sequence directly: rejects
    /// any sign of malformed virama, chained virama (triple stack), asat
    /// without a consonant base, and dep-vowel-sign after an independent
    /// vowel. A fallback that fails any of these would smuggle illegal
    /// Myanmar into the candidate panel.
    internal static func tailFallbackOutputIsClean(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return SyllableParser.scanOutputLegality(s)
    }

    /// Replace ASCII digits (0-9) with Myanmar digits (U+1040–U+1049),
    /// leaving all other characters unchanged.
    internal static func arabicToBurmeseDigits(_ s: String) -> String {
        String(s.unicodeScalars.map { scalar in
            if scalar.value >= 0x30 && scalar.value <= 0x39 {
                return Character(Unicode.Scalar(0x1040 + (scalar.value - 0x30))!)
            }
            return Character(scalar)
        })
    }

    /// Shared fallback emitter for buffers whose composable portion
    /// produces no Myanmar parse but that still carry digits or literal
    /// content. Used by both the empty-`initialNormalized` early-return
    /// and the right-shrink-to-empty branch (TASK-003) so a buffer like
    /// `1.` or `12:` always yields Myanmar-digit + ASCII-digit
    /// candidates instead of an empty panel.
    ///
    /// Mapped punctuation (when `burmesePunctuationEnabled` is on) is
    /// applied to the Myanmar-digit primary's tail; the ASCII-digit
    /// secondary keeps the raw tail to match the existing convention.
    /// Measure-word expansions still apply only when the buffer is
    /// pure ASCII digits (no leading literal, no tail).
    internal func digitOrLiteralFallback(
        leadingLiteral: String,
        digitPrefix: String,
        literalTail: String,
        displayBuffer: String,
        context: [String]
    ) -> CompositionState {
        let rawFullLiteral = leadingLiteral + digitPrefix + literalTail
        let mappedTail = burmesePunctuationEnabled
            ? Self.mapPunctuation(literalTail)
            : literalTail
        let fullLiteral = leadingLiteral + digitPrefix + mappedTail
        guard Self.containsDigit(fullLiteral) else {
            return CompositionState(
                rawBuffer: displayBuffer,
                selectedCandidateIndex: 0,
                candidates: [],
                committedContext: context
            )
        }
        let burmese = leadingLiteral
            + Self.arabicToBurmeseDigits(digitPrefix + mappedTail)
        var candidates = [Candidate(
            surface: burmese,
            reading: rawFullLiteral,
            source: .grammar,
            score: 0
        )]
        // Measure-word expansions apply only when the buffer is pure
        // ASCII digits (no tail content at all). Cap to 2 suffixes per
        // buffer so the plain-digit candidate stays the default pick.
        if settings?.numberMeasureWordsEnabled == true,
           literalTail.isEmpty,
           leadingLiteral.isEmpty,
           !digitPrefix.isEmpty {
            for entry in NumberMeasureWords.shared.candidates(
                forDigits: digitPrefix, limit: 2
            ) {
                candidates.append(Candidate(
                    surface: "\(burmese) \(entry.measureWord)",
                    reading: rawFullLiteral,
                    source: .grammar,
                    score: 0
                ))
            }
        }
        if burmese != rawFullLiteral {
            candidates.append(Candidate(
                surface: rawFullLiteral,
                reading: rawFullLiteral,
                source: .grammar,
                score: 0
            ))
        }
        return CompositionState(
            rawBuffer: displayBuffer,
            selectedCandidateIndex: 0,
            candidates: candidates,
            committedContext: context
        )
    }

    /// Split a leading run of ASCII digits from the rest of the buffer.
    internal static func splitLeadingDigits(_ buffer: String) -> (digits: String, remainder: String) {
        if let firstNonDigit = buffer.firstIndex(where: {
            guard let scalar = $0.unicodeScalars.first, $0.unicodeScalars.count == 1 else { return true }
            return scalar.value < 0x30 || scalar.value > 0x39
        }) {
            return (String(buffer[..<firstNonDigit]), String(buffer[firstNonDigit...]))
        }
        return (buffer, "")
    }
}
