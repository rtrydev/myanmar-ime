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
    /// insertion, computes a scalar splice position by re-parsing the
    /// letter prefix (up to that offset in the cleaned buffer) with
    /// single-best parse and counting scalars in the result. Emits a
    /// Myanmar-digit primary and ASCII-digit secondary variant per
    /// candidate, matching trailing-digit behaviour.
    internal func spliceMidBufferDigits(
        into candidates: [Candidate],
        cleaned: String,
        insertions: [(offset: Int, digit: Character)]
    ) -> [Candidate] {
        guard !insertions.isEmpty else { return candidates }
        let cleanedChars = Array(cleaned)
        // Runs of adjacent digits share a splice offset — "t23ote" produces
        // two insertions both at offset 1. Memoise by offset so the prefix
        // parse runs once per unique site instead of once per digit.
        var positionByOffset: [Int: Int] = [:]
        let splicePositions: [Int] = insertions.map { insertion in
            if let cached = positionByOffset[insertion.offset] { return cached }
            let prefixChars = cleanedChars.prefix(insertion.offset)
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
            positionByOffset[insertion.offset] = position
            return position
        }
        let burmeseDigits: [Unicode.Scalar] = insertions.map { insertion in
            let raw = insertion.digit.unicodeScalars.first!.value
            return Unicode.Scalar(0x1040 + (raw - 0x30))!
        }
        let asciiDigits: [Unicode.Scalar] = insertions.map {
            $0.digit.unicodeScalars.first!
        }
        var result: [Candidate] = []
        var seen: Set<String> = []
        for candidate in candidates {
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
    /// Applies splices in descending position order so earlier offsets
    /// remain valid as later ones shift.
    internal static func insertScalars(
        into surface: String,
        scalars: [Unicode.Scalar],
        at positions: [Int]
    ) -> String {
        precondition(scalars.count == positions.count)
        var working = Array(surface.unicodeScalars)
        let ordered = zip(positions, scalars)
            .sorted(by: { $0.0 > $1.0 })
        for (pos, scalar) in ordered {
            let clamped = max(0, min(pos, working.count))
            working.insert(scalar, at: clamped)
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: working)
        return String(view)
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
        let parses = parser.parseCandidates(normalized, maxResults: 4)
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
