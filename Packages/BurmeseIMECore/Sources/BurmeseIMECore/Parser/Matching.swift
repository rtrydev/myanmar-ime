import Foundation

extension SyllableParser {

    /// Consonants that form a digraph (kh, gh, ph, dh, th) or a reserved
    /// cluster alias (sh) when immediately followed by `h`. When the
    /// first post-base medial is `h` and the base is one of these, the
    /// canonicalizer treats the `h` as the second digraph character, not
    /// as a separate `h`-medial — otherwise `kh...` input would be
    /// indistinguishable from `k + h-medial + ...`.
    private static let hDigraphStarters: Set<Character> = ["k", "g", "p", "d", "t", "s"]

    /// Every roman base consonant key, used by the onset canonicalizer to
    /// decide whether a 1-to-3 char prefix at the current input position
    /// is a valid base before reading medial letters after it. Keeping
    /// the check here (not inside the trie) keeps the canonicalizer
    /// independent of which canonical entries happen to be present.
    private static let baseConsonantSet: Set<String> = Set(
        Romanization.consonants.map { $0.roman }
    )

    /// Roman base (digit-stripped) → set of Myanmar consonants that share
    /// that base when the disambiguating digit is aliased away. Used by
    /// the canonicalizer to decide which trie entries under a probed
    /// canonical key belong to the input's base — entries whose
    /// `OnsetEntry.onset` falls outside this set would only match if the
    /// user had typed the digit-bearing roman explicitly (e.g. `ny2`).
    /// Without the group, canonical collisions like
    /// `ny2 + [ya-pin, w-medial]` vs `ny + [ya-yit, w-medial]`
    /// (both aliased to `nywy`) would drop the digit-bearing sibling.
    private static let aliasedConsonantGroup: [String: Set<Character>] = {
        var groups: [String: Set<Character>] = [:]
        for entry in Romanization.consonants {
            let stripped = Romanization.aliasReading(entry.roman)
            groups[stripped, default: []].insert(entry.myanmar)
        }
        return groups
    }()

    /// Match onset entries (consonant + optional medials) at position.
    ///
    /// The trie itself only stores canonical-order keys (`h`-prefix +
    /// consonant + `w` + `y` + `y2`). A straight byte-walk catches every
    /// canonical-order input directly. Non-canonical medial orderings
    /// (e.g. `kyw` for `kwy`, `kwh` for `hkw`) are handled by an auxiliary
    /// canonicalization pass that reads the prospective medial run,
    /// reorders it into canonical form, and probes the canonical key.
    /// This replaces the previous init-time permutation expansion, which
    /// materialized ~1025 extra trie entries for every natural-order
    /// permutation of every multi-medial combo.
    internal func matchOnsets(_ chars: [Character], from start: Int) -> [(end: Int, entry: OnsetEntry)] {
        var results: [OnsetMatch] = []
        let remaining = chars.count - start
        guard remaining > 0 else { return results }
        let maxLen = min(onsetTrie.maxDepth, remaining)

        // Fast path: byte-walk over canonical-order input.
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

        // Canonicalization pass: handle user-typed medial permutations
        // that the byte-walk misses. We enumerate up to three onset
        // shapes (1-char base, 2-char digraph base, 1-char base with an
        // `h` prefix), consume the run of medial letters after the base,
        // and probe the canonical ordering in the trie. Probes where the
        // canonical form coincides with the raw input slice are skipped
        // so the byte-walk's emissions are not duplicated.
        canonicalizeOnsetProbes(chars, from: start, into: &results)

        // TASK-046: drop the bare `ah` consonant onset (canonical
        // roman `"ah"` → U+1021 အ) when its match leaves a stranded
        // inherent-`a` boundary. The `ah` key is the only consonant
        // rule whose match consumes a vowel letter (`a`) as part of
        // its onset trigger; when the buffer continues with another
        // ASCII letter, the parser otherwise silently swallows the
        // `h` of the next syllable into the `ah` onset (`kahar` →
        // `ကအာ` instead of `ကဟာ`, `aha` → `အ` instead of `အဟ`,
        // `ahmada` → `အမဒ` instead of `အဟ္မဒ`). Removing the match
        // forces the DP to take the `<a-standalone> + ha + <V>`
        // decomposition that preserves the user's `h`. End-of-buffer
        // `ah` (no following content) and post-`+` / post-`'`
        // positions are preserved, so `ah`, `ah+`, and
        // `ah+dhi+pa+yay` keep producing U+1021. The `ah` onset
        // stays reachable for those carve-outs through the bare
        // byte-walk's other entries (multi-medial variants are
        // already heavily aliased and never compete).
        filterAhStrandedAMatches(chars: chars, results: &results)

        return results
    }

    /// TASK-046 helper. Drops bare `ah` onset matches that sit in a
    /// "stranded inherent-`a`" context — i.e. the character
    /// immediately after the matched span is a non-separator ASCII
    /// letter. Such matches are the `ah` collision shape (the user's
    /// `h` is swallowed into the `ah` onset rather than starting a
    /// fresh syllable). Separators `+`, `'`, `*`, end-of-buffer, and
    /// any non-letter scalar leave the `ah` match in place because
    /// they explicitly close the syllable and the user-intended
    /// reading IS `<a-anchor>`. Numeric alias markers (`2`, `3`)
    /// don't apply to `ah` (no digit-bearing variant exists), so any
    /// trailing letter is a definitive stranded-context trigger.
    ///
    /// Carve-out: when the character immediately *before* the
    /// matched span is itself an `a`, the `ah` match is at a
    /// `<C>a-aha-<X>` site (the previous syllable has already
    /// committed an inherent `a` with the leading consonant; the
    /// `a` we'd consume here is the START of a fresh `1021`-anchor
    /// syllable, not a stranded inherent-`a` of the previous
    /// syllable). Keeping the `ah` match in this site preserves
    /// reverse-romanization round-trips for surfaces where `1021`
    /// follows a complete `<C>a` syllable mid-buffer (`ngarahain`
    /// for `ငါအိမ်`, `kahakyaung` for `<some>+<C>a + 1021 + kyaung`,
    /// …). Without this carve-out, dropping the `ah` here forces
    /// the DP into a chained inherent-`a` parse that TASK-016
    /// then rejects, leaving the entire run unparseable and
    /// surfacing as a literal-fallback Latin leak.
    ///
    /// TASK-070: extend the same carve-out to the case where the
    /// previous character is an explicit syllable boundary that the
    /// user typed to mark a fresh `1021` anchor: tone marks `.`/`:`,
    /// explicit stack `+`, and the apostrophe soft separator `'`.
    /// Without this extension `thi.ahaung`, `tha:ahaung`,
    /// `ka+ahaung`, `ka'ahaung` etc. would drop the `ah` onset and
    /// fall through to the `<a-standalone> + ha + <V>` decomposition,
    /// erasing the user's `အ` mid-sentence.
    private func filterAhStrandedAMatches(
        chars: [Character],
        results: inout [OnsetMatch]
    ) {
        results.removeAll { match in
            let (end, entry) = (match.end, match.entry)
            // Bare `ah` only — multi-medial variants (`ahw`, `ahy`,
            // …) are already heavily aliased at trie-build time and
            // do not produce the collision.
            guard entry.canonicalRoman == "ah", entry.medials.isEmpty else {
                return false
            }
            guard end < chars.count else { return false }
            let nextChar = chars[end]
            guard let ascii = nextChar.asciiValue else { return false }
            let isLowerLetter = ascii >= 0x61 && ascii <= 0x7A
            let isUpperLetter = ascii >= 0x41 && ascii <= 0x5A
            guard isLowerLetter || isUpperLetter else { return false }
            // Carve-out: previous char was `a` or an explicit
            // syllable-boundary marker (`.`, `:`, `+`, `'`). The
            // `<C>a-aha-<X>` and `<...>.<aha-<X>` sites are
            // legitimate fresh `1021`-anchor positions that should
            // not collapse into the TASK-046 collision.
            let start = end - 2
            if start > 0 {
                let prev = chars[start - 1]
                if prev == "a" || prev == "." || prev == ":"
                    || prev == "+" || prev == "'" {
                    return false
                }
            }
            return true
        }
    }

    /// Auxiliary to `matchOnsets`. Extracted so the fast-path byte-walk
    /// reads cleanly; every identifier here is only touched by the
    /// non-canonical medial-order case.
    ///
    /// The old init-time permutation expansion only emitted extra trie
    /// keys for combos of two or more medials (single-medial `[h]` was
    /// never reordered from canonical `h + base` to `base + h`). The
    /// canonicalizer preserves that: a one-medial post-base `h` run is
    /// read but no probe is emitted, so inputs like `bh`, `nh`, `khh`
    /// stay unmatched and decompose to two syllables — matching the
    /// pre-refactor behaviour the test suites lock in.
    internal func canonicalizeOnsetProbes(
        _ chars: [Character],
        from start: Int,
        into results: inout [OnsetMatch]
    ) {
        let n = chars.count
        guard start < n else { return }

        // Enumerate candidate bases as `chars[start..<start+L]` for L in
        // 1...3, validated against the roman consonant set. The old
        // permutation expansion only produced natural-order keys of the
        // form `consRoman + post-base-medial-permutation`; it never
        // generated keys that started with a user-typed `h` before the
        // consonant (preH is the canonical form's own encoding of the
        // h-medial, not a user-typable letter position). Matching that,
        // we do not introduce a preH shape here — canonical-form inputs
        // like `hky` are caught directly by the byte-walk in
        // `matchOnsets`, and preH+non-canonical post-base orderings such
        // as `hkyw` were never matchable pre-refactor.
        for baseLen in 1...3 {
            guard start + baseLen <= n else { break }

            var baseRoman = ""
            baseRoman.reserveCapacity(baseLen)
            for i in start..<start + baseLen {
                baseRoman.append(chars[i])
            }
            guard Self.baseConsonantSet.contains(baseRoman) else { continue }

            let baseFirst = baseRoman.first
            let baseIsHDigraphStarter = baseLen == 1 &&
                (baseFirst.map { Self.hDigraphStarters.contains($0) } ?? false)
            let baseEnd = start + baseLen

            var cursor = baseEnd
            var hasW = false
            var hasPostH = false
            var yCount = 0
            var explicitY2 = false
            medialLoop: while cursor < n && yCount + (hasW ? 1 : 0) + (hasPostH ? 1 : 0) < 4 {
                let ch = chars[cursor]
                switch ch {
                case "y":
                    if cursor + 1 < n && chars[cursor + 1] == "2" {
                        if yCount >= 2 { break medialLoop }
                        yCount += 1
                        explicitY2 = true
                        cursor += 2
                    } else {
                        if yCount >= 2 { break medialLoop }
                        yCount += 1
                        cursor += 1
                    }
                case "w":
                    if hasW { break medialLoop }
                    hasW = true
                    cursor += 1
                case "h":
                    if hasPostH { break medialLoop }
                    // For 1-char hDigraph bases, `h` as the very first
                    // post-base medial collides with the digraph reading
                    // of the preceding two chars — skip.
                    if !hasW && yCount == 0 && baseIsHDigraphStarter {
                        break medialLoop
                    }
                    hasPostH = true
                    cursor += 1
                default:
                    break medialLoop
                }

                // Preserve the old expansion's one-medial-no-permute
                // rule: only probe canonical when the combo accrued so
                // far has at least two medials. Without this guard,
                // inputs like `bh`, `nh`, `khh` — which the old trie
                // left unmatched and the DP decomposed into two
                // syllables — would start stacking instead.
                let totalMedials = yCount + (hasW ? 1 : 0) + (hasPostH ? 1 : 0)
                if totalMedials < 2 { continue }

                // Canonical key build: `h` prefix (if any) + base + `w`
                // + y-run. When `y2` was typed explicitly at least once,
                // the canonical form carries a trailing `y2` (matching
                // the trie's canonical entry). Otherwise the alias form
                // (no `2`) is emitted so the alias-penalty trie entry
                // fires. This mirrors the two entries `aliasVariants`
                // inserts for every canonical roman.
                let yPart: String
                switch (yCount, explicitY2) {
                case (0, _): yPart = ""
                case (1, false): yPart = "y"
                case (1, true): yPart = "y2"
                case (2, false): yPart = "yy"
                default: yPart = "yy2"
                }
                var canonical = ""
                canonical.reserveCapacity(1 + baseRoman.count + 1 + yPart.count)
                if hasPostH { canonical.append("h") }
                canonical.append(baseRoman)
                if hasW { canonical.append("w") }
                canonical.append(yPart)

                // Skip probes where the canonical form is exactly what
                // the byte-walk already traversed — avoids double-emit.
                var matchesSlice = cursor - start == canonical.count
                if matchesSlice {
                    var canonicalIter = canonical.makeIterator()
                    for i in start..<cursor {
                        guard let cCh = canonicalIter.next(), cCh == chars[i] else {
                            matchesSlice = false
                            break
                        }
                    }
                }
                if matchesSlice { continue }

                // Probe canonical key in the trie.
                var node: Int32 = 0
                var ok = true
                for cCh in canonical {
                    guard let byte = cCh.asciiValue else { ok = false; break }
                    let child = onsetTrie.children[Int(node) * 128 + Int(byte)]
                    if child < 0 { ok = false; break }
                    node = child
                }
                if ok {
                    // Canonical collisions: `htw` is the canonical key
                    // for both `t + [w-medial, h-medial]` and `ht + [w-
                    // medial]` combos. The byte-walk returns everything
                    // at the node, but when we got here via a non-
                    // canonical input like `twh`, only the combo whose
                    // base matches `baseRoman` is a valid reading —
                    // filter to that one. `baseConsonantGroup` is the
                    // set of Myanmar characters whose roman digit-alias
                    // is `baseRoman` (e.g. `ny` → {nya, nnya}).
                    let baseConsonantGroup = Self.aliasedConsonantGroup[baseRoman] ?? []
                    let sRange = onsetTrie.terminalStart[Int(node)]
                    let eRange = onsetTrie.terminalStart[Int(node) + 1]
                    if sRange < eRange {
                        for i in Int(sRange)..<Int(eRange) {
                            let entry = onsetTerminals[i]
                            if baseConsonantGroup.contains(entry.onset) {
                                results.append((cursor, entry))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Match vowel/final at position.
    internal func matchVowels(_ chars: [Character], from start: Int) -> [(end: Int, entry: VowelMatchEntry)] {
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

    internal func precomputeOnsetMatches(_ chars: [Character]) -> [[OnsetMatch]] {
        var matches = Array(repeating: [OnsetMatch](), count: chars.count + 1)
        guard !chars.isEmpty else { return matches }

        for index in 0..<chars.count {
            matches[index] = matchOnsets(chars, from: index)
        }
        return matches
    }

    internal func precomputeVowelMatches(_ chars: [Character]) -> [[VowelMatch]] {
        var matches = Array(repeating: [VowelMatch](), count: chars.count + 1)
        guard !chars.isEmpty else { return matches }

        for index in 0..<chars.count {
            matches[index] = matchVowels(chars, from: index)
        }
        return matches
    }
}
