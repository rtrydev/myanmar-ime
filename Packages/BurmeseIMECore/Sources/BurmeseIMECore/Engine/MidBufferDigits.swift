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
    ///
    /// TASK-052 guard: a digit run is also NOT extracted when its
    /// trailing letter run (the chars between the digit run and the
    /// next non-composing-letter boundary) contains a `*` (asat
    /// marker). The `*` binds to its nearest preceding consonant in
    /// the user's intended scalar order; extracting the digit collapses
    /// the user's `<digit><letters with *>` shape into `<letters with
    /// *>`, which the parser may then mis-segment so the asat anchors
    /// to a phantom U+1021 instead of the consonant the user typed
    /// after the digit. Keeping the digits literal in that case
    /// preserves the positional context the parser needs.
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
                let trailingRunHasAsat = trailingLetterRunContainsAsterisk(
                    chars: chars, from: j
                )
                if precededByLetter && followedByLetter && !trailingRunHasAsat {
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

    /// True when the contiguous run of composing-letter chars starting
    /// at `start` contains an `*` (asat marker) before hitting a
    /// non-letter / non-`*` boundary or the end of `chars`. Used by
    /// `extractMidBufferDigits` to skip extraction of a digit run that
    /// sits immediately before a letter run carrying an explicit asat
    /// marker — see the TASK-052 comment on `extractMidBufferDigits`
    /// for the bug class this guard prevents.
    private static func trailingLetterRunContainsAsterisk(
        chars: [Character], from start: Int
    ) -> Bool {
        var k = start
        while k < chars.count {
            let ch = chars[k]
            if isAsciiLowerLetter(ch) { k += 1; continue }
            if ch == "*" { return true }
            return false
        }
        return false
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
            // consonant base, medial, dep-vowel sign, anusvara, or a
            // tone mark (creaky / visarga) that the parser placed
            // before the asat as part of the same syllable. Without
            // this the digit would land between (vowel | medial | tone)
            // and the asat that closes the same syllable, producing the
            // `<digit><asat>` shape MidBufferDigitAsatSplitSuite (and
            // TASK-052) forbid.
            if cur == 0x103A,
               (prev >= 0x1000 && prev <= 0x1021)
                || (prev >= 0x102B && prev <= 0x1032)
                || (prev >= 0x1036 && prev <= 0x1038)
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

    /// TASK-018: True when the right-shrink probe's dropped tail starts
    /// with three or more consecutive `a` letters. That shape arises
    /// when a long inherent-A chain (`<C>aaaaa<...>`) gets peeled by
    /// the chained-inherent-A guard introduced in TASK-016: the kept
    /// prefix is the leading consonant + one inherent-A arc, and the
    /// rest of the chain plus any continuation falls into the dropped
    /// tail. Routing such tails through `composeLetterRunsInTail`
    /// re-renders the chain as a clean Myanmar surface (collapsing the
    /// `a*` chain to a single anchor / inherent vowel), instead of
    /// leaking raw ASCII letters into the rank-0 candidate when the
    /// 6-character gate would otherwise hold.
    ///
    /// The `a{3,}` prefix shape is the discriminator: arbitrary long
    /// fuzz buffers (e.g. `ureqnborylahzy`) typically have a
    /// non-`a`-prefixed dropped tail, so they keep the existing
    /// literal-tail behaviour and the parser-internal re-segmentation
    /// inside `composeLetterRunsInTail` does not break anchor
    /// monotonicity for unrelated inputs.
    internal func droppedTailHasInherentAChainPrefix(_ tail: String) -> Bool {
        let chars = Array(tail.unicodeScalars)
        guard chars.count >= 3 else { return false }
        for i in 0..<3 {
            if chars[i].value != 0x61 { return false } // 'a'
        }
        return true
    }

    /// Compose any letter-runs embedded in the tail via single-best parse.
    /// Non-letter characters (digits, already-mapped punctuation) pass
    /// through unchanged; the caller handles digit→Myanmar conversion on
    /// the primary candidate variant.
    ///
    /// TASK-052: when a letter run starts with one or more `*` chars
    /// AND the immediately preceding non-composing character was an
    /// ASCII digit, peel those leading `*` chars and emit them
    /// verbatim instead of letting `composedLetterRunSurface` strip
    /// them. Asat needs a consonant base on its left to anchor the
    /// U+103A scalar; digits never serve as that base, so the user's
    /// typed asterisk must surface as a literal `*` rather than
    /// silently disappearing (the pre-fix `ka1*` → `က၁` shape, which
    /// dropped the typed `*` from the rank-0 surface entirely).
    internal func composeLetterRunsInTail(_ tail: String) -> String {
        guard !tail.isEmpty else { return tail }
        var result = ""
        var letterRun = ""
        var prevNonComposingWasAsciiDigit = false
        for ch in tail {
            if Romanization.composingCharacters.contains(ch) {
                letterRun.append(ch)
            } else {
                if !letterRun.isEmpty {
                    result += emitLetterRun(
                        letterRun,
                        preserveLeadingAsterisks: prevNonComposingWasAsciiDigit
                    )
                    letterRun = ""
                }
                result.append(ch)
                prevNonComposingWasAsciiDigit = Self.isAsciiDigit(ch)
            }
        }
        if !letterRun.isEmpty {
            result += emitLetterRun(
                letterRun,
                preserveLeadingAsterisks: prevNonComposingWasAsciiDigit
            )
        }
        return result
    }

    /// Emit one letter run from the tail composer. When
    /// `preserveLeadingAsterisks` is true, peel leading `*` chars off
    /// the run and surface them verbatim before handing the remainder
    /// to `composedLetterRunSurface` (which would otherwise strip
    /// them as redundant asat closers — see TASK-008 / TASK-052).
    ///
    /// Also when `preserveLeadingAsterisks` is true and the composed
    /// surface for the run begins with the orphan-anchor cluster
    /// `1021 103A`, fall back to the literal run. The user typed
    /// `<digit><letter-run-with-*>` and the parser produced an orphan
    /// asat that the sanitizer anchored to a phantom `အ`; with a
    /// digit on the left side (the run's previous emit) the resulting
    /// `<digit>1021103A` adjacency is the TASK-052 violation we are
    /// guarding against. Surfacing the run verbatim keeps the
    /// invariant intact while still preserving the user's keystrokes.
    private func emitLetterRun(
        _ run: String,
        preserveLeadingAsterisks: Bool
    ) -> String {
        guard preserveLeadingAsterisks else {
            return composedLetterRunSurface(run)
        }
        var preserved = ""
        var rest = run
        while rest.first == "*" {
            preserved.append("*")
            rest.removeFirst()
        }
        if rest.isEmpty { return preserved }
        let composed = composedLetterRunSurface(rest)
        if composed.unicodeScalars.starts(with: [
            Unicode.Scalar(0x1021)!,
            Unicode.Scalar(0x103A)!,
        ]) {
            // Orphan-anchor cluster would land immediately after the
            // digit. Fall back to the original run so the user's
            // keystrokes round-trip cleanly instead of materialising
            // the malformed `<digit>1021103A` adjacency.
            return preserved + rest
        }
        return preserved + composed
    }

    internal func composedLetterRunSurface(_ run: String) -> String {
        var normalized = Self.normalizeForParser(run)
        guard !normalized.isEmpty else { return run }
        // Strip leading `*` chars: every `*` is structurally an asat
        // closer for the previous syllable, but the right-shrink probe
        // only drops `*` when that previous syllable already terminates
        // with asat. So a leading `*` in the tail is always a redundant
        // duplicate and must not synthesise its own `1021` independent-A
        // anchor (TASK-008). Without this strip the parser emits
        // `200C 103A` for the leading asat, the orphan-ZWNJ promotion
        // rewrites it to `1021 103A` (`အ်`), and the affixes-concat
        // step splices `<closed syllable>1021 103A` into every
        // candidate — the `103A 1021 103A` injection. After the strip
        // the remaining run (e.g. `ka` from `*ka`) parses normally,
        // and an all-`*` tail collapses to an empty string.
        while normalized.first == "*" { normalized.removeFirst() }
        guard !normalized.isEmpty else { return "" }
        // The composed run is concatenated onto whatever surviving prefix
        // the right-shrink probe produced — it does not start at the
        // user's buffer origin. Suppress the leading-`အ` promotion so
        // the tail doesn't double-anchor onto a prefix that already has
        // its own leading vowel base (`ace` → `အ` + `e`-tail must stay
        // `အယ်`, not `အအယ်`).
        let parses = parser.parseCandidates(normalized, maxResults: 4, isFullBuffer: false)
        guard !parses.isEmpty else { return run }
        // TASK-049: detect the case where the tail's parser parse
        // silently absorbed a trailing tone marker via a `.skip` arc
        // (parses[0].score < 0 with input ending in `:` or `.`),
        // and route through `composedLetterRunSurface` against the
        // pre-tone body so the tone can be re-attached by the
        // engine's affix-merge branch instead of vanishing.
        let topScore = parses.first?.score ?? 0
        if topScore < 0,
           let last = normalized.last,
           last == ":" || last == "." {
            let body = String(normalized.dropLast())
            // Don't recurse on an empty body (a bare tone marker —
            // there is no anchor in this tail to attach to). Return
            // the marker verbatim so the engine's affix-merge branch
            // sees `:` / `.` at the start of effectiveTail and routes
            // through `applyBareConsonantToneFromTail` against the
            // candidate surface.
            if body.isEmpty { return run }
            let bodySurface = composedLetterRunSurface(body)
            return bodySurface + String(last)
        }
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

    /// TASK-052 extension of `splitLeadingDigits`. When the buffer
    /// starts with at least one ASCII digit, this peels the digit run
    /// AND any immediately-following `*` (asat-marker) chars and
    /// further interleaved digit runs into a single literal prefix.
    /// The `*` chars surface verbatim because asat needs a consonant
    /// base on its left, which digits never provide.
    ///
    /// Examples:
    ///   `1*`     → ("1*",     "")
    ///   `12*`    → ("12*",    "")
    ///   `1*1`    → ("1*1",    "")
    ///   `12*34`  → ("12*34",  "")
    ///   `1*2*3`  → ("1*2*3",  "")
    ///   `1*ka`   → ("1*",     "ka")
    ///   `12*ka`  → ("12*",    "ka")
    ///
    /// When the buffer does not start with a digit, behaves like
    /// `splitLeadingDigits` (does not consume `*`s, since a leading
    /// `*` without preceding digits is handled by `splitLeadingLiteral`
    /// upstream or is part of an `<letter>*` asat-marker pair).
    internal static func splitLeadingDigitsAndAdjacentAsterisks(
        _ buffer: String
    ) -> (digits: String, remainder: String) {
        let (head, tail) = splitLeadingDigits(buffer)
        guard !head.isEmpty else { return (head, tail) }
        var prefix = head
        var rest = tail
        while true {
            var consumed = false
            while rest.first == "*" {
                prefix.append("*")
                rest.removeFirst()
                consumed = true
            }
            let (moreDigits, after) = splitLeadingDigits(rest)
            if !moreDigits.isEmpty {
                prefix += moreDigits
                rest = after
                consumed = true
            }
            if !consumed { break }
        }
        return (prefix, rest)
    }
}
