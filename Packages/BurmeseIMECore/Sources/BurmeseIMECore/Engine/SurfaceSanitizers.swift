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
                    // TASK-087: when the aa's base consonant is the LOWER
                    // of a plain Pali virama stack (`<C> 1039 <C>`), the
                    // aa shape is lexical, not structural — the stacked
                    // pair already descends, so MLC convention picks the
                    // shape per word: `သိက္ခာ`, `ရိက္ခာ`, `ဥပေက္ခာ`,
                    // `စန္ဒာ`, `နန္ဒာ` keep round ာ while `သဒ္ဓါ`,
                    // `မဂ္ဂါ…` keep the tall hook (a full-store scan
                    // finds 153 stack-lower sites whose curated shape
                    // contradicts the structural prediction). Treat the
                    // shape as authored: store surfaces pass through
                    // verbatim and parser outputs keep the typed shape.
                    //
                    // Kinzi is also virama-preceded (`103A 1039 <C>`)
                    // but stays under the structural rule: tall is the
                    // only attested form for kinzi+ဂ+aa (`အင်္ဂါ`,
                    // `ဘင်္ဂါလီ`) and the parser's own top-1 for kinzi
                    // buffers carries round aa — this rewrite is what
                    // produces the correct kinzi rendering.
                    if j >= 1, scalars[j - 1].value == 0x1039,
                       !(j >= 2 && scalars[j - 2].value == 0x103A) {
                        break
                    }
                    // `Grammar.requiresTallAa` is the orthographic source
                    // of truth for plain onsets (and kinzi bases): the
                    // descender consonants ခ ဂ င ဒ ပ ဝ take tall ါ,
                    // everything else takes round ာ.
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

    /// TASK-081: `preservedSurfaces` carries lexicon-/history-attested
    /// surfaces whose reading matches the user's typed buffer (exact
    /// alias or compose key). Burmese has a closed set of lexicalized
    /// irregular spellings (`ယောက်ျား`, `ကျွန်ုပ်`, …) that the
    /// structural legality scan correctly rejects as *generative*
    /// shapes but that are the standard dictionary orthography — the
    /// scan must not outvote curated lexicon data on exact-reading
    /// input. Preserved surfaces are exempt from dropping; they do
    /// not count toward `hasClean`, so the all-illegal escape hatch
    /// (return everything unchanged) is unaffected.
    internal static func sanitizeMalformedMyanmarMarks(
        _ candidates: [Candidate],
        preservedSurfaces: Set<String> = []
    ) -> [Candidate] {
        let hasClean = candidates.contains {
            SyllableParser.scanOutputLegality($0.surface)
        }
        guard hasClean else { return candidates }
        return candidates.filter {
            preservedSurfaces.contains($0.surface)
                || SyllableParser.scanOutputLegality($0.surface)
        }
    }

    /// TASK-081 follow-up: narrow encoding-validity scan for
    /// lexicon-/history-attested surfaces. The attested-surface
    /// exemption (`preservedSurfaces` above) exists for *lexicalized
    /// irregular* spellings — shapes a syllable grammar never
    /// generates but that are standard dictionary orthography
    /// (`ယောက်ျား`, `ကျွန်ုပ်`, `ရှ်`-coda loanwords). The shipped
    /// corpus also carries a residue of *encoding-broken* rows
    /// (segmentation/typo artifacts), and exempting those resurfaces
    /// them on exact-reading input (`tang+` → `တင္`, `.ka` → `့က`,
    /// `myi.u:` → `မျိူး`, `aykya:` → `ေကြး`). Four shapes are
    /// flagged, each a hard Unicode-storage-order violation rather
    /// than a grammar irregularity:
    ///   1. surface-initial dependent/combining mark (no base to
    ///      attach to);
    ///   2. dangling U+1039 virama (surface-final, or not followed
    ///      by a stackable base consonant);
    ///   3. U+1031 e-vowel not preceded by a base consonant,
    ///      independent vowel, or medial (storage order places 1031
    ///      after the consonant cluster it renders before);
    ///   4. the `102D 1030` dependent-vowel collision (ိ + ူ), a
    ///      typo cluster for the only legal cross-category chain
    ///      `102D 102F` (ို).
    /// Surfaces passing these checks may still fail the structural
    /// legality scan — that is exactly the lexicalized-irregular
    /// class the exemption protects. Keep this scan narrow: it must
    /// never grow into a second grammar. The durable fix is
    /// corpus_builder-side filtering plus regeneration; this engine
    /// gate keeps the malformed residue out of the panel until then.
    @_spi(Testing) public static func isEncodingInvalidSurface(_ surface: String) -> Bool {
        let scalars = surface.unicodeScalars.map(\.value)
        guard let first = scalars.first else { return false }
        if isMyanmarDependentMarkScalar(first) { return true }
        for (i, value) in scalars.enumerated() {
            switch value {
            case 0x1039:
                // Virama must be followed by a stackable base.
                guard i + 1 < scalars.count,
                      (0x1000...0x1021).contains(scalars[i + 1])
                        || scalars[i + 1] == 0x103F
                else { return true }
            case 0x1031:
                // e-vowel storage order: must follow a base consonant,
                // independent vowel, great-sa, or medial.
                guard i >= 1,
                      (0x1000...0x102A).contains(scalars[i - 1])
                        || scalars[i - 1] == 0x103F
                        || (0x103B...0x103E).contains(scalars[i - 1])
                else { return true }
            case 0x1030:
                if i >= 1, scalars[i - 1] == 0x102D { return true }
            default:
                break
            }
        }
        return false
    }

    /// Myanmar dependent marks that cannot open a surface: dependent
    /// vowel signs (102B–1032), anusvara/dot-below/visarga (1036–1038),
    /// asat (103A), virama (1039), and the medials (103B–103E).
    @inline(__always)
    private static func isMyanmarDependentMarkScalar(_ value: UInt32) -> Bool {
        (0x102B...0x1032).contains(value)
            || (0x1036...0x103A).contains(value)
            || (0x103B...0x103E).contains(value)
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
    internal static func sanitizeAdjacentIndependentVowels(
        _ candidates: [Candidate],
        preservedSurfaces: Set<String> = []
    ) -> [Candidate] {
        // First pass: drop everything flagged by the full invariant
        // (TASK-015 + TASK-022 + TASK-037). When at least one clean
        // sibling exists, the panel surfaces only clean candidates.
        // TASK-052: surfaces in `preservedSurfaces` (typically the
        // user-respecting strict-stack outputs from the explicit-`+`
        // promotion path) are exempt from the filter — when the user
        // typed an explicit `+` between two bare-vowel rules
        // (`a+i` → `1021 1021 102E`), the resulting adjacent
        // independent-vowel scalars are intentional, not a parser
        // bug shape.
        let cleanFiltered = candidates.filter {
            preservedSurfaces.contains($0.surface)
                || !surfaceViolatesIndependentVowelInvariant($0.surface)
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
            preservedSurfaces.contains($0.surface)
                || !surfaceContainsAdjacentIndepVowels($0.surface)
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

    /// TASK-060: detect the `<dep-mark><U+1021><single dep-mark>
    /// <end-or-non-dep-mark>` shape — the engine-fabricated phantom
    /// anchor between dep-vowel clusters. The bug arises when a
    /// user types a non-standalone vowel rule (`u`, `i`, `e`, `aw`,
    /// …) after a syllable whose dep-vowel cluster is already
    /// anchored on its own consonant base — e.g. `kou` composes as
    /// `1000 102D 102F` (prefix `ko`) plus the promoted tail
    /// `1021 1030` (standalone `အူ`), which concatenates to
    /// `1000 102D 102F 1021 1030` (`ကိုအူ`) — the visible bug.
    ///
    /// Discriminator vs. legitimate shapes:
    ///   * Legitimate `marar` → `1019 102C 1021 102C` — `1021` is
    ///     preceded by `102C` (single dep-mark of the prior
    ///     syllable). predecessor's predecessor is `1019`
    ///     (consonant base), so the prior syllable is fully formed
    ///     before this fresh `1021` syllable. NOT flagged.
    ///   * Legitimate two-cluster (TASK-022) `kayoo` →
    ///     `1000 1031 1021 102D 102F 1021 102D 102F` — each `1021`
    ///     is followed by a multi-scalar dep-mark cluster. NOT
    ///     flagged.
    ///   * Bug shape `kou` → `1000 102D 102F 1021 1030` — `1021`
    ///     preceded by `102F`, whose own predecessor `102D` is a
    ///     dep-mark, AND followed by single-scalar dep-mark `1030`
    ///     terminating the surface. Flagged.
    @_spi(Testing) public static func surfaceContainsPhantomMidAnchor(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 3 else { return false }
        // Dep-mark categories for the predicate. Dep-vowels and the
        // anusvara `1036` participate in the syllable's vowel
        // cluster after the consonant onset; medials `103B..103E`
        // are part of the consonant onset cluster, not a dep-vowel
        // of a separate syllable. The predOfPred check below uses
        // the narrower dep-vowel range to distinguish "predecessor
        // is the second dep-vowel of the prior syllable" (bug case
        // `kou` → `1000 102D 102F 1021 1030`) from "predecessor is
        // the first dep-vowel of a medial-bearing syllable"
        // (legitimate `kyaa+Aa` → `1000 103C 102C 1021 102C`).
        @inline(__always)
        func isDepMarkAny(_ v: UInt32) -> Bool {
            (v >= 0x102B && v <= 0x1032)
                || v == 0x1036
                || (v >= 0x103B && v <= 0x103E)
        }
        @inline(__always)
        func isDepVowelOrTone(_ v: UInt32) -> Bool {
            (v >= 0x102B && v <= 0x1032) || v == 0x1036
        }
        for i in 1..<(scalars.count - 1) {
            guard scalars[i] == 0x1021 else { continue }
            let prev = scalars[i - 1]
            let next = scalars[i + 1]
            guard isDepMarkAny(prev) && isDepMarkAny(next) else { continue }
            guard i >= 2 else { continue }
            let predOfPred = scalars[i - 2]
            // Only flag when the prior syllable already has a dep-
            // vowel before the predecessor — i.e. predecessor is
            // the second-or-later dep-vowel of its syllable, the
            // signature of the o-cluster + orphan-u bug shape.
            guard isDepVowelOrTone(predOfPred) else { continue }
            if i + 2 >= scalars.count {
                return true
            }
            let nextNext = scalars[i + 2]
            if !isDepMarkAny(nextNext) {
                return true
            }
        }
        return false
    }

    /// TASK-060 sanitizer: drop candidates whose surface carries the
    /// phantom-mid-anchor shape detected by
    /// `surfaceContainsPhantomMidAnchor`. Like the other anchor
    /// sanitizers, the filter only fires when at least one
    /// non-flagged sibling exists in the panel.
    internal static func sanitizePhantomMidAnchor(_ candidates: [Candidate]) -> [Candidate] {
        let cleanFiltered = candidates.filter {
            !surfaceContainsPhantomMidAnchor($0.surface)
        }
        if !cleanFiltered.isEmpty && cleanFiltered.count != candidates.count {
            return cleanFiltered
        }
        return candidates
    }

    /// TASK-060: cheap surface check used to gate the full-buffer
    /// reparse injection. Returns true when `surface` contains a
    /// `<dep-mark><U+1021><dep-mark>` adjacency anywhere — including
    /// the legitimate ya-asat-closer + 1021 form
    /// (`...103A 1021 1030`). The full-buffer reparse only runs when
    /// at least one panel candidate carries this signature, since
    /// only those buffers need the clean ya-asat-closer + U+1026
    /// sibling injected. Keeps the parse-on-every-keystroke cost off
    /// the garbage-input fast path.
    internal static func candidateSurfaceCarriesOrphanAnchorAfterCluster(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 3 else { return false }
        for i in 1..<(scalars.count - 1) {
            guard scalars[i] == 0x1021 else { continue }
            let prev = scalars[i - 1]
            let next = scalars[i + 1]
            let prevIsDepMark = (prev >= 0x102B && prev <= 0x1032)
                || prev == 0x1036
                || (prev >= 0x103A && prev <= 0x103E)
            let nextIsDepMark = (next >= 0x102B && next <= 0x1032)
                || next == 0x1036
                || (next >= 0x103B && next <= 0x103E)
            if prevIsDepMark && nextIsDepMark {
                return true
            }
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
    ///   <X>?<C1><U+103A><U+101A><U+103A>...
    ///
    /// where:
    ///   - `<X>` is empty, U+1021 (orphan-anchor implicit-အ), or any
    ///     independent vowel U+1021..U+102A (a stand-alone-vowel
    ///     anchor like `1027` from `aye+e`).
    ///   - `<C1>` is a bare consonant base (U+1000..U+1021 or
    ///     U+103F) and the lone consonant between the two asats is
    ///     ya (U+101A), with no dep-vowel, medial, virama, or fresh
    ///     anchor between them.
    ///
    /// The bug class is the doubled-`e`-rule chain
    /// (`eea`/`een`/`eeing`/...): the `e` rule emits `101A 103A`
    /// (ya-asat) and two consecutive `e`-rule arcs concatenate to
    /// `... 101A 103A 101A 103A ...` with no new base between. The
    /// second coda has no real syllable to close. The `e` rule is the
    /// only rule that emits a coda without an explicit coda key, so
    /// the lone in-between consonant of every fabricated chain is ya
    /// — TASK-085 narrows the predicate accordingly so the legitimate
    /// loanword bare-consonant codas (`ဘတ်စ်`, `ဗိုင်းရပ်စ်`,
    /// `ဝက်ဘ်ဆိုက်`, …) stop being flagged.
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

    /// TASK-051: True when `surface` contains a `<digit>` (ASCII
    /// U+0030..U+0039 or Myanmar U+1040..U+1049) immediately followed
    /// by an attachable mark that semantically requires a consonant
    /// base on its left:
    /// - dep-vowels and e-kar (U+102B..U+1032),
    /// - anusvara (U+1036),
    /// - asat (U+103A) — same shape as
    ///   `surfaceContainsDigitOrphanAsat`,
    /// - medials (U+103B..U+103E).
    ///
    /// Per Unicode TUS storage order each of these must immediately
    /// follow a consonant base (with the optional kinzi triple or
    /// virama-stacked upper). Digits are never a consonant base, so
    /// every adjacency in this set is structurally illegal —
    /// CLAUDE.md §3 codifies this as "a digit never anchors asat or
    /// dependent marks".
    ///
    /// This predicate is the broader sibling of
    /// `surfaceContainsDigitOrphanAsat`. It is used both as a
    /// post-splice repair gate (to inject a U+1021 anchor on the
    /// right of the digit) and as a sanitizer guard (to drop any
    /// surviving violators when a clean sibling exists). The narrower
    /// `surfaceContainsDigitOrphanAsat` is preserved unchanged for
    /// the existing `<digit>1021 103A` indirect-anchor shape that
    /// only fires for asat.
    @_spi(Testing) public static func surfaceContainsDigitOrphanAttachableMark(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 2 else { return false }
        @inline(__always) func isDigit(_ v: UInt32) -> Bool {
            (v >= 0x30 && v <= 0x39) || (v >= 0x1040 && v <= 0x1049)
        }
        @inline(__always) func isAttachableMark(_ v: UInt32) -> Bool {
            (v >= 0x102B && v <= 0x1032)
                || v == 0x1036
                || v == 0x103A
                || (v >= 0x103B && v <= 0x103E)
        }
        for i in 1..<scalars.count {
            guard isDigit(scalars[i - 1]) else { continue }
            if isAttachableMark(scalars[i]) { return true }
        }
        return false
    }

    /// TASK-051: repair a digit-orphan-mark adjacency by injecting a
    /// `U+1021` independent-vowel anchor between the digit and the
    /// orphan'd attachable mark. Mirrors the per-cluster anchor
    /// injection that `promoteOrphanInternalMarks` already performs
    /// for parse-internal orphans, but operates on a finished
    /// candidate surface (post-digit-splice) where the parse-internal
    /// fix-up has already run.
    ///
    /// Each contiguous run of attachable marks immediately after a
    /// digit gets a single `U+1021` anchor inserted at its start —
    /// the same shape the engine already produces for `kar2aung` /
    /// `tar2aing`. Returns `nil` when no repair is needed (no
    /// digit-orphan-mark adjacency in the surface).
    internal static func injectAnchorAfterDigitForOrphanMarks(_ surface: String) -> String? {
        let scalars = Array(surface.unicodeScalars)
        guard scalars.count >= 2 else { return nil }
        @inline(__always) func isDigit(_ v: UInt32) -> Bool {
            (v >= 0x30 && v <= 0x39) || (v >= 0x1040 && v <= 0x1049)
        }
        @inline(__always) func isAttachableMark(_ v: UInt32) -> Bool {
            (v >= 0x102B && v <= 0x1032)
                || v == 0x1036
                || v == 0x103A
                || (v >= 0x103B && v <= 0x103E)
        }
        var rebuilt: [Unicode.Scalar] = []
        rebuilt.reserveCapacity(scalars.count + 2)
        var anyInjection = false
        var i = 0
        while i < scalars.count {
            rebuilt.append(scalars[i])
            // After a digit, if the next scalar is an attachable mark
            // that needs a consonant base on its left, inject a
            // U+1021 anchor. Subsequent marks in the same cluster
            // attach to the newly-injected anchor.
            if isDigit(scalars[i].value),
               i + 1 < scalars.count,
               isAttachableMark(scalars[i + 1].value) {
                rebuilt.append(Unicode.Scalar(0x1021)!)
                anyInjection = true
            }
            i += 1
        }
        guard anyInjection else { return nil }
        return String(String.UnicodeScalarView(rebuilt))
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
        // Need at least 2 scalars: a Myanmar prefix + a composing
        // punct scalar. Trailing-`*` shapes like `ka<*>` (`1000
        // 002A`) are length 2 and DO leak. The earlier `>= 3`
        // gate excluded them; lowered now that the trailing-`*`
        // adjacency check (`runEnd >= scalars.count`) handles the
        // 2-scalar case explicitly (TASK-040).
        guard scalars.count >= 2 else { return false }
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
        @inline(__always) func isMyanmarToneScalar(_ v: UInt32) -> Bool {
            v == 0x1037 || v == 0x1038
        }
        // Walk for runs of contiguous composing-punct scalars. A
        // run is a leak when:
        //
        //   1. PURE strict-consume run (`*`, `'`, no `.`/`:` mixed
        //      in) AND either contains `*` (asterisk has no
        //      legitimate role outside asat-consumption) OR has
        //      ≥2 strict-consume chars (doubled `''`).
        //
        //   2. MIXED run containing `*` (TASK-040): the `*` mixes
        //      with `.` / `:` to produce shapes like `.*`, `:*`,
        //      `*.`, `*:` — these are NOT legitimate document
        //      punctuation in Burmese and represent the parser's
        //      failure to consume the user's intended asat marker
        //      next to a tone marker. The original predicate
        //      rescued these via `docPunctCount > 0`; the rescue
        //      is now restricted to runs that contain ZERO `*`.
        //
        // Adjacency:
        //   - Left side: must be Myanmar (the run leaks INTO
        //     existing Burmese content). Trailing `*` after a
        //     consonant base (`ka<*>` at surface end) qualifies.
        //   - Right side: must be Myanmar OR the run must trail
        //     into end-of-surface AND contain `*` (TASK-040
        //     trailing-`*` case, e.g. `ka:*` → `ကး*` ends in
        //     ASCII `*` with no right-side Myanmar).
        //   - SPECIAL trailing-doc-punct case (TASK-040): a run
        //     of pure doc-punct (`.` / `:`, no `*`/`'`) with NO
        //     right-side Myanmar AND immediately preceded by a
        //     Myanmar TONE scalar (1037 / 1038) is a leak —
        //     the user typed two tone keys in a row, the engine
        //     consumed the first as the syllable's tone and
        //     stranded the second as raw ASCII.
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
            let hasLeftMyanmar = i > 0 && isMyanmar(scalars[i - 1])
            let hasRightMyanmar = runEnd < scalars.count && isMyanmar(scalars[runEnd])
            // Document-punct rescue: legitimate document-punct
            // shapes pass through. The rescue admits any run with
            // doc-punct (`.` / `:`) — those are markdown-style
            // emphasis, ellipsis, double-colon, etc. The TASK-056
            // intent (mid-buffer leaks) is preserved for runs
            // without doc-punct. TASK-040 narrows the rescue with
            // a single targeted exception:
            //
            //   - Pure doc-punct (no `*`/`'`) trailing immediately
            //     after a Myanmar TONE scalar (1037 / 1038) with
            //     no right-side Myanmar is a leak: the user typed
            //     two tone keys in a row, the parser consumed the
            //     first as the syllable's tone and stranded the
            //     second as raw ASCII (`kar:.` → `ကား.` ends in
            //     `1038 002E`). Document-punct after a tone-closed
            //     syllable is structurally ambiguous, but the
            //     trailing position with no following Burmese
            //     content disambiguates it as a stranded
            //     keystroke.
            if docPunctCount > 0 {
                let leftIsTone = i > 0 && isMyanmarToneScalar(scalars[i - 1])
                if leftIsTone && !hasRightMyanmar {
                    // Trailing run after a Myanmar tone scalar
                    // with no right-side Burmese content is a
                    // stranded-keystroke leak: TASK-040 covers
                    // both pure doc-punct (`kar:.` → `ကား.`) and
                    // mixed doc-punct + `*` (`kar:.*` →
                    // `ကား.*`, `kar..*` → `ကာ့.*`) at this site.
                    return true
                }
                // TASK-055: tone-orphaned-punct leak — the user typed
                // `<C><open-vowel><punct1><punct2><C><V>`, the parser
                // peeled `<punct1>` onto the prior syllable as
                // `1037`/`1038` tone, and the surviving `<punct2>`
                // ended up between the tone scalar and the next
                // Myanmar onset. The original predicate only flagged
                // pure-strict runs of ≥2 chars or any run with `*`;
                // a single `.` / `:` after a tone scalar fell below
                // those thresholds. The tone-predecessor is the
                // discriminator that distinguishes this bug from the
                // legitimate `<C>(a)<punct><punct><C><V>` literal-
                // flush shape pinned by `MidBufferPunctuationSuite`
                // (where the LHS is tone-INELIGIBLE bare-`<C>a` so
                // no tone absorption fires and the predecessor is
                // a bare consonant, not a tone scalar).
                if leftIsTone && hasRightMyanmar {
                    return true
                }
                // Mixed run containing `*` trailing after Myanmar
                // (consonant base or anything Myanmar) with no
                // right-side Myanmar: the `*` is a stranded
                // unconsumed-asat marker. Catches `ka:*` →
                // `က:*` (`1000 003A 002A`), `ka.*` → `က.*`
                // (`1000 002E 002A`) — the rank-1+ literal-punct
                // interpretations that surface after the
                // tone-consumed surface gets dropped by the
                // earlier branch.
                if asteriskCount > 0 && hasLeftMyanmar && !hasRightMyanmar {
                    return true
                }
                i = runEnd
                continue
            }
            // TASK-055: tone-orphaned strict-consume leak — symmetric
            // to the doc-punct branch above. When the surviving
            // punct after tone absorption is `'` (e.g. `thar.'kar`
            // → `သာ့'ကာ`, `kar:'kar` → `ကား'ကာ`), the run is a
            // single strict-consume char with no `*`, which would
            // otherwise be dropped by the threshold guard below.
            // The tone-predecessor + Myanmar-onset adjacency is
            // again the bug discriminator.
            if i > 0 && isMyanmarToneScalar(scalars[i - 1]) && hasRightMyanmar {
                return true
            }
            // Strict-consume / mixed-with-`*` run. Leak when it
            // contains `*` (any count) OR has ≥2 strict-consume
            // chars (doubled `''`).
            guard asteriskCount >= 1 || strictConsumeCount >= 2 else {
                i = runEnd
                continue
            }
            // Adjacency check.
            //   - Bounded both sides by Myanmar: classic
            //     interleaved leak (`ka*.tar` style).
            //   - Trailing `*` (no right-side content) bounded
            //     left by Myanmar: trailing-leak case
            //     (`ka:*` → `ကး*`, `kar*` rejected via this path
            //     too — but `kar*` parses cleanly with `103A`
            //     and the surface contains no raw `002A`, so
            //     the predicate doesn't even enter this branch
            //     for cleanly-consumed `*`).
            //   - Carve-out: when right side is Myanmar
            //     punctuation (U+104A / U+104B mapped doc-punct),
            //     don't flag — that's a legitimate
            //     `<C><*><။><C>` shape under
            //     `burmesePunctuationEnabled`.
            if hasLeftMyanmar && hasRightMyanmar { return true }
            if asteriskCount >= 1 && hasLeftMyanmar && runEnd >= scalars.count {
                return true
            }
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

    /// TASK-069 sanitizer: drop candidates whose surface carries the
    /// bare `1021 103A` adjacency — independent vowel `အ` (U+1021)
    /// immediately followed by asat (U+103A) — where the `1021` is
    /// NOT preceded by a digit (covered by `sanitizeDigitOrphanAsat`,
    /// TASK-052) and NOT preceded by a tone marker (covered by
    /// `sanitizeToneOrphanAsat`, TASK-057).
    ///
    /// Burmese rule reference: asat suppresses the inherent vowel of
    /// a true consonant. The independent vowel `အ` is structurally a
    /// placeholder consonant whose only role is to host dep-vowel
    /// marks; suppressing its inherent vowel via asat leaves no
    /// pronounceable syllable. The legality scan in
    /// `Parser/Finalization.swift::scanOutputLegality` accepts the
    /// shape because `isConsonantBase` admits U+1021 (the upper bound
    /// of the consonant range is inclusive at U+1021 for orphan-
    /// anchor injection purposes). This sanitizer closes the gap.
    ///
    /// Sibling shapes `e*`/`i*`/`o*`/`u*` route to legal forms with
    /// real coda consonants (ya-asat / nya-asat) or particle variants
    /// — those surfaces have `<C>` between the `1021` and `103A`
    /// (e.g. `e*` → `1021 101A 103A`), so the adjacency check does
    /// not flag them.
    ///
    /// Same fallback policy as the other orphan-asat sanitizers:
    /// only filter when at least one clean candidate exists,
    /// otherwise keep violators so the panel is not empty.
    internal static func sanitizeBareIndepVowelAsat(_ candidates: [Candidate]) -> [Candidate] {
        let cleanFiltered = candidates.filter {
            !surfaceContainsBareIndepVowelAsat($0.surface)
        }
        if !cleanFiltered.isEmpty {
            return cleanFiltered
        }
        return candidates
    }

    /// TASK-067 sanitizer: drop candidates whose surface carries the
    /// triple-virama-stack signature — three or more consonants joined
    /// by two or more viramas in a row (`<C> 1039 <C> 1039 <C>`).
    /// Burmese caps virama stacks at two consonants; the chained shape
    /// has no orthographic interpretation and is rejected by the
    /// parser's own `SyllableParser.scanOutputLegality` predicate.
    ///
    /// The chained-stack surface reaches the post-affix candidate set
    /// only via the windowed-glue path for long uniform `<C>+<C>+...`
    /// chains (N ≥ 10, buffer length crosses `compositionWindowSize`).
    /// In that path the frozen-prefix surface and the active-tail
    /// surface each pass the parser's legality scan in isolation, but
    /// their seam materialises a chained-virama-stack. The merged-
    /// stage `sanitizeMalformedMyanmarMarks` sees no clean sibling
    /// (every Myanmar candidate at the windowed length shares the
    /// shape) so the "preserve when no clean sibling exists" fallback
    /// keeps the illegal candidates. Once the literal fallback is
    /// injected post-`updateInternal` the panel has a clean ASCII
    /// sibling, and this targeted filter can drop the chained-virama
    /// surfaces.
    ///
    /// Scoped to the triple-stack signature (rather than the full
    /// `scanOutputLegality` predicate) so unrelated mid-typing
    /// orphan-mark shapes (`thueiooz` and similar — incremental
    /// typing of a long sentence where the next keystroke resolves
    /// the orphan) stay reachable, preserving the existing
    /// `UncoveredVowelChainShapeSuite::midTypingPrefixes_doNotForce
    /// LiteralAtRank0` invariant.
    ///
    /// Same fallback policy as the other orphan sanitizers: only
    /// filter when at least one clean candidate exists, otherwise
    /// keep violators so the panel is not empty.
    internal static func sanitizeTripleViramaStack(_ candidates: [Candidate]) -> [Candidate] {
        let cleanFiltered = candidates.filter {
            !surfaceContainsTripleViramaStack($0.surface)
        }
        if !cleanFiltered.isEmpty {
            return cleanFiltered
        }
        return candidates
    }

    @_spi(Testing) public static func surfaceContainsTripleViramaStack(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 5 else { return false }
        @inline(__always) func isConsonantBase(_ v: UInt32) -> Bool {
            return (v >= 0x1000 && v <= 0x1021) || v == 0x103F
        }
        for i in 0..<(scalars.count - 4) {
            // `<C> 1039 <C> 1039 <C>` — three consonants joined by
            // two viramas. The parser's `scanOutputLegality`
            // triple-stack guard (Parser/Finalization.swift:431-436)
            // uses the same shape.
            guard scalars[i + 1] == 0x1039,
                  scalars[i + 3] == 0x1039,
                  isConsonantBase(scalars[i]),
                  isConsonantBase(scalars[i + 2]),
                  isConsonantBase(scalars[i + 4])
            else { continue }
            return true
        }
        return false
    }

    @_spi(Testing) public static func surfaceContainsBareIndepVowelAsat(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 2 else { return false }
        @inline(__always) func isDigit(_ v: UInt32) -> Bool {
            (v >= 0x30 && v <= 0x39) || (v >= 0x1040 && v <= 0x1049)
        }
        for i in 1..<scalars.count {
            guard scalars[i - 1] == 0x1021 && scalars[i] == 0x103A else {
                continue
            }
            // Defer to the TASK-052 / TASK-057 sanitizers for the
            // digit-prefixed and tone-prefixed cases. Their own
            // predicates cover those shapes; preserving the
            // disjoint responsibility keeps each sanitizer's
            // semantics scoped to its own surface shape.
            if i >= 2 {
                let pre = scalars[i - 2]
                if isDigit(pre) { continue }
                if pre == 0x1037 || pre == 0x1038 { continue }
            }
            return true
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
        // between the two asats is just one bare YA (U+101A) — no
        // dep-vowel, medial, virama, tone mark, or independent-
        // vowel anchor — i.e. the second coda's "anchor" is a
        // phantom ya-asat continuation rather than a real syllable.
        //
        // For each position `i` where `scalars[i] == 103A` and
        // `scalars[i - 1]` is a consonant base, find the next
        // `103A` at position `j` (the next asat in the surface).
        // The run between is `scalars[i + 1 ..< j]`. Reject when:
        //   - the run contains exactly ONE consonant base, AND
        //   - that base is ya (U+101A), AND
        //   - the run contains no dep-vowel (102B..1032), medial
        //     (103B..103E), tone mark (1036..1038), virama (1039),
        //     or independent-vowel scalar (1021..102A).
        //
        // TASK-085: the ya restriction matters. The `e` rule is the
        // only rule that emits a coda without an explicit coda key,
        // and it always emits ya-asat (`101A 103A`) — so every
        // doubled-coda chain the bug class can fabricate has ya as
        // the lone in-between consonant. A lone NON-ya consonant
        // between two asats is the standard loanword orthography
        // for foreign consonant clusters and acronym letters
        // (`ဘတ်စ်` bus, `ဗိုင်းရပ်စ်` virus, `ဝက်ဘ်ဆိုက်` website,
        // `အက်စ်` the letter S — 453 shipped lexicon entries carry
        // the `<C>်<C>်` shape, none of them `<C>်ယ်`). Flagging
        // those collapsed entire buffers to a literal-only panel
        // once the literal fallback counted as the clean sibling.
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
            var loneConsonantBetween: UInt32 = 0
            var sawAttachableMark = false
            var sawFreshAnchor = false
            while j < scalars.count, scalars[j] != 0x103A {
                let v = scalars[j]
                if (v >= 0x1000 && v <= 0x1021) || v == 0x103F {
                    consonantBaseCountBetween += 1
                    loneConsonantBetween = v
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
            // exactly one bare ya (U+101A) with no dep-vowel,
            // medial, virama, tone mark, or fresh anchor between.
            // Non-ya lone consonants are the legitimate loanword
            // bare-consonant coda shape (TASK-085).
            if consonantBaseCountBetween == 1
                && loneConsonantBetween == 0x101A
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

    /// TASK-030 dep-vowel category index — kept at file scope so the
    /// inner walk in the predicate below doesn't need a nested
    /// `@inline(__always)` closure (function-scope closures cannot be
    /// reliably inlined under `-O` and the whole point of this file
    /// is to make the predicate cheap on the hot `plus_chain_30`
    /// path).
    @inline(__always) internal static func task030DepVowelCategory(_ v: UInt32) -> Int {
        switch v {
        case 0x102B, 0x102C: return 1   // aa family
        case 0x102D, 0x102E: return 2   // i family
        case 0x102F, 0x1030: return 3   // u family
        case 0x1031:         return 4   // e family
        case 0x1032:         return 5   // ai family
        default:             return 0
        }
    }

    @inline(__always) internal static func task030IsBase(_ v: UInt32) -> Bool {
        if v == 0x103F { return true }
        if (0x1000...0x1021).contains(v) { return true }
        if (0x1023...0x102A).contains(v) { return true }
        return false
    }

    /// TASK-030: detect a single anchor (consonant base or independent
    /// vowel) carrying either:
    ///   (a) two distinct dep-vowel clusters back-to-back without a
    ///       fresh base / virama / asat between them, or
    ///   (b) a same-category dep-vowel duplicate within a single base
    ///       run.
    ///
    /// This is the engine-level analogue of the parser's
    /// `Parser/Finalization::scanOutputLegality` rejection: the parser
    /// already refuses these shapes for its own DP, but production
    /// ranking can promote violators from deeper buckets when the LM
    /// has evidence for them.
    ///
    /// The legal multi-scalar dep-vowel cluster shapes are the
    /// o-cluster (`102D 102F`, categories {2,3}) and the leading-`1031`
    /// aung-order (`1031 102B|102C`, categories {4,1}). After a complete
    /// cluster closes, ANY further dep-vowel scalar means a second
    /// cluster on the same anchor — which never appears in attested
    /// Burmese orthography.
    ///
    /// **Hot-path note.** Iterates `surface.unicodeScalars` directly
    /// (no `Array` allocation). Bails out instantly when the surface
    /// contains zero dep-vowel scalars in the U+102B..U+1032 range, so
    /// non-matching `plus_chain_30` candidates pay only one scan.
    @_spi(Testing) public static func surfaceContainsMultiClusterOnSingleAnchor(_ surface: String) -> Bool {
        // Cheap pre-scan: a multi-cluster shape requires at least two
        // dep-vowel scalars in the surface. Walk once; if we see <2
        // (or any are same-category) we may early-exit.
        let scalars = surface.unicodeScalars
        var depVowelCount = 0
        for scalar in scalars {
            let v = scalar.value
            if v >= 0x102B && v <= 0x1032 {
                depVowelCount += 1
                if depVowelCount >= 2 { break }
            }
        }
        if depVowelCount < 2 { return false }

        // Per-anchor walk. `clusterCats` is a fixed 5-slot bitset
        // (categories 1..5) — no allocation, no closure.
        var clusterBitset: UInt8 = 0
        var clusterCount: Int = 0
        var firstScalar: UInt32 = 0
        var afterClusterClosed = false
        for scalar in scalars {
            let v = scalar.value
            // Most scalars are outside the syllable-structure zone
            // (e.g. ASCII passthrough, format controls, lexicon
            // codepoints above U+103F). Reject early.
            if v < 0x1000 || v > 0x103F {
                continue
            }
            if Self.task030IsBase(v) {
                clusterBitset = 0
                clusterCount = 0
                firstScalar = 0
                afterClusterClosed = false
                continue
            }
            if v == 0x103A || v == 0x1039 {
                clusterBitset = 0
                clusterCount = 0
                firstScalar = 0
                afterClusterClosed = false
                continue
            }
            if v >= 0x103B && v <= 0x103E { continue } // medials
            if v == 0x1036 || v == 0x1037 || v == 0x1038 { continue } // tones / anusvara
            let cat = Self.task030DepVowelCategory(v)
            if cat == 0 { continue }
            if afterClusterClosed { return true }
            let bit = UInt8(1) << cat
            if (clusterBitset & bit) != 0 { return true } // same-cat duplicate
            clusterBitset |= bit
            clusterCount += 1
            if clusterCount == 1 {
                firstScalar = v
                // TASK-034: tighten the legal-cluster-extension check
                // to the EXACT canonical scalar pairs, not category-
                // level pairs. Only `102D` (the canonical i-family
                // first scalar of the o-cluster) may legally extend
                // into u-family; the long-i `102E` closes the cluster
                // immediately. Likewise only `1031` (the e-kar) may
                // legally extend into aa-family. Pre-fix the check
                // used `cat == 2` and `cat == 4` which admitted
                // non-canonical pairs like `102E 1030`, `102E 102F`,
                // `102D 1030` — none of which is attested Burmese
                // orthography.
                if v != 0x102D && v != 0x1031 {
                    afterClusterClosed = true
                }
            } else if clusterCount == 2 {
                // TASK-034: same tightening at the second-scalar
                // check — require exact canonical pairs:
                //   o-cluster:    `102D 102F`
                //   aung-order:   `1031 102B|102C`
                // All other two-scalar combinations are violators.
                let isOCluster = firstScalar == 0x102D && v == 0x102F
                let isAungOrder = firstScalar == 0x1031
                    && (v == 0x102B || v == 0x102C)
                if isOCluster || isAungOrder {
                    afterClusterClosed = true
                } else {
                    // Cross-category 2-cluster that isn't one of the
                    // two legal multi-scalar shapes — already a single-
                    // cluster cross-category violator (TASK-028) or a
                    // non-canonical i+u / e+non-aa pairing (TASK-034).
                    return true
                }
            }
        }
        return false
    }

    /// TASK-030: tighter predicate — true when the surface carries the
    /// multi-cluster shape AND the surface as a whole sits on a single
    /// anchor (one base, no internal asat/virama/second-base). This is
    /// the bug-class signature: short user-typed buffers like `kayoo`,
    /// `kayii`, `iuu`, `uua` whose entire (unique) syllable happens to
    /// be the violator, with no multi-syllable structure that could
    /// resolve as the user keeps typing.
    ///
    /// Distinguishes:
    /// - `kayoo` violator `1000 1031 102D 102F 102D 102F` — 1 base,
    ///   single-anchor, BUG CLASS.
    /// - `thueiooz` violator `101E 1030 101A 103A 102E 102D 102F …
    ///   1007` — 3 bases, multi-anchor, MID-TYPING (a longer sentence
    ///   prefix where the next keystroke can resolve the orphan
    ///   sub-cluster).
    ///
    /// Used at the Class A literal-promotion gate so the literal goes
    /// to rank 0 only when no future keystroke can rehabilitate the
    /// surface (the buffer represents one typed unit, not a sentence
    /// fragment).
    @_spi(Testing) public static func surfaceIsWhollyMultiClusterOnSingleAnchor(_ surface: String) -> Bool {
        // Pre-fix: only fired when the entire surface sat on a single
        // anchor (`baseCount <= 1`, no internal asat/virama).
        //
        // TASK-034 extension: also fire when the FIRST anchor's open
        // cluster runs into a fresh base WITHOUT an asat/virama
        // closure between them (the `<C>oun`/`<C>iu` family —
        // `1021 102D 102F 1030 1014` for `oun`, where the first
        // anchor `1021` carries an illegal multi-cluster
        // `102D 102F 1030` and then `1014` starts a fresh base
        // without proper closure). Such shapes are "wholly bug-class"
        // because no future keystroke can rehabilitate a syllable
        // whose dep-vowel cluster has already escaped past one base.
        //
        // The discriminator vs. legitimate mid-typing prefixes
        // (`thueiooz`-shape long sentence intermediates): in those
        // cases the multi-cluster sits in an ORPHAN sub-cluster
        // AFTER an asat/virama closure (the prior syllable has
        // already closed; the orphan-mark sub-cluster will be
        // resolved when the user types more letters). The walk
        // tracks "have we seen an asat/virama so far?" — when the
        // first multi-cluster violation triggers, fire only if no
        // asat/virama has been seen yet in the prior scan.
        let scalars = surface.unicodeScalars
        var baseCount = 0
        for scalar in scalars {
            let v = scalar.value
            if Self.task030IsBase(v) {
                baseCount += 1
                if baseCount > 1 { break }
            }
        }
        if baseCount == 0 { return false }
        if baseCount == 1 {
            // No internal break possible; defer to the broader predicate.
            return surfaceContainsMultiClusterOnSingleAnchor(surface)
        }
        // baseCount >= 2: replicate the broader predicate's per-
        // anchor walk, but this time bail out at the FIRST violation
        // and check whether an asat/virama has already been seen.
        // Pre-asat violations are bug-class (the first anchor's
        // cluster ran into a fresh base without closure); post-asat
        // violations are mid-typing orphan residue that the next
        // keystroke can resolve.
        var clusterBitset: UInt8 = 0
        var clusterCount: Int = 0
        var firstScalar: UInt32 = 0
        var afterClusterClosed = false
        var sawAsatOrVirama = false
        for scalar in scalars {
            let v = scalar.value
            if v < 0x1000 || v > 0x103F { continue }
            if Self.task030IsBase(v) {
                clusterBitset = 0
                clusterCount = 0
                firstScalar = 0
                afterClusterClosed = false
                continue
            }
            if v == 0x103A || v == 0x1039 {
                clusterBitset = 0
                clusterCount = 0
                firstScalar = 0
                afterClusterClosed = false
                sawAsatOrVirama = true
                continue
            }
            if v >= 0x103B && v <= 0x103E { continue }
            if v == 0x1036 || v == 0x1037 || v == 0x1038 { continue }
            let cat = Self.task030DepVowelCategory(v)
            if cat == 0 { continue }
            if afterClusterClosed {
                // Multi-cluster violation. Fire only if no
                // asat/virama has closed a syllable so far in the
                // surface.
                return !sawAsatOrVirama
            }
            let bit = UInt8(1) << cat
            if (clusterBitset & bit) != 0 {
                return !sawAsatOrVirama
            }
            clusterBitset |= bit
            clusterCount += 1
            if clusterCount == 1 {
                firstScalar = v
                if v != 0x102D && v != 0x1031 {
                    afterClusterClosed = true
                }
            } else if clusterCount == 2 {
                let isOCluster = firstScalar == 0x102D && v == 0x102F
                let isAungOrder = firstScalar == 0x1031
                    && (v == 0x102B || v == 0x102C)
                if isOCluster || isAungOrder {
                    afterClusterClosed = true
                } else {
                    return !sawAsatOrVirama
                }
            }
        }
        return false
    }

    /// TASK-030 sanitizer: drop candidates whose surface carries the
    /// multi-cluster-on-single-anchor shape. Same fallback policy as
    /// the other sanitizers: only filter when at least one clean
    /// sibling exists, otherwise keep the violator so the panel is
    /// not empty.
    internal static func sanitizeMultiClusterOnSingleAnchor(_ candidates: [Candidate]) -> [Candidate] {
        // Fast pre-check: skip the full filter pass if no candidate
        // carries the violator shape. The hot `plus_chain_30` path
        // produces zero violators per keystroke, so paying only one
        // walk per candidate (and zero allocations when none match)
        // keeps the per-keystroke budget within the perf gate.
        var anyViolator = false
        for candidate in candidates {
            if surfaceContainsMultiClusterOnSingleAnchor(candidate.surface) {
                anyViolator = true
                break
            }
        }
        if !anyViolator { return candidates }
        let cleanFiltered = candidates.filter {
            !surfaceContainsMultiClusterOnSingleAnchor($0.surface)
        }
        if !cleanFiltered.isEmpty {
            return cleanFiltered
        }
        return candidates
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
    /// Synthesize alias-variant parses by swapping every syllable-onset
    /// `ယ` (U+101A) in `parse.output` to `ရ` (U+101B). The bumped
    /// `aliasCost` makes the variant lose composite-score ties to the
    /// canonical parse so the canonical surface stays at rank 0
    /// unless the LM strongly prefers the swapped reading.
    ///
    /// Reasoning: the lexicon already carries `y` ↔ `r` aliases for
    /// every compound it stores (`hsayar` -> ဆရာ), but compounds the
    /// lexicon does not hold (`နှာရေ`, `ပန်ရေ`, `လွန်ရေ`, …) come
    /// straight from the parser's canonical romanization, which has no
    /// notion of the homophony. Surface-level synthesis closes that
    /// gap without re-parsing the alias-rewritten buffer (which would
    /// inject competing interpretations that shift medial selection,
    /// Pali-stack inference, and anchor monotonicity on unrelated
    /// buffers).
    ///
    /// Only ya -> ra runs: `r` is the canonical romanization for ရ
    /// so a user who typed `r` is already asking for ra at that
    /// position and the canonical parse already covers it. The
    /// `arcBoundaries` are inherited verbatim — the swap is a 1-for-1
    /// scalar replacement at known syllable starts. Returns one
    /// variant per swappable onset (does not enumerate the
    /// combinatorial cross-product when multiple syllables are
    /// eligible); the panel reachability rule only requires the
    /// intended surface be reachable.
    internal static func bareYaAsRaSurfaceVariants(of parse: SyllableParse) -> [SyllableParse] {
        guard parse.arcBoundaries.count > 1 else { return [] }
        let scalars = Array(parse.output.unicodeScalars)
        let readingChars = Array(parse.reading)
        let yaScalar: UInt32 = 0x101A
        let raScalar: UInt32 = 0x101B
        var variants: [SyllableParse] = []
        for boundaryIndex in 0..<(parse.arcBoundaries.count - 1) {
            let startScalar = parse.arcBoundaries[boundaryIndex].scalarOffset
            guard startScalar < scalars.count,
                  scalars[startScalar].value == yaScalar else { continue }
            // Only swap syllables whose reading onset is literally
            // `y` — that's the user's typing intent the alias targets.
            // The parser also emits `ya` scalars as the prefix of the
            // `e` vowel ending (`ယ်`), but those scalars are syllable
            // codas, not onsets; the arc-boundary scalar offset there
            // happens to land on the `ya` scalar only when the
            // syllable has no real onset consonant (`e` vowel after a
            // standalone tone / asat). Restricting to a leading `y`
            // in the reading keeps the swap aligned with the user's
            // intent.
            let readingStart = parse.arcBoundaries[boundaryIndex].charEnd
            guard readingStart < readingChars.count,
                  readingChars[readingStart] == "y" else { continue }
            // Skip the swap when the user typed an explicit `+` right
            // before this syllable's onset. The `+` is a hard
            // boundary that pins the consonant the user typed
            // (CLAUDE.md §6) — `k+ya` is unambiguously ka + ya, and
            // the alias variant would otherwise outrank the
            // user-intended surface under a vocabulary-bearing LM
            // that happens to weight `ka + ra` higher.
            if readingStart > 0,
               readingStart - 1 < readingChars.count,
               readingChars[readingStart - 1] == "+" {
                continue
            }
            var replaced = scalars
            replaced[startScalar] = Unicode.Scalar(raScalar)!
            var scalarView = String.UnicodeScalarView()
            scalarView.append(contentsOf: replaced)
            let output = String(scalarView)
            variants.append(SyllableParse(
                output: output,
                reading: parse.reading,
                aliasCost: parse.aliasCost + 1,
                legalityScore: parse.legalityScore,
                score: parse.score,
                structureCost: parse.structureCost,
                syllableCount: parse.syllableCount,
                rarityPenalty: parse.rarityPenalty,
                arcBoundaries: parse.arcBoundaries
            ))
        }
        return variants
    }

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
        // TASK-047: refuse to anchor an orphan dep-vowel whose
        // immediate predecessor is a virama (U+1039) when the parse
        // reading contains `+`. The user typed an explicit `+`
        // between two syllables, so a `<C> 1039 <dep-vowel>`
        // pattern in the materialised surface is the parser's
        // mis-interpretation of the user's `+` as a virama-stack
        // marker (rather than a soft syllable boundary). Inserting
        // U+1021 between the virama and the dep-vowel produces a
        // structurally weird `<C> 1039 1021 <dep-vowel>` shape that
        // promotes the wrong parse (k_+_aung → `က္အောင်`) over the
        // user-respecting two-syllable form (`ကအောင်`) the
        // soft-boundary path materialises. Suppress the rebuild
        // whenever a `+` appears in the reading; the parser's
        // soft-`+` parse is the canonical sibling to keep at top.
        let readingContainsPlus = parse.reading.contains("+")
        if readingContainsPlus {
            for pos in orphanPositions {
                guard pos >= 1 else { continue }
                let prev = scalars[pos - 1].value
                if prev == 0x1039 {
                    return nil
                }
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
