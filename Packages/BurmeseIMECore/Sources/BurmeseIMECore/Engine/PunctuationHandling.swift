import Foundation

extension BurmeseEngine {

    internal struct EmbeddedPunctSplit {
        let renderedPrefix: String
        let activeBuffer: String
    }

    /// Replace mapped ASCII punctuation (`.`, `,`, `!`, `?`, `;`) with their
    /// Myanmar equivalents. Non-mapped characters pass through untouched.
    internal static func mapPunctuation(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            if let replacement = PunctuationMapper.mapped(c) {
                out += replacement
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// Vowel suffixes that end in `.` (e.g. `u.`, `i.`, `an.`). When the
    /// buffer already has one of these at a candidate split position, the
    /// `.` is acting as a creaky-tone / vowel modifier in the romanization
    /// and must not be folded into the Myanmar full stop.
    internal static let vowelSuffixesWithTrailingDot: [String] = {
        Romanization.vowels.compactMap { entry in
            entry.roman.hasSuffix(".") ? entry.roman : nil
        }
    }()

    internal static func dotActsAsVowelModifier(prefixEndingAtDot prefix: Substring) -> Bool {
        vowelSuffixesWithTrailingDot.contains(where: { prefix.hasSuffix($0) })
    }

    /// Locate the last mapped-punct character that is followed by more
    /// content, and split `buffer` there. Purely trailing mapped-punct
    /// returns `nil` — that case is already covered by the main
    /// pipeline's `stripTrailingMappablePunctuation` path.
    internal func splitAtLastEmbeddedMappedPunct(_ buffer: String) -> EmbeddedPunctSplit? {
        var boundary: String.Index? = nil
        for idx in buffer.indices.reversed() {
            guard PunctuationMapper.isMappable(buffer[idx]) else { continue }
            let after = buffer.index(after: idx)
            guard after != buffer.endIndex else { continue }
            guard buffer[after...].contains(where: { !PunctuationMapper.isMappable($0) }) else {
                continue
            }
            // `.` is overloaded: it terminates a sentence when it follows
            // arbitrary content (`thar.myat`), but it is also the creaky-
            // tone marker on vowels like `u.`, `i.`, `an.`, `aung.`. If
            // the current position closes one of those vowel suffixes, the
            // `.` is acting as a modifier and must not split the buffer —
            // otherwise `rarthiu.tu.` would freeze `rarthiu.` as a punct
            // segment and render ရာသီဦ။တု instead of ရာသီဦးတု။.
            if buffer[idx] == ".",
               Self.dotActsAsVowelModifier(prefixEndingAtDot: buffer[...idx]) {
                continue
            }
            boundary = after
            break
        }
        guard let boundary else { return nil }
        return EmbeddedPunctSplit(
            renderedPrefix: renderFrozenPunctSegments(String(buffer[..<boundary])),
            activeBuffer: String(buffer[boundary...])
        )
    }

    /// Render a buffer slice as Myanmar, splitting on mapped-punct chars
    /// and running single-best parsing on each composable run between
    /// them. Used only for the frozen prefix — lexicon + N-best are
    /// reserved for the active tail.
    internal func renderFrozenPunctSegments(_ s: String) -> String {
        var out = ""
        var current = ""
        for c in s {
            if let mapped = PunctuationMapper.mapped(c) {
                // When `.` closes a creaky-tone vowel suffix (`u.`, `i.`,
                // `an.`, …) it stays attached to the current composable
                // run instead of flushing as a Myanmar full stop.
                if c == ".",
                   Self.dotActsAsVowelModifier(prefixEndingAtDot: Substring(current + ".")) {
                    current.append(".")
                    continue
                }
                if !current.isEmpty {
                    out += renderFrozenSegment(current)
                    current = ""
                }
                out += mapped
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty {
            out += renderFrozenSegment(current)
        }
        return out
    }

    /// Single-best render of a punct-free segment. Digits convert to
    /// Myanmar digits up front; the remaining composable run is parsed
    /// with right-shrink to skip chars the parser can't consume.
    /// Anything beyond the composable run passes through as-is (the
    /// caller has already stripped mapped-punct from the input).
    internal func renderFrozenSegment(_ segment: String) -> String {
        let (digits, rest) = Self.splitLeadingDigits(segment)
        let digitPart = Self.arabicToBurmeseDigits(digits)
        let (composable, literal) = splitComposablePrefix(rest)
        let normalized = Self.normalizeForParser(composable)
        guard !normalized.isEmpty else {
            return digitPart + composable + literal
        }
        var probe = normalized
        var dropped = ""
        while !probe.isEmpty {
            let parses = parser.parseCandidates(probe, maxResults: 1)
            if parses.contains(where: { Self.isAcceptableParse($0) }) { break }
            dropped = String(probe.removeLast()) + dropped
        }
        guard !probe.isEmpty else {
            return digitPart + composable + literal
        }
        let topParse = parser.parseCandidates(probe, maxResults: 1).first
        let output = topParse?.output ?? probe
        return digitPart + output + dropped + literal
    }

    /// Strip trailing mapped-punctuation characters (`.`, `,`, `!`, `?`, `;`)
    /// from the end of `s`. Returns the kept prefix and the peeled suffix
    /// in original order. Used to rescue trailing `.` from the composable
    /// buffer (it's in `Romanization.composingCharacters`) so it can be
    /// routed through the literal-tail mapping path.
    ///
    /// A trailing `.` is only re-added to `kept` when the preceding chars
    /// actually accept it as a creaky-tone modifier (e.g. `mu.` → မု,
    /// `mi.` → မိ). Otherwise the `.` stays peeled and is mapped to the
    /// literal-tail substitution path — preventing inputs like `thar.`
    /// from polluting the parse with a tone marker the base can't take.
    internal func stripTrailingMappablePunctuation(_ s: String) -> (kept: String, stripped: String) {
        var kept = s
        var stripped = ""
        while let last = kept.last, PunctuationMapper.isMappable(last) {
            stripped = String(last) + stripped
            kept.removeLast()
        }
        if !kept.isEmpty, stripped.first == "." {
            if creakyToneAttachesTo(kept) {
                kept.append(".")
                stripped.removeFirst()
            }
        }
        return (kept, stripped)
    }

    /// True when appending `.` to `prefix` improves the parser's top
    /// legality — i.e. there is a creaky-tone reading that genuinely
    /// extends the base. A bare comparison ("with-dot scores higher than
    /// without") generalises across every creaky-tone rule in the table
    /// without hard-coding the eligible bases here.
    internal func creakyToneAttachesTo(_ prefix: String) -> Bool {
        let withDot = parser.parseCandidates(prefix + ".", maxResults: 1).first
        guard let withDot, withDot.legalityScore > 0 else { return false }
        let plain = parser.parseCandidates(prefix, maxResults: 1).first
        let plainLegality = plain?.legalityScore ?? 0
        return withDot.legalityScore >= plainLegality
    }

    /// Peel a leading run of non-alphanumeric literal characters (the
    /// "literal head") from the rest of the buffer. Lowercase ASCII
    /// letters start composable syllables; ASCII digits have their own
    /// downstream path (→ Myanmar numerals); `'` and `+` are composable
    /// null-vowel / kinzi separators handled by the parser. Everything
    /// else at the start is treated as a literal segment and carried
    /// verbatim onto each candidate surface — `.aung` → `.အောင်`,
    /// `(thar)` → `(သာ)`, `"thar"` → `"သာ"`. Note `.`, `:`, `*` are in
    /// `composingCharacters` but cannot start a legal parse, so peeling
    /// them here prevents the composable run from starting empty.
    internal static func splitLeadingLiteral(_ buffer: String) -> (literal: String, remainder: String) {
        let firstNonLiteral = buffer.firstIndex(where: { ch in
            guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
                return true
            }
            let v = scalar.value
            if v >= 0x61 && v <= 0x7A { return true }            // a-z
            if v >= 0x30 && v <= 0x39 { return true }            // 0-9
            if v == 0x27 || v == 0x2B { return true }            // ' and +
            return false
        }) ?? buffer.endIndex
        return (String(buffer[..<firstNonLiteral]), String(buffer[firstNonLiteral...]))
    }
}
