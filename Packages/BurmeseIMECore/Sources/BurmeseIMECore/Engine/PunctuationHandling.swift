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

    internal static let vowelSuffixesWithTrailingColon: [String] = {
        Romanization.vowels.compactMap { entry in
            entry.roman.hasSuffix(":") ? entry.roman : nil
        }
    }()

    internal static func dotActsAsVowelModifier(prefixEndingAtDot prefix: Substring) -> Bool {
        vowelSuffixesWithTrailingDot.contains(where: { prefix.hasSuffix($0) })
    }

    internal static func colonActsAsVowelModifier(prefixEndingAtColon prefix: Substring) -> Bool {
        vowelSuffixesWithTrailingColon.contains(where: { prefix.hasSuffix($0) })
    }

    internal static let midBufferComposingPunctuation: Set<Character> = [".", ":", "*", "'"]

    internal func splitAtLastEmbeddedComposingPunct(_ buffer: String) -> EmbeddedPunctSplit? {
        var split: EmbeddedPunctSplit? = nil
        for idx in buffer.indices {
            guard shouldSplitEmbeddedComposingPunct(in: buffer, at: idx) else { continue }
            let after = buffer.index(after: idx)
            guard after != buffer.endIndex else { continue }
            guard buffer[after...].contains(where: { !Self.isFrozenPunctuationLiteral($0) }) else {
                continue
            }
            let renderedPrefix = renderFrozenPunctSegments(String(buffer[..<after]))
            guard !Self.hasAsciiLetters(renderedPrefix) else { continue }
            split = EmbeddedPunctSplit(
                renderedPrefix: renderedPrefix,
                activeBuffer: String(buffer[after...])
            )
        }
        return split
    }

    private func shouldSplitEmbeddedComposingPunct(
        in buffer: String,
        at idx: String.Index
    ) -> Bool {
        let c = buffer[idx]
        guard Self.midBufferComposingPunctuation.contains(c) else { return false }
        if c == ".",
           Self.dotActsAsVowelModifier(prefixEndingAtDot: buffer[...idx]) {
            return false
        }
        if c == ":",
           Self.colonActsAsVowelModifier(prefixEndingAtColon: buffer[...idx]) {
            return false
        }
        if c == "." || c == ":" {
            return true
        }
        return Self.hasAdjacentComposingPunctuation(in: buffer, at: idx)
    }

    private static func isFrozenPunctuationLiteral(_ c: Character) -> Bool {
        midBufferComposingPunctuation.contains(c) || PunctuationMapper.isMappable(c)
    }

    private static func hasAsciiLetters(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
        }
    }

    private static func hasAdjacentComposingPunctuation(
        in buffer: String,
        at idx: String.Index
    ) -> Bool {
        if idx > buffer.startIndex {
            let prev = buffer.index(before: idx)
            if midBufferComposingPunctuation.contains(buffer[prev]) {
                return true
            }
        }
        let next = buffer.index(after: idx)
        if next < buffer.endIndex,
           midBufferComposingPunctuation.contains(buffer[next]) {
            return true
        }
        return false
    }

    /// Locate the last literal-punct character that has at least one
    /// composable letter after it, and split `buffer` there. "Literal
    /// punct" is any character that cannot extend a composable run —
    /// mapped punct (`.`, `,`, `!`, `?`, `;`), the composing-punct
    /// subset (`*`, `'`, `:`, `.` outside the modifier exception),
    /// and every other non-letter / non-digit / non-`+` character
    /// (`-`, `_`, `(`, `)`, brackets, whitespace, ...).
    ///
    /// Purely trailing literal punct returns `nil` so the existing
    /// trailing-punct path (`stripTrailingMappablePunctuation` /
    /// literal-tail concatenation) still handles `thar,`, `thar.`, …
    /// without recursing.
    ///
    /// Generalises `splitAtLastEmbeddedMappedPunct`. Task 03.
    internal func splitAtLastEmbeddedLiteralPunct(_ buffer: String) -> EmbeddedPunctSplit? {
        var boundary: String.Index? = nil
        var renderedPrefixCache: String? = nil
        for idx in buffer.indices.reversed() {
            let c = buffer[idx]
            guard Self.isLiteralPunctSplitChar(c) else { continue }
            // `.` and `:` are overloaded: they terminate / separate when
            // they follow arbitrary content, but they are also creaky-
            // tone modifiers on vowel suffixes like `u.`, `i.`, `an.`,
            // `aung.`, `aw:`. When the current position closes one of
            // those modifier endings, leave the char attached to the
            // composable run instead of splitting on it.
            if c == ".",
               Self.dotActsAsVowelModifier(prefixEndingAtDot: buffer[...idx]) {
                continue
            }
            if c == ":",
               Self.colonActsAsVowelModifier(prefixEndingAtColon: buffer[...idx]) {
                continue
            }
            let after = buffer.index(after: idx)
            guard after != buffer.endIndex else { continue }
            // Active suffix must contain at least one composable letter
            // (a-z) — otherwise there's nothing to recompose and the
            // legacy literal-tail path is fine.
            guard buffer[after...].contains(where: Self.isAsciiLetter) else {
                continue
            }
            // The rendered prefix must be ASCII-letter-free. If a
            // segment in the prefix can't compose cleanly (parser
            // dropping unparseable chars to the literal tail —
            // common on fuzz inputs like `arc:dlax...`), splitting
            // here would leak ASCII into the surface. Defer to the
            // regular pipeline's parser-driven cleanup instead.
            // Mirrors the same guard in `splitAtLastEmbeddedComposingPunct`.
            let renderedPrefix = renderFrozenPunctSegments(String(buffer[..<after]))
            guard !Self.hasAsciiLetters(renderedPrefix) else { continue }
            boundary = after
            renderedPrefixCache = renderedPrefix
            break
        }
        guard let boundary, let renderedPrefix = renderedPrefixCache else {
            return nil
        }
        return EmbeddedPunctSplit(
            renderedPrefix: renderedPrefix,
            activeBuffer: String(buffer[boundary...])
        )
    }

    /// True for characters that break a composable run when seen
    /// mid-buffer. Excludes:
    /// - composable letters (a-z, A-Z)
    /// - digits (handled separately by `splitLeadingDigits` / digit
    ///   spliceback)
    /// - `+` (kinzi separator that the parser consumes)
    /// - `*` and `'` (asat / null-vowel separator that the parser
    ///   consumes — they belong inside a syllable, not between
    ///   syllables)
    /// - whitespace (script transition — stays literal per the
    ///   Pinyin-style inline-mixing convention; `thar english`
    ///   commits as `သာ english`, not `သာ ယ်ငလီရှ`)
    ///
    /// `:` and `.` are split candidates here, but the splitter calls
    /// `dotActsAsVowelModifier` / `colonActsAsVowelModifier` first to
    /// keep creaky-tone / tone-variant suffix usage attached to the
    /// composable run.
    internal static func isLiteralPunctSplitChar(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let scalar = c.unicodeScalars.first else {
            return true
        }
        let v = scalar.value
        if v >= 0x61 && v <= 0x7A { return false }   // a-z
        if v >= 0x41 && v <= 0x5A { return false }   // A-Z
        if v >= 0x30 && v <= 0x39 { return false }   // 0-9
        if v == 0x2B { return false }                 // `+`  (kinzi)
        if v == 0x2A { return false }                 // `*`  (asat marker)
        if v == 0x27 { return false }                 // `'`  (null-vowel separator)
        // Whitespace — script transition, stays literal.
        if v == 0x20 || v == 0x09 || v == 0x0A || v == 0x0D { return false }
        return true
    }

    @inline(__always)
    private static func isAsciiLetter(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let scalar = c.unicodeScalars.first else {
            return false
        }
        let v = scalar.value
        return (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A)
    }

    /// Render a buffer slice as Myanmar, splitting on every literal-punct
    /// boundary (mapped, composing-punct, and any other non-composable
    /// non-digit char) and running single-best parsing on each composable
    /// run between them. Used only for the frozen prefix — lexicon + N-best
    /// are reserved for the active tail.
    internal func renderFrozenPunctSegments(_ s: String) -> String {
        var out = ""
        var current = ""
        for c in s {
            // When `.` / `:` closes a creaky-tone or tone-variant vowel
            // suffix (`u.`, `i.`, `an.`, `aw:`, …) it stays attached to
            // the current composable run instead of flushing as
            // punctuation.
            if c == ".",
               Self.dotActsAsVowelModifier(prefixEndingAtDot: Substring(current + ".")) {
                current.append(".")
                continue
            }
            if c == ":",
               Self.colonActsAsVowelModifier(prefixEndingAtColon: Substring(current + ":")) {
                current.append(":")
                continue
            }
            // Flush at any literal-punct split char *or* the in-syllable
            // composing-punct subset (`*`, `'`). The split-char set
            // already covers the broader literal-punct range
            // (`,`, `;`, `(`, `-`, ...); the additional check on
            // `midBufferComposingPunctuation` keeps `*` and `'` flushing
            // here so the older `splitAtLastEmbeddedComposingPunct` call
            // site (which expects `ka*.tar` to render the `*` as a
            // literal between rendered segments) keeps its behaviour.
            // The new mid-buffer literal-punct path never enters this
            // renderer with `*` or `'` because the composing-punct
            // splitter already runs first.
            if Self.isLiteralPunctSplitChar(c) || Self.midBufferComposingPunctuation.contains(c) {
                if !current.isEmpty {
                    out += renderFrozenSegment(current)
                    current = ""
                }
                if burmesePunctuationEnabled,
                   let mapped = PunctuationMapper.mapped(c) {
                    out += mapped
                } else {
                    out.append(c)
                }
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
        var output = topParse?.output ?? probe
        // Apply orphan-ZWNJ promotion so bare-vowel segments (`aung`,
        // `i`, `ee`, …) get an explicit `အ` independent-vowel anchor
        // instead of a leading U+200C that renders the dependent-vowel
        // marks unanchored. Mirrors the engine's `update` post-process.
        if let parse = topParse,
           let promoted = Self.promoteOrphanZwnjToImplicitA(parse) {
            output = promoted.output
        }
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
