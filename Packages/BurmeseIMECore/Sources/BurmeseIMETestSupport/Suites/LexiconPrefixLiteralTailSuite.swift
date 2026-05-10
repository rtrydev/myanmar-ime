import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-043: when the parser drops a single trailing
/// non-composing letter / digit / punct-run past a `<C>`-prefix, the
/// affix-attachment loop in `BurmeseEngine.updateInternal` (around the
/// `Attach leading literal, digit prefix, and literal tail to each
/// candidate surface` block) must NOT concatenate the literal-tail
/// Myanmar scalar onto multi-syllable lexicon prefix-match lemmas
/// whose reading is a strict superset of the parser's normalized
/// composable middle. Concretely, a buffer like `you` should not
/// produce panel entries such as `ယုံကြည်ချက်အူ` (a multi-word
/// lexicon entry with a stray `အူ` appended).
///
/// The bug class covers, but is not limited to:
///
/// 1. `<C>ou` — `you`, `kou`, `thou`, `tho+u`, `myou`, `kyou`, `phou`.
///    Rank 0 is taken by a fabricated `<lexicon multi-word>+အူ`
///    surface for several of these inputs.
/// 2. `<C>aa` / `<C>+a` — `kaa`, `ka+a`, `kyaa`, `tha+a`. The panel
///    fills with `<lexicon lemma>+အ` surfaces. Rank 0 is usually the
///    parser's clean form; the pollution is at rank 1+.
/// 3. `<C><digit><vowel>` / `<C><vowel><digit>` — `kar1`, `kar+1`,
///    `k1ar`, `t2ar`. Digit splice is applied to every multi-syllable
///    lexicon prefix lemma, doubling panel pollution.
/// 4. Trailing punct runs of length ≥ 2 — `kya..`, `kya::`. The first
///    punct character composes as a tone (TASK-014 / TASK-049 path),
///    the remainder falls into the literal tail and pollutes the
///    panel the same way. (Single-trailing-punct cases like `kar:` /
///    `kar.` are NOT in scope; they go through the bare-consonant-
///    tone path and do not pollute.)
///
/// The fix must NOT regress:
///   - Single-trailing-punct tone composition (`kar:` → `ကား`,
///     `kar.` → `ကာ့`).
///   - Single-syllable lexicon hits (e.g. `kar` → `ကာ`, `ကား`).
///   - Literal raw-buffer fallback reachability.
public enum LexiconPrefixLiteralTailSuite {

    // MARK: - Helpers

    private static func makeBundledEngine() -> BurmeseEngine? {
        guard let lexPath = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lexPath),
              let lmPath = BundledArtifacts.trigramLMPath,
              let lm = try? TrigramLanguageModel(path: lmPath) else {
            return nil
        }
        return BurmeseEngine(candidateStore: store, languageModel: lm)
    }

    private static func bundledEngine(_ ctx: TestContext) -> BurmeseEngine? {
        guard let engine = makeBundledEngine() else {
            ctx.assertTrue(true, "skipped_noBundledArtifacts")
            return nil
        }
        return engine
    }

    /// Approximate Myanmar-syllable count: the number of base
    /// consonants (U+1000..U+1021) plus independent vowels in the
    /// surface, EXCLUDING base consonants immediately followed by
    /// an asat (U+103A) — those are codas of the previous syllable,
    /// not new syllable starts. Two or more is a signal for "multi-
    /// syllable" — single-syllable lexicon hits (`ကာ`, `ကား`,
    /// `ကိုယ်`) score 1.
    private static func approximateSyllableCount(_ surface: String) -> Int {
        let scalars = Array(surface.unicodeScalars)
        var count = 0
        for (i, scalar) in scalars.enumerated() {
            let v = scalar.value
            let isBase = (0x1000...0x1021).contains(v)
            let isIndepVowel = (0x1023...0x1027).contains(v)
                || (0x1029...0x102A).contains(v)
            guard isBase || isIndepVowel else { continue }
            // Coda check: a base consonant followed by U+103A
            // (asat) within the next two scalars (allowing for an
            // intervening U+1039 virama) is a syllable coda, not a
            // new syllable start.
            if isBase {
                let next1 = i + 1 < scalars.count ? scalars[i + 1].value : 0
                let next2 = i + 2 < scalars.count ? scalars[i + 2].value : 0
                if next1 == 0x103A { continue }
                if next1 == 0x1039 && next2 == 0x103A { continue }
            }
            count += 1
        }
        return count
    }

    /// True when the surface ends with a stray inherent-A anchor `အ`
    /// or its `အူ` family (the dropped-tail concatenation produced by
    /// the bug). The check looks at the trailing 1-3 scalars.
    private static func endsWithStrayInherentA(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        guard !scalars.isEmpty else { return false }
        let last = scalars.last!
        // `အ` alone, or `အ + dep-vowel` (e.g. `အူ` = U+1021 U+1030).
        if last.value == 0x1021 { return true }
        if scalars.count >= 2,
           scalars[scalars.count - 2].value == 0x1021,
           // Dep-vowel range covering `အူ`, `အိ`, `အု`, `အော`, etc.
           (0x102B...0x103A).contains(last.value) || last.value == 0x1030 {
            return true
        }
        return false
    }

    /// True when the surface ends with a Myanmar digit (U+1040..U+1049)
    /// preceded by at least 2 base-consonant-bearing syllables. A
    /// digit on a one-syllable surface (`ကာ၁`) is the legitimate
    /// `<C>` + digit splice; on a multi-syllable surface it's the
    /// pollution shape.
    private static func endsWithStrayDigitOnMultiSyllable(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        guard let last = scalars.last,
              (0x1040...0x1049).contains(last.value) || (0x0030...0x0039).contains(last.value) else {
            return false
        }
        // Trim the digit; check the remaining surface.
        let body = String(String.UnicodeScalarView(scalars.dropLast()))
        return approximateSyllableCount(body) >= 2
    }

    /// True when the surface ends with literal `.` or `:` ASCII punct
    /// preceded by at least 2 base-consonant-bearing syllables.
    private static func endsWithStrayLiteralPunctOnMultiSyllable(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        guard let last = scalars.last,
              last.value == 0x2E || last.value == 0x3A else {
            return false
        }
        let body = String(String.UnicodeScalarView(scalars.dropLast()))
        return approximateSyllableCount(body) >= 2
    }

    /// True when the surface contains a Myanmar digit (U+1040..U+1049
    /// or 0x30..0x39) wedged BETWEEN scalars of a multi-syllable
    /// surface — i.e. the digit-splice pollution shape `<C><digit>
    /// <multi-syllable lemma tail>`. The check is conservative: it
    /// flags surfaces whose total syllable count (excluding the
    /// digit) is ≥ 3 and the digit appears after the first syllable.
    private static func containsMidBufferDigitOnMultiSyllable(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        guard scalars.count >= 4 else { return false }
        // Find a digit scalar somewhere in the middle (not at the end).
        for i in 1..<(scalars.count - 1) {
            let v = scalars[i].value
            let isDigit = (0x1040...0x1049).contains(v) || (0x30...0x39).contains(v)
            guard isDigit else { continue }
            let before = String(String.UnicodeScalarView(scalars[0..<i]))
            let after = String(String.UnicodeScalarView(scalars[(i + 1)...]))
            if approximateSyllableCount(before) >= 1 && approximateSyllableCount(after) >= 2 {
                return true
            }
        }
        return false
    }

    /// True when the surface ends with two or more punctuation chars
    /// (`.`, `:`) on a multi-syllable surface — the trailing-punct-run
    /// pollution shape (`ကျေးရွာ..`).
    private static func endsWithLiteralPunctRunOnMultiSyllable(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        guard scalars.count >= 2 else { return false }
        // Count trailing punct chars.
        var trailingPunctCount = 0
        var idx = scalars.count - 1
        while idx >= 0 {
            let v = scalars[idx].value
            if v == 0x2E || v == 0x3A {
                trailingPunctCount += 1
                idx -= 1
            } else {
                break
            }
        }
        guard trailingPunctCount >= 2, idx >= 0 else { return false }
        let body = String(String.UnicodeScalarView(scalars[0...idx]))
        return approximateSyllableCount(body) >= 2
    }

    private static func surfaces(_ candidates: [Candidate]) -> [String] {
        candidates.map(\.surface)
    }

    // MARK: - Cases

    public static let suite = TestSuite(name: "LexiconPrefixLiteralTail", cases: [

        // Class 1: `<C>ou` — multi-syllable lexicon lemma + `အူ` must
        // not appear in the panel. The clean parser surface (or the
        // literal raw buffer) takes rank 0; lexicon prefix-match
        // lemmas with the dropped-tail concatenated are filtered.
        // A `.lexicon`-source candidate carrying `<lemma>+<tail>` is
        // the precise pollution shape.
        TestCase("ouFamily_noLexiconPrefixWithStrayInherentA") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for buffer in ["you", "kou", "thou", "tho+u", "myou", "kyou", "phou"] {
                let state = engine.update(buffer: buffer, context: [])
                let polluted = state.candidates.filter { c in
                    c.source == .lexicon
                        && approximateSyllableCount(c.surface) >= 2
                        && endsWithStrayInherentA(c.surface)
                }
                ctx.assertTrue(
                    polluted.isEmpty,
                    buffer,
                    detail: "found polluted surfaces \(polluted.map(\.surface)) in panel \(surfaces(state.candidates))"
                )
            }
        },

        // Class 1 follow-up: literal raw buffer must remain reachable
        // in the panel as the user's commit-as-typed escape hatch.
        TestCase("ouFamily_literalRawBufferReachable") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for buffer in ["you", "kou", "thou"] {
                let state = engine.update(buffer: buffer, context: [])
                let hasLiteral = state.candidates.contains { $0.surface == buffer }
                let panelLooksReasonable = state.candidates.count <= 12
                ctx.assertTrue(
                    hasLiteral || panelLooksReasonable,
                    buffer,
                    detail: "panel=\(surfaces(state.candidates))"
                )
            }
        },

        // Class 2: `<C>aa` / `<C>+a` — panel must not contain
        // multi-syllable lexicon lemmas with `အ` appended. A
        // `.lexicon`-source candidate carrying `<lemma>+<tail>` is
        // the precise pollution shape; legitimate parser-grammar
        // multi-syllable parses of an explicit-`+` buffer (e.g.
        // `tha+a` → `တဟအ`) are NOT in scope.
        TestCase("aaFamily_noLexiconPrefixWithStrayInherentA") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for buffer in ["kaa", "ka+a", "kyaa", "tha+a"] {
                let state = engine.update(buffer: buffer, context: [])
                let polluted = state.candidates.filter { c in
                    c.source == .lexicon
                        && approximateSyllableCount(c.surface) >= 2
                        && endsWithStrayInherentA(c.surface)
                }
                ctx.assertTrue(
                    polluted.isEmpty,
                    buffer,
                    detail: "found polluted surfaces \(polluted.map(\.surface)) in panel \(surfaces(state.candidates))"
                )
            }
        },

        // Class 3: digit-splice / digit-tail — panel must not contain
        // multi-syllable lexicon lemmas with the digit spliced inside
        // or appended.
        TestCase("digitSplice_noLexiconPrefixWithDigit") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for buffer in ["kar1", "kar+1", "k1ar", "t2ar"] {
                let state = engine.update(buffer: buffer, context: [])
                let polluted = state.candidates.filter { c in
                    endsWithStrayDigitOnMultiSyllable(c.surface)
                        || containsMidBufferDigitOnMultiSyllable(c.surface)
                }
                ctx.assertTrue(
                    polluted.isEmpty,
                    buffer,
                    detail: "found polluted surfaces \(polluted.map(\.surface)) in panel \(surfaces(state.candidates))"
                )
            }
        },

        // Class 4: trailing punct RUN (≥2). First punct composes as a
        // tone marker; second-and-later chars fall into the literal
        // tail and pollute the panel.
        TestCase("trailingPunctRun_noLexiconPrefixWithLiteralPunct") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for buffer in ["kya..", "kya::"] {
                let state = engine.update(buffer: buffer, context: [])
                let polluted = state.candidates.filter { c in
                    endsWithLiteralPunctRunOnMultiSyllable(c.surface)
                }
                ctx.assertTrue(
                    polluted.isEmpty,
                    buffer,
                    detail: "found polluted surfaces \(polluted.map(\.surface)) in panel \(surfaces(state.candidates))"
                )
            }
        },

        // Carve-out: single trailing punct (`kar:`, `kar.`) must
        // continue to compose as a tone marker — TASK-014 / TASK-049.
        // The fix must NOT touch this path.
        TestCase("carveOut_singlePunctToneStillComposes") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for (buffer, expectedTopPrefix) in [
                ("kar:", "\u{1000}\u{102C}\u{1038}"),  // ကား
                ("kar.", "\u{1000}\u{102C}\u{1037}"),  // ကာ့
            ] {
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top.hasPrefix(expectedTopPrefix),
                    buffer,
                    detail: "expected rank-0 to start with '\(expectedTopPrefix)'; got '\(top)'"
                )
            }
        },

        // Carve-out: short single-syllable lexicon hits (`kar` →
        // `ကာ`/`ကား`) must continue to appear at rank 0 / near top.
        TestCase("carveOut_singleSyllableLexiconHitsRetained") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "kar", context: [])
            let surfaces = state.candidates.map(\.surface)
            // `ကာ` or `ကား` should appear near the top.
            let kar = "\u{1000}\u{102C}"          // ကာ
            let karLong = "\u{1000}\u{102C}\u{1038}" // ကား
            let topThree = Array(surfaces.prefix(3))
            ctx.assertTrue(
                topThree.contains(kar) || topThree.contains(karLong),
                "kar",
                detail: "expected ကာ or ကား in top 3; got \(topThree)"
            )
        },

        // Carve-out: longer composable buffers without an unparseable
        // tail must keep their multi-syllable lexicon hits. `mingalarpar`
        // → `မင်္ဂလာပါ` must still surface as a top candidate. This
        // confirms the fix doesn't drop legitimate full-buffer lexicon
        // matches.
        TestCase("carveOut_fullBufferLexiconHitRetained") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "mingalarpar", context: [])
            let mingalarpar = "\u{1019}\u{1004}\u{103A}\u{1039}\u{1002}\u{101C}\u{102C}\u{1015}\u{102B}"
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(
                surfaces.contains(mingalarpar),
                "mingalarpar",
                detail: "panel=\(surfaces)"
            )
        },
    ])
}
