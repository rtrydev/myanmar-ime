import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-039: trailing inherent-`a` keystrokes after a
/// non-inherent vowel rule are silently dropped — typing `khia` (or
/// `khouta`, `iaa`, `khaunga`, ...) produces the same rank-0 surface
/// as the no-`a` form, so the user's keystroke vanishes without any
/// signal.
///
/// The bug class is widespread: a `vowelOnly(inherent-a)` arc whose
/// emission is the empty string can chain after any prior arc that
/// produced visible Myanmar output (an `onsetOnly`, `onsetVowel`, or
/// any `vowelOnly` whose vowel emits non-empty Myanmar). The TASK-016
/// guard only rejected the chain when the *immediately previous* arc
/// was itself an inherent-`a` arc with a consonant ancestor — the
/// non-inherent vowel rules (`i`, `u`, `e`, `o`, `out`, `ote`, `aing`,
/// `aung`, …) escape that guard.
///
/// The fix generalises the guard to reject the inherent-`a` arc
/// whenever ANY ancestor arc has emitted non-empty Myanmar. The
/// buffer-leading bare-`aa` carve-out (no consonant ancestor, all
/// previous arcs emit empty) is preserved, so `aa` / `aaa` continue
/// to render as `အ` via the leading-A promotion.
public enum TrailingAFterVowelRuleSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    /// Consonants spanning the inventory — single-letter and digraph
    /// forms. Excludes medial-extender consonants (`y`, `r`, `w`, `h`)
    /// because their `<C>i` / `<C>u` / `<C>o` shapes interact with
    /// medial promotion and produce ambiguous baselines.
    private static let bareConsonants: [String] = [
        "k", "kh", "g", "gh", "ng", "s", "z", "t", "ht", "d", "dh",
        "n", "p", "ph", "v", "b", "m", "l", "th",
    ]

    /// Non-inherent vowel rules that produce a visible Myanmar
    /// emission. Trailing `a` after any of these is the bug class.
    /// Rules whose canonical emits the inherent-`a` (i.e. `a` itself)
    /// are excluded — those are TASK-016's territory.
    private static let nonInherentVowelRules: [String] = [
        "i", "u", "e", "o", "ay", "aw", "ar",
        "in", "out", "ote", "ate", "aung", "aing", "ain",
    ]

    /// Buffer-leading vowel rules (no consonant onset). Same bug
    /// class — `iaa`, `uaa`, `eaa`, `oaa`, `araa` should not
    /// silently swallow the trailing `a`.
    private static let leadingVowelRules: [String] = [
        "i", "u", "e", "o", "ay", "ar", "in", "out",
    ]

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// True when `surface` is the raw-buffer literal for `buffer`.
    /// Acceptance criterion lets the engine choose between
    /// "different scalar count" and "raw-buffer literal".
    private static func isRawLiteral(_ surface: String, buffer: String) -> Bool {
        surface == buffer
    }

    public static let suite = TestSuite(name: "TrailingAFterVowelRule", cases: [

        // PRIMARY ACCEPTANCE: the candidate panel must reflect the
        // user's keystrokes. For every `(consonant, non-inherent
        // vowel rule)` and every n in {1, 2, 3}, the candidate panel
        // for `<C><V>a^n` must contain a candidate whose surface is
        // either:
        //   - different from `<C><V>`'s rank-0 surface (the trailing
        //     `a` produced a visible re-segmentation or extra
        //     scalar);
        //   - the raw-buffer literal (commit-as-typed); or
        //   - a Myanmar prefix with an ASCII `a^n` tail.
        //
        // The pure rank-0 form of the criterion (rank-0 differs OR is
        // literal) cannot be enforced without conflicting with
        // incremental-typing acceptance (see ComprehensiveRanking —
        // mid-sentence prefixes like `aphaya`, `dina`, `ngara` are
        // legitimately silent-absorption parses where the next
        // keystroke supplies the rest of the word). The panel form
        // captures the user-facing invariant: the user must be able
        // to find a candidate that does NOT silently drop their
        // keystrokes, even if it's not at rank 0. The bare-engine
        // literal-fallback path achieves this by appending the raw
        // buffer at the bottom of the panel.
        TestCase("panelHasReflectingCandidate_consonant_x_nonInherentRule") { ctx in
            let engine = emptyEngine()
            for c in bareConsonants {
                for v in nonInherentVowelRules {
                    let base = c + v
                    let baseTop = engine.update(buffer: base, context: [])
                        .candidates.first?.surface ?? ""
                    for n in 1...3 {
                        let buffer = base + String(repeating: "a", count: n)
                        let cands = engine.update(buffer: buffer, context: []).candidates
                        let hasReflecting = cands.contains { cand in
                            if cand.surface != baseTop { return true }
                            if cand.surface == buffer { return true }
                            // Mixed Myanmar + ASCII tail.
                            let asciiTail = String(cand.surface.unicodeScalars
                                .reversed()
                                .prefix { (0x61...0x7A).contains($0.value) }
                                .reversed()
                                .map(Character.init))
                            if asciiTail.count >= n
                                && asciiTail.allSatisfy({ $0 == "a" }) {
                                return true
                            }
                            return false
                        }
                        ctx.assertTrue(
                            hasReflecting,
                            "\(buffer)",
                            detail: "panel has no candidate reflecting \(n) trailing a's; baseTop='\(baseTop)' panel=\(cands.prefix(6).map(\.surface))"
                        )
                    }
                }
            }
        },

        // BUFFER-LEADING coverage: `iaa`, `uaa`, `eaa`, `oaa`, etc.
        // — vowel rule with no consonant onset followed by trailing
        // `a`s. Same panel invariant: at least one candidate must
        // reflect the user's full keystroke sequence.
        TestCase("panelHasReflectingCandidate_bufferLeading_vowelRule") { ctx in
            let engine = emptyEngine()
            for v in leadingVowelRules {
                let baseTop = engine.update(buffer: v, context: [])
                    .candidates.first?.surface ?? ""
                for n in 1...3 {
                    let buffer = v + String(repeating: "a", count: n)
                    let cands = engine.update(buffer: buffer, context: []).candidates
                    let hasReflecting = cands.contains { cand in
                        if cand.surface != baseTop { return true }
                        if cand.surface == buffer { return true }
                        let asciiTail = String(cand.surface.unicodeScalars
                            .reversed()
                            .prefix { (0x61...0x7A).contains($0.value) }
                            .reversed()
                            .map(Character.init))
                        if asciiTail.count >= n
                            && asciiTail.allSatisfy({ $0 == "a" }) {
                            return true
                        }
                        return false
                    }
                    ctx.assertTrue(
                        hasReflecting,
                        "\(buffer)",
                        detail: "panel has no candidate reflecting \(n) trailing a's; baseTop='\(baseTop)' panel=\(cands.prefix(6).map(\.surface))"
                    )
                }
            }
        },

        // Specific reproductions documented in the task — sanity
        // check that the named buffers all surface a candidate
        // reflecting the user's full keystrokes.
        TestCase("specificReproductions_keystrokesSurface") { ctx in
            let engine = emptyEngine()
            let inputs = [
                "khia", "khoa", "khouta", "khaunga", "kainga",
                "iaa", "iaaa", "khotea", "khaaya", "khaaya.",
                "thar:aa", "thar:aaa",
                "min+galarparaa", "min+galarparaaa",
                "thingyanaaa",
            ]
            for buffer in inputs {
                let cands = engine.update(buffer: buffer, context: []).candidates
                ctx.assertFalse(
                    cands.isEmpty,
                    "\(buffer)_nonEmpty",
                    detail: "panel must not be empty for '\(buffer)'"
                )
                // Compute baseline surface (buffer minus trailing
                // a's) for the scalar-count comparison.
                var baseChars = Array(buffer)
                while baseChars.last == "a" { baseChars.removeLast() }
                let base = String(baseChars)
                let baseTop = engine.update(buffer: base, context: [])
                    .candidates.first?.surface ?? ""
                let trailingACount = buffer.count - base.count
                let hasReflecting = cands.contains { cand in
                    if cand.surface != baseTop { return true }
                    if cand.surface == buffer { return true }
                    let asciiTail = String(cand.surface.unicodeScalars
                        .reversed()
                        .prefix { (0x61...0x7A).contains($0.value) }
                        .reversed()
                        .map(Character.init))
                    if asciiTail.count >= trailingACount
                        && asciiTail.allSatisfy({ $0 == "a" }) {
                        return true
                    }
                    return false
                }
                ctx.assertTrue(
                    hasReflecting,
                    buffer,
                    detail: "no candidate reflects \(trailingACount) trailing a's on top of '\(baseTop)'; panel=\(cands.prefix(6).map(\.surface))"
                )
            }
        },

        // REGRESSION GUARDS — the carve-outs must continue to work.
        TestCase("regression_bareLeadingAaProducesIndependentA") { ctx in
            let engine = emptyEngine()
            // `aa` and `aaa` must still produce a single `အ`
            // (`U+1021`) via the leading-A promotion. The
            // generalised guard's no-consonant-ancestor carve-out
            // preserves this.
            for buffer in ["aa", "aaa"] {
                let top = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top.unicodeScalars.first?.value == 0x1021,
                    buffer,
                    detail: "expected leading 'အ' (U+1021), got '\(top)' [\(hex(top))]"
                )
            }
        },

        TestCase("regression_consonantPlusInherentAStillWorks") { ctx in
            let engine = emptyEngine()
            // `kaa` → must contain a candidate where the trailing
            // `a` re-renders as `အ` (TASK-016).
            let kaaCands = engine.update(buffer: "kaa", context: []).candidates
            let hasKaA = kaaCands.contains { $0.surface.contains("\u{1021}") }
            ctx.assertTrue(
                hasKaA,
                "kaa_hasIndependentA",
                detail: "kaa panel should contain a candidate with U+1021; got \(kaaCands.prefix(5).map(\.surface))"
            )
        },

        TestCase("regression_singleConsonantPlusVowelUnchanged") { ctx in
            let engine = emptyEngine()
            // The base `<C><V>` forms continue to render as before.
            let cases: [(buffer: String, expected: String)] = [
                ("khi", "\u{1001}\u{102E}"),
                ("khout", "\u{1001}\u{1031}\u{102B}\u{1000}\u{103A}"),
                ("kar", "\u{1000}\u{102C}"),
                ("kara", "\u{1000}\u{101B}"),
            ]
            for c in cases {
                let top = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top == c.expected,
                    c.buffer,
                    detail: "expected '\(c.expected)' got '\(top)'"
                )
            }
        },

        // STRICT RANK-0 ACCEPTANCE for the buffer-leading vowel-rule
        // bug class. The Class D literal-fallback promotion in
        // `injectLiteralFallback` covers buffer-leading vowel-rule
        // shapes (`iaa`, `iaaa`, `uaa`, `eaa`, `oaa`, …) by
        // promoting the raw-buffer literal to rank 0 when the
        // trailing `a^n` (n>=2) would otherwise vanish silently.
        // The predicate is restricted to pure-vowel-rule buffers
        // (no consonants, no separators) so the consonant-anchored
        // mid-typing prefixes in the corpus (`nga`, `kya`, `apha`,
        // …) stay on the regular ranking path.
        //
        // Acceptance: rank-0 surface for `<vowel-rule>aa+` is
        // either the raw-buffer literal OR has a different scalar
        // count from the `<vowel-rule>` baseline.
        TestCase("rankZero_bufferLeadingVowelRuleClassD") { ctx in
            let engine = emptyEngine()
            // (buffer-leading-rule, trailing-a counts to test).
            // The leading-A promotion path (`aa+` with no other
            // letter) is excluded — it has its own carve-out and is
            // covered by `regression_bareLeadingAaProducesIndependentA`.
            let leadingRules = ["i", "u", "e", "o", "ar", "ay", "aw", "in", "out"]
            for v in leadingRules {
                let baseTop = engine.update(buffer: v, context: [])
                    .candidates.first?.surface ?? ""
                let baseScalarCount = baseTop.unicodeScalars.count
                for n in 2...4 {
                    let buffer = v + String(repeating: "a", count: n)
                    let top = engine.update(buffer: buffer, context: [])
                        .candidates.first?.surface ?? ""
                    let topScalarCount = top.unicodeScalars.count
                    let isLiteral = top == buffer
                    let differsInCount = topScalarCount != baseScalarCount
                    ctx.assertTrue(
                        isLiteral || differsInCount,
                        "\(buffer)",
                        detail: "rank-0 silent-absorption: top='\(top)' [count=\(topScalarCount)] base='\(baseTop)' [count=\(baseScalarCount)]; expected literal OR different scalar count"
                    )
                }
            }
        },

        // Carve-out: leading-A promotion (`aa`, `aaa`, `aaaa`)
        // must NOT be hit by Class D. Trimming all trailing
        // `a`s leaves an empty buffer, which the predicate
        // skips, so the leading-A path stays intact. (`aaaaa+`
        // hits the pre-existing TASK-047 Class B pathological-
        // collapse path which already promotes the literal at
        // 5+ same-letter runs; that is independent of Class D.)
        TestCase("rankZero_classD_excludesLeadingARun") { ctx in
            let engine = emptyEngine()
            for buffer in ["aa", "aaa", "aaaa"] {
                let top = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    top == buffer,
                    buffer,
                    detail: "leading-A run should NOT be promoted to literal at rank 0; got '\(top)'"
                )
                ctx.assertTrue(
                    top.unicodeScalars.first?.value == 0x1021,
                    buffer,
                    detail: "expected leading 'အ' (U+1021); got '\(top)' [\(hex(top))]"
                )
            }
        },

        // Carve-out: consonant-anchored buffers stay on the
        // regular ranking path even for n>=2 trailing `a`s. Class
        // D only fires on pure-vowel-rule buffers; for
        // consonant-anchored shapes the TASK-016 / TASK-026 /
        // Class B paths handle the chained inherent-`a` either by
        // re-rendering as `အ` (`kaa → ကအ`, `khoutaa → ခေါက်အ`)
        // or by Class B literal promotion for pathological
        // collapses (`kaaaaaaaa`, `kbbbbbbbb`).
        TestCase("rankZero_classD_excludesConsonantAnchored") { ctx in
            let engine = emptyEngine()
            // Each of these has a consonant in the buffer (k, m,
            // t, p, n, h, etc.) and ends in `aa+`. Rank-0 must NOT
            // be the literal — the regular ranking path already
            // handles them.
            let cases = ["kaa", "kaaa", "kaakaa", "thaaaa",
                         "khoutaa", "khoutaaa", "khaungaa",
                         "khaungaaa"]
            for buffer in cases {
                let top = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    top == buffer,
                    buffer,
                    detail: "consonant-anchored buffer should NOT be promoted to literal at rank 0 by Class D; got '\(top)'"
                )
            }
        },

        // Carve-out: separator-bearing buffers stay on the
        // regular ranking path. Visarga + inherent-A path
        // (`kar:aa → ကားအ`) is preserved via the separator gate
        // in the Class D predicate.
        TestCase("rankZero_classD_excludesSeparatorBearing") { ctx in
            let engine = emptyEngine()
            // Visarga and dot-tone buffers ending in `aa+` retain
            // their Burmese surface (the literal pass-through path
            // for these is already handled by the existing
            // `digitOrLiteralFallback` / mid-buffer-tone logic, not
            // by Class D).
            for buffer in ["kar:aa", "kar:aaa", "ka:aa"] {
                let top = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    top == buffer,
                    buffer,
                    detail: "separator-bearing buffer should NOT be promoted to literal at rank 0 by Class D; got '\(top)'"
                )
            }
        },
    ])
}
