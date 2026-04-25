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
        return surfaceHasOnlyNativeViramaStacks(parse.output)
    }

    internal static func surfaceHasOnlyNativeViramaStacks(_ output: String) -> Bool {
        guard SyllableParser.scanOutputLegality(output) else { return false }
        let scalars = output.unicodeScalars.map(\.value)
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
    /// Result of `inferImplicitStackMarkers`. `input` carries every
    /// inferred `+` (strict-valid and liberal-only). `strictOnlyInput`
    /// carries only the strict-valid `+` insertions and is non-nil
    /// **only when at least one strict-valid site coexists with a
    /// liberal-only site** — the engine picks it up as a sibling
    /// inferred parse so the cross-class liberal stacks don't poison
    /// the otherwise-clean strict kinzi/native-stack rendering. The
    /// strict-only string is suppressed when all sites are liberal
    /// (it would equal the no-`+` parse) or when all are strict (it
    /// would equal `input`).
    @_spi(Testing) public static func inferImplicitStackMarkers(
        _ input: String
    ) -> (
        input: String,
        insertions: Int,
        liberalInsertions: Int,
        strictOnlyInput: String?,
        strictOnlyInsertions: Int
    )? {
        guard !input.contains("+") else { return nil }
        // Skip the char-array allocation when there is no plausible
        // Pali stack upper at all — the rest of the scan would walk the
        // buffer for nothing.
        guard input.unicodeScalars.contains(where: { isPaliStackCodaScalar($0.value) }) else {
            return nil
        }
        let chars = Array(input)
        guard chars.count >= 3 else { return nil }
        // Task 04 fast-path: `ai + ng + <stackable>` collapses the
        // user's bare `ng` into the diphthong's existing nga-asat
        // coda and inserts a single `+` between `ai` and the
        // stackable lower. The `ai` rule already emits
        // `102D 102F 1004 103A` (i + u + nga + asat), so an
        // additional bare-onset `ng` would surface as a redundant
        // second `င` — the user typed it intending the kinzi upper,
        // which is the same nga that `ai` already provides. Output
        // the canonical `ai+<rest>` instead of letting the regular
        // loop infer two competing sites that produce double-nga
        // surfaces (task 03/04 combined case).
        if chars.count >= 5,
           chars[0] == "a", chars[1] == "i",
           chars[2] == "n", chars[3] == "g" {
            let lowers = stackLowerConsonantsStarting(chars: chars, at: 4)
            if lowers.contains(where: { Grammar.isValidStack(upper: Myanmar.nga, lower: $0) }) {
                let collapsed = "ai+" + String(chars[4...])
                return (collapsed, 1, 0, nil, 1)
            }
        }
        let medialLetters: Set<Character> = ["y", "r", "w"]
        var insertAt: [(index: Int, isLiberal: Bool, marker: String)] = []
        for lowerIndex in 1..<chars.count {
            let lowerStart = chars[lowerIndex]
            guard lowerStart.isLetter,
                  !isPaliStackVowelLetter(lowerStart)
            else { continue }
            let previous = chars[lowerIndex - 1]
            guard isPaliStackCodaLetter(previous)
                    || stackVowelUpperRuleLastLetters.contains(previous)
            else { continue }
            guard !isContinuationOfStackLowerConsonant(chars: chars, at: lowerIndex) else {
                continue
            }
            // Don't slice an aspirated / cluster-alias consonant
            // digraph (`dh`, `ph`, `gh`, `bh`, `th`, `sh`, `hm`, …).
            // The previous + current character pair (or a longer
            // span centred on the insertion point) may form a single
            // consonant key — inserting `+` between them would
            // re-parse the digraph as `<base> + virama + <ha-or-medial>`
            // and emit a malformed surface.
            guard !isInsideMultiCharConsonantKey(chars: chars, insertIndex: lowerIndex) else {
                continue
            }
            guard let inferred = inferredPaliStackIsLiberal(
                chars: chars,
                insertIndex: lowerIndex
            ) else {
                continue
            }
            // Reject medial-heavy onsets. The preceding syllable starts
            // at the end of the most recently completed vowel (or the
            // last `+` if explicit); any `y`/`r`/`w` between positions
            // 1 and the matched vowel means the onset has at least one
            // medial. `h` is ambiguous (onset digraph `th` vs medial
            // `hm`) so it is excluded from the medial set.
            //
            // Exception for `h`-coda sites (Pali/Sanskrit loanwords like
            // `brahma` / `brahman`): medial+stack is the canonical form
            // (ဗြဟ္မ), so the medial onset does not disqualify the site.
            // Native words with medial onsets do not use `h` as a coda,
            // so this narrowing is safe.
            //
            // Locating the *current* onset's start matters here: when
            // there is no `+` in the buffer, falling back to the buffer
            // head causes the medial scan to walk through every prior
            // syllable and reject the site whenever any earlier vowel
            // contained a `y`/`r`/`w` letter (`ar`, `aw`, `ay`, …) —
            // which kills mid-buffer kinzi for almost every natural
            // sentence.
            let onsetStart = currentOnsetStart(
                chars: chars,
                vowelStart: inferred.vowelStart
            )
            let hasSimpleOnset = Self.hasSimplePaliStackOnset(
                chars: chars,
                onsetStart: onsetStart,
                vowelIndex: inferred.vowelStart
            )
            guard hasSimpleOnset else { continue }
            let onsetHasMedial = onsetStart + 1 < inferred.vowelStart
                && (onsetStart + 1..<inferred.vowelStart)
                    .contains(where: { medialLetters.contains(chars[$0]) })
            let precedingCoda = lowerIndex >= 1 ? chars[lowerIndex - 1] : "\0"
            guard !onsetHasMedial || precedingCoda == "h" else { continue }
            // Bare-onset nga sites need an asat-then-virama injection
            // (`*+`) so the parser materialises kinzi (`ng + asat +
            // virama + <C>`) instead of a bare virama stack
            // (`ng + virama + <C>`). Other inference sites carry the
            // asat in the preceding vowel rule's output, so a plain
            // `+` is enough.
            let marker = inferred.isBareNga ? "*+" : "+"
            insertAt.append((lowerIndex, inferred.isLiberal, marker))
        }
        // When a bare-nga site fires at lowerIndex K, the bare nga
        // upper occupies chars[K-2..K-1] ("ng"). Any earlier site
        // landing at lowerIndex K-2 or K-1 would put a marker inside
        // that nga digraph and produce a competing decomposition
        // whose injected `+` poisons the parser output (e.g.
        // `ainggar` would receive both the existing site at
        // chars[1..2] boundary AND the bare-nga site at chars[3..4],
        // yielding `ai+ng*+gar` whose parses are illegal). Drop the
        // overlapping non-bare-nga sites so only the bare-nga
        // injection survives, mirroring how the strict/liberal split
        // already protects `anggar` via `strictOnlyInput`.
        let bareNgaIndices = Set(insertAt.lazy.filter { $0.marker == "*+" }.map(\.index))
        if !bareNgaIndices.isEmpty {
            insertAt.removeAll { entry in
                guard entry.marker != "*+" else { return false }
                return bareNgaIndices.contains(entry.index + 1)
                    || bareNgaIndices.contains(entry.index + 2)
            }
        }
        guard !insertAt.isEmpty else { return nil }
        let liberalInsertions = insertAt.lazy.filter(\.isLiberal).count
        let strictInsertAt = insertAt.filter { !$0.isLiberal }
        let result = injectMarkers(input, at: insertAt.map { ($0.index, $0.marker) })
        let strictOnlyResult: String?
        if liberalInsertions > 0, !strictInsertAt.isEmpty {
            strictOnlyResult = injectMarkers(
                input,
                at: strictInsertAt.map { ($0.index, $0.marker) }
            )
        } else {
            strictOnlyResult = nil
        }
        return (
            result,
            insertAt.count,
            liberalInsertions,
            strictOnlyResult,
            strictInsertAt.count
        )
    }

    private static func injectMarkers(
        _ input: String,
        at insertions: [(index: Int, marker: String)]
    ) -> String {
        var result = input
        for entry in insertions.sorted(by: { $0.index > $1.index }) {
            let si = result.index(result.startIndex, offsetBy: entry.index)
            result.insert(contentsOf: entry.marker, at: si)
        }
        return result
    }

    /// Locate the start of the current syllable's onset for inference's
    /// medial-heaviness check. The onset begins right after either an
    /// explicit `+` separator or the end of the most recently completed
    /// vowel reading. The vowel ends at its true vowel letter (`a`, `e`,
    /// `i`, `o`, `u`); trailing vowel-extender letters (`r`, `w`, `y`,
    /// `n`, `g`) that happen to be part of `ar`/`aw`/`ay`/`an`/`ang`
    /// readings are absorbed too so they do not get mis-classified as
    /// the next onset's leading consonant.
    private static func currentOnsetStart(
        chars: [Character],
        vowelStart: Int
    ) -> Int {
        if let plusIdx = chars[..<vowelStart].lastIndex(of: "+") {
            return plusIdx + 1
        }
        let trueVowelLetters: Set<Character> = ["a", "e", "i", "o", "u"]
        let vowelExtenders: Set<Character> = ["r", "w", "y", "n", "g"]
        guard let lastVowel = chars[..<vowelStart].lastIndex(where: {
            trueVowelLetters.contains($0)
        }) else {
            return 0
        }
        var vowelEnd = lastVowel
        var i = lastVowel + 1
        while i < vowelStart, vowelExtenders.contains(chars[i]) {
            vowelEnd = i
            i += 1
        }
        return vowelEnd + 1
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
        chars: [Character],
        insertIndex: Int
    ) -> (isLiberal: Bool, vowelStart: Int, isBareNga: Bool)? {
        guard insertIndex > 0,
              insertIndex < chars.count
        else { return nil }
        let lowers = stackLowerConsonantsStarting(chars: chars, at: insertIndex)
        guard !lowers.isEmpty else { return nil }
        guard let upperMatch = stackUpperConsonantsEndingBeforeLower(
            chars: chars,
            insertIndex: insertIndex
        ) else {
            return nil
        }
        var sawLiberal = false
        for upper in upperMatch.uppers {
            for lower in lowers {
                guard Grammar.isValidStackLiberal(upper: upper, lower: lower) else {
                    continue
                }
                if Grammar.isValidStack(upper: upper, lower: lower) {
                    return (false, upperMatch.vowelStart, upperMatch.isBareNga)
                }
                sawLiberal = true
            }
        }
        // Bare-onset nga is strict-only — kinzi never participates in
        // liberal cross-class stacking, so reject the site if the
        // strict path failed.
        if upperMatch.isBareNga {
            return nil
        }
        return sawLiberal ? (true, upperMatch.vowelStart, false) : nil
    }

    private static let stackLowerRomanKeys: [String] = {
        var seen: Set<String> = []
        var keys: [String] = []
        for key in Romanization.consonants.map(\.roman) + Romanization.clusterAliases.map(\.roman)
        where key.count > 1 && seen.insert(key).inserted {
            keys.append(key)
        }
        return keys
    }()

    private static let maxStackLowerRomanKeyLength: Int = {
        stackLowerRomanKeys.lazy.map(\.count).max() ?? 1
    }()

    private static let stackVowelUpperRuleLastLetters: Set<Character> = {
        Set(stackVowelUpperRules.compactMap(\.key.last))
    }()

    /// True when inserting `+` at `insertIndex` would slice a
    /// single-consonant digraph in half. Two patterns trigger this
    /// guard:
    ///
    /// 1. The character immediately before `insertIndex` is a `stop`
    ///    consonant (`b`, `c`, `d`, `g`, `k`, `p`, `s`, `t`, `z`) and
    ///    the character at `insertIndex` is `h`. This covers every
    ///    aspirated digraph the user can type (`dh`, `ph`, `gh`, `bh`,
    ///    `th`, `ch`, `sh`, …) — including the bare `bh` form that has
    ///    no separate `Romanization.consonants` entry. Splitting any
    ///    of these forces the parser to re-read the digraph as
    ///    `<base> + virama + ha-or-medial`, producing a malformed
    ///    surface.
    /// 2. The pair at the insertion point matches a multi-char
    ///    consonant key from `Romanization.consonants` /
    ///    `Romanization.clusterAliases` whose split form would be
    ///    similarly malformed (`khr`, `dhr`, `bhr`, `ghr`, `phr`,
    ///    `thr`, `shw`).
    ///
    /// `ng` / `ny` / `zz` / `ss` are intentionally NOT covered: the
    /// kinzi-forming `<vowel>n + g<C>` site needs `n+g` to split,
    /// and the doubled-letter digraphs don't reach this loop because
    /// their preceding letters aren't Pali coda letters. Leading-`h`
    /// cluster aliases (`hm`, `hn`, `hl`, `hr`, `hw`) are also out —
    /// `precedingCoda == "h"` is a deliberate carve-out for Pali
    /// loanwords (`brahma`, `ahmat`) where the inference splits the
    /// alias into a real `<C> + virama + <C>` stack on purpose.
    private static func isInsideMultiCharConsonantKey(
        chars: [Character],
        insertIndex: Int
    ) -> Bool {
        guard insertIndex > 0, insertIndex < chars.count else { return false }
        let stops: Set<Character> = ["b", "c", "d", "g", "k", "p", "s", "t", "z"]
        if chars[insertIndex] == "h", stops.contains(chars[insertIndex - 1]) {
            return true
        }
        let lo = max(0, insertIndex - maxStackLowerRomanKeyLength + 1)
        let hi = min(chars.count, insertIndex + maxStackLowerRomanKeyLength)
        for start in lo..<insertIndex {
            for key in stackLowerRomanKeys
            where keyMustNotBeSplit(key) {
                let end = start + key.count
                guard end <= hi, end > insertIndex else { continue }
                if matchesRomanKey(key, chars: chars, at: start) {
                    return true
                }
            }
        }
        return false
    }

    /// Multi-char consonant keys whose interior boundary should never
    /// receive an inferred `+`. These are the keys whose split form
    /// (`<base> + virama + <ha-or-medial>`) is orthographically
    /// malformed — i.e. the digraph is a single consonant or a
    /// cluster alias, not a Pali stack site.
    private static func keyMustNotBeSplit(_ key: String) -> Bool {
        // Aspirated and cluster-alias digraphs have `h` somewhere
        // after position 0 (`dh`, `ph`, `sh`, `khr`, `dhr`, …).
        // The leading `h` cluster aliases (`hm`, `hn`, `hl`, `hr`,
        // `hw`, …) are intentionally excluded — the existing
        // `precedingCoda == "h"` carve-out (Pali words like `brahma`,
        // `ahmat`) needs the inference to fire there, splitting the
        // alias into a real `<C> + virama + <C>` stack on purpose.
        guard let hIdx = key.firstIndex(of: "h"), hIdx != key.startIndex else {
            return false
        }
        return true
    }

    private static func isContinuationOfStackLowerConsonant(
        chars: [Character],
        at index: Int
    ) -> Bool {
        guard index > 0 else { return false }
        let startFloor = max(0, index - maxStackLowerRomanKeyLength + 1)
        for start in startFloor..<index {
            let offset = index - start
            for key in stackLowerRomanKeys
            where key.count > offset
                && matchesRomanKey(key, chars: chars, at: start)
                && inferredPaliStackIsLiberal(chars: chars, insertIndex: start) != nil {
                return true
            }
        }
        return false
    }

    internal static func stackLowerConsonantsStarting(
        chars: [Character],
        at index: Int
    ) -> [Character] {
        var lowers: [Character] = []
        func append(_ consonant: Character) {
            if !lowers.contains(consonant) {
                lowers.append(consonant)
            }
        }
        for entry in Romanization.consonants
        where matchesRomanKey(entry.roman, chars: chars, at: index) {
            append(entry.myanmar)
        }
        for alias in Romanization.clusterAliases
        where matchesRomanKey(alias.roman, chars: chars, at: index) {
            append(alias.consonant)
        }
        return lowers
    }

    private static func stackUpperConsonantsEndingBeforeLower(
        chars: [Character],
        insertIndex: Int
    ) -> (uppers: [Character], vowelStart: Int, isBareNga: Bool)? {
        if let matchedVowels = vowelRuleUpperConsonants(chars: chars, insertIndex: insertIndex) {
            return (matchedVowels.uppers, matchedVowels.vowelStart, false)
        }
        let codaIndex = insertIndex - 1
        if codaIndex > 0,
           isPaliStackCodaLetter(chars[codaIndex]),
           isPaliStackVowelLetter(chars[codaIndex - 1]),
           let upper = Romanization.romanToConsonant[String(chars[codaIndex])] {
            return ([upper], codaIndex - 1, false)
        }
        // Task 03: leading independent vowel + bare-onset `nga` +
        // stackable consonant. The parser consumes `ng` as a bare
        // OnsetEntry (no preceding asat-vowel arc), so neither of the
        // checks above matches. Restrict to the buffer-leading case
        // (single-letter vowel at chars[0]) since that is the only
        // site where the upper `nga` lands as a bare onset rather
        // than the coda of a previous syllable's vowel rule. The
        // injection emits `*+` (asat + virama) so the parser
        // materialises the kinzi (`<vowel> 1004 103A 1039 <C>`)
        // rather than a bare virama stack
        // (`<vowel> 1004 1039 <C>`). The `ai`-diphthong case
        // (`ainggar`) is intercepted earlier in
        // `inferImplicitStackMarkers` because the user's `ng` there
        // is redundant with the diphthong's nga-asat coda.
        if codaIndex == 2,
           chars[codaIndex] == "g",
           chars[codaIndex - 1] == "n",
           isPaliStackVowelLetter(chars[0]) {
            return ([Myanmar.nga], 0, true)
        }
        return nil
    }

    private struct StackVowelUpperRule: Sendable {
        let key: [Character]
        let uppers: [Character]
    }

    private static let stackVowelUpperRules: [StackVowelUpperRule] = {
        var grouped: [String: [Character]] = [:]
        for entry in Romanization.vowels {
            let key = Romanization.aliasReading(entry.roman)
            guard key.count > 1,
                  let upper = stackUpperConsonant(fromVowelOutput: entry.myanmar)
            else { continue }
            if grouped[key]?.contains(upper) == true {
                continue
            }
            grouped[key, default: []].append(upper)
        }
        return grouped
            .map { StackVowelUpperRule(key: Array($0.key), uppers: $0.value) }
            .sorted { lhs, rhs in lhs.key.count > rhs.key.count }
    }()

    private static func vowelRuleUpperConsonants(
        chars: [Character],
        insertIndex: Int
    ) -> (uppers: [Character], vowelStart: Int)? {
        for rule in stackVowelUpperRules {
            let length = rule.key.count
            guard length <= insertIndex else { continue }
            let start = insertIndex - length
            var matches = true
            for offset in 0..<length where chars[start + offset] != rule.key[offset] {
                matches = false
                break
            }
            if matches {
                return (rule.uppers, start)
            }
        }
        return nil
    }

    private static func stackUpperConsonant(fromVowelOutput output: String) -> Character? {
        let scalars = Array(output.unicodeScalars)
        guard !scalars.isEmpty else { return nil }
        for i in stride(from: scalars.count - 1, through: 0, by: -1)
        where scalars[i].value == 0x103A {
            var j = i - 1
            while j >= 0 {
                let scalar = scalars[j]
                if Myanmar.isConsonant(scalar) {
                    return Character(scalar)
                }
                if Self.isMedialOrMarker(scalar) {
                    j -= 1
                    continue
                }
                break
            }
        }
        return nil
    }

    private static func matchesRomanKey(
        _ key: String,
        chars: [Character],
        at index: Int
    ) -> Bool {
        guard key.count <= chars.count - index else { return false }
        var offset = index
        for ch in key {
            if chars[offset] != ch { return false }
            offset += 1
        }
        return true
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

    internal static func viramaInsensitiveHasPrefix(_ s: String, _ prefix: String) -> Bool {
        stripViramas(s).unicodeScalars.starts(with: stripViramas(prefix).unicodeScalars)
    }

    private static func stripViramas(_ s: String) -> String {
        if s.unicodeScalars.contains(where: { $0.value == 0x1039 }) {
            return String(s.unicodeScalars.filter { $0.value != 0x1039 })
        }
        return s
    }

    internal static func substituteViramaAnchor(in surface: String, matching anchor: String) -> String {
        let surfaceScalars = Array(surface.unicodeScalars)
        let anchorScalars = Array(anchor.unicodeScalars)
        var surfaceIndex = 0
        for anchorScalar in anchorScalars where anchorScalar.value != 0x1039 {
            while surfaceIndex < surfaceScalars.count,
                  surfaceScalars[surfaceIndex].value == 0x1039 {
                surfaceIndex += 1
            }
            guard surfaceIndex < surfaceScalars.count,
                  surfaceScalars[surfaceIndex].value == anchorScalar.value
            else {
                return surface
            }
            surfaceIndex += 1
        }
        while surfaceIndex < surfaceScalars.count,
              surfaceScalars[surfaceIndex].value == 0x1039 {
            surfaceIndex += 1
        }
        let suffix = String(String.UnicodeScalarView(surfaceScalars[surfaceIndex...]))
        return anchor + suffix
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
