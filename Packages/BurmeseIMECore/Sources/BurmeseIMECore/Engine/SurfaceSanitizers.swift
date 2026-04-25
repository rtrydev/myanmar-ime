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

    internal static func bareVowelOverrideSurface(for normalized: String) -> String? {
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
        return SyllableParse(
            output: output,
            reading: parse.reading,
            aliasCost: parse.aliasCost,
            legalityScore: legalityScore,
            score: parse.score,
            structureCost: parse.structureCost,
            syllableCount: max(1, parse.syllableCount),
            rarityPenalty: parse.rarityPenalty
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

        var rebuilt: [Unicode.Scalar] = []
        rebuilt.reserveCapacity(scalars.count + orphanPositions.count)
        let insertSet = Set(orphanPositions)
        for i in scalars.indices {
            if insertSet.contains(i) {
                rebuilt.append(Unicode.Scalar(0x1021)!)
            }
            rebuilt.append(scalars[i])
        }
        let output = String(String.UnicodeScalarView(rebuilt))
        guard SyllableParser.scanOutputLegality(output) else { return nil }
        return SyllableParse(
            output: output,
            reading: parse.reading,
            aliasCost: parse.aliasCost,
            legalityScore: max(parse.legalityScore, 1),
            score: parse.score,
            structureCost: parse.structureCost,
            syllableCount: max(1, parse.syllableCount),
            rarityPenalty: parse.rarityPenalty
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
            if current == 0x1031 && w == 0x1031 { return false }
            if isAttachableMarkValue(w) { j -= 1; continue }
            return false
        }
        return false
    }
}
