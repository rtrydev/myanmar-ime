import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-046: the `ah` consonant rule key (which canonically produces
/// U+1021 အ — the independent-vowel `a` anchor) is the only consonant
/// roman whose match consumes a *vowel letter* (`a`) as part of its
/// onset trigger. When the user's buffer has the shape
/// `<C>a + h<V>` — a consonant-bearing syllable closed by an inherent
/// `a` followed by a fresh `ha`-syllable — the parser greedily reads
/// `<C>` + `ah` (= U+1021) + `<V>`, swallowing the `h` of the next
/// syllable into a phantom `ah`-onset. The user's `h` consonant
/// (U+101F) never appears in the rank-0 surface.
///
/// The same collision fires for buffer-leading `ah<C><V>` shapes
/// (Pali stack words like `ahmada`, `ahmat`) and buffer-leading
/// `ah<vowel-letter>` shapes (`aha`, `ahar`, `ahin`) where the user's
/// intended parse is `<a-anchor> + ha + <V>`.
///
/// Acceptance criteria (from the task):
///   - **Mid-buffer collision shapes** (`<C>a-h<V>`): the rank-0
///     surface must contain U+101F (ha) at the position the user's
///     `h` was typed; it must NOT contain U+1021 inserted there.
///   - **Buffer-leading `ah<C><V>` Pali-stack words** (`ahmada`,
///     `ahmat`): the rank-0 surface must contain BOTH U+1021 (the
///     leading `ah` → အ) AND U+101F (the second-syllable `h`).
///   - **Buffer-leading bare `ah<V>` shapes** (`aha`, `ahar`, `ahin`,
///     `ahan`, `ahot`): the rank-0 surface must contain U+101F (ha)
///     rather than collapsing to `<a-anchor> + <V>` with the `h`
///     lost.
///   - **Carve-outs** (must not regress): `ah` typed alone, `ah+...`,
///     `ah+dhi+pa+yay`, and `brahma` must keep producing their
///     existing surfaces (the `ah` onset is legitimate at buffer
///     start when followed by `+` or end-of-buffer, and `brahma`
///     parses through the `bra` cluster onset rather than the `ah`
///     mid-buffer collision).
///
/// The fix is structural: penalise the `ah` onset match in
/// "stranded inherent-`a` contexts" — i.e. when the next character
/// after `ah` is an ASCII letter that could plausibly form a fresh
/// `<C>...` syllable on its own. Buffer-leading or post-separator
/// `ah` matches with no following letter (or with `+`/`'` immediately
/// after) remain unpenalised.
public enum AhConsonantBoundaryHSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// `surface` contains scalar `target` somewhere.
    private static func contains(_ surface: String, scalar target: UInt32) -> Bool {
        surface.unicodeScalars.contains { $0.value == target }
    }

    /// Count of scalar `target` in `surface`.
    private static func count(_ surface: String, scalar target: UInt32) -> Int {
        surface.unicodeScalars.filter { $0.value == target }.count
    }

    public static let suite = TestSuite(name: "AhConsonantBoundaryH", cases: [

        // Mid-buffer collision — `<C>a + h<V>`. The current parser
        // produces a rank-0 surface where the `h` is replaced by U+1021;
        // the fix must surface the legal `<C> + ha + <V>` decomposition
        // at rank 0 (which contains U+101F at the `h` position).
        TestCase("midBuffer_consonantA_hVowel_keepsHaConsonant") { ctx in
            let engine = emptyEngine()
            let cases: [String] = [
                "kaha", "kahar",
                "tahar", "tahain",
                "shahar",
                "myaha",
                "thwahar",
                "yahaung",
                "thingaha",
                "khaha", "phaha",
            ]
            for buffer in cases {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(buffer, detail: "no candidates")
                    continue
                }
                ctx.assertTrue(
                    contains(top, scalar: 0x101F),
                    buffer,
                    detail: "rank-0 must contain U+101F (ha); got '\(top)' [\(hex(top))]"
                )
            }
        },

        // Buffer-leading bare `ah<V>` shapes — no preceding consonant.
        // The user's intended parse is `<a-anchor> + ha + <V>`, which
        // contains U+101F. The current parser collapses to
        // `<a-anchor> + <V>` and drops the `h` entirely.
        TestCase("bufferLeading_ahVowel_keepsHaConsonant") { ctx in
            let engine = emptyEngine()
            let cases: [String] = [
                "aha", "ahar",
                "aharkar",
                "ahin", "ahan", "ahot",
            ]
            for buffer in cases {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(buffer, detail: "no candidates")
                    continue
                }
                ctx.assertTrue(
                    contains(top, scalar: 0x101F),
                    buffer,
                    detail: "rank-0 must contain U+101F (ha); got '\(top)' [\(hex(top))]"
                )
            }
        },

        // Buffer-leading `ah<C><V>` Pali-stack words. Rank-0 must
        // surface both U+1021 (the leading `ah` → အ) and U+101F (the
        // second-syllable `h` either as a bare consonant or as the
        // upper of a Pali stack `ဟ္`).
        TestCase("bufferLeading_ahConsonantVowel_paliStack_keepsBothScalars") { ctx in
            let engine = emptyEngine()
            for buffer in ["ahmada", "ahmat"] {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(buffer, detail: "no candidates")
                    continue
                }
                ctx.assertTrue(
                    contains(top, scalar: 0x1021),
                    buffer,
                    detail: "rank-0 must contain U+1021 (ah-anchor); got '\(top)' [\(hex(top))]"
                )
                ctx.assertTrue(
                    contains(top, scalar: 0x101F),
                    buffer,
                    detail: "rank-0 must contain U+101F (ha consonant); got '\(top)' [\(hex(top))]"
                )
            }
        },

        // Mid-buffer with stack-bearing prefixes (`thingaha`),
        // medial-bearing prefixes (`myaha`, `thwahar`, `shahar`),
        // and aspirated onsets (`khaha`, `phaha`) all keep the `h`
        // somewhere in the rank-0 surface.
        TestCase("midBuffer_explicitTaskExamples_haPresent") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, desc: String)] = [
                ("kahar", "consonant + a + h + ar"),
                ("tahar", "alt-consonant + a + h + ar"),
                ("tahain", "consonant + a + h + ain (asat-final vowel)"),
                ("shahar", "cluster-alias prefix"),
                ("myaha", "medial-bearing prefix"),
                ("thwahar", "wa-medial prefix"),
                ("yahaung", "y-onset prefix"),
                ("thingaha", "kinzi-stack prefix"),
            ]
            for entry in cases {
                let state = engine.update(buffer: entry.buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(entry.buffer, detail: "no candidates (\(entry.desc))")
                    continue
                }
                ctx.assertTrue(
                    contains(top, scalar: 0x101F),
                    entry.buffer,
                    detail: "rank-0 must contain U+101F (ha) for \(entry.desc); got '\(top)' [\(hex(top))]"
                )
            }
        },

        // Carve-out: `ah` typed alone (end-of-buffer) must still
        // produce U+1021 as a candidate, since the `ah` onset is
        // legitimate at buffer-end.
        TestCase("carveOut_bareAh_producesU1021") { ctx in
            let engine = emptyEngine()
            let state = engine.update(buffer: "ah", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(
                surfaces.contains("\u{1021}") || surfaces.contains { $0.unicodeScalars.first?.value == 0x1021 },
                "ah",
                detail: "expected U+1021 reachable in panel for 'ah'; got \(surfaces)"
            )
        },

        // Carve-out: `ah+` (followed by virama / soft-boundary) must
        // produce U+1021 at rank 0 — the `+` is an explicit syllable
        // separator, no stranded inherent-`a` collision.
        TestCase("carveOut_ahPlus_producesU1021") { ctx in
            let engine = emptyEngine()
            let state = engine.update(buffer: "ah+", context: [])
            guard let top = state.candidates.first?.surface else {
                ctx.fail("ah+", detail: "no candidates")
                return
            }
            ctx.assertTrue(
                top.unicodeScalars.first?.value == 0x1021,
                "ah+",
                detail: "rank-0 must start with U+1021 for 'ah+'; got '\(top)' [\(hex(top))]"
            )
        },

        // Carve-out: `ah+dhi+pa+yay` (existing
        // `GrammarSuite.engine_stackChain_ahDhiPaYay_doesNotTruncate`
        // case). The rank-0 surface must NOT regress — it should still
        // surface a multi-syllable word starting with U+1021.
        TestCase("carveOut_ahDhiPaYay_doesNotTruncate") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "ah+dhi+pa+yay", context: [])
            guard let top = state.candidates.first?.surface else {
                ctx.fail("ah+dhi+pa+yay", detail: "no candidates")
                return
            }
            ctx.assertTrue(
                top.unicodeScalars.count >= 4,
                "ah+dhi+pa+yay",
                detail: "expected ≥4 scalars in rank-0; got '\(top)' [\(hex(top))]"
            )
            ctx.assertTrue(
                top.unicodeScalars.first?.value == 0x1021,
                "ah+dhi+pa+yay",
                detail: "rank-0 must start with U+1021; got '\(top)' [\(hex(top))]"
            )
        },

        // Carve-out: `brahma` (existing
        // `RankingSuite.tasksDir05_paliStackReachable_brahma` case).
        // The expected `ဘရဟ္မ` surface (1018 101B 101F 1039 1019)
        // must still be reachable in the panel.
        TestCase("carveOut_brahma_paliStackReachable") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "brahma", context: [])
            let surfaces = state.candidates.map(\.surface)
            let expected = "\u{1018}\u{101B}\u{101F}\u{1039}\u{1019}"
            ctx.assertTrue(
                surfaces.contains(expected),
                "brahma",
                detail: "expected \(expected) [\(hex(expected))] in panel; got \(surfaces)"
            )
        },

        // The `ahmada` and `ahmat` Pali-stack reachability test
        // (existing `RankingSuite.tasksDir05_paliStackReachable_ahmada`)
        // currently passes only because it asserts panel membership,
        // not rank position. After the fix, the expected stack-bearing
        // surface must reach top-2.
        TestCase("ahmada_paliStack_reachesTopTwo") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "ahmada", context: [])
            let expected = "\u{1021}\u{101F}\u{1039}\u{1019}\u{1012}"
            let topTwoSurfaces = state.candidates.prefix(2).map(\.surface)
            ctx.assertTrue(
                topTwoSurfaces.contains(expected),
                "ahmada",
                detail: "expected \(expected) [\(hex(expected))] in top-2; got \(topTwoSurfaces)"
            )
        },

        TestCase("ahmat_paliStack_reachesTopTwo") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "ahmat", context: [])
            let expected = "\u{1021}\u{101F}\u{1039}\u{1019}\u{1010}\u{103A}"
            let topTwoSurfaces = state.candidates.prefix(2).map(\.surface)
            ctx.assertTrue(
                topTwoSurfaces.contains(expected),
                "ahmat",
                detail: "expected \(expected) [\(hex(expected))] in top-2; got \(topTwoSurfaces)"
            )
        },

        // The literal candidate (raw `aha`/`kahar`/…) must remain
        // reachable per TASK-043 policy — the literal-fallback step
        // is unaffected.
        TestCase("literal_remainsReachable") { ctx in
            let engine = emptyEngine()
            for buffer in ["aha", "kahar", "ahmada"] {
                let state = engine.update(buffer: buffer, context: [])
                let surfaces = state.candidates.map(\.surface)
                ctx.assertTrue(
                    surfaces.contains(buffer),
                    buffer,
                    detail: "literal '\(buffer)' missing; got \(surfaces)"
                )
            }
        },
    ])
}
