import Foundation

extension BurmeseEngine {

    /// Auto-correct the aa sign in each candidate surface to match the
    /// descender requirement of its preceding consonant: descender onsets
    /// (kha, ga, nga, da, pa, wa) take tall ါ (U+102B); others take short
    /// ာ (U+102C). Previously both shapes were emitted as siblings, which
    /// roughly doubled the candidate panel with orthographically wrong
    /// forms. Collapsing to the single correct shape removes that noise.
    internal static func expandAaVariants(_ candidates: [Candidate]) -> [Candidate] {
        var result: [Candidate] = []
        var seen: Set<String> = []
        for candidate in candidates {
            let corrected = correctAaShape(candidate.surface)
            let surface = corrected == candidate.surface ? candidate.surface : corrected
            guard seen.insert(surface).inserted else { continue }
            if surface == candidate.surface {
                result.append(candidate)
            } else {
                result.append(Candidate(
                    surface: surface,
                    reading: candidate.reading,
                    source: candidate.source,
                    score: candidate.score
                ))
            }
        }
        return result
    }

    /// Hoisted out of `correctAaShape` so the ~7-element set isn't
    /// rebuilt on every candidate surface the engine post-processes.
    internal static let tallAaScalarSet: Set<UInt32> = Set(
        Grammar.requiresTallAa.compactMap { $0.unicodeScalars.first?.value }
    )

    /// Walk a surface string and rewrite each ာ/ါ to the shape appropriate
    /// for its preceding consonant. Medials and signs between the
    /// consonant and the aa sign are skipped over.
    ///
    /// Operates on Unicode scalars, not grapheme clusters: Myanmar
    /// consonant + dependent vowel signs form a single extended grapheme,
    /// so a `Character`-level scan would never see the aa scalar on its
    /// own and the correction would silently no-op on multi-sign
    /// syllables like `ပေါင်း`.
    @_spi(Testing) public static func correctAaShape(_ text: String) -> String {
        let shortAa: UInt32 = 0x102C
        let tallAa: UInt32 = 0x102B
        // Most surfaces have no aa sign at all (garbage-bash buffers, or
        // syllables whose vowel is not `a`). Skip the scalar-array
        // allocation and nested walk for those.
        var hasAa = false
        for scalar in text.unicodeScalars where scalar.value == shortAa || scalar.value == tallAa {
            hasAa = true
            break
        }
        guard hasAa else { return text }
        var scalars = Array(text.unicodeScalars)
        let tallAaSet = tallAaScalarSet
        for i in 0..<scalars.count {
            let v = scalars[i].value
            guard v == shortAa || v == tallAa else { continue }
            // Record whether a medial sign (U+103B ya-pin, U+103C ya-yit,
            // U+103D wa-hswe, U+103E ha-htoe) sat between the aa and its
            // base consonant. When one did, the medial already visually
            // disambiguates the consonant's round bottom and native
            // orthography writes short-aa ာ — e.g. `ပြော` (freq 1,358,895
            // in BurmeseLexiconSource.tsv), `ပွား`, `ဂြော` — so the
            // tall-aa rewrite must be skipped (task 11).
            var sawMedial = false
            var j = i - 1
            while j >= 0 {
                let prev = scalars[j]
                let pv = prev.value
                if pv >= 0x103B && pv <= 0x103E { sawMedial = true }
                if Myanmar.isConsonant(prev) {
                    // `Grammar.requiresTallAa` is the orthographic source of
                    // truth at every position the descender consonant
                    // appears, regardless of what scalar precedes it. The
                    // earlier "if preceded by virama, fall back to short"
                    // carve-out (task 01) was wrong — the lexicon shows the
                    // tall hook is the only attested form for kinzi+ဂ+aa
                    // (`အင်္ဂါ`, `ဘင်္ဂါလီ`), the only attested form for
                    // ဂ_+aa Pali stacks (`မဂ္ဂါဝပ်`), and the dominant form
                    // for ပ_+aa (`အဓိပ္ပါယ်` 23,838× vs. `အဓိပ္ပာယ်`
                    // 17,340×). Any per-surface short-aa exception is now
                    // encoded as a data table override (see task 05),
                    // not as a structural rule here.
                    let wantsTall = tallAaSet.contains(prev.value) && !sawMedial
                    let target: UInt32 = wantsTall ? tallAa : shortAa
                    if v != target {
                        scalars[i] = Unicode.Scalar(target)!
                    }
                    break
                }
                j -= 1
            }
        }
        var result = ""
        result.unicodeScalars.reserveCapacity(scalars.count)
        for scalar in scalars {
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    /// Test whether `surface` is an orphan ZWNJ + combining-mark pair.
    /// See `Grammar.swift` module doc for the rationale.
    ///
    /// Covers dependent vowels (102B–1039), asat (103A), and the medials
    /// ya-pin / ya-yit / wa-hswe / ha-htoe (103B–103E). Any of these
    /// following a ZWNJ base is an onset-less orphan that is never legal
    /// Burmese orthography.
    internal static func isOrphanZwnjMark(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        guard scalars.count >= 2, scalars[0].value == 0x200C else { return false }
        let v = scalars[1].value
        return v >= 0x102B && v <= 0x103E
    }

    /// Structural guard for lexicon entries whose surface is nothing but
    /// Myanmar combining marks (dep-vowels, medials, virama/asat, tone
    /// marks in U+102B–U+103E). Those are never legal standalone words —
    /// they always attach to a consonant base. The corpus_builder
    /// segmenter drops them before counts are aggregated (task 01), but
    /// this engine-side filter catches any that slip through a legacy
    /// lexicon build.
    internal static func isOrphanCombiningMarkSurface(_ surface: String) -> Bool {
        let scalars = surface.unicodeScalars
        guard !scalars.isEmpty else { return false }
        for scalar in scalars {
            let v = scalar.value
            if v < 0x102B || v > 0x103E { return false }
        }
        return true
    }

    internal static func sanitizeOrphanZwnj(_ candidates: [Candidate]) -> [Candidate] {
        let hasLegal = candidates.contains {
            !isOrphanZwnjMark($0.surface)
                && !isOrphanCombiningMarkSurface($0.surface)
                && !isPollutedFormatControlSurface($0.surface)
                && !isLeadingNonMyanmarScalar($0.surface)
        }
        guard hasLegal else { return candidates }
        return candidates.filter {
            !isOrphanZwnjMark($0.surface)
                && !isOrphanCombiningMarkSurface($0.surface)
                && !isPollutedFormatControlSurface($0.surface)
                && !isLeadingNonMyanmarScalar($0.surface)
        }
    }

    internal static func sanitizeMalformedMyanmarMarks(_ candidates: [Candidate]) -> [Candidate] {
        let hasClean = candidates.contains {
            SyllableParser.scanOutputLegality($0.surface)
        }
        guard hasClean else { return candidates }
        return candidates.filter {
            SyllableParser.scanOutputLegality($0.surface)
        }
    }

    /// TASK-012: drop any candidate whose surface contains an
    /// independent-vowel scalar (U+1021..U+102A) immediately
    /// followed by virama (U+1039). That adjacency is structurally
    /// illegal in modern Burmese — independent vowels cannot serve
    /// as the upper of a virama stack
    /// (`Grammar.stackableConsonants` is restricted to
    /// U+1000..U+101F plus U+103F) — and historically reached the
    /// candidate panel through the windowed-prefix / active-tail
    /// seam in long `+`-chains. The defensive filter is run after
    /// the other sanitizers so it operates on the merged + ZWNJ-
    /// promoted surface set.
    internal static func sanitizeIndepVowelVirama(_ candidates: [Candidate]) -> [Candidate] {
        let hasClean = candidates.contains {
            !surfaceHasIndepVowelVirama($0.surface)
        }
        guard hasClean else { return candidates }
        return candidates.filter {
            !surfaceHasIndepVowelVirama($0.surface)
        }
    }

    /// TASK-015: drop any candidate whose surface violates the
    /// "one base per syllable" invariant for onsetless multi-vowel
    /// inputs. Three illegal shapes:
    ///   1. Adjacent independent-vowel scalars (`[1021..102A]
    ///      [1021..102A]`).
    ///   2. Repeated U+1021 anchors injected into a single orphan-
    ///      mark cluster (the orphan-mark sanitizer's
    ///      one-anchor-per-scalar bug).
    ///   3. Precomposed independent vowel (U+1024..U+102A excluding
    ///      U+1028) preceded by a dep-vowel sign with no intervening
    ///      syllable closer or base consonant — i.e. mid-syllable
    ///      precomposed indep insertion.
    /// Like the other sanitizers, the filter only runs when at
    /// least one clean candidate exists; otherwise the panel keeps
    /// the violating candidates as a last-resort fallback.
    internal static func sanitizeAdjacentIndependentVowels(_ candidates: [Candidate]) -> [Candidate] {
        // First pass: drop everything flagged by the full invariant
        // (TASK-015 + TASK-022 + TASK-037). When at least one clean
        // sibling exists, the panel surfaces only clean candidates.
        let cleanFiltered = candidates.filter {
            !surfaceViolatesIndependentVowelInvariant($0.surface)
        }
        if !cleanFiltered.isEmpty {
            return cleanFiltered
        }
        // Fallback when nothing survives the full invariant: drop
        // only the structurally worst class — adjacent independent-
        // vowel pairs (`<indep><indep>` with no dep-mark between),
        // which never correspond to any legitimate Burmese spelling.
        // This keeps the multi-anchor "open cluster" shapes (e.g.
        // `အူဦ` for `u+u`) reachable as a last resort while still
        // suppressing the strictly-worse adjacency form (`ဦဦ`) the
        // ranker may otherwise float to the top once mixed-anchor
        // chains are filtered.
        let adjacencyFree = candidates.filter {
            !surfaceContainsAdjacentIndepVowels($0.surface)
        }
        if !adjacencyFree.isEmpty {
            return adjacencyFree
        }
        return candidates
    }

    /// Per-class predicate for the (1) check inside
    /// `surfaceViolatesIndependentVowelInvariant`. Hoisted so the
    /// fallback in `sanitizeAdjacentIndependentVowels` can reuse the
    /// same scan without rerunning the more expensive walks.
    private static func surfaceContainsAdjacentIndepVowels(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 2 else { return false }
        for i in 0..<(scalars.count - 1) {
            if (0x1021...0x102A).contains(scalars[i])
                && (0x1021...0x102A).contains(scalars[i + 1]) {
                return true
            }
        }
        return false
    }

    /// True when `surface` violates one of the TASK-015 invariants.
    ///
    /// The two structural shapes guarded against:
    ///   1. Adjacent independent-vowel scalars — `[1021..102A]
    ///      [1021..102A]` directly adjacent. Each Burmese syllable
    ///      has exactly one base; two indep-vowel scalars next to
    ///      each other cannot both be the base of separate syllables
    ///      without at least a dependent-vowel mark or syllable
    ///      closer between them.
    ///   2. Repeated U+1021 anchors injected into a single orphan-
    ///      mark stretch — the orphan-mark sanitizer is supposed to
    ///      wrap a contiguous orphan-mark run with one anchor, not
    ///      one per scalar (`nyaungoo` produced four U+1021 anchors
    ///      pre-fix; only one is correct).
    /// The "precomposed indep mid-syllable" pattern (`thiu`,
    /// `rarthiu`) is intentionally *not* a violation — it represents
    /// two valid Burmese syllables (`thi` + `u`) where the second is
    /// an independent-vowel particle, an established orthographic
    /// shape exercised by existing test suites.
    @_spi(Testing) public static func surfaceViolatesIndependentVowelInvariant(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        // (1) adjacent indep-vowel scalars.
        if scalars.count >= 2 {
            for i in 0..<(scalars.count - 1) {
                if (0x1021...0x102A).contains(scalars[i])
                    && (0x1021...0x102A).contains(scalars[i + 1]) {
                    return true
                }
            }
        }
        // (2) TASK-037 generalised anchor walk: any two independent-
        // vowel scalars (U+1021..U+102A) appearing inside the same
        // open syllable cluster — separated only by dep-vowel /
        // medial / anusvara marks, with no consonant base, virama
        // stack, or U+103A asat reset between them — violate the
        // "exactly one base per syllable" rule. This catches both
        // same-anchor pairs (two U+1021) and mixed-anchor pairs
        // (e.g. U+1021 → U+1026/U+1027/U+1029) that the original
        // U+1021-only chain counter missed. The previous
        // "chainCount >= 3" rule was a special case of this walk
        // (three U+1021 with intervening dep-marks) — it falls out
        // of the general check naturally.
        //
        // Reset on:
        //   - Consonant bases (U+1000..U+1021 except the indep-vowel
        //     range). Note the indep-vowel scalars themselves do NOT
        //     reset the walk — they ARE the second anchor.
        //   - Asat (U+103A): closes the cluster.
        //   - Virama (U+1039): introduces a stacked consonant which
        //     terminates the open cluster and starts a new one.
        //   - Anything outside the indep-vowel + dep-mark vocabulary.
        do {
            var i = 0
            var anchorCount = 0
            var sawDepMarkSinceAnchor = false
            while i < scalars.count {
                let v = scalars[i]
                if (0x1021...0x102A).contains(v) {
                    if anchorCount >= 1 && sawDepMarkSinceAnchor {
                        return true
                    }
                    anchorCount += 1
                    sawDepMarkSinceAnchor = false
                    i += 1
                    continue
                }
                let isDepMark = (0x102B...0x1032).contains(v)
                    || v == 0x1036
                    || (0x103B...0x103E).contains(v)
                if isDepMark {
                    sawDepMarkSinceAnchor = true
                    i += 1
                    continue
                }
                // Consonant bases, virama, asat, tone closers, format
                // controls, and any other scalar all reset the walk:
                // they break the "open cluster" the anchor walk is
                // looking for.
                anchorCount = 0
                sawDepMarkSinceAnchor = false
                i += 1
            }
        }
        // (3) TASK-022: bridged-anchor pollution. Two or more
        // orphan-mark clusters (each pre-anchored by U+1021)
        // bridged by a <consonant-base> 103A asat-closed coda
        // fragment from the orphan-mark sanitizer's `e`-rule
        // fallback. The shape is:
        //
        //   <U+1021><dep-vowel(s)><consonant><U+103A><U+1021><dep-vowel(s)>
        //
        // and crucially the second cluster contains only dep-vowel
        // signs — no further base consonant + asat coda. A
        // legitimate two-syllable pattern like
        // `… 1021 1031 102C 1004 103A 1021 102C 1010 103A …`
        // (`aungout`) terminates the second cluster with a base +
        // asat coda, indicating a complete syllable rather than
        // an orphan-mark anchor.
        if scalarsContainBridgedAnchorPollution(scalars) {
            return true
        }
        return false
    }

    /// TASK-022 detector helper. Returns true when `scalars` contains
    /// a bridged orphan-mark anchor chain whose final cluster is a
    /// bare orphan-mark anchor (no terminating consonant-asat coda).
    /// The shape is:
    ///
    ///   <U+1021><dep-vowel-run>{ <consonant><U+103A><U+1021><dep-vowel-run> }+
    ///
    /// where the LAST cluster is a bare orphan-mark anchor (not
    /// terminated by a base-consonant + asat coda). A legitimate
    /// multi-syllable pattern terminates EVERY cluster with a base-
    /// consonant + asat coda (e.g. `aungout` → `… 1021 102C 1010
    /// 103A`), so it does not match. The bug shape
    /// `… 1021 102D 102F 101A 103A 1021 102D 102F` (the `aoo` /
    /// `aungoo` orphan-fallback's final dangling cluster) does.
    private static func scalarsContainBridgedAnchorPollution(
        _ scalars: [UInt32]
    ) -> Bool {
        guard scalars.count >= 5 else { return false }

        // Scan helper: starting at `start`, walk a contiguous run of
        // dep-mark scalars. Returns the index just past the run.
        func walkDepRun(from start: Int) -> Int {
            var k = start
            while k < scalars.count {
                let v = scalars[k]
                let isDepMark = (0x102B...0x1032).contains(v)
                    || v == 0x1036
                    || (0x103B...0x103E).contains(v)
                guard isDepMark else { break }
                k += 1
            }
            return k
        }

        // Try every U+1021 anchor as the start of a chain.
        for start in 0..<scalars.count where scalars[start] == 0x1021 {
            var i = start
            // Track whether at least one bridge has been crossed.
            var bridgeCount = 0
            while true {
                // Walk past this cluster's dep-vowel run.
                let depEnd = walkDepRun(from: i + 1)
                guard depEnd > i + 1 else { break } // need >= 1 dep-mark
                // Look for bridge: <consonant><U+103A>.
                guard depEnd + 1 < scalars.count else {
                    // No room for bridge; if we already crossed at
                    // least one bridge, this cluster is a bare
                    // anchor at the end → flag it.
                    if bridgeCount >= 1 { return true }
                    break
                }
                let bridgeBase = scalars[depEnd]
                let isBridgeBase = (bridgeBase >= 0x1000 && bridgeBase <= 0x1021)
                    || bridgeBase == 0x103F
                guard isBridgeBase, scalars[depEnd + 1] == 0x103A else {
                    // Not a bridge. If we've crossed bridges, the
                    // current cluster is the trailing one. A
                    // legitimate trailing cluster ends with a
                    // base-consonant + asat (caught above as a
                    // bridge-shape continuation), so anything else
                    // (e.g. just dep-marks running to end of surface)
                    // is the bug shape.
                    if bridgeCount >= 1 { return true }
                    break
                }
                // Next anchor must be U+1021.
                guard depEnd + 2 < scalars.count, scalars[depEnd + 2] == 0x1021 else {
                    // Bridge but no following anchor → this is the
                    // legitimate `<cluster> + <complete syllable>`
                    // shape. Move on.
                    break
                }
                bridgeCount += 1
                i = depEnd + 2
            }
        }
        return false
    }

    /// TASK-039: drop any candidate whose surface chains two
    /// `<consonant><U+103A>` codas back-to-back attached to a single
    /// anchor with no real intervening base. The shape is:
    ///
    ///   <X>?<C1><U+103A><C2><U+103A>...
    ///
    /// where:
    ///   - `<X>` is empty, U+1021 (orphan-anchor implicit-အ), or any
    ///     independent vowel U+1021..U+102A (a stand-alone-vowel
    ///     anchor like `1027` from `aye+e`).
    ///   - Both `<C1>` and `<C2>` are bare consonant bases (U+1000..
    ///     U+1021 or U+103F) with no dep-vowel, medial, virama, or
    ///     fresh anchor between them.
    ///   - The pattern occurs at the very start of the surface (no
    ///     consonant base precedes `<C1>` other than `<X>`).
    ///
    /// The bug class is the doubled-`e`-rule chain
    /// (`eea`/`een`/`eeing`/...): the `e` rule emits `101A 103A`
    /// (ya-asat) and two consecutive `e`-rule arcs concatenate to
    /// `... 101A 103A 101A 103A ...` with no new base between. The
    /// second coda has no real syllable to close.
    ///
    /// Two-syllable shapes where the second coda has its own
    /// dedicated consonant base (e.g. `let+pet` →
    /// `101C 1000 103A 1015 1000 103A` — the `1015` `p` is the
    /// second syllable's base, not part of a doubled-coda chain) are
    /// untouched: between the two `103A`s the surface contains TWO
    /// consonant scalars (the closing `1000` of `let` and the
    /// opening `1015` of `pet`), which the predicate refuses to
    /// consider a doubled-coda chain.
    internal static func sanitizeDoubledCodaChain(_ candidates: [Candidate]) -> [Candidate] {
        let cleanFiltered = candidates.filter {
            !surfaceContainsDoubledCodaChain($0.surface)
        }
        if !cleanFiltered.isEmpty {
            return cleanFiltered
        }
        return candidates
    }

    /// TASK-052: drop any candidate whose surface contains a `<digit>`
    /// (ASCII U+0030..U+0039 or Myanmar U+1040..U+1049) immediately
    /// followed by U+103A (asat), or by U+1021 then U+103A (the
    /// indirect-via-`အ` orphan-anchor shape). Asat needs a consonant
    /// base on its left to anchor the U+103A scalar — digits never
    /// serve as that base, so both adjacencies are structural
    /// orthography violations. Like the other sanitizers, the filter
    /// only runs when at least one clean candidate exists; otherwise
    /// the panel keeps the violating candidates so the user is not
    /// left without a Myanmar surface to commit.
    internal static func sanitizeDigitOrphanAsat(_ candidates: [Candidate]) -> [Candidate] {
        let cleanFiltered = candidates.filter {
            !surfaceContainsDigitOrphanAsat($0.surface)
        }
        if !cleanFiltered.isEmpty {
            return cleanFiltered
        }
        return candidates
    }

    @_spi(Testing) public static func surfaceContainsDigitOrphanAsat(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        @inline(__always) func isDigit(_ v: UInt32) -> Bool {
            (v >= 0x30 && v <= 0x39) || (v >= 0x1040 && v <= 0x1049)
        }
        if scalars.count >= 2 {
            for i in 1..<scalars.count {
                guard isDigit(scalars[i - 1]) else { continue }
                if scalars[i] == 0x103A { return true }
            }
        }
        if scalars.count >= 3 {
            for i in 2..<scalars.count {
                guard isDigit(scalars[i - 2]) else { continue }
                if scalars[i - 1] == 0x1021 && scalars[i] == 0x103A { return true }
            }
        }
        return false
    }

    /// TASK-056: drop any candidate whose surface contains a run of
    /// contiguous **pure strict-consume** punct scalars (`*` U+002A
    /// or `'` U+0027 only — no `.`/`:` mixed in) sitting between
    /// Myanmar scalars (U+1000–U+109F), where the run satisfies one
    /// of two leak signatures:
    ///
    /// 1. **Run contains `*` (asterisk).** Asterisk is the asat
    ///    marker — its only legitimate semantic role is to be
    ///    consumed into U+103A. If `*` survives as raw ASCII
    ///    between Myanmar with no `.`/`:` neighbour to justify a
    ///    document-punct interpretation, the parser failed. This
    ///    fires for `k**ar` → `က**အာ` (run `**`, both Myanmar
    ///    sides), `kar.*ar` → `ကာ့*အာ` (`.` consumed as tone
    ///    U+1037, leaving `*` directly between Myanmar), and
    ///    `kar:*ar` → `ကား*အာ` (same shape with visarga U+1038).
    /// 2. **Two-or-more contiguous strict-consume chars.** Two
    ///    strict-consume chars can never both fulfil their semantic
    ///    role on a single boundary; the second leaks. This catches
    ///    `''` (doubled apostrophe — `kar''ka` → `ကာ''က`) which
    ///    rule (1) does not, since single `'` between Myanmar is
    ///    silently consumed by the parser as a soft separator and
    ///    never reaches the surface, but `''` doubled does.
    ///
    /// **Mixed-punct runs (containing `.` or `:`) are NOT
    /// filtered** — those are legitimate document punctuation that
    /// `splitAtLastEmbeddedComposingPunct` and
    /// `MidBufferPunctuationSuite` route through verbatim
    /// (`ka..tar` → `က..တာ`, `ka*.tar` → `က*.တာ`,
    /// `ka'.tar` → `က'.တာ`). Doubled `..`/`::` runs without
    /// `*`/`'` are likewise allowed (ellipsis, double-colon).
    /// Trailing or leading `'` is also permitted by design
    /// (`thar'`, `'thar`, `'thar'` — see `ApostropheLiteralSuite`);
    /// the predicate only fires when the punct run sits BETWEEN
    /// two Myanmar scalars, not at the surface boundary.
    ///
    /// Same fallback policy as the other sanitizers: only filter
    /// when at least one clean candidate exists.
    internal static func sanitizeInterleavedComposingPunct(_ candidates: [Candidate]) -> [Candidate] {
        let cleanFiltered = candidates.filter {
            !surfaceContainsInterleavedComposingPunct($0.surface)
        }
        if !cleanFiltered.isEmpty {
            return cleanFiltered
        }
        return candidates
    }

    @_spi(Testing) public static func surfaceContainsInterleavedComposingPunct(_ surface: String) -> Bool {
        // Fast path: most candidate surfaces are pure Myanmar (no
        // `*`/`'`/`:`/`.` scalars at all). A streaming scalar scan
        // bails out without allocating the `scalars` array.
        var sawComposingPunct = false
        for scalar in surface.unicodeScalars {
            let v = scalar.value
            if v == 0x002A || v == 0x0027 || v == 0x003A || v == 0x002E {
                sawComposingPunct = true
                break
            }
        }
        guard sawComposingPunct else { return false }
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 3 else { return false }
        // Myanmar letters / signs / vowel-marks / digits / tone
        // marks. Excludes U+104A (little section ၊) and U+104B
        // (section ။) — those are the Myanmar equivalents of `,`
        // / `.` and act as document punctuation when
        // `burmesePunctuationEnabled` maps `.` → `။` mid-buffer
        // (e.g. `ka*.tar` → `က*။တာ`). Treating them as
        // "Myanmar" would falsely flag the legitimate
        // `<C><*><။><C>` shape as an interleaved leak.
        @inline(__always) func isMyanmar(_ v: UInt32) -> Bool {
            (v >= 0x1000 && v <= 0x109F) && v != 0x104A && v != 0x104B
        }
        @inline(__always) func isAsterisk(_ v: UInt32) -> Bool {
            v == 0x002A
        }
        @inline(__always) func isStrictConsumePunct(_ v: UInt32) -> Bool {
            v == 0x002A || v == 0x0027
        }
        @inline(__always) func isDocPunct(_ v: UInt32) -> Bool {
            v == 0x003A || v == 0x002E
        }
        @inline(__always) func isComposingPunct(_ v: UInt32) -> Bool {
            isStrictConsumePunct(v) || isDocPunct(v)
        }
        // Walk for runs of contiguous composing-punct scalars. A
        // run is a leak when it is PURE strict-consume (no `.`/`:`
        // mixed in — those make the run document-punct) AND either
        // contains `*` (asterisk has no legitimate role outside
        // asat-consumption) OR has ≥2 strict-consume chars (doubled
        // apostrophe). Mixed runs (`*.`, `'.`, `*:`, `'*.`, …) are
        // legitimate document punctuation.
        var i = 0
        while i < scalars.count {
            guard isComposingPunct(scalars[i]) else {
                i += 1
                continue
            }
            var runEnd = i + 1
            var strictConsumeCount = isStrictConsumePunct(scalars[i]) ? 1 : 0
            var asteriskCount = isAsterisk(scalars[i]) ? 1 : 0
            var docPunctCount = isDocPunct(scalars[i]) ? 1 : 0
            while runEnd < scalars.count, isComposingPunct(scalars[runEnd]) {
                if isStrictConsumePunct(scalars[runEnd]) { strictConsumeCount += 1 }
                if isAsterisk(scalars[runEnd]) { asteriskCount += 1 }
                if isDocPunct(scalars[runEnd]) { docPunctCount += 1 }
                runEnd += 1
            }
            // Document-punct presence rescues the run. A `*` next
            // to `.` or `:` is interpreted as part of a literal
            // punct group (markdown emphasis, ellipsis, etc.), not
            // as an orphaned asat marker.
            guard docPunctCount == 0 else {
                i = runEnd
                continue
            }
            // Pure strict-consume run. Leak when it contains `*`
            // (any count) OR has ≥2 chars (doubled `''`).
            guard asteriskCount >= 1 || strictConsumeCount >= 2 else {
                i = runEnd
                continue
            }
            // Check IMMEDIATE adjacency: the scalar directly
            // before the run start AND directly after the run end
            // must be Myanmar (not Myanmar-punctuation U+104A /
            // U+104B, which act as document punctuation just like
            // ASCII `,` / `.`). This prevents false positives on
            // legitimate `<C><*><။><C>` shapes where `*` is part
            // of a literal-punct group with the mapped Myanmar
            // full stop on its right (`ka*.tar` →
            // `က*။တာ` under `burmesePunctuationEnabled`).
            let hasLeftMyanmar = i > 0 && isMyanmar(scalars[i - 1])
            let hasRightMyanmar = runEnd < scalars.count && isMyanmar(scalars[runEnd])
            if hasLeftMyanmar && hasRightMyanmar { return true }
            i = runEnd
        }
        return false
    }

    /// TASK-057: drop any candidate whose surface contains a `<tone>`
    /// marker (U+1037 creaky / U+1038 visarga) immediately followed by
    /// `<U+1021><U+103A>` — the phantom-`အ`-anchor shape produced by
    /// the orphan-mark anchor injector when the user's `*` lands after
    /// a tone-closed vowel rule. The triplet `<tone> 1021 103A` has
    /// no legitimate Burmese spelling: a tone closes the syllable, so
    /// any following `1021 103A` (independent-`အ` + asat) reflects
    /// engine fabrication rather than user-typed content. Mirrors
    /// `sanitizeDigitOrphanAsat` (TASK-052) — same fallback policy:
    /// only filter when at least one clean candidate exists, otherwise
    /// keep violators so the panel is not empty.
    internal static func sanitizeToneOrphanAsat(_ candidates: [Candidate]) -> [Candidate] {
        let cleanFiltered = candidates.filter {
            !surfaceContainsToneOrphanAsat($0.surface)
        }
        if !cleanFiltered.isEmpty {
            return cleanFiltered
        }
        return candidates
    }

    @_spi(Testing) public static func surfaceContainsToneOrphanAsat(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 3 else { return false }
        for i in 2..<scalars.count {
            let preTone = scalars[i - 2]
            guard preTone == 0x1037 || preTone == 0x1038 else { continue }
            if scalars[i - 1] == 0x1021 && scalars[i] == 0x103A {
                return true
            }
        }
        return false
    }

    @_spi(Testing) public static func surfaceContainsDoubledCodaChain(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 4 else { return false }

        @inline(__always) func isConsonantBase(_ v: UInt32) -> Bool {
            return (v >= 0x1000 && v <= 0x1021) || v == 0x103F
        }
        @inline(__always) func isIndependentVowel(_ v: UInt32) -> Bool {
            return v >= 0x1021 && v <= 0x102A
        }

        // TASK-045: generalised forward scan. The previous TASK-039
        // implementation hard-coded three leading-prefix shapes
        // (empty / one indep-vowel / `1021 1031`) and missed every
        // other prefix that can carry a doubled-`e`-rule chain
        // (consonant + dep-vowels, medial-bearing onsets, virama
        // stacks, closed-syllable preludes, mid-buffer occurrences,
        // …). The generalised rule: walk the surface looking for
        // any pair of `<C><103A>` codas back-to-back where the run
        // between the two asats is just one bare consonant base —
        // no dep-vowel, medial, virama, tone mark, or independent-
        // vowel anchor — i.e. the second coda's "anchor" is a
        // phantom syllable rather than a real syllable.
        //
        // For each position `i` where `scalars[i] == 103A` and
        // `scalars[i - 1]` is a consonant base, find the next
        // `103A` at position `j` (the next asat in the surface).
        // The run between is `scalars[i + 1 ..< j]`. Reject when:
        //   - the run contains exactly ONE consonant base, AND
        //   - the run contains no dep-vowel (102B..1032), medial
        //     (103B..103E), tone mark (1036..1038), virama (1039),
        //     or independent-vowel scalar (1021..102A).
        //
        // Single-coda + own real syllable + coda (legit) is
        // preserved by either:
        //   - the second consonant having its own dep-vowel /
        //     medial / tone mark / virama-stack continuation
        //     (`ကျွန်တော်` between asats: `1010 1031 102C` — has
        //     `1031`/`102C` dep-vowels → not flagged), or
        //   - having ≥2 consonant bases between asats (`let+pet`
        //     between asats: `1015 1000` — two consonants → not
        //     flagged), or
        //   - having an independent-vowel anchor (`aye+aye`
        //     between asats: `1021 1031 101A` — `1021` indep-vowel
        //     → not flagged; `ka+aye` similarly).
        var i = 1
        while i < scalars.count {
            guard scalars[i] == 0x103A else { i += 1; continue }
            // First asat must close a real consonant base.
            let preCoda = scalars[i - 1]
            guard isConsonantBase(preCoda) else { i += 1; continue }

            // Scan forward looking for the next `103A` and
            // characterise the run between the two asats.
            var j = i + 1
            var consonantBaseCountBetween = 0
            var sawAttachableMark = false
            var sawFreshAnchor = false
            while j < scalars.count, scalars[j] != 0x103A {
                let v = scalars[j]
                if (v >= 0x1000 && v <= 0x1021) || v == 0x103F {
                    consonantBaseCountBetween += 1
                }
                if isIndependentVowel(v) {
                    sawFreshAnchor = true
                }
                // Dep-vowels, medials, tone marks, virama. Any of
                // these makes the would-be second coda's anchor
                // into a real syllable (vowelled or stacked) rather
                // than a phantom doubled-coda continuation.
                if (v >= 0x102B && v <= 0x1032)
                    || (v >= 0x1036 && v <= 0x1038)
                    || v == 0x1039
                    || (v >= 0x103B && v <= 0x103E) {
                    sawAttachableMark = true
                }
                j += 1
            }
            // Reached the end of the surface without finding a
            // second `103A` — this asat is not part of a chain.
            guard j < scalars.count else { break }

            // Doubled-coda chain when the run between the asats is
            // exactly one consonant base with no dep-vowel,
            // medial, virama, tone mark, or fresh anchor between.
            if consonantBaseCountBetween == 1
                && !sawAttachableMark
                && !sawFreshAnchor {
                return true
            }
            // Otherwise advance from the second asat — pairs may
            // overlap in sequences of three or more codas, and the
            // next `<C><103A>` pair starting at `j` deserves its
            // own check.
            i = j
        }
        return false
    }

    @_spi(Testing) public static func surfaceHasIndepVowelVirama(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 2 else { return false }
        for i in 0..<(scalars.count - 1) {
            let v = scalars[i]
            if v >= 0x1021 && v <= 0x102A && scalars[i + 1] == 0x1039 {
                return true
            }
        }
        return false
    }

    /// ZWSP is allowed as a lexicon word-boundary marker. ZWNJ/ZWJ are only
    /// tolerated for the parser's leading orphan-mark fallback; elsewhere in
    /// a lexicon surface they are corpus pollution and should not outrank a
    /// clean candidate.
    internal static func isPollutedFormatControlSurface(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            guard scalar.value == 0x200C || scalar.value == 0x200D else { continue }
            if index == 0, scalars.count >= 2 {
                let next = scalars[1].value
                if next >= 0x102B && next <= 0x103E { continue }
            }
            return true
        }
        return false
    }

    /// Structural guard for lexicon surfaces polluted by a non-Myanmar
    /// leading scalar. A polluted row (ellipsis-prefixed
    /// `…ကျွန်တော်`, BOM-bearing `ကျွန်﻿တော်`, Shan/Myanmar digit +
    /// combining mark like `႐ု`) rides forward from a stale SQLite
    /// even after the corpus_builder filter lands, so we drop it at
    /// the engine too. ZWNJ / ZWJ are allowed as leading scalars since
    /// some legitimate orthographic clusters start with them.
    ///
    /// The filter requires at least one Myanmar-block scalar elsewhere
    /// in the surface so pure-ASCII test fixtures (used to exercise
    /// ranking behaviour with symbolic placeholder surfaces like
    /// `HIGH` / `LOW`) are not mistaken for pollution
    /// (task 05 belt-and-suspenders).
    internal static func isLeadingNonMyanmarScalar(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        guard let first = scalars.first else { return false }
        let hasMyanmar = scalars.contains {
            $0.value >= 0x1000 && $0.value <= 0x109F
        }
        guard hasMyanmar else { return false }
        for scalar in scalars where scalar.value == 0xFEFF {
            return true
        }
        if first.value == 0x200C || first.value == 0x200D {
            return false
        }
        if first.value < 0x1000 || first.value > 0x109F {
            return true
        }
        let isDigit = (first.value >= 0x1040 && first.value <= 0x1049)
            || (first.value >= 0x1090 && first.value <= 0x1099)
        if isDigit, scalars.count >= 2 {
            let second = scalars[1].value
            if second >= 0x102B && second <= 0x103E {
                return true
            }
        }
        return false
    }

    /// Pali loanwords whose canonical orthography is a virama-stacked
    /// cluster (`<C>န္<C>` / `<C>ဒ္<C>`) but whose grammar parse leaves
    /// the unstacked or anusvara fallback on top when no lexicon entry
    /// covers the reading. `padma` in particular needs a cross-class
    /// `ဒ္မ` stack that `Grammar.isValidStack` rejects on principle,
    /// so the parser cannot synthesise it on its own.
    ///
    /// Sourced as data so adding a Pali loanword is a one-line change
    /// to this table — no logic edit needed. The medium-term plan is
    /// to relocate this to a curated TSV under `Data/` and have the
    /// engine load it at init (see `tasks/05-pali-cross-class-stack-override-is-a-three-entry-hardcode.md`);
    /// the table here keeps the public API stable in the meantime.
    @_spi(Testing) public static let paliStackOverrides: [String: String] = [
        "ganda":   "\u{1002}\u{1014}\u{1039}\u{1012}",          // ဂန္ဒ
        "padma":   "\u{1015}\u{1012}\u{1039}\u{1019}",          // ပဒ္မ
        "vandana": "\u{1017}\u{1014}\u{1039}\u{1012}\u{1014}",  // ဗန္ဒန
        // TASK-046: buffer-leading `ah<C>` Pali-stack words. The
        // grammar parser produces both an h-medial form (`အမှဒ`) and
        // a stacked form, but only the stacked form (`အဟ္မ<…>`) is
        // the canonical orthography for these Arabic-origin
        // loanwords. The override pins the top-rank to the stacked
        // surface so the user does not have to navigate past the
        // h-medial sibling.
        "ahmada":  "\u{1021}\u{101F}\u{1039}\u{1019}\u{1012}",            // အဟ္မဒ
        "ahmat":   "\u{1021}\u{101F}\u{1039}\u{1019}\u{1010}\u{103A}",    // အဟ္မတ်
    ]

    internal static func paliStackOverrideSurface(for normalized: String) -> String? {
        paliStackOverrides[normalized]
    }

    /// Bare onsetless vowels whose DP+LM pick lands on a coda-cluster
    /// parse (`ည်` for `i`) or a repeated-asat / stacked-indep-vowel
    /// decomposition (`ယ်ယ်ယ်` for `eee`, `ဦဦ` for `uu`) instead of
    /// the independent-vowel form a typist reaches for.
    ///
    /// Two patterns trigger the override:
    ///
    /// 1. The single-letter `i` rule needs the short-i shape `အိ` —
    ///    the parser rule `i` → `ီ` (long-i) would produce `အီ` via
    ///    orphan-ZWNJ promotion; the short-i sibling is injected
    ///    here.
    /// 2. A bare vowel letter (`a`, `e`, `i`, `o`, `u`) repeated
    ///    N times (N ≥ 2). The parser materialises each letter as
    ///    its own syllable (`eee` → `ယ်ယ်ယ်`, `uu` → `ဦဦ`); the
    ///    canonical *single*-vowel form is what the user is reaching
    ///    for when mashing the same key. The repeated decomposition
    ///    stays reachable as a lower-ranked sibling.
    ///
    /// The single-letter `aaa…` collapses to inherent `အ` already, so
    /// the table below maps `a*` → `အ` for symmetry. `ay`, `oo`,
    /// `u2`, etc. are handled by other rules and are intentionally
    /// not entered here.
    private static let canonicalRepeatedBareVowel: [Character: String] = [
        "a": "\u{1021}",            // အ
        "e": "\u{1021}\u{102E}",    // အီ
        "i": "\u{1024}",            // ဤ
        "o": "\u{1029}",            // ဩ
        "u": "\u{1021}\u{1030}",    // အူ
    ]

    @_spi(Testing) public static func bareVowelOverrideSurface(for normalized: String) -> String? {
        if normalized == "i" { return "\u{1021}\u{102D}" } // အိ
        guard let first = normalized.first,
              normalized.count >= 2,
              normalized.allSatisfy({ $0 == first })
        else {
            return nil
        }
        return canonicalRepeatedBareVowel[first]
    }

    /// Task 04: scalar prefix of the `ai` diphthong (`ိုင်`,
    /// U+102D U+102F U+1004 U+103A). When the buffer starts with
    /// `ai` directly followed by `ng`, the parser's no-bias DP ties
    /// `ai + ng` (diphthong + bare nga) with `ain + g` (short-i +
    /// na-asat + bare ga). LM frequency in the corpus may prefer
    /// either, but the canonical Burmese reading users mean by
    /// typing `aing<…>` is the diphthong-anchored one.
    private static let aiDiphthongScalars: [UInt32] = [0x102D, 0x102F, 0x1004, 0x103A]

    /// True when `normalized` begins with `aing` and the next char
    /// is a letter (i.e. the `ng` is forming a bare nga onset for a
    /// following syllable). `ai`, `ai.`, `ai:`, `aing` alone, and
    /// `ain<X≠g>` shapes do not trigger the override — those reach
    /// the diphthong via the existing parser path.
    internal static func aiDiphthongOverrideApplies(to normalized: String) -> Bool {
        let chars = Array(normalized)
        guard chars.count >= 4 else { return false }
        return chars[0] == "a"
            && chars[1] == "i"
            && chars[2] == "n"
            && chars[3] == "g"
    }

    /// True when the candidate surface starts with the `ai` diphthong
    /// scalar sequence (allowing a leading independent vowel `အ`
    /// or invisible base ZWNJ).
    internal static func candidateLeadsWithAiDiphthong(_ surface: String) -> Bool {
        let scalars = surface.unicodeScalars.map(\.value)
        for offset in 0...min(1, scalars.count) {
            guard scalars.count >= offset + aiDiphthongScalars.count else { continue }
            if Array(scalars[offset..<offset + aiDiphthongScalars.count]) == aiDiphthongScalars {
                return true
            }
        }
        return false
    }

    /// Build a sibling parse where the leading ZWNJ orphan has been
    /// replaced with U+1021 (အ, the independent "a" onset). Returns nil
    /// when `parse.output` is not a ZWNJ + combining-mark orphan. See
    /// `Grammar.swift` module doc for the orphan-ZWNJ rationale. The
    /// sibling inherits the original ranking signals, but recomputes
    /// structural legality from the promoted surface so it can pass the
    /// same acceptable-parse gates as parser-native legal output.
    @_spi(Testing) public static func promoteOrphanZwnjToImplicitA(_ parse: SyllableParse) -> SyllableParse? {
        let scalars = Array(parse.output.unicodeScalars)
        guard scalars.count >= 2, scalars[0].value == 0x200C else { return nil }
        let mark = scalars[1].value
        guard mark >= 0x102B && mark <= 0x103E else { return nil }
        var replaced = scalars
        replaced[0] = Unicode.Scalar(0x1021)!
        var scalarView = String.UnicodeScalarView()
        scalarView.append(contentsOf: replaced)
        let output = String(scalarView)
        let legalityScore = SyllableParser.scanOutputLegality(output)
            ? max(parse.legalityScore, 1)
            : 0
        // ZWNJ → U+1021 is a 1-for-1 scalar replacement, so arc-boundary
        // scalar offsets are unchanged.
        return SyllableParse(
            output: output,
            reading: parse.reading,
            aliasCost: parse.aliasCost,
            legalityScore: legalityScore,
            score: parse.score,
            structureCost: parse.structureCost,
            syllableCount: max(1, parse.syllableCount),
            rarityPenalty: parse.rarityPenalty,
            arcBoundaries: parse.arcBoundaries
        )
    }

    /// Build a sibling parse where every mid-surface orphan attachable
    /// mark (dependent vowel / tone mark / medial with no consonant
    /// base behind it) has U+1021 (အ) inserted before it to provide an
    /// anchor. Mirrors `promoteOrphanZwnjToImplicitA` for the mid-
    /// surface case covered by task 01 — inputs like `aungain` whose
    /// second vowel sits after a coda-asat with no onset to anchor it.
    ///
    /// Returns nil when the parse has no orphan marks, or when the
    /// rebuilt surface still fails `scanOutputLegality`. Leading-ZWNJ
    /// orphans stay with `promoteOrphanZwnjToImplicitA`.
    internal static func promoteOrphanInternalMarks(_ parse: SyllableParse) -> SyllableParse? {
        let scalars = Array(parse.output.unicodeScalars)
        guard scalars.count >= 2 else { return nil }
        if scalars[0].value == 0x200C { return nil }

        let orphanPositions = orphanAttachableMarkIndices(in: scalars)
        guard !orphanPositions.isEmpty else { return nil }

        // TASK-057: refuse to anchor an orphan asat whose immediate
        // predecessor scalar is a tone marker (U+1037 creaky / U+1038
        // visarga). The tone closes the syllable; injecting a U+1021
        // between the tone and the asat fabricates a phantom `အ` base
        // for an asat the user typed redundantly after the tone
        // closure (`kar:.*`, `kar.:*`, `o:.*`). The legality scan
        // would accept the rebuilt `<tone> 1021 103A` shape because
        // `1021` is in `isConsonantBase`'s range, but the user did
        // NOT type any `a` letter — the `1021` is an engine
        // fabrication. Drop the rebuild so the engine falls through
        // to the literal-fallback or a cleaner sibling.
        for pos in orphanPositions {
            guard scalars[pos].value == 0x103A else { continue }
            guard pos >= 1 else { continue }
            let prev = scalars[pos - 1].value
            if prev == 0x1037 || prev == 0x1038 {
                return nil
            }
        }

        // TASK-022: collapse contiguous orphan-mark scalars into a
        // single anchor per cluster, but split clusters whenever a
        // same-category dep-vowel reappears (since `scanOutputLegality`
        // rejects same-category dep-vowel stacks on a single base —
        // see `attachableMarkHasAnchor` in this file and the parser's
        // `Finalization.scanOutputLegality`). The earlier per-scalar
        // injection produced multi-anchor patterns like
        // `1021 102D 1021 102F 1021 102D 1021 102F` (four anchors
        // for two semantic syllables); the per-cluster scheme below
        // produces `1021 102D 102F 1021 102D 102F` (two anchors for
        // two `o`-rule clusters) — one anchor per cluster, with
        // each cluster legally stacked under its anchor.
        let sortedPositions = orphanPositions.sorted()
        var clusterStarts: [Int] = []
        var previousPos: Int? = nil
        var seenCategoriesInCluster: Set<Int> = []
        for pos in sortedPositions {
            let currentCategory = orphanScalarCategory(scalars[pos])
            let isContiguous = previousPos.map { pos == $0 + 1 } ?? false
            let alreadySeenCategory = currentCategory != 0
                && seenCategoriesInCluster.contains(currentCategory)
            let startNewCluster = !isContiguous || alreadySeenCategory
            if startNewCluster {
                clusterStarts.append(pos)
                seenCategoriesInCluster.removeAll()
            }
            if currentCategory != 0 {
                seenCategoriesInCluster.insert(currentCategory)
            }
            previousPos = pos
        }

        var rebuilt: [Unicode.Scalar] = []
        rebuilt.reserveCapacity(scalars.count + clusterStarts.count)
        let insertSet = Set(clusterStarts)
        for i in scalars.indices {
            if insertSet.contains(i) {
                rebuilt.append(Unicode.Scalar(0x1021)!)
            }
            rebuilt.append(scalars[i])
        }
        let output = String(String.UnicodeScalarView(rebuilt))
        guard SyllableParser.scanOutputLegality(output) else { return nil }
        // Each cluster-start insertion shifts boundaries that sit
        // STRICTLY after that scalar offset by +1. A boundary at
        // exactly the insertion position keeps its scalar offset —
        // semantically the inserted U+1021 anchor belongs to the arc
        // whose orphan mark it is anchoring, so the boundary preceding
        // it stays where it is. The boundary's `charEnd` is unchanged.
        let sortedInsertPositions = clusterStarts.sorted()
        let adjustedBoundaries = parse.arcBoundaries.map { boundary -> SyllableParse.ArcBoundary in
            let inserted = sortedInsertPositions.lazy
                .filter { $0 < boundary.scalarOffset }
                .count
            return SyllableParse.ArcBoundary(
                charEnd: boundary.charEnd,
                scalarOffset: boundary.scalarOffset + inserted
            )
        }
        return SyllableParse(
            output: output,
            reading: parse.reading,
            aliasCost: parse.aliasCost,
            legalityScore: max(parse.legalityScore, 1),
            score: parse.score,
            structureCost: parse.structureCost,
            syllableCount: max(1, parse.syllableCount),
            rarityPenalty: parse.rarityPenalty,
            arcBoundaries: adjustedBoundaries
        )
    }


    private static func orphanAttachableMarkIndices(in scalars: [Unicode.Scalar]) -> [Int] {
        var result: [Int] = []
        for i in scalars.indices {
            let v = scalars[i].value
            if !isAttachableMarkValue(v) { continue }
            if !attachableMarkHasAnchor(scalars: scalars, at: i) {
                result.append(i)
            }
        }
        return result
    }

    private static func isAttachableMarkValue(_ v: UInt32) -> Bool {
        (v >= 0x102B && v <= 0x1032)
            || (v >= 0x1036 && v <= 0x1038)
            || (v >= 0x103B && v <= 0x103E)
    }

    private static func attachableMarkHasAnchor(scalars: [Unicode.Scalar], at i: Int) -> Bool {
        let current = scalars[i].value
        let currentIsToneMark = current >= 0x1036 && current <= 0x1038
        let currentIsMedial = current >= 0x103B && current <= 0x103E
        let currentCategory = depVowelCategory(current)
        var j = i - 1
        while j >= 0 {
            let w = scalars[j].value
            if (w >= 0x1000 && w <= 0x1021) || w == 0x103F { return true }
            let wIsIndependentVowel = w >= 0x1023 && w <= 0x102A
            if currentIsToneMark, wIsIndependentVowel { return true }
            if w == 0x103A {
                if currentIsToneMark { j -= 1; continue }
                return false
            }
            if w == 0x200C { return j == 0 }
            if wIsIndependentVowel { return false }
            // TASK-038: Unicode TUS storage order requires medials
            // to sit between the consonant base and any dep-vowel
            // / tone mark. Crossing one during the backward walk
            // means the medial is misplaced.
            if currentIsMedial, (w >= 0x102B && w <= 0x1032) {
                return false
            }
            if currentIsMedial, (w >= 0x1036 && w <= 0x1038) {
                return false
            }
            if w == 0x1039 {
                if j + 1 < scalars.count {
                    let next = scalars[j + 1].value
                    if (next >= 0x1000 && next <= 0x1021) || next == 0x103F {
                        j -= 1
                        continue
                    }
                }
                return false
            }
            // Mirrors the parser's scanOutputLegality (task 01):
            // U+1031 (e-kar) must be the first dep-vowel scalar on
            // its base; closing tone markers (1037 creaky / 1038
            // visarga) end the syllable; same-category dep-vowels
            // never stack.
            if current == 0x1031, w >= 0x102B, w <= 0x1032, w != 0x1031 {
                return false
            }
            if w == 0x1037 || w == 0x1038 {
                return false
            }
            if current == 0x1031 && w == 0x1031 { return false }
            let wCategory = depVowelCategory(w)
            if currentCategory != 0,
               wCategory == currentCategory,
               w >= 0x102B, w <= 0x1032 {
                return false
            }
            // Cross-category dep-vowel allow-list (TASK-028). Mirrors
            // `Parser/Finalization.swift::scanOutputLegality` so the
            // orphan-mark detector treats illegal cross-category
            // chains as unanchored — feeding them to the per-cluster
            // anchor injector. TASK-053: the only legal cross-
            // category walks on a single anchor are the `o`-cluster
            // (`102D 102F`) and the `1031 102B/102C` aw-family. Every
            // other cross-category walk including the `1031 + non-aa`
            // class must reject so the orphan-mark injector breaks
            // the cluster apart with a fresh `1021` anchor.
            if currentCategory != 0,
               wCategory != 0,
               wCategory != currentCategory {
                let isOClusterUpstream = (w == 0x102D && current == 0x102F)
                let isAungUpstream = (w == 0x1031 && currentCategory == 1)
                if !(isOClusterUpstream || isAungUpstream) {
                    return false
                }
            }
            if isAttachableMarkValue(w) { j -= 1; continue }
            return false
        }
        return false
    }

    /// Categorise the scalar at a per-cluster orphan-injection
    /// candidate position. Reuses `depVowelCategory` for dep-vowel
    /// scalars; non-dep-vowel scalars (medials, asat, tone marks)
    /// return 0 so they don't trigger same-category cluster splits.
    @inline(__always)
    private static func orphanScalarCategory(_ scalar: Unicode.Scalar) -> Int {
        depVowelCategory(scalar.value)
    }

    @inline(__always)
    private static func depVowelCategory(_ v: UInt32) -> Int {
        switch v {
        case 0x102B, 0x102C: return 1
        case 0x102D, 0x102E: return 2
        case 0x102F, 0x1030: return 3
        case 0x1031:        return 4
        case 0x1032:        return 5
        default:            return 0
        }
    }
}
