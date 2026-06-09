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
    /// them (task 08). Four transforms, applied in order:
    ///
    ///   1. Consecutive `+` collapse to a single `+` — virama over
    ///      virama is structurally impossible, so `k++ar` is equivalent
    ///      to `k+ar` for any parse that survives right-shrink.
    ///   2. TASK-011: `<consonant-letter>a+<consonant-letter>` reshape
    ///      to `<consonant-letter>+<consonant-letter>a`. The user's
    ///      explicit `+` between two open `<C>a` syllables is the
    ///      virama-stack signal — without the reshape the parser
    ///      treats `+` as a soft-boundary (since the upper carries an
    ///      inherent vowel that virama cannot stack onto) and the
    ///      stacked surface never reaches the candidate pool. Moving
    ///      the inherent `a` from the upper to the lower mirrors
    ///      exactly what the no-`+` inference loop produces for the
    ///      doubled-letter form (`kakka` → `kak+ka` →
    ///      `1000 1000 1039 1000`).
    ///   3. `+` immediately before a vowel character is dropped — virama
    ///      cannot stack to a dependent vowel sign or standalone vowel,
    ///      so `k+ar` / `k+a+t` degrade to `kar` / `ka+t`. Without this,
    ///      the DP emits illegal virama-before-vowel shapes that the
    ///      right-shrink probe then prunes back to the seed consonant,
    ///      silently losing the user's tail.
    ///   4. Leading/trailing `+` peel off — a virama with no partner on
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
        // TASK-011: reshape `<C>a+<C>` → `<C>+<C>` (drop the upper's
        // inherent `a` so the explicit `+` virama signal survives).
        // Without this reshape the parser treats `+` between two
        // open syllables as a soft boundary (no surface) and the
        // user's stack signal vanishes silently. Dropping (rather
        // than moving) the upper's `a` keeps the structural shape
        // identical to a manually typed `<C>+<C>` (e.g. `k+ka`)
        // while preserving the user's lower vowel; chains like
        // `ya+p+ga` reshape to `y+p+ga` (one drop per `+`-flanking
        // `a`) without ever producing the chained-`a` shape that
        // TASK-016 rejects.
        var reshapedChars = Array(collapsed)
        let vowelLeadersSet: Set<Character> = ["a", "e", "i", "o", "u"]
        var idx = 0
        while idx < reshapedChars.count {
            if reshapedChars[idx] == "+",
               idx >= 2,
               reshapedChars[idx - 1] == "a",
               isInherentABearingConsonantLetter(reshapedChars[idx - 2]),
               idx + 1 < reshapedChars.count,
               isInherentABearingConsonantLetter(reshapedChars[idx + 1]),
               !vowelLeadersSet.contains(reshapedChars[idx + 1]) {
                // Drop the upper's `a`. The `+` immediately follows
                // the upper consonant and the parser materialises
                // the virama-stack reading as `<C>+<C>…`. After the
                // drop, the array shifts left by one — what was at
                // idx (`+`) is now at idx-1, and what was at idx+1
                // (the lower's first letter) is now at idx. Advance
                // past the lower's first letter so we don't re-check
                // this site.
                reshapedChars.remove(at: idx - 1)
                idx += 1
                continue
            }
            idx += 1
        }
        // TASK-047 / TASK-052: the `+` before a vowel-letter is
        // stripped only when the legacy long-vowel collapse is the
        // semantically-intended primary reading.
        //
        //  (a) TASK-047: when ANY segment to the LHS of the `+`
        //      contains a consonant letter, keep the `+` so the
        //      parser's `softBoundaryContext` gate fires the hard
        //      syllable break (`<C>+<bare-vowel-rule>` →
        //      two-syllable surface).
        //
        //  (b) TASK-052: when the entire LHS chain is bare-vowel
        //      rules (no consonant anywhere on the left side of
        //      the buffer), keep the `+` so the parser materialises
        //      the two-syllable surface with each side anchored to
        //      its own `1021`. The legacy strip is preserved ONLY
        //      for the immediately-adjacent identical-letter case
        //      (`u+u`, `i+i`, `a+a`, `e+e`, `o+o`) where the
        //      doubled-vowel collapse is the user's intended
        //      emphasis reading.
        //
        // CLAUDE.md §6 rule: "User-typed `+` is a hard syllable /
        // stack boundary." Stripping it loses signal that the
        // parser cannot recover from.
        let vowelLeaders: Set<Character> = ["a", "e", "i", "o", "u"]
        let consonantLetters: Set<Character> = [
            "k", "g", "n", "s", "z", "t", "d", "p", "v", "b",
            "m", "y", "r", "l", "w", "h"
        ]
        var result = ""
        result.reserveCapacity(reshapedChars.count)
        var i = 0
        while i < reshapedChars.count {
            if reshapedChars[i] == "+",
               i + 1 < reshapedChars.count,
               vowelLeaders.contains(reshapedChars[i + 1]) {
                // Walk back through the ENTIRE LHS — past any other
                // `+`s — looking for a consonant letter. Per case
                // (a) TASK-047 we keep the `+` whenever any segment
                // on the left side has a consonant onset. Without
                // this full walk, a `<C><a>+<vowel>+<vowel>` chain
                // would mis-classify the second `+` as bare-vowel-
                // chain (the immediate prior segment is bare vowel)
                // even though the buffer's leftmost segment is a
                // consonant-bearing syllable.
                var hasConsonantLHS = false
                var hasIdenticalDoubleStart = -1
                var j = i - 1
                while j >= 0 {
                    let ch = reshapedChars[j]
                    if consonantLetters.contains(ch) {
                        hasConsonantLHS = true
                        break
                    }
                    if ch == "+", hasIdenticalDoubleStart < 0 {
                        hasIdenticalDoubleStart = j + 1
                    }
                    j -= 1
                }
                if !hasConsonantLHS {
                    // Bare-vowel-chain LHS. The immediately-preceding
                    // segment runs from `lhsStart` to `i` (exclusive).
                    // Strip ONLY when this immediate segment and the
                    // immediate RHS segment are the same single-letter
                    // bare-vowel rule (`u+u`, `i+i`, `a+a`, …).
                    let lhsStart = hasIdenticalDoubleStart >= 0
                        ? hasIdenticalDoubleStart : 0
                    let lhs = String(reshapedChars[lhsStart..<i])
                    var k = i + 1
                    while k < reshapedChars.count,
                          reshapedChars[k] != "+",
                          reshapedChars[k] != "*",
                          reshapedChars[k] != "'" {
                        k += 1
                    }
                    let rhs = String(reshapedChars[(i + 1)..<k])
                    if shouldStripPlusForIdenticalBareVowel(lhs: lhs, rhs: rhs) {
                        i += 1
                        continue
                    }
                    // Otherwise keep the `+` so the parser's soft-`+`
                    // arc materialises the two-syllable surface.
                }
            }
            result.append(reshapedChars[i])
            i += 1
        }
        while result.first == "+" { result.removeFirst() }
        while result.last == "+" { result.removeLast() }
        return result
    }

    /// TASK-052: True when `lhs` and `rhs` are the same bare-vowel
    /// rule and the parser collapses them into a single long-vowel
    /// independent-vowel surface (`u+u` → `အူ`, `i+i` → `ဤ`,
    /// `a+a` → `အ`). For these the legacy `+` strip is kept so the
    /// long-vowel form remains rank 0 — the user's repeated vowel
    /// is interpreted as emphasis on a single phonetic syllable.
    /// All other bare-vowel-LHS shapes preserve the `+` so the
    /// parser materialises the two-syllable form.
    private static func shouldStripPlusForIdenticalBareVowel(
        lhs: String, rhs: String
    ) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty, lhs == rhs else { return false }
        // Single-letter doubled vowels: `a+a`, `e+e`, `i+i`, `o+o`,
        // `u+u`. Keep them collapsed because the corpus reading is
        // unambiguous (long-vowel emphasis or particle).
        let identicalDoubles: Set<String> = ["a", "e", "i", "o", "u"]
        return identicalDoubles.contains(lhs)
    }

    /// Letters that map to consonants whose inherent vowel is `a`
    /// (every base consonant in `Romanization.consonants` plus the
    /// medial-extension `h`/`y`/`r`/`w` that some keys use as their
    /// trailing letter). Used by the TASK-011 reshape to identify
    /// the `<C>a+<C>` shape without false-positive matching of vowel
    /// letters.
    private static func isInherentABearingConsonantLetter(_ ch: Character) -> Bool {
        // Single-letter consonant keys from Romanization.consonants:
        // k, g, n, s, z, t, d, p, v, b, m, y, r, l, w, h.
        switch ch {
        case "k", "g", "n", "s", "z", "t", "d", "p", "v", "b",
             "m", "y", "r", "l", "w", "h":
            return true
        default:
            return false
        }
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

    /// TASK-026: trim a doubled-bare-vowel tail run from `droppedTail`
    /// when its leading characters match the kept buffer's last
    /// character. The DP guard
    /// (`Parser/NBestDP.swift::runDP`) rejects chained `vowelOnly` arcs
    /// for the bare-vowel keys `i`/`u`/`e`/`o`, so the right-shrink
    /// probe peels the duplicated letters off into `droppedTail`.
    /// Without this trim the tail composer re-renders them as a second
    /// visible syllable on top of the same vowel anchor, producing the
    /// exact scalar shapes the task forbids (`<C>ိုအို`, `<C>ူဦ`,
    /// `<C>ည်ည်`, `<C>ယ်ယ်`).
    ///
    /// Returns the (possibly unchanged) `normalized` and `droppedTail`
    /// pair. The `a` letter is intentionally NOT trimmed: TASK-016
    /// relies on the dropped `a` re-rendering as `U+1021` so `kaa`
    /// surfaces as the visible two-syllable `ကအ` shape.
    internal static func trimChainedBareVowelTail(
        normalized: String,
        droppedTail: String
    ) -> (normalized: String, droppedTail: String) {
        guard let kept = normalized.last,
              let head = droppedTail.first,
              head == kept,
              isOtherChainedBareVowelLetter(head)
        else {
            return (normalized, droppedTail)
        }
        var trimmed = droppedTail
        while let next = trimmed.first, next == kept {
            trimmed.removeFirst()
        }
        return (normalized, trimmed)
    }

    @inline(__always)
    private static func isOtherChainedBareVowelLetter(_ c: Character) -> Bool {
        c == "i" || c == "u" || c == "e" || c == "o"
    }

    /// TASK-039: peel a leading doubled bare-vowel run (`ee*`) when
    /// the buffer continues with non-`e` content. The `e` rule in
    /// `Romanization.vowels` emits `101A 103A` (ya-asat). Two
    /// consecutive `e`-rule arcs concatenate to `… 101A 103A 101A
    /// 103A …` — a doubled ya-asat coda chain attached to a single
    /// implicit-A anchor. That shape has no legitimate Burmese
    /// spelling (one syllable carries one coda, not two). The
    /// existing `bareVowelOverrideSurface` collapses pure
    /// repetitions (`ee` / `eee` / `eeee`) to `အီ`, but a buffer
    /// whose `ee*` run is followed by additional letters
    /// (`eea`, `een`, `eeing`, `een+ka`, …) escapes the override
    /// and reaches the parser unchanged.
    ///
    /// Strategy: when the buffer starts with at least two `e`s and
    /// the run is followed by content (at least one more
    /// composable character), peel the leading run down to a
    /// single `e`. The parser then sees `ea` / `en` / `eing` /
    /// `en+ka` — each of which produces a single legal ya-asat
    /// coda followed by clean tail composition (`အယ်` /
    /// `အယ်န` / `အယ်အီင` / `အယ်န္က`).
    ///
    /// Restricted to `e` only because:
    ///   - `i` / `u` / `o` continued buffers (`iia`, `uue`, `ooe`,
    ///     …) reach the parser through different code paths and
    ///     are already covered by other invariants.
    ///   - The `e` doubled-coda chain is a pure storage-order
    ///     artifact: it never corresponds to a spelling the user
    ///     could be reaching for, so peeling has no false-positive
    ///     surface.
    internal static func peelLeadingDoubledE(_ buffer: String) -> String {
        let chars = Array(buffer)
        guard chars.count >= 3, chars[0] == "e", chars[1] == "e" else {
            return buffer
        }
        // Walk past the leading `e` run.
        var i = 0
        while i < chars.count && chars[i] == "e" {
            i += 1
        }
        // Need a non-`e` continuation. Pure repetition (`ee`,
        // `eee`, …) is handled by `bareVowelOverrideSurface` and
        // must not reach this peel — it would otherwise collapse
        // to a single `e` and lose the override.
        guard i < chars.count else { return buffer }
        // The continuation must contain composable content (at
        // least one of: an ASCII letter, a digit, a `+` separator,
        // or a tone marker). Pure-punctuation tails (e.g. trailing
        // tone marker) reach `peelDoubledBareVowelTrailingTone` on
        // their own and need no leading peel.
        return "e" + String(chars[i..<chars.count])
    }

    /// TASK-027: peel a trailing run of "coda-style" consonant letters
    /// (`y`, `w`, `r`, `l`) from `buffer` when the run is a structural
    /// artifact rather than a deliberate spelling. Two patterns:
    ///
    ///   1. Doubled coda repeat (`kayy`, `kaww`, `karr`, `kall`): the
    ///      buffer's tail has two or more consecutive matching coda
    ///      letters. Examples — `kayy` → ("kay", "y"); `karrr` → ("ka",
    ///      "rr"); `kall` → ("kal", "l"). Without the peel the parser's
    ///      `vowelOnly(<rule>) + onsetOnly(<letter>)` chain (or the
    ///      `onsetOnly + onsetOnly` doubled-consonant chain for `kall`)
    ///      materialises a visible standalone consonant scalar
    ///      (`101A`/`101D`/`101B`/`101C`) tacked onto an otherwise
    ///      complete syllable, which no Burmese typist intends.
    ///
    ///   2. Single trailing coda letter after a closed-syllable vowel
    ///      rule (`myaungy`): the rule itself already encodes a
    ///      consonant-letter coda (`g` for `aung`, `n` for `ain`/`an`,
    ///      `t` for `at`/`ote`/`out`/`ate`, etc.) and the user appends
    ///      another stray coda-style letter. The closed-syllable rules
    ///      checked here are the multi-character vowel rules whose
    ///      canonical roman ends with `g`, `n`, or — restricted to the
    ///      `aung`/`aing`/`ain`/`out`/`ote`/`ate`/`own`/`on`/`an`/`in`
    ///      family — to avoid touching short rules like `at`/`et`/`it`
    ///      whose trailing consonant is the user's only signal that
    ///      they wanted a closed syllable at all (no clear bug
    ///      reproduction for those shapes).
    ///
    /// **Trailing-tone interaction (TASK-027 follow-up):** when the
    /// buffer ends with a tone marker (`.` or `:`) the peel checks the
    /// pre-tone tail for the doubled-coda / stray-coda patterns and
    /// re-attaches the tone to the trimmed buffer. Without this any
    /// tone marker would consume the trailing position and the peel
    /// would silently no-op, letting the bug surface (`ကေယ့`,
    /// `ကလလ့`, `မြောင်ယ့`) re-emerge. The peeled letters never include
    /// the tone marker — only the duplicate / stray coda letters.
    ///
    /// Returns the trimmed buffer and the peeled-off characters. The
    /// peeled characters are dropped from the parser input AND from
    /// the literal-tail pipeline (callers must not re-render them);
    /// the user still sees the original keystrokes via the engine's
    /// composing-buffer string.
    internal static func peelRepeatedTrailingCoda(_ buffer: String) -> (trimmed: String, peeled: String) {
        // Strip an optional trailing tone marker so the doubled-coda
        // and stray-coda checks see the underlying syllable shape.
        // Without this, `kayy.` / `kall:` / `myaungy.` evade the peel
        // because the trailing `.` / `:` consumes the tail position
        // (the bug class flagged in TASK-027's validation report).
        let (preToneBuffer, toneSuffix) = splitTrailingToneMarker(buffer)
        let chars = Array(preToneBuffer)
        guard chars.count >= 3 else { return (buffer, "") }

        // Pattern 1: doubled coda repeat. Walk back over identical
        // trailing coda letters; require at least two (so `kayy` peels
        // one `y`, `karrr` peels two `r`s, `kall` peels one `l`).
        if let last = chars.last, isCodaStyleConsonantLetter(last) {
            var doublingStart = chars.count
            while doublingStart > 0 && chars[doublingStart - 1] == last {
                doublingStart -= 1
            }
            let runLen = chars.count - doublingStart
            if runLen >= 2 {
                let trimmed = String(chars.prefix(doublingStart + 1)) + toneSuffix
                let peeled = String(chars.suffix(runLen - 1))
                return (trimmed, peeled)
            }
        }

        // Pattern 2: single trailing coda letter after a long
        // closed-syllable vowel rule. The rules considered here are
        // the multi-char closed-syllable forms whose canonical roman
        // ends with a consonant letter and is at least 3 chars long
        // (so `at`/`et`/`it`/`ay`/`aw`/`ar` are excluded — those are
        // short rules whose trailing letter the user typed once as
        // the only signal of the closed-syllable form they wanted).
        if chars.count >= 4,
           let last = chars.last,
           isCodaStyleConsonantLetter(last) {
            // Take up to 5 chars of suffix excluding the trailing
            // candidate letter and check against the closed-syllable
            // rule list. Longest-match-first.
            let upto = Array(chars.dropLast())
            for ruleSuffix in longClosedSyllableVowelRuleSuffixes {
                if upto.count >= ruleSuffix.count
                    && Array(upto.suffix(ruleSuffix.count)) == ruleSuffix {
                    return (String(upto) + toneSuffix, String(last))
                }
            }
        }

        return (buffer, "")
    }

    /// Split a single trailing tone marker (`.` or `:`) off the buffer.
    /// Used by `peelRepeatedTrailingCoda` and
    /// `peelDoubledBareVowelTrailingTone` so a tone marker at the tail
    /// does not mask the underlying doubled-letter pattern that those
    /// guards target. Only one marker is peeled — chained
    /// `..` / `::` / `.:` are not real Burmese tone shapes and the
    /// existing pipeline already handles them as literal punctuation.
    @inline(__always)
    private static func splitTrailingToneMarker(_ buffer: String) -> (preTone: String, toneSuffix: String) {
        guard let last = buffer.last, last == "." || last == ":" else {
            return (buffer, "")
        }
        var pre = buffer
        pre.removeLast()
        return (pre, String(last))
    }

    /// TASK-026 follow-up: peel a doubled bare-vowel tail (`ee`, `ii`,
    /// `oo`, `uu`) when the buffer ends in a tone marker (`.` or `:`).
    /// Without this, the right-shrink probe sees the tone marker as the
    /// trailing character and the doubled-vowel run never falls into
    /// `droppedTail`, so `trimChainedBareVowelTail` cannot fire —
    /// letting the malformed surfaces (`ကယ်ယ့်`, `ကီည့်`, `ကိုအို့`,
    /// `ကူဥ`) re-emerge for `kee.`/`kii.`/`koo.`/`kuu.` and their
    /// colon siblings. Strategy: strip the tone marker, peel the
    /// doubled-vowel duplicate(s) the same way TASK-016 / TASK-026
    /// would for the no-tone form, then re-attach the tone to the
    /// trimmed buffer so the parser can apply the `<vowel><tone>`
    /// rule to the now-single bare vowel (e.g. `ke.` → `ကယ့်`,
    /// `ko.` → `ကို့`, `ko:` → `ကိုး`). For `i`/`u` the parser's
    /// rule scheme uses `.` to switch to the short-vowel sign rather
    /// than as a creaky-tone marker, so `kii.` resolves to `ki.` →
    /// `ကိ` (short i, tone implicit in vowel choice) — still
    /// structurally clean, which is the load-bearing invariant.
    ///
    /// Only fires when the doubled-bare-vowel run sits immediately
    /// after a consonant-bearing prefix (`<C>...VV` shape); buffer-
    /// leading doubled vowels (`ee.`, `ii:`, …) are left untouched
    /// because they are handled by `bareVowelOverrideSurface` and
    /// the dot-suffixed bare-vowel rules (`ee.`, `oo.`, …) already
    /// produce clean independent-vowel surfaces.
    ///
    /// Returns the (possibly unchanged) trimmed buffer; the peeled
    /// duplicate letters are discarded from the composing pipeline
    /// (the user still sees their original keystrokes via the
    /// engine's composing-buffer overlay).
    internal static func peelDoubledBareVowelTrailingTone(_ buffer: String) -> String {
        let (preTone, toneSuffix) = splitTrailingToneMarker(buffer)
        guard !toneSuffix.isEmpty else { return buffer }
        let chars = Array(preTone)
        // Need at least 2 chars before the tone — a doubled bare-vowel
        // run (`VV<tone>` for buffer-leading inputs) or a `<C>VV<tone>`
        // shape with a preceding consonant.
        guard chars.count >= 2, let last = chars.last,
              isOtherChainedBareVowelLetter(last)
        else { return buffer }
        // Walk back over identical trailing bare-vowel letters and
        // require at least two — `kee.` peels one `e`, `keee.` peels
        // two `e`s, `koooo:` peels three `o`s. The first occurrence
        // stays so the parser still sees `ke.` / `ki:` / `ko.`.
        var doublingStart = chars.count
        while doublingStart > 0 && chars[doublingStart - 1] == last {
            doublingStart -= 1
        }
        let runLen = chars.count - doublingStart
        guard runLen >= 2 else { return buffer }
        // Short-circuit when the original buffer is itself a dedicated
        // rule-table entry (`Romanization.romanToVowel` lookup hit):
        // `ii.` → ဣ (1023) and `oo:` → ဪ (102A) collapse cleanly via
        // the rule, and peeling would regress them to `i.` / `o:`
        // which produce different surfaces. Only fires for buffer-
        // leading doubled-vowel inputs whose full buffer (with tone)
        // is in the romanization table; consonant-anchored shapes
        // (`kii.`, `koo:`, …) are not rule entries and always peel.
        if Romanization.romanToVowel[buffer] != nil {
            return buffer
        }
        // Anchor: the char immediately before the doubled-vowel run.
        // For buffer-leading inputs (`ii:`, `uu.`, `ee.`, `ee:`, `oo.`)
        // the run starts at index 0 and there is no anchor — peel
        // anyway so the engine sees the single-vowel + tone form
        // (`i:`, `u.`, `e.`, `e:`, `o.`). For consonant-anchored
        // inputs, require the anchor be an ASCII letter that is *not*
        // the same vowel (so a buffer like `iee.` doesn't peel — its
        // doubled `ee` run would already be handled differently).
        let anchorIdx = doublingStart - 1
        if anchorIdx >= 0 {
            let anchor = chars[anchorIdx]
            guard anchor.isASCII, anchor.isLetter, anchor != last else {
                return buffer
            }
        }
        let trimmed = String(chars.prefix(doublingStart + 1)) + toneSuffix
        return trimmed
    }

    /// Visible standalone consonant letters that the parser materialises
    /// as a single base scalar when consumed as a 1-char onset arc:
    /// `y` → `101A`, `w` → `101D`, `r` → `101B`, `l` → `101C`. These
    /// are the letters the TASK-027 bug pattern leaves stranded at the
    /// end of an otherwise-complete syllable. Other single-letter
    /// onsets (e.g. `k`, `p`, `m`, `n`) are deliberately excluded — a
    /// trailing `kak` or `kap` is a legitimate doubled-syllable
    /// spelling (`ကက`, `ကပ`).
    @inline(__always)
    private static func isCodaStyleConsonantLetter(_ c: Character) -> Bool {
        c == "y" || c == "w" || c == "r" || c == "l"
    }

    /// Vowel rules whose canonical roman is at least 3 chars long and
    /// ends with a consonant letter — these are the "long closed-
    /// syllable" rules that already encode a consonant-letter coda
    /// in their own spelling. A trailing extra coda letter after one
    /// of these is the TASK-027 pattern-2 bug shape (`myaungy`,
    /// `kainy`, `kowny`, …). Stored as `[Character]` arrays so the
    /// suffix check in `peelRepeatedTrailingCoda` can compare without
    /// per-call string slicing. Sorted longest-first so the suffix
    /// check picks the most specific rule first.
    private static let longClosedSyllableVowelRuleSuffixes: [[Character]] = {
        let keys: [String] = [
            "aung", "aing",
            "ain", "out", "ote", "ate", "own",
            "on",
        ]
        return keys
            .sorted { $0.count > $1.count }
            .map { Array($0) }
    }()

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

    /// Like `surfaceHasOnlyNativeViramaStacks`, but stricter — the
    /// upper of every U+1039 stack must be a base consonant, *not*
    /// an asat-closed kinzi marker. Used by the TASK-010 leading
    /// bare-vowel ZWNJ-promotion gate to distinguish Pali consonant
    /// stacks (`အိုက္က`, `အူပ္ပ`, …) from diphthong-derived kinzi
    /// (`အိုင်္င`) — the latter is generated by vowel-rule paths
    /// (`ai+nga`, `aing+ng`) and must not be promoted to rank 0 by
    /// the leading bare-vowel rule.
    internal static func surfaceHasConsonantOnlyViramaStack(_ output: String) -> Bool {
        guard SyllableParser.scanOutputLegality(output) else { return false }
        let scalars = output.unicodeScalars.map(\.value)
        var sawConsonantStack = false
        for i in 0..<scalars.count where scalars[i] == 0x1039 {
            let prev = i >= 1 ? scalars[i - 1] : 0
            // Reject kinzi shape (asat-as-upper).
            if prev == 0x103A { return false }
            let nextScalar = i + 1 < scalars.count ? scalars[i + 1] : 0
            guard let prevCh = Unicode.Scalar(prev).map(Character.init),
                  let nextCh = Unicode.Scalar(nextScalar).map(Character.init),
                  Grammar.stackableConsonants.contains(prevCh)
            else { return false }
            guard Grammar.isValidStack(upper: prevCh, lower: nextCh) else {
                return false
            }
            sawConsonantStack = true
        }
        return sawConsonantStack
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
    /// would equal `input`). `promotableOnlyInput` (TASK-006) carries
    /// the promotable sites only (kinzi / genuine Pali shapes,
    /// excluding Burmese-compound-shape vowel-rule sites). It is
    /// non-nil only when promotable and bug-class sites coexist, so
    /// the engine can still promote a kinzi sibling on a buffer like
    /// `thingyantar` even though the full-stack sibling is demoted.
    @_spi(Testing) public static func inferImplicitStackMarkers(
        _ input: String,
        digitBoundaries: Set<Int> = []
    ) -> (
        input: String,
        insertions: Int,
        liberalInsertions: Int,
        vowelRuleLiberalInsertions: Int,
        strictOnlyInput: String?,
        strictOnlyInsertions: Int,
        promotableOnlyInput: String?,
        promotableOnlyInsertions: Int
    )? {
        // TASK-045: when the user typed any `+` the inference still has
        // to fire — an explicit `+` between syllable A and syllable B
        // says nothing about whether some implicit kinzi/stack site
        // INSIDE A or B should also fire. Run the inference on each
        // `+`-delimited segment independently and reassemble.
        // `+` is a hard syllable boundary marker, not a global
        // suppress-inference signal.
        if input.contains("+") {
            return inferImplicitStackMarkersAcrossPlusSegments(
                input,
                digitBoundaries: digitBoundaries
            )
        }
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
            // TASK-082: nga (U+1004) is never an inferred stack lower —
            // kinzi over nga (`င်္င`) is unattested orthography. When
            // the only stackable consonant after the diphthong is nga
            // itself (the `…aing|ng…` boundary), the next syllable is a
            // plain nga onset, not a stack site.
            if lowers.contains(where: {
                $0 != Myanmar.nga && Grammar.isValidStack(upper: Myanmar.nga, lower: $0)
            }) {
                let collapsed = "ai+" + String(chars[4...])
                return (collapsed, 1, 0, 0, nil, 1, nil, 0)
            }
            // Bare-onset tail (no consonant after the diphthong's `ng`,
            // e.g. `ainga`): mirror the mid-buffer liberal branch below
            // so the kinzi-preview sibling stays panel-reachable while
            // the liberal rarity bump keeps the open form at rank 0.
            // Skipped when a consonant lower exists (nga-only case
            // above falls through to the regular loop, where the
            // nga-lower exclusion blocks the site).
            if lowers.isEmpty {
                let liberalInput = "ai+" + String(chars[2...])
                return (liberalInput, 1, 1, 1, nil, 0, nil, 0)
            }
        }
        // Mid-buffer generalisation of the diphthong-coda collapse.
        // The buffer-leading case above handles `aing<stackable>` at
        // offset 0. Here we scan for the same `ai + ng` pattern at any
        // onset-led position (ngStart >= 3, so the `a` of `ai` is not at
        // index 0). Two outcomes:
        //  - Stackable lower WITH non-trivial vowel content OR aspirated key:
        //    collapse — drop the `ng` chars and insert `+` before the
        //    lower. The `ai` rule's built-in nga-asat already serves as the
        //    kinzi upper; adding the user's `ng` would double it.
        //  - No strict-valid lower, or single-char lower followed only by
        //    bare `a` (inherent vowel): block the regular loop at this `ng`
        //    position so the open form wins naturally.
        var blockedLowerIndices: Set<Int> = []
        if chars.count >= 5 {
        for ngStart in 3..<(chars.count - 1)
        where chars[ngStart] == "n" && chars[ngStart + 1] == "g"
           && chars[ngStart - 2] == "a" && chars[ngStart - 1] == "i" {
            let stackStart = ngStart + 2
            // A digit anywhere in [1, stackStart] means the user placed a
            // hard syllable break inside or immediately after the ai+ng
            // pattern. Skip the collapse AND block the regular loop at
            // ngStart — without this block the loop would fire at the
            // 'ai+ng' vowel-rule boundary and produce a kinzi anyway.
            if !digitBoundaries.isEmpty,
               digitBoundaries.contains(where: { $0 > 0 && $0 <= stackStart }) {
                blockedLowerIndices.insert(ngStart)
                continue
            }
            let lowers = stackLowerConsonantsStarting(chars: chars, at: stackStart)
            if lowers.isEmpty {
                // No consonant after `ng` — user typed a bare-onset ng.
                // Return a liberal inference so the kinzi form is reachable
                // at rank ≥ 1 (for panel access) but the liberal rarity
                // bump keeps the open form at rank 0.
                let liberalInput = String(chars[..<ngStart]) + "+" + String(chars[ngStart...])
                // The mid-buffer `ai+ng` liberal collapse is structurally
                // a vowel-rule path (the `ai` produces a kinzi-anchor
                // upper); count it under vowelRuleLiberalInsertions so
                // the rarity bump in `ingestInferredParses` keeps the
                // open form at rank 0 even when the LM is silent.
                return (liberalInput, 1, 1, 1, nil, 0, nil, 0)
            }
            // TASK-082: nga is never an inferred stack lower (kinzi
            // over nga `င်္င` is unattested) — a `…aing|ng…` boundary
            // (`naingngan` = `နိုင်` + `ငံ`) renders a plain nga onset.
            // Treating the nga-only case as non-stackable routes it to
            // the blocked path below, so the open form wins naturally.
            guard lowers.contains(where: {
                $0 != Myanmar.nga && Grammar.isValidStack(upper: Myanmar.nga, lower: $0)
            }) else {
                // Has a consonant lower but it cannot stack with nga —
                // block the regular loop here so open form wins naturally.
                blockedLowerIndices.insert(ngStart)
                // Same `aing` vowel-rule guard as below (task 02): also
                // block stackStart so a liberal cross-class inference at
                // that position doesn't fire via the new vowel rule.
                blockedLowerIndices.insert(stackStart)
                continue
            }
            // Determine collapse vs. block. An aspirated lower (next char
            // is `h`, forming a two-char key like `kh`, `gh`) always
            // collapses. A single-char lower collapses only when followed
            // by non-trivial vowel content; bare `a` (inherent vowel) at
            // the end leaves the open form preferred.
            let isAspiratedLower = stackStart + 1 < chars.count
                && chars[stackStart + 1] == "h"
            if !isAspiratedLower {
                let afterSingle = stackStart + 1
                let restIsBareA = afterSingle >= chars.count
                    || Array(chars[afterSingle...]) == ["a"]
                if restIsBareA {
                    blockedLowerIndices.insert(ngStart)
                    // Task 02: the new `aing` vowel rule lets
                    // `vowelRuleUpperConsonants` recognise `<...>aing|<C>`
                    // as an inference site at lowerIndex = stackStart, so
                    // we must also block that position. Without this, an
                    // earlier blocked ngStart still produces a kinzi
                    // through the regular loop's vowel-rule path.
                    blockedLowerIndices.insert(stackStart)
                    continue
                }
            }
            let collapsed = String(chars[..<ngStart]) + "+" + String(chars[stackStart...])
            return (collapsed, 1, 0, 0, nil, 1, nil, 0)
        }
        } // end if chars.count >= 5
        // TASK-019 Bug B follow-up: doubled-letter `<X><X>` immediately
        // after a vowel rule whose Myanmar surface ends with nga-asat
        // (`1004 103A` — `in`, `aing`, `aung`, `ai` and their tone-marked
        // siblings). The vowel rule already provides the kinzi upper
        // (nga); the user's first `<X>` is a redundant kinzi anchor and
        // the second `<X>` is the stack lower. Collapse to `<...><vowel>+<X><...>`
        // so the parser materialises kinzi (`nga + asat + virama + <lower>`)
        // with exactly one lower scalar — without this collapse the
        // doubled-letter inference branch in
        // `stackUpperConsonantsEndingBeforeLower` injects `*+` and the
        // parser splits the buffer (`<C>i + ng + asat + virama + ga`)
        // producing a stray `i-kar` (`102E`) before the kinzi. The
        // existing `ai+ng` buffer-leading and mid-buffer collapses
        // handle the explicit `<C>aing<gg>` / `aing<gg>` shapes; this
        // pass covers every other nga-asat-emitting vowel rule.
        if chars.count >= 4 {
            for vowelEnd in 2..<(chars.count - 1) {
                let lower = chars[vowelEnd]
                guard lower.isLetter, chars[vowelEnd + 1] == lower else { continue }
                guard let lowerConsonant = Romanization.romanToConsonant[String(lower)],
                      Grammar.stackableConsonants.contains(lowerConsonant),
                      Grammar.isValidStack(upper: Myanmar.nga, lower: lowerConsonant)
                else { continue }
                // Skip when the prior `ai+ng` collapses already cover
                // the position (key ends in `ng` AND the letter before
                // the `ng` is the diphthong's `i`/`a` shape) — they
                // produce a different rewrite.
                guard let key = ngaAsatVowelKeyEnding(chars: chars, at: vowelEnd) else {
                    continue
                }
                let vowelStart = vowelEnd - key.count
                // Skip when a LONGER nga-asat-emitting rule starts
                // earlier and extends past `vowelEnd` — the parser
                // would consume the doubled letter as part of the
                // longer rule, so our shorter-key collapse would
                // mis-segment the buffer. Concrete case: `maingga`
                // (`m,a,i,n,g,g,a`) — `in` matches `chars[2..4]` but
                // `aing` matches `chars[1..5]`, consuming the first
                // doubled `g` as the rule's nga-asat coda. The
                // existing `ai+ng` mid-buffer collapse owns this
                // shape and produces a clean rewrite.
                if hasLongerNgaAsatRuleOverlapping(
                    chars: chars,
                    coveringEnd: vowelEnd,
                    excluding: key
                ) {
                    continue
                }
                // Block the collapse when an explicit syllable break
                // (digit) sits between the vowel start and the doubled
                // letter — the user opted out of stacking there.
                if !digitBoundaries.isEmpty,
                   digitBoundaries.contains(where: { $0 > vowelStart && $0 <= vowelEnd + 1 }) {
                    continue
                }
                // No bare-inherent-a tail guard here. Unlike the
                // existing `ai+ng` mid-buffer collapse — which
                // operates on the user's explicit `ng` after `ai` and
                // can defer to the open form when the next syllable
                // is just `a` — the doubled-letter signal `<X><X>`
                // is itself the user's intent marker for kinzi-
                // stacking. Even when the post-stack syllable is
                // bare-inherent-a (`kingga`, `maingga`), the user
                // typing the doubled letter explicitly asked for
                // the kinzi rendering; without firing here, the
                // parser falls back to a doubled `1002` open form
                // (`ကင်ဂဂ`) that no Burmese word ever spells that
                // way.
                // Drop the redundant first doubled letter and insert
                // `+`. The vowel rule's nga-asat plus the inserted
                // `+` materialises the kinzi (`nga + asat + virama +
                // <lower>`); the surviving second `<X>` is the lower.
                let collapsed = String(chars[..<vowelEnd]) + "+" + String(chars[(vowelEnd + 1)...])
                return (collapsed, 1, 0, 0, nil, 1, nil, 0)
            }
        }
        let medialLetters: Set<Character> = ["y", "r", "w"]
        // `isBurmeseCompoundSite` flags TASK-006 bug-class inference
        // sites: vowel-rule upper that is NOT the nga consonant AND
        // the post-stack syllable is closed (carries a coda/closing
        // letter). These are the cross-class / same-class N+T/D/P
        // patterns where the user clearly typed a native Burmese
        // compound (`kantar`, `pantar`, `tantaw`, `ngantawthi`, ...);
        // the engine demotes them via a rarity bump in
        // `ingestInferredParses` so the asat-closed sibling wins rank 0.
        //
        // Excluded:
        //  - Kinzi sites (`nga` upper from `in`/`ain`/`aing`/`aung`
        //    rules, paired with a velar lower) — canonical Burmese,
        //    must continue to promote.
        //  - Open post-stack sites (`atta`, `sanda`, `vandanar`,
        //    `mantara`, `tarbandana`, `dhamma`, `kappa`, `ratna`,
        //    `padma`, ...) — recognised Pali transliteration shapes,
        //    canonical stacked surface stays at top.
        //  - Coda-branch sites (`pakta`, `karma`, `brahma`, ...) —
        //    Pali shape; existing `r`-heuristic bump still applies.
        var insertAt: [(
            index: Int,
            isLiberal: Bool,
            marker: String,
            isBurmeseCompoundSite: Bool
        )] = []
        for lowerIndex in 1..<chars.count {
            guard !blockedLowerIndices.contains(lowerIndex) else { continue }
            // A digit at this position explicitly separates syllables — the
            // user did not intend a stack/kinzi here (task 01).
            guard !digitBoundaries.contains(lowerIndex) else { continue }
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
            // Diphthong-coda subclass (TASK-006): the user closed the
            // previous syllable with a nga-asat coda from a diphthong
            // vowel rule (`ai`/`aing`/`in`-family/`aung`), so the next
            // letter is the start of a new syllable — there is no
            // "stack site" to fire. Two patterns:
            //
            //  1. Liberal cross-class with `upperIsNga`: the matched
            //     vowel rule directly emits `1004 103A` (`mintara` →
            //     `in+t`, `pyaingtaw` → `aing+t`). Inserting a virama
            //     stack across the diphthong's nga-asat coda produces
            //     malformed dual-coda surfaces.
            //  2. `hasNgaAsatShorterAlternate`: the longest matched
            //     rule is `ain` (upper=na, strict same-class with the
            //     dental lower) but the shorter `in` rule (upper=nga)
            //     also matches. The parser typically segments the
            //     buffer using the shorter rule (`<...>i` with
            //     nga-asat coda + `n` as next onset + virama-stack
            //     with `t`), producing the malformed shape regardless
            //     of strict/liberal classification (`naintaw`,
            //     `saintaw`, `naindar`).
            //
            // Reject the site outright in both cases.
            if inferred.isFromVowelRule {
                if inferred.hasNgaAsatShorterAlternate {
                    continue
                }
                if inferred.isLiberal, inferred.upperIsNga {
                    continue
                }
            }
            // Bare-onset nga sites need an asat-then-virama injection
            // (`*+`) so the parser materialises kinzi (`ng + asat +
            // virama + <C>`) instead of a bare virama stack
            // (`ng + virama + <C>`). Other inference sites carry the
            // asat in the preceding vowel rule's output, so a plain
            // `+` is enough.
            let marker = inferred.isBareNga ? "*+" : "+"
            // Vowel-rule-upper inference sites with non-nga upper
            // AND a post-stack closed syllable (TASK-006: `kantar`,
            // `pantar`, `tantaw`, `tantar`, `ngantar`, `kantawpar`,
            // `ngantawthi`, `thingyantaw`, ...) are the bug class.
            // The upper consonant (`na` from `an`/`on`/`ain` etc.) is
            // already asat-closed by the preceding vowel rule, and
            // the next syllable's vowel structure carries its own
            // closing consonant (`ar`, `aw`, `ay`, etc.) — clear
            // signals of a native Burmese compound. Replacing the
            // asat with a virama stack is a Pali override that should
            // require a curated `paliStackOverrides` entry, not
            // implicit inference.
            //
            // Sites with `nga` upper (kinzi: `min+ga`, `tin+ga`,
            // `pyaing+ga`-style) are excluded — those are canonical
            // Burmese and must continue to promote.
            //
            // Sites where the post-stack syllable is OPEN (just
            // `<C>a`, no closing letter — `atta`, `vandanar`, `sanda`,
            // `mantara`, `tarbandana`, `dhamma`, `kappa`, `ratna`,
            // `padma`, etc.) keep the existing inference behaviour:
            // those are recognised Pali transliteration shapes where
            // the stacked surface is the canonical rendering.
            let isVowelRuleNonNgaUpper = inferred.isFromVowelRule && !inferred.upperIsNga
            let isBugClassClosedPostStack = isVowelRuleNonNgaUpper
                && Self.postStackSyllableIsClosed(
                    chars: chars,
                    insertIndex: lowerIndex
                )
            insertAt.append((lowerIndex, inferred.isLiberal, marker, isBugClassClosedPostStack))
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
        // `vowelRuleLiberalInsertions` (kept for public tuple shape;
        // semantically it's "Burmese-compound-shape vowel-rule
        // inference sites that the engine should demote") counts the
        // TASK-006 bug-class sites, including both strict same-class
        // na+t/d/n and liberal cross-class na+p/k/m where the
        // post-stack syllable is closed.
        let vowelRuleLiberalInsertions = insertAt.lazy
            .filter(\.isBurmeseCompoundSite)
            .count
        let strictInsertAt = insertAt.filter { !$0.isLiberal }
        // Promotable insertions = NOT bug-class. Used to build a
        // sibling input that excludes the demoted bug-class sites
        // (TASK-006). For `thingyantar` the `n+g` kinzi site is
        // promotable but the `n+t` Burmese-compound site is not, so
        // the promotable-only input is `thin+gyantar` — feeding the
        // parser the kinzi-bearing sibling without the cross-class
        // virama that the engine wants to demote.
        let promotableInsertAt = insertAt.filter { !$0.isBurmeseCompoundSite }
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
        let promotableOnlyResult: String?
        if vowelRuleLiberalInsertions > 0, !promotableInsertAt.isEmpty {
            promotableOnlyResult = injectMarkers(
                input,
                at: promotableInsertAt.map { ($0.index, $0.marker) }
            )
        } else {
            promotableOnlyResult = nil
        }
        return (
            result,
            insertAt.count,
            liberalInsertions,
            vowelRuleLiberalInsertions,
            strictOnlyResult,
            strictInsertAt.count,
            promotableOnlyResult,
            promotableInsertAt.count
        )
    }

    /// TASK-045: per-segment kinzi/stack inference for buffers
    /// containing one or more user-typed `+`s. Splits `input` on `+`,
    /// runs the regular `inferImplicitStackMarkers` body on each
    /// segment, and reassembles the per-segment results into the
    /// aggregate tuple — preserving every user-typed `+` plus every
    /// inferred site inside each segment.
    ///
    /// Aggregation rules:
    /// - `input` = segments joined by the original `+` characters,
    ///   each segment carrying its inferred markers.
    /// - `insertions` / `liberalInsertions` /
    ///   `vowelRuleLiberalInsertions` are the sums of the per-segment
    ///   counts (these counters drive the rarity bumps in
    ///   `ingestInferredParses` and are additive by construction).
    /// - `strictOnlyInput` and `promotableOnlyInput` mirror the same
    ///   per-segment fall-back: a segment that produced a strict-only
    ///   variant contributes that variant; a segment that did not
    ///   contributes its full inferred form. The combined string is
    ///   non-nil only when at least one segment produced the variant.
    /// - `digitBoundaries` are absolute offsets in `input`; offsets
    ///   that fall inside a segment are translated to per-segment
    ///   offsets before recursion. `+` itself is never a digit
    ///   boundary, so the segment offsets cannot collide.
    ///
    /// Returns nil when no segment produced any inference (matches the
    /// no-`+` behaviour of returning nil on a buffer with no inferred
    /// sites).
    private static func inferImplicitStackMarkersAcrossPlusSegments(
        _ input: String,
        digitBoundaries: Set<Int>
    ) -> (
        input: String,
        insertions: Int,
        liberalInsertions: Int,
        vowelRuleLiberalInsertions: Int,
        strictOnlyInput: String?,
        strictOnlyInsertions: Int,
        promotableOnlyInput: String?,
        promotableOnlyInsertions: Int
    )? {
        // Walk the input character-by-character to derive segment
        // boundaries and absolute offsets. The character-array offsets
        // here must match the offsets that `digitBoundaries` carries —
        // both are computed as `chars.count`-style indices in the
        // engine.
        let chars = Array(input)
        var segments: [(text: String, start: Int)] = []
        var current = ""
        var currentStart = 0
        for (i, c) in chars.enumerated() {
            if c == "+" {
                segments.append((current, currentStart))
                current = ""
                currentStart = i + 1
            } else {
                current.append(c)
            }
        }
        segments.append((current, currentStart))

        // Per-segment recursion. `digitBoundaries` are absolute
        // offsets; translate them into per-segment offsets and drop
        // the `+` positions themselves (they are segment delimiters,
        // never digit indexes).
        var totalInsertions = 0
        var totalLiberal = 0
        var totalVowelRuleLiberal = 0
        var totalStrictOnly = 0
        var totalPromotableOnly = 0
        var fullParts: [String] = []
        var strictParts: [String] = []
        var promotableParts: [String] = []
        // Track which segments produced an inference whose insertion
        // landed near the segment boundary (specifically: the
        // segment's reassembled tail ends with `<lower>` after
        // an inferred `+`). When such a segment is followed by a
        // user-typed `+` whose next segment also starts with a
        // stackable consonant, the `collapseConnectorRuns` TASK-011
        // reshape has stripped the upper's inherent `a` — so the
        // reassembled buffer reads `<...><lower>+<C>...`, and the
        // parser interprets the user's `+` as a second virama on top
        // of the inferred kinzi. Re-insert the inherent `a` between
        // the inferred lower and the user's `+` so the parser
        // materialises kinzi on the inferred side and a separate
        // syllable on the user-stack side (soft-boundary fires
        // because virama cannot bond to a now-vowel-bearing upper).
        var segmentEndsInInferredBareLower: [Bool] = []
        var anyStrictOnlyVariant = false
        var anyPromotableOnlyVariant = false
        var anyInferred = false
        for segment in segments {
            let segText = segment.text
            let segStart = segment.start
            // Only digit boundaries falling strictly inside this
            // segment matter. A `+` between segments is at offset
            // `segStart - 1` in absolute terms (or beyond the last
            // segment); those positions are not digit positions.
            let segEnd = segStart + segText.count
            let segDigits = Set(
                digitBoundaries
                    .filter { $0 >= segStart && $0 <= segEnd }
                    .map { $0 - segStart }
            )
            if let inferred = inferImplicitStackMarkers(
                segText,
                digitBoundaries: segDigits
            ) {
                anyInferred = true
                totalInsertions += inferred.insertions
                totalLiberal += inferred.liberalInsertions
                totalVowelRuleLiberal += inferred.vowelRuleLiberalInsertions
                totalStrictOnly += inferred.strictOnlyInsertions
                totalPromotableOnly += inferred.promotableOnlyInsertions
                fullParts.append(inferred.input)
                if let strictOnly = inferred.strictOnlyInput {
                    anyStrictOnlyVariant = true
                    strictParts.append(strictOnly)
                } else {
                    strictParts.append(inferred.input)
                }
                if let promotableOnly = inferred.promotableOnlyInput {
                    anyPromotableOnlyVariant = true
                    promotableParts.append(promotableOnly)
                } else {
                    promotableParts.append(inferred.input)
                }
                // Detect the bare-lower-ending inferred shape that
                // would chain with the user's next `+` into a
                // double-virama. The inferred input ends with `+<C>`
                // where `<C>` is a stackable consonant letter and
                // there is no following vowel letter inside this
                // segment.
                segmentEndsInInferredBareLower.append(
                    Self.inferredEndsInBareStackableLower(inferred.input)
                )
            } else {
                fullParts.append(segText)
                strictParts.append(segText)
                promotableParts.append(segText)
                segmentEndsInInferredBareLower.append(false)
            }
        }
        // Re-insert the inherent `a` at every boundary where the
        // current segment's inferred input ends in a bare stackable
        // lower AND the next segment starts with a stackable
        // consonant — i.e. the user's reshape-stripped `+`-stack on
        // a segment that we just enriched with an inferred kinzi.
        for i in 0..<(fullParts.count - 1) {
            guard segmentEndsInInferredBareLower[i] else { continue }
            let nextSeg = fullParts[i + 1]
            guard let nextFirst = nextSeg.first else { continue }
            let vowelLetters: Set<Character> = ["a", "e", "i", "o", "u"]
            guard nextFirst.isLetter, !vowelLetters.contains(nextFirst) else { continue }
            guard let nextConsonant = Romanization.romanToConsonant[String(nextFirst)],
                  Grammar.stackableConsonants.contains(nextConsonant) else {
                continue
            }
            fullParts[i].append("a")
            strictParts[i].append("a")
            promotableParts[i].append("a")
        }

        guard anyInferred else { return nil }

        let combinedInput = fullParts.joined(separator: "+")
        let combinedStrict: String? = anyStrictOnlyVariant
            ? strictParts.joined(separator: "+") : nil
        let combinedPromotable: String? = anyPromotableOnlyVariant
            ? promotableParts.joined(separator: "+") : nil

        return (
            combinedInput,
            totalInsertions,
            totalLiberal,
            totalVowelRuleLiberal,
            combinedStrict,
            totalStrictOnly,
            combinedPromotable,
            totalPromotableOnly
        )
    }

    /// TASK-045 helper. True when `inferredInput` ends with `+<C>`
    /// where `<C>` is a stackable consonant letter. This signals that
    /// the segment-level inference has placed a kinzi/stack site
    /// whose lower is the segment's last consonant letter. When the
    /// next user `+`-segment also begins with a stackable consonant,
    /// the `collapseConnectorRuns` TASK-011 reshape has already
    /// stripped the inherent `a` after this lower, so the reassembled
    /// buffer would read `<...>+<lower>+<lower-of-user-stack>...` and
    /// the parser would fold both `+`s into a double-virama chain.
    /// Re-inserting the inherent `a` between the inferred lower and
    /// the user's `+` restores the syllable break the user originally
    /// typed (`<C>a+<C>`).
    ///
    /// Examples (caller passes the inferred segment input):
    ///   - inferred=`min+g` → ends `+g`, `g` is stackable → true
    ///   - inferred=`min+ga` → ends with `a` (vowel) → false
    ///   - inferred=`atta` → no `+` → false
    private static func inferredEndsInBareStackableLower(
        _ inferredInput: String
    ) -> Bool {
        let chars = Array(inferredInput)
        guard chars.count >= 3 else { return false }
        let last = chars[chars.count - 1]
        let beforeLast = chars[chars.count - 2]
        guard beforeLast == "+" else { return false }
        let vowelLetters: Set<Character> = ["a", "e", "i", "o", "u"]
        guard last.isLetter, !vowelLetters.contains(last) else { return false }
        guard let consonant = Romanization.romanToConsonant[String(last)] else {
            return false
        }
        return Grammar.stackableConsonants.contains(consonant)
    }

    /// True when the syllable starting at `insertIndex` (the lower
    /// consonant of the inferred stack site) is "closed" — i.e. it
    /// carries a vowel-rule coda letter (`r`, `w`, `y`, `n`, `g`)
    /// before the next syllable boundary. Native Burmese compound
    /// shapes (`kantar`, `pantar`, `tantaw`, `kantawpar`,
    /// `ngantawthi`, `thingyantaw`) end the post-stack syllable with
    /// a closing letter that materialises a long-vowel reading
    /// (`ar`, `aw`, `ay`) or another asat coda (`an`, `in`). Pali
    /// transliteration shapes (`atta`, `sanda`, `vandanar`,
    /// `mantara`, `tarbandana`, `dhamma`, `kappa`, `ratna`, `padma`)
    /// keep the post-stack syllable open (just `<C>a`, no closing
    /// letter), which is the structural signal that the user typed a
    /// genuine Pali word where the stacked surface is canonical.
    ///
    /// The scan starts at `insertIndex + 1` (one past the lower's
    /// first letter) to skip the lower consonant itself, then walks
    /// forward to find the first vowel letter and inspects what
    /// follows. The check is deliberately simple — a precise
    /// syllable-boundary detector would re-implement the parser; this
    /// heuristic only needs to distinguish "Pali shape" from
    /// "Burmese compound shape" on the immediate post-stack syllable.
    private static func postStackSyllableIsClosed(
        chars: [Character],
        insertIndex: Int
    ) -> Bool {
        // Skip the lower consonant. Multi-letter consonant keys
        // (`kh`, `ph`, `dh`, `bh`, `gh`, `th`, `sh`, `hm`, `hn`, ...)
        // contribute extra letters before the vowel.
        var idx = insertIndex + 1
        // Aspirated digraph: lower starts with a stop and the next
        // letter is `h` (`kh`, `ph`, `gh`, `bh`, `th`, `dh`, `ch`,
        // `sh`).
        if idx < chars.count, chars[idx] == "h" {
            idx += 1
        }
        // Find the first vowel letter for the post-stack syllable.
        let vowelLetters: Set<Character> = ["a", "e", "i", "o", "u"]
        while idx < chars.count, !vowelLetters.contains(chars[idx]) {
            // No vowel before another consonant or end of buffer —
            // treat as open (degenerate; the parser will fall back).
            // A consonant cluster after the lower (e.g. `+` or another
            // stack site's marker) breaks the syllable; default open.
            if chars[idx] == "+" { return false }
            idx += 1
        }
        guard idx < chars.count else { return false }
        // `idx` is the vowel letter. Examine what comes after.
        var after = idx + 1
        // Skip any second vowel letter (diphthong: `ai`, `aw`, `ay`,
        // `oo`, `ee`, ...). For our purposes, a closing letter after
        // a vowel-letter sequence (e.g. `aw`, `ay`) still counts as
        // closed — the trailing `w`/`y` IS the coda.
        let codaLetters: Set<Character> = ["r", "w", "y", "n", "g", "t", "m"]
        // Walk through trailing vowel-extender or coda letters. If
        // any coda letter is found AND it's NOT followed by another
        // vowel letter (which would mean it's the onset of the next
        // syllable), the syllable is closed.
        while after < chars.count {
            let ch = chars[after]
            if codaLetters.contains(ch) {
                // Coda letter. Check whether it's followed by a vowel
                // letter (then it's actually an onset of next syllable).
                if after + 1 < chars.count, vowelLetters.contains(chars[after + 1]) {
                    // Onset of next syllable — the post-stack syllable
                    // ended at the previous vowel without a coda.
                    return false
                }
                return true
            }
            if vowelLetters.contains(ch) {
                // Another vowel letter — diphthong continuation,
                // keep scanning.
                after += 1
                continue
            }
            // Some other character (digit, `+`, end). Open.
            return false
        }
        // End of buffer reached after just the vowel — bare open.
        return false
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
        // Onsetless syllable: the leading "consonant" position holds an
        // independent-vowel romanization key (`a`, `e`, `i`, `o`, `u`,
        // `ay`, `aw`, `oo`, `ii`, `u2`, `oo2`, `ay2`, `i2`, …). Burmese
        // orthography permits a virama stack after any independent
        // vowel U+1021..U+102A, so any of these qualifies as a "simple"
        // onset for inference purposes — the asymmetry that previously
        // singled out `a` had no language-level justification (TASK-010).
        //
        // The relaxation is gated on the buffer being short enough to
        // plausibly be a Pali-style word (≤ 8 letters total). This
        // excludes long random fuzz buffers and windowed-tail
        // fragments where a buffer-leading vowel is an artifact of
        // windowing rather than the user's intended onsetless
        // syllable; in those contexts the existing `a`-only heuristic
        // remains correct because the user-visible buffer's true
        // leading character is a consonant.
        if onsetStart == vowelIndex {
            if chars[vowelIndex] == "a" { return true }
            guard chars.count <= 8 else { return false }
            return isPaliStackVowelLetter(chars[vowelIndex])
        }
        return chars[onsetStart..<vowelIndex].contains { ch in
            ch.isLetter && !isPaliStackVowelLetter(ch)
        }
    }

    private static func inferredPaliStackIsLiberal(
        chars: [Character],
        insertIndex: Int
    ) -> (
        isLiberal: Bool,
        vowelStart: Int,
        isBareNga: Bool,
        isFromVowelRule: Bool,
        upperIsNga: Bool,
        hasNgaAsatShorterAlternate: Bool
    )? {
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
        // Track whether the upper inferred for this site is the nga
        // consonant. The diphthong-coda subclass (`ai`/`aing`/`in`/
        // `aung` family) emits an `upper = nga` from `vowelRuleUpperConsonants`
        // because the vowel rule's surface ends with U+1004 U+103A
        // (nga-asat). When such an inference site fires liberal
        // cross-class, the user clearly already has a closed-syllable
        // boundary from the diphthong's nga-asat — adding a virama
        // stack inside the next syllable produces the malformed
        // `<diphthong-with-nga-asat> + <na-virama-ta>` shape (see
        // task TASK-006 / `naintaw`, `saintaw`).
        let upperIsNga = upperMatch.uppers.contains(Myanmar.nga)
        var sawLiberal = false
        for upper in upperMatch.uppers {
            for lower in lowers {
                // TASK-082: nga (U+1004) never serves as a stack LOWER
                // in Burmese/Pali orthography — kinzi over nga (`င်္င`)
                // and `<C>`-over-nga virama stacks are unattested. A
                // `…n|ng…` / `…ng|ng…` letter boundary is a plain nga
                // onset for the next syllable. Explicit user-typed `+`
                // remains the escape hatch; only the implicit inference
                // is excluded here.
                guard lower != Myanmar.nga else { continue }
                guard Grammar.isValidStackLiberal(upper: upper, lower: lower) else {
                    continue
                }
                if Grammar.isValidStack(upper: upper, lower: lower) {
                    return (
                        false,
                        upperMatch.vowelStart,
                        upperMatch.isBareNga,
                        upperMatch.isFromVowelRule,
                        upperIsNga,
                        upperMatch.hasNgaAsatShorterAlternate
                    )
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
        return sawLiberal
            ? (
                true,
                upperMatch.vowelStart,
                false,
                upperMatch.isFromVowelRule,
                upperIsNga,
                upperMatch.hasNgaAsatShorterAlternate
            )
            : nil
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
    ) -> (
        uppers: [Character],
        vowelStart: Int,
        isBareNga: Bool,
        isFromVowelRule: Bool,
        hasNgaAsatShorterAlternate: Bool
    )? {
        // TASK-019: doubled-letter kinzi signal. When the user typed
        // `<X><X>` (the lower at `insertIndex` matches the immediately
        // preceding consonant), AND the preceding context is a vowel-
        // rule with an asat-closed coda, treat the doubled letter as
        // the kinzi-stack signal — even when the vowel rule's upper
        // (`na` from `an`/`aung`/etc.) would not strict-stack with
        // the lower. The kinzi anchor uses the orthographic constant
        // `nga` (1004), and the inference emits the `*+` marker so
        // the parser materialises kinzi (`nga + asat + virama +
        // <lower>`). The doubled letter's first half is consumed by
        // the kinzi; the second half is the stack lower.
        if insertIndex >= 1,
           insertIndex < chars.count,
           chars[insertIndex] == chars[insertIndex - 1],
           let lowerConsonant = Romanization.romanToConsonant[String(chars[insertIndex])],
           Grammar.stackableConsonants.contains(lowerConsonant),
           Grammar.isValidStack(upper: Myanmar.nga, lower: lowerConsonant),
           let vowelStartForDoubled = doubledLetterVowelStart(chars: chars, doubledStart: insertIndex - 1)
        {
            return ([Myanmar.nga], vowelStartForDoubled, true, false, false)
        }
        if let matchedVowels = vowelRuleUpperConsonants(chars: chars, insertIndex: insertIndex) {
            return (
                matchedVowels.uppers,
                matchedVowels.vowelStart,
                false,
                true,
                matchedVowels.hasNgaAsatShorterAlternate
            )
        }
        let codaIndex = insertIndex - 1
        if codaIndex > 0,
           isPaliStackCodaLetter(chars[codaIndex]),
           isPaliStackVowelLetter(chars[codaIndex - 1]),
           let upper = Romanization.romanToConsonant[String(chars[codaIndex])] {
            return ([upper], codaIndex - 1, false, false, false)
        }
        // TASK-010: buffer-leading multi-letter open vowel rule
        // (`ay`, `aw`, `oo`, `ii`, `ywe`, …) followed by a Pali-stack
        // site. Without this fallback, multi-letter onsetless openers
        // whose last letter is not in `isPaliStackVowelLetter`
        // (e.g. `ay` ending in `y`) never trigger inference because
        // the single-letter check above fails. Restricted to short
        // buffers (≤ 8 chars) so the relaxation only fires on
        // self-contained Pali words like `aykka`/`awkka`/`ookka` and
        // never on windowed-active-tail fragments where the leading
        // vowel is an artefact of windowing rather than user intent.
        if chars.count <= 8,
           codaIndex > 0,
           isPaliStackCodaLetter(chars[codaIndex]),
           let upper = Romanization.romanToConsonant[String(chars[codaIndex])],
           isLeadingBareVowelRule(chars: chars, beforeCoda: codaIndex) {
            return ([upper], 0, false, false, false)
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
            return ([Myanmar.nga], 0, true, false, false)
        }
        return nil
    }

    /// Multi-letter independent-vowel romanization keys
    /// (digit-stripped) used by `isLeadingBareVowelRule` (TASK-010)
    /// to recognise onsetless openers at the buffer head that should
    /// anchor a Pali-stack inference site. The set is restricted to
    /// rule keys whose ENTIRE family of homonymous variants
    /// (e.g. `ay` covers both `ay` and `ay2`) is "open" — output has
    /// no asat coda. Closed-syllable vowel rules whose digit-stripped
    /// key collides with an open variant (e.g. `an` covers closed
    /// `an`/`an2` plus open `an3`) are excluded so the existing
    /// `vowelRuleUpperConsonants` path keeps owning their inference
    /// sites and a closed rule's coda doesn't get treated as a stack
    /// upper at every position past it.
    private static let leadingBareVowelRuleKeys: Set<String> = {
        // Group vowel rules by their digit-stripped key.
        var rulesByKey: [String: [Romanization.VowelEntry]] = [:]
        for entry in Romanization.vowels {
            let key = Romanization.aliasReading(entry.roman)
            guard let first = key.first, first.isLetter else { continue }
            guard key.count >= 2 else { continue }
            rulesByKey[key, default: []].append(entry)
        }
        var set: Set<String> = []
        for (key, group) in rulesByKey {
            // Include only when EVERY variant in the group is open
            // (no asat-derived upper consonant). A single closed
            // variant in the family means the parser will favour the
            // closed reading and the inference path handled by
            // `vowelRuleUpperConsonants` is the right one.
            let allOpen = group.allSatisfy {
                stackUpperConsonant(fromVowelOutput: $0.myanmar) == nil
            }
            if allOpen {
                set.insert(key)
            }
        }
        return set
    }()

    /// True when `chars[0..<beforeCoda]` is a recognised multi-letter
    /// vowel rule key (digit-stripped). Used by
    /// `stackUpperConsonantsEndingBeforeLower` (TASK-010) to detect
    /// buffer-leading multi-letter independent vowels (`ay`, `aw`, …)
    /// whose last letter is not in `isPaliStackVowelLetter`.
    private static func isLeadingBareVowelRule(
        chars: [Character],
        beforeCoda: Int
    ) -> Bool {
        guard beforeCoda >= 2 else { return false }
        let prefix = String(chars[0..<beforeCoda])
        return leadingBareVowelRuleKeys.contains(prefix)
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
    ) -> (
        uppers: [Character],
        vowelStart: Int,
        hasNgaAsatShorterAlternate: Bool
    )? {
        var primary: (uppers: [Character], vowelStart: Int, length: Int)?
        // `stackVowelUpperRules` is sorted longest-first, so the first
        // match is the longest. We collect it as `primary`, then keep
        // scanning for any shorter rule that also matches at the same
        // end position and emits the nga-asat coda (`1004 103A` —
        // produced by the `in`/`ai`/`aing`/`aung` family). When such a
        // shorter alternate exists, the inference site is in the
        // diphthong-coda subclass: the parser may segment the buffer
        // using the shorter rule (`<...>i + n + <C>` → `<...>` with
        // nga-asat coda + `n` as next onset + virama-stack with `t`),
        // producing a malformed dual-coda surface. Callers reject the
        // site outright when this flag is true. See TASK-006.
        for rule in stackVowelUpperRules {
            let length = rule.key.count
            guard length <= insertIndex else { continue }
            let start = insertIndex - length
            var matches = true
            for offset in 0..<length where chars[start + offset] != rule.key[offset] {
                matches = false
                break
            }
            guard matches else { continue }
            if primary == nil {
                primary = (rule.uppers, start, length)
                continue
            }
            // Already have a longer primary match; check whether this
            // shorter rule emits nga-asat (upper == nga). If so, the
            // site is ambiguous between the two segmentations.
            if length < primary!.length, rule.uppers.contains(Myanmar.nga) {
                return (primary!.uppers, primary!.vowelStart, true)
            }
        }
        guard let pick = primary else { return nil }
        return (pick.uppers, pick.vowelStart, false)
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

    /// TASK-019 helper: returns the start index of the asat-closed
    /// vowel rule that ends at `doubledStart` (the first character of
    /// the doubled cluster), or nil if no such vowel rule matches.
    /// The doubled letter `<X><X>` after a recognised vowel-rule with
    /// an asat-closed coda (`an`, `aung`, …) is the kinzi-stack signal
    /// — the kinzi anchor uses `nga` regardless of the vowel rule's
    /// natural upper. Bare `<X><X>` patterns at the buffer head (no
    /// preceding vowel rule) return nil so the existing buffer-leading
    /// bare-nga path keeps owning that case.
    ///
    /// Vowel rules whose own Myanmar surface ends with `1004 103A`
    /// (nga-asat — `in`, `aing`, `ai`, `aung` family) are EXCLUDED
    /// here. The `*+` injection that this branch enables would add
    /// a SECOND asat scalar after the rule's existing one and force
    /// the parser to re-segment the buffer (`<C>i + ng + asat +
    /// virama + <X>` instead of `<C> + in + virama + <X>`), leaving a
    /// stray `i-kar` (`102E`) before the kinzi. Those nga-asat-rule
    /// shapes are handled by the doubled-letter pre-pass at the top
    /// of `inferImplicitStackMarkers` — when the pre-pass collapses,
    /// it consumes the position; when its bare-inherent-a guard
    /// blocks, the open form wins naturally without a polluted
    /// stray-vowel `*+` rendering.
    private static func doubledLetterVowelStart(
        chars: [Character],
        doubledStart: Int
    ) -> Int? {
        guard doubledStart >= 2 else { return nil }
        for rule in stackVowelUpperRules {
            // Skip rules whose upper is nga: they are nga-asat-emitting
            // (`in`, `aing`, `ai`, `aung`); see the doc comment above.
            if rule.uppers.contains(Myanmar.nga) { continue }
            let length = rule.key.count
            guard length <= doubledStart else { continue }
            let start = doubledStart - length
            var matches = true
            for offset in 0..<length where chars[start + offset] != rule.key[offset] {
                matches = false
                break
            }
            if matches { return start }
        }
        return nil
    }

    /// Romanization keys for vowel rules whose Myanmar surface ends
    /// with `1004 103A` (nga-asat). These are the rules whose own
    /// output already contains the kinzi upper, so any user-typed
    /// doubled-letter `<X><X>` immediately after the rule is the
    /// signal "stack <X> under the kinzi" — the first `<X>` is a
    /// redundant kinzi anchor, the second is the stack lower.
    /// Includes every variant of `in`, `aing`, `ai`, `aung`, etc.,
    /// with their tone-marker siblings (`:`, `.`). Sorted longest-
    /// first so the matcher consumes the longest applicable key
    /// (`aing` before `ai`, `aung2:` before `aung`, …). Excludes
    /// `ng` / `ngg` (consonant keys, not vowel rules) and the open
    /// `ai*` rules whose output does NOT end with nga-asat (none in
    /// the current rule table).
    @_spi(Testing) public static let ngaAsatVowelKeys: [[Character]] = {
        var seen: Set<String> = []
        var keys: [[Character]] = []
        for entry in Romanization.vowels {
            let key = Romanization.aliasReading(entry.roman)
            guard key.count >= 2 else { continue }
            // Last two scalars must be `1004 103A` (nga + asat) for
            // the kinzi-anchor signal to apply.
            let scalars = Array(entry.myanmar.unicodeScalars)
            guard scalars.count >= 2,
                  scalars[scalars.count - 2].value == 0x1004,
                  scalars[scalars.count - 1].value == 0x103A
            else { continue }
            guard seen.insert(key).inserted else { continue }
            keys.append(Array(key))
        }
        return keys.sorted { lhs, rhs in lhs.count > rhs.count }
    }()

    /// Returns the rule-key character array for the longest
    /// `ngaAsatVowelKeys` entry that ends exactly at `vowelEnd` in
    /// `chars`, or nil if no such key matches. Used by the doubled-
    /// letter kinzi pre-pass to decide whether to collapse a
    /// `<vowel-rule><X><X>` site into `<vowel-rule>+<X>`.
    private static func ngaAsatVowelKeyEnding(
        chars: [Character],
        at vowelEnd: Int
    ) -> [Character]? {
        for key in ngaAsatVowelKeys {
            let length = key.count
            guard length <= vowelEnd else { continue }
            let start = vowelEnd - length
            var matches = true
            for offset in 0..<length where chars[start + offset] != key[offset] {
                matches = false
                break
            }
            if matches { return key }
        }
        return nil
    }

    /// True when any nga-asat-emitting vowel rule (other than
    /// `excluding`) covers a span that strictly extends past
    /// `coveringEnd`. Used by the doubled-letter pre-pass to bail
    /// when a longer rule (e.g. `aing`) overlaps a shorter match
    /// (e.g. `in`) — in that case the parser's natural longest-match
    /// segmentation would consume the doubled letter as part of the
    /// longer rule, so the shorter-key collapse would mis-rewrite
    /// the buffer.
    private static func hasLongerNgaAsatRuleOverlapping(
        chars: [Character],
        coveringEnd: Int,
        excluding: [Character]
    ) -> Bool {
        for key in ngaAsatVowelKeys {
            // Only consider STRICTLY longer keys.
            if key.count <= excluding.count { continue }
            // Try every start position whose end strictly exceeds
            // coveringEnd — i.e. the key covers chars within
            // [start, start + key.count) and start + key.count >
            // coveringEnd. Equivalently, start in
            // (coveringEnd - key.count, coveringEnd].
            let lowerBound = max(0, coveringEnd - key.count + 1)
            let upperBound = min(chars.count - key.count, coveringEnd)
            guard lowerBound <= upperBound else { continue }
            for start in lowerBound...upperBound {
                var matches = true
                for offset in 0..<key.count
                where chars[start + offset] != key[offset] {
                    matches = false
                    break
                }
                if matches { return true }
            }
        }
        return false
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

    internal static func containsMyanmarSurfaceScalar(_ output: String) -> Bool {
        output.unicodeScalars.contains {
            $0.value >= 0x1000 && $0.value <= 0x109F
        }
    }

    @_spi(Testing) public static func isAcceptableParse(_ parse: SyllableParse) -> Bool {
        // Carve-out for clean Pali-style virama stacks whose DP-time
        // legality flagged 0 but whose materialised surface is
        // orthographically clean (`hasOnlyCleanViramaStacks`).
        //
        // TASK-025: also require `parse.score >= 0`. The DP's `.skip`
        // arc penalises score by -100 per unparseable char it
        // consumes; legitimate stack rescues never include a `.skip`
        // arc and always score ≥ 0. Without this guard, a buffer like
        // `k+ka.` is accepted at full length (the `.` is silently
        // absorbed by a `.skip` arc) and the trailing tone marker
        // never reaches the right-shrink probe's `droppedTail` — the
        // tone-attachment helper in
        // `Engine/PunctuationHandling.swift::applyBareConsonantToneFromTail`
        // is then never invoked, and both the literal `.`/`:` and the
        // would-be tone scalar disappear from every panel candidate.
        let stackCarveOut = parse.legalityScore == 0
            && parse.score >= 0
            && hasOnlyCleanViramaStacks(parse)
        guard parse.legalityScore > 0 || stackCarveOut else { return false }
        guard !hasInterleavedLatin(parse.output) else { return false }
        guard !hasTripleViramaStack(parse.output) else { return false }
        // The parser's per-transition `isLegal` flag is computed before
        // the materialised surface is scanned, so a parse can pass the
        // DP-time legality check yet still emit a structurally
        // malformed surface (e.g. orphan e-kar after a closing tone
        // marker — see task 01). Applying `scanOutputLegality` here
        // means the right-shrink probe in
        // `parseLongestAcceptablePrefix` correctly backs off to a
        // length whose top parse renders cleanly, so the engine can
        // then compose the dropped tail with an explicit `အ` base.
        //
        // Parses whose surface starts with U+200C (orphan ZWNJ) — or
        // whose mid-surface carries an unanchored mark — are still
        // acceptable when the engine's `promoteOrphanZwnjToImplicitA`
        // / `promoteOrphanInternalMarks` post-processing would
        // produce a legal sibling, since the engine adds those
        // siblings to the candidate pool downstream.
        guard SyllableParser.scanOutputLegality(parse.output)
                || canBePromotedToLegal(parse)
        else { return false }
        for reading in standaloneTallAaReadings where parse.reading.hasPrefix(reading) {
            return false
        }
        // TASK-017: reject parses whose post-promotion surface carries
        // a dep-vowel orphan cluster past an asat-closed coda — i.e.
        // an independent-vowel anchor (`U+1021`) after the closed-
        // syllable coda followed by ONLY dep-vowel marks (no base
        // consonant). This is the trailing-`oo` / `ii` / `uu` orphan-
        // chain pattern (`nyaungoo` → `… 1004 103A 1021 102D 102F`);
        // the right-shrink probe drops the trailing chars and
        // `composeLetterRunsInTail` re-renders them as the precomposed
        // independent-vowel form (`ဩ` / `ဦ` / `ဤ`). Legitimate
        // two-syllable patterns where the post-anchor cluster ends
        // with a base + asat coda (`aungout` → `… 1004 103A 1021 1031
        // 102C 1000 103A`) are NOT rejected because the trailing
        // region terminates in a base consonant.
        //
        // Restricted to the post-asat-coda case so single-syllable
        // bare-vowel patterns (`iii`, `ee`) and their canonical
        // bare-vowel-override sibling (`ဤ`, `အီ`) are unaffected.
        //
        // TASK-052 carve-out: skip the rejection when the parse
        // reading carries an explicit `+`. A user-typed `+` between
        // the asat-closed coda and the post-anchor cluster signals
        // a deliberate hard syllable break (e.g. `ka+e+o` →
        // `… 101A 103A 1021 102D 102F`); the orphan-chain heuristic
        // would otherwise force the right-shrink probe to drop the
        // post-`+` syllable, breaking `ExplicitPlusVowelChainSuite`.
        if !parse.reading.contains("+"),
           surfaceHasOrphanAnchorPastAsatCoda(promotedSurface(parse)) {
            return false
        }
        return true
    }

    /// Best-effort post-promotion surface for `parse`. Mirrors the
    /// same chain `update(buffer:context:)` runs (leading-ZWNJ
    /// promotion → mid-surface orphan-mark promotion). Returns the
    /// parse output unchanged when no promotion applies.
    private static func promotedSurface(_ parse: SyllableParse) -> String {
        if let zwnjPromoted = promoteOrphanZwnjToImplicitA(parse) {
            if let internalPromoted = promoteOrphanInternalMarks(zwnjPromoted) {
                return internalPromoted.output
            }
            return zwnjPromoted.output
        }
        if let internalPromoted = promoteOrphanInternalMarks(parse) {
            return internalPromoted.output
        }
        return parse.output
    }

    /// True when `surface` carries an orphan-vowel anchor past an
    /// asat-closed coda — i.e. an `U+1021..U+102A` independent-vowel
    /// anchor after the last `U+103A` asat where the trailing region
    /// contains no base consonant. This is the trailing-`oo` / `ii`
    /// / `uu` orphan-chain pattern (`nyaungoo` →
    /// `… 1004 103A 1021 102D 102F`); the right-shrink probe drops
    /// the trailing chars and `composeLetterRunsInTail` re-renders
    /// them as the precomposed independent-vowel form (`ဩ` / `ဦ` /
    /// `ဤ`). Legitimate two-syllable patterns where the post-anchor
    /// cluster terminates in a base-consonant + asat coda (`aungout`
    /// → `… 1004 103A 1021 1031 102C 1000 103A`) are NOT rejected.
    /// TASK-017.
    private static func surfaceHasOrphanAnchorPastAsatCoda(
        _ surface: String
    ) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        var lastAsatIdx = -1
        for i in 0..<scalars.count where scalars[i] == 0x103A {
            lastAsatIdx = i
        }
        guard lastAsatIdx >= 0 else { return false }
        // Find the first anchor past the asat coda.
        var anchorIdx = -1
        for i in (lastAsatIdx + 1)..<scalars.count
        where (0x1021...0x102A).contains(scalars[i]) {
            anchorIdx = i
            break
        }
        guard anchorIdx >= 0 else { return false }
        // Walk forward from the anchor. If we see a base consonant
        // (U+1000..U+101F or U+103F), it's a legitimate next syllable
        // — not an orphan chain.
        for i in (anchorIdx + 1)..<scalars.count {
            let v = scalars[i]
            let isBaseConsonant = (v >= 0x1000 && v <= 0x101F) || v == 0x103F
            if isBaseConsonant {
                return false
            }
        }
        return true
    }

    /// Returns `true` when the orphan-promotion post-processing the
    /// engine runs on the parser's output would yield a parse whose
    /// surface passes `scanOutputLegality`. Mirrors the chain in
    /// `update(buffer:context:)`: leading-ZWNJ promotion first, then
    /// mid-surface orphan-mark promotion on either the original or the
    /// ZWNJ-promoted sibling.
    private static func canBePromotedToLegal(_ parse: SyllableParse) -> Bool {
        if let zwnjPromoted = promoteOrphanZwnjToImplicitA(parse) {
            if SyllableParser.scanOutputLegality(zwnjPromoted.output) { return true }
            if let internalPromoted = promoteOrphanInternalMarks(zwnjPromoted),
               SyllableParser.scanOutputLegality(internalPromoted.output) {
                return true
            }
        }
        if let internalPromoted = promoteOrphanInternalMarks(parse),
           SyllableParser.scanOutputLegality(internalPromoted.output) {
            return true
        }
        return false
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
