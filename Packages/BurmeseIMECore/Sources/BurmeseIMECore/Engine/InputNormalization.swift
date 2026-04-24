import Foundation

extension BurmeseEngine {

    /// Tall-aa vowel keys that only make sense after a descender consonant.
    /// When a parse's reading *starts* with one of these, it means the parser
    /// consumed the token as a standalone dependent vowel — which the engine
    /// rejects so the trailing "2" falls out as a literal tail instead.
    internal static let standaloneTallAaReadings: [String] = [
        "ar2", "aw2", "out2", "aung2",
    ]

    internal static func normalizeForParser(_ input: String) -> String {
        // Digits are always literal in user input (never variant
        // selectors), so the parser must never see `2`/`3`. They get
        // peeled by `splitComposablePrefix` upstream; this is a
        // belt-and-suspenders filter in case a digit sneaks in via
        // a different caller.
        let filtered = String(input.lowercased().filter {
            Romanization.composingCharacters.contains($0)
        })
        return collapseConnectorRuns(filtered)
    }

    /// Collapse ill-formed connector sequences before the DP ever sees
    /// them (task 08). Three transforms, applied in order:
    ///
    ///   1. Consecutive `+` collapse to a single `+` — virama over
    ///      virama is structurally impossible, so `k++ar` is equivalent
    ///      to `k+ar` for any parse that survives right-shrink.
    ///   2. `+` immediately before a vowel character is dropped — virama
    ///      cannot stack to a dependent vowel sign or standalone vowel,
    ///      so `k+ar` / `k+a+t` degrade to `kar` / `ka+t`. Without this,
    ///      the DP emits illegal virama-before-vowel shapes that the
    ///      right-shrink probe then prunes back to the seed consonant,
    ///      silently losing the user's tail.
    ///   3. Leading/trailing `+` peel off — a virama with no partner on
    ///      one side has nothing to stack to and only produces the
    ///      illegal hanging-virama shape.
    internal static func collapseConnectorRuns(_ input: String) -> String {
        guard input.contains("+") else { return input }
        var collapsed = ""
        collapsed.reserveCapacity(input.count)
        var prevWasPlus = false
        for ch in input {
            if ch == "+" {
                if prevWasPlus { continue }
                prevWasPlus = true
            } else {
                prevWasPlus = false
            }
            collapsed.append(ch)
        }
        let vowelLeaders: Set<Character> = ["a", "e", "i", "o", "u"]
        var result = ""
        result.reserveCapacity(collapsed.count)
        let chars = Array(collapsed)
        var i = 0
        while i < chars.count {
            if chars[i] == "+",
               i + 1 < chars.count,
               vowelLeaders.contains(chars[i + 1]) {
                i += 1
                continue
            }
            result.append(chars[i])
            i += 1
        }
        while result.first == "+" { result.removeFirst() }
        while result.last == "+" { result.removeLast() }
        return result
    }

    /// Split a buffer into its leading run of composing characters and the
    /// remainder (starting at the first non-composing character). ASCII
    /// digits always break the composable run — they are literal Myanmar/
    /// Arabic numerals at the position typed, never variant selectors for
    /// internal alias keys (`ky2`, `t2`, `ay2`, `u2`, …). Users
    /// disambiguate variants via the candidate panel, not by typing `2`
    /// or `3`.
    internal func splitComposablePrefix(_ buffer: String) -> (composable: String, literal: String) {
        var composable = ""
        var iterator = buffer.makeIterator()
        var splitIndex = buffer.startIndex
        var current = buffer.startIndex
        while let ch = iterator.next() {
            defer { current = buffer.index(after: current) }
            guard Romanization.composingCharacters.contains(ch) else { break }
            composable.append(ch)
            splitIndex = buffer.index(after: current)
        }
        return (composable, String(buffer[splitIndex...]))
    }

    /// Defence-in-depth gate for virama-stack surfaces. The DP already
    /// penalises malformed virama transitions with `legalityScore = 0`;
    /// this rescue path lets such candidates survive when the emitted
    /// scalar sequence is nonetheless orthographically clean. "Clean"
    /// means every `U+1039` is framed by scalars that can actually form
    /// a native subscript:
    ///
    ///   - Upper must be a stackable base consonant, or the asat half
    ///     of a kinzi marker (`U+1004 U+103A`).
    ///   - Lower must be a stackable base consonant whose class matches
    ///     the upper's (for kinzi the upper is nga → velar class).
    ///
    /// Anything else — virama after a dependent vowel sign, independent
    /// vowel, anusvara; asat-before-virama on a non-nga base; or a
    /// cross-class pair — fails the gate so the engine drops the parse.
    internal static func hasOnlyCleanViramaStacks(_ parse: SyllableParse) -> Bool {
        guard parse.reading.contains("+") else { return false }
        guard SyllableParser.scanOutputLegality(parse.output) else { return false }
        let scalars = parse.output.unicodeScalars.map(\.value)
        var sawVirama = false
        for i in 0..<scalars.count where scalars[i] == 0x1039 {
            sawVirama = true
            let prev = i >= 1 ? scalars[i - 1] : 0
            let twoBack = i >= 2 ? scalars[i - 2] : 0
            let nextScalar = i + 1 < scalars.count ? scalars[i + 1] : 0
            guard let nextCh = Unicode.Scalar(nextScalar).map(Character.init) else {
                return false
            }
            let upper: Character
            if prev == 0x103A {
                guard twoBack == 0x1004 else { return false }
                upper = Character(Unicode.Scalar(0x1004)!)
            } else {
                guard let ch = Unicode.Scalar(prev).map(Character.init),
                      Grammar.stackableConsonants.contains(ch) else {
                    return false
                }
                upper = ch
            }
            guard Grammar.isValidStack(upper: upper, lower: nextCh) else {
                return false
            }
        }
        return sawVirama
    }

    /// True when any parse in `parses` already surfaces a kinzi or
    /// virama-stack glyph. `inferImplicitStackMarkers` re-parses the
    /// buffer with `+` injected so the stacked surface enters the
    /// ranking pool — but when the primary N-best already contains
    /// such a surface (e.g. the user typed `+` explicitly, or a
    /// lexicon-reached alias produced one), the second parse is pure
    /// duplication. Bail out before paying the DP cost.
    internal static func hasStackedSurface(_ parses: [SyllableParse]) -> Bool {
        for parse in parses {
            for scalar in parse.output.unicodeScalars where scalar.value == 0x1039 {
                return true
            }
        }
        return false
    }

    /// Returns true when `output` chains two viramas (U+1039) separated by
    /// exactly one consonant scalar. This catches both literal triple
    /// stacks (`<C> 1039 <C> 1039 <C>`) and a kinzi marker that
    /// immediately precedes another stack
    /// (`<nga> 103A 1039 <C> 1039 <C>`). Modern orthography never stacks
    /// more than a pair, so the engine drops these even if each
    /// individual stack pair is otherwise class-valid.
    internal static func hasTripleViramaStack(_ output: String) -> Bool {
        let scalars = Array(output.unicodeScalars)
        guard scalars.count >= 3 else { return false }
        for i in 0..<(scalars.count - 2) {
            guard scalars[i].value == 0x1039 else { continue }
            let mid = scalars[i + 1].value
            let isConsonantBase = (mid >= 0x1000 && mid <= 0x1021) || mid == 0x103F
            guard isConsonantBase else { continue }
            if scalars[i + 2].value == 0x1039 { return true }
        }
        return false
    }

    /// Return `input` with the leading `y`/`w`/`r`/`h` dropped when it
    /// is immediately followed by a non-vowel letter (i.e. the parser
    /// promoted a stranded medial letter into an onset consonant
    /// without a separating `a`). Returns nil when the leading letter
    /// is safely paired with a vowel, so established parses like
    /// `hmar` → မှာ are untouched.
    internal static func stripLeadingMedialPromotion(_ input: String) -> String? {
        let chars = Array(input)
        guard chars.count >= 2 else { return nil }
        let lead = chars[0]
        guard lead == "y" || lead == "w" || lead == "r" || lead == "h" else { return nil }
        let next = chars[1]
        let vowelChars: Set<Character> = ["a", "e", "i", "o", "u"]
        guard next.isLetter, !vowelChars.contains(next) else { return nil }
        return String(chars.dropFirst())
    }

    /// Return `input` with implicit kinzi / virama-stack markers (`+`)
    /// inserted at every orthographically plausible Pali/Sanskrit stack
    /// site, plus the insertion count, or nil when the input already
    /// carries a `+` (respect the user's explicit signal) or has no
    /// detectable site.
    ///
    /// A site is
    /// `<simple-onset> <vowel-letter> <coda-letter> <consonant-letter>`,
    /// or the initial-`a` variant used by onsetless Pali words like
    /// `atta`: the coda can be a Pali stack upper (`n`, `m`, `t`, `d`,
    /// `p`, `b`, `k`, `g`, `s`, `r`, `l`, `h`), and the following
    /// consonant can become the lower. A candidate site is inserted only
    /// when both letters map to stackable Myanmar consonants under the
    /// liberal (Pali/Sanskrit) stack rule. Digraph onsets (`th`, `dh`,
    /// `bh`, `kh`, `ph`, `sh`, `hm`, `hl`) stay safe because the
    /// `prev == vowel-letter` guard rejects them — the `h` sits next to
    /// a consonant, not a vowel. Inference is gated on the preceding
    /// onset being "simple" — no `y` / `r` / `w` medial letters between
    /// the first consonant and the vowel. Modern polysyllable words with
    /// medial-heavy onsets (e.g. `kwyantaw` → ကျွန်တော်) conventionally
    /// spell the nasal coda with asat, not a stack, so inferring one
    /// there would pick the wrong form.
    ///
    /// The inserted `+` is then resolved by the parser's
    /// `softBoundaryContext` gate: same-class stacks materialise as
    /// kinzi / virama forms, cross-class lowers degrade to a plain
    /// syllable break — so over-insertion is safe, the unstacked
    /// reading is preserved via the existing no-`+` parse that also
    /// runs for the same buffer.
    internal static func inferImplicitStackMarkers(
        _ input: String
    ) -> (input: String, insertions: Int, liberalInsertions: Int)? {
        guard !input.contains("+") else { return nil }
        // Skip the char-array allocation when there is no plausible
        // Pali stack upper at all — the rest of the scan would walk the
        // buffer for nothing.
        guard input.unicodeScalars.contains(where: { isPaliStackCodaScalar($0.value) }) else {
            return nil
        }
        // Second fast-exit: confirm the buffer has *any* candidate stack
        // site (`<V> <coda> <C>` where `<C>` starts the next syllable) before
        // paying the per-site `Array(input)` / `lastIndex(of: "+")` /
        // medial-onset scan. Walk scalars once; bail out the moment we
        // either find a site or prove none exists.
        let scalars = input.unicodeScalars
        var sawCandidateSite = false
        var prev: UInt32 = 0
        var cur: UInt32 = 0
        for scalar in scalars {
            let value = scalar.value
            if isPaliStackCodaScalar(cur),
               isPaliStackVowelScalar(prev) {
                let coda = Unicode.Scalar(cur).map(Character.init)
                let lower = Unicode.Scalar(value).map(Character.init)
                if isAsciiLetterScalar(value),
                   !isPaliStackVowelScalar(value),
                   let coda,
                   let lower,
                   inferredPaliStackIsLiberal(coda: coda, lowerStart: lower) != nil {
                    sawCandidateSite = true
                    break
                }
            }
            prev = cur
            cur = value
        }
        guard sawCandidateSite else { return nil }
        let chars = Array(input)
        guard chars.count >= 3 else { return nil }
        let medialLetters: Set<Character> = ["y", "r", "w"]
        var insertAt: [Int] = []
        var liberalInsertions = 0
        for i in 1..<(chars.count - 1) where isPaliStackCodaLetter(chars[i]) {
            let prev = chars[i - 1]
            let next = chars[i + 1]
            guard isPaliStackVowelLetter(prev) else { continue }
            guard next.isLetter,
                  !isPaliStackVowelLetter(next)
            else { continue }
            guard let isLiberal = inferredPaliStackIsLiberal(coda: chars[i], lowerStart: next) else {
                continue
            }
            // Reject medial-heavy onsets. The preceding syllable starts
            // at buffer head or the most recent `+`; any `y`/`r`/`w`
            // between positions 1 and `i-1` means the onset has at
            // least one medial. `h` is ambiguous (onset digraph `th`
            // vs medial `hm`) so it is excluded from the medial set.
            //
            // Exception for `h`-coda sites (Pali/Sanskrit loanwords like
            // `brahma` / `brahman`): medial+stack is the canonical form
            // (ဗြဟ္မ), so the medial onset does not disqualify the site.
            // Native words with medial onsets do not use `h` as a coda,
            // so this narrowing is safe.
            let onsetStart = chars[..<i].lastIndex(of: "+").map { $0 + 1 } ?? 0
            let hasSimpleOnset = Self.hasSimplePaliStackOnset(
                chars: chars,
                onsetStart: onsetStart,
                vowelIndex: i - 1
            )
            guard hasSimpleOnset else { continue }
            let onsetHasMedial = onsetStart + 1 < i - 1
                && (onsetStart + 1..<i - 1).contains(where: { medialLetters.contains(chars[$0]) })
            guard !onsetHasMedial || chars[i] == "h" else { continue }
            insertAt.append(i + 1)
            if isLiberal { liberalInsertions += 1 }
        }
        guard !insertAt.isEmpty else { return nil }
        var result = input
        for idx in insertAt.reversed() {
            let si = result.index(result.startIndex, offsetBy: idx)
            result.insert("+", at: si)
        }
        return (result, insertAt.count, liberalInsertions)
    }

    private static func hasSimplePaliStackOnset(
        chars: [Character],
        onsetStart: Int,
        vowelIndex: Int
    ) -> Bool {
        if onsetStart == vowelIndex {
            return chars[vowelIndex] == "a"
        }
        return chars[onsetStart..<vowelIndex].contains { ch in
            ch.isLetter && !isPaliStackVowelLetter(ch)
        }
    }

    private static func inferredPaliStackIsLiberal(
        coda: Character,
        lowerStart: Character
    ) -> Bool? {
        guard let upper = Romanization.romanToConsonant[String(coda)],
              let lower = Romanization.romanToConsonant[String(lowerStart)],
              Grammar.isValidStackLiberal(upper: upper, lower: lower)
        else { return nil }
        return !Grammar.isValidStack(upper: upper, lower: lower)
    }

    @inline(__always)
    private static func isAsciiLetterScalar(_ value: UInt32) -> Bool {
        (value >= 0x61 && value <= 0x7A) || (value >= 0x41 && value <= 0x5A)
    }

    @inline(__always)
    private static func isPaliStackVowelScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x61, 0x65, 0x69, 0x6F, 0x75, 0x77: // a e i o u w
            return true
        default:
            return false
        }
    }

    @inline(__always)
    private static func isPaliStackCodaScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x62, 0x64, 0x67, 0x68, 0x6B, 0x6C, 0x6D, 0x6E, 0x70, 0x72, 0x73, 0x74:
            return true
        default:
            return false
        }
    }

    @inline(__always)
    private static func isPaliStackVowelLetter(_ char: Character) -> Bool {
        switch char {
        case "a", "e", "i", "o", "u", "w":
            return true
        default:
            return false
        }
    }

    @inline(__always)
    private static func isPaliStackCodaLetter(_ char: Character) -> Bool {
        switch char {
        case "n", "m", "t", "d", "p", "b", "k", "g", "s", "r", "l", "h":
            return true
        default:
            return false
        }
    }

    /// Return `input` with the first kinzi-forming `+` removed, or nil if
    /// the input has no such `+`. A kinzi-forming `+` is preceded by
    /// `in` (i.e. the kinzi-vowel reading) and followed by a
    /// consonant-starting letter, matching the `<...>in+<C>` shape.
    internal static func dropKinziPlus(_ input: String) -> String? {
        let chars = Array(input)
        guard chars.count >= 4 else { return nil }
        for i in 2..<chars.count - 1 {
            guard chars[i] == "+" else { continue }
            guard chars[i - 2] == "i", chars[i - 1] == "n" else { continue }
            let next = chars[i + 1]
            guard next.isLetter else { continue }
            return String(chars[..<i] + chars[(i + 1)...])
        }
        return nil
    }

    internal static func hasInterleavedLatin(_ output: String) -> Bool {
        let scalars = Array(output.unicodeScalars)
        var lastMyanmarIdx = -1
        for (i, scalar) in scalars.enumerated()
        where scalar.value >= 0x1000 && scalar.value <= 0x109F {
            lastMyanmarIdx = i
        }
        guard lastMyanmarIdx >= 0 else { return false }
        // `Romanization.normalize` lowercases the buffer up-stream, so a
        // composed surface can only contain lowercase ASCII letters —
        // uppercase never reaches this check. Narrowing to 0x61..0x7A
        // (tasks/ 08) surfaces a regression if that invariant ever
        // breaks rather than silently masking it with a broader range.
        for i in 0..<lastMyanmarIdx {
            let value = scalars[i].value
            if value >= 0x61 && value <= 0x7A {
                return true
            }
        }
        return false
    }

    internal static func containsAsciiSurfaceScalar(_ output: String) -> Bool {
        output.unicodeScalars.contains {
            $0.value >= 0x21 && $0.value <= 0x7E
        }
    }

    internal static func isAcceptableParse(_ parse: SyllableParse) -> Bool {
        guard parse.legalityScore > 0 || hasOnlyCleanViramaStacks(parse) else { return false }
        guard !hasInterleavedLatin(parse.output) else { return false }
        guard !hasTripleViramaStack(parse.output) else { return false }
        for reading in standaloneTallAaReadings where parse.reading.hasPrefix(reading) {
            return false
        }
        return true
    }

    /// Strip zero-width spaces (U+200B) so surfaces from the lexicon
    /// (which may embed ZWSP word-boundary markers) compare equal to
    /// grammar-generated surfaces (which never contain ZWSP).
    internal static func stripZWSP(_ s: String) -> String {
        if s.unicodeScalars.contains(where: { $0.value == 0x200B }) {
            return String(s.unicodeScalars.filter { $0.value != 0x200B })
        }
        return s
    }

    /// Scalar-level prefix check. Swift's `String.hasPrefix` operates on
    /// grapheme clusters, which fails for Myanmar when a syllable grows
    /// across keystrokes: the anchor's trailing consonant (e.g. `ပ`,
    /// a grapheme by itself) becomes part of a composite grapheme in
    /// the next step (e.g. `ပြ` = pa + medial ra-yit). Scalar prefix
    /// semantics correctly treat the extension as preserving the anchor.
    internal static func scalarHasPrefix(_ s: String, _ prefix: String) -> Bool {
        s.unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    /// True if the scalar is one that attaches to a preceding consonant
    /// (medial, dependent vowel, e-kar, asat, diacritics). Used to detect
    /// when an anchor's last bare consonant has been absorbed into a
    /// cluster by a later keystroke — such anchors are orthographically
    /// stale even though scalar prefix semantics would still accept them.
    internal static func isMedialOrMarker(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // U+1031 e-kar, U+1039 virama/asat, U+103A visible asat,
        // U+103B-U+103E medials, U+102B-U+1032 dependent vowels.
        if v == 0x1031 || v == 0x1039 || v == 0x103A { return true }
        if (0x103B...0x103E).contains(v) { return true }
        if (0x102B...0x1032).contains(v) { return true }
        return false
    }

    /// Replace both ya-pin (U+103B) and ya-yit (U+103C) with ya-pin so
    /// two surfaces that differ only in that medial choice compare equal.
    internal static func normalizeYaPinYaYit(_ s: String) -> String {
        if s.unicodeScalars.contains(where: { $0.value == 0x103C }) {
            return String(s.unicodeScalars.map {
                $0.value == 0x103C ? Unicode.Scalar(0x103B)! : $0
            }.map { Character($0) })
        }
        return s
    }

    /// Copy `surface` but swap each ya-pin/ya-yit medial to match the
    /// corresponding medial in `matching` (ZWSP-stripped anchor surface).
    /// Walks both scalar arrays in lockstep; when the source has a ya-pin
    /// or ya-yit at a position where the anchor also has one, the anchor's
    /// choice wins. Stops substituting when the anchor is exhausted.
    internal static func substituteMedials(in surface: String, matching anchor: String) -> String {
        var result = Array(surface.unicodeScalars)
        let anchorScalars = Array(anchor.unicodeScalars)
        var ai = 0
        for si in 0..<result.count {
            guard ai < anchorScalars.count else { break }
            let sv = result[si].value
            let av = anchorScalars[ai].value
            // Skip ZWSPs in the surface (lexicon entries may have them).
            if sv == 0x200B { continue }
            if (sv == 0x103B || sv == 0x103C) && (av == 0x103B || av == 0x103C) {
                result[si] = anchorScalars[ai]
                ai += 1
            } else if sv == av {
                ai += 1
            } else {
                break
            }
        }
        return String(String.UnicodeScalarView(result))
    }
}
