import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-047: when every Myanmar candidate that survives the engine's
/// sanitizer pass is structurally flagged as illegal — or when the
/// rank-0 Myanmar surface drops the vast majority of the user's
/// keystrokes (extreme right-shrink collapse) — the literal-fallback
/// candidate must take rank 0 instead of being appended at the bottom
/// of the panel.
///
/// Two distinct buffer classes:
///
/// - **Class A — sanitizer-fallback-retained illegal Myanmar surface.**
///   Buffers like `uue`, `uuar`, `iauu`, `iueii`, `aaoo` produce a
///   rank-0 Myanmar surface that the engine's structural-legality
///   predicates flag (multi-anchor / doubled-coda / indep-vowel-virama
///   / multi-anchor-pollution). The sanitizers preserve the violator
///   when no clean sibling exists, leaving a structurally-illegal
///   candidate at rank 0. The literal must promote past it.
///
/// - **Class B — extreme right-shrink collapse.** Buffers like
///   `kaaaaaaaaa`, `k+k+k+k+k+k`, `aaaaa` produce a rank-0 surface
///   of one or two scalars because the right-shrink probe peels off
///   the unparseable tail. The rank-0 surface is structurally legal
///   but semantically loses 60–80% of the keystrokes. The literal
///   must promote so the user can commit what they typed.
///
/// Carve-outs (must NOT promote literal to rank 0):
///   - `tablet`, `aungc`, `kya` — well-behaved Burmese parses with
///     an Myanmar-leading rank-0; literal stays at the bottom.
///   - `kbbbbbbbbb` (lossless 1:1 letter-by-letter) — no collapse.
///   - `lekkale` (full-buffer parse) — no collapse, no illegality.
///   - `mingalarpar` / `kar` (lexicon hits) — literal not added.
public enum LiteralFallbackIllegalSurfaceSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    private static func surfaces(_ candidates: [Candidate]) -> [String] {
        candidates.map(\.surface)
    }

    public static let suite = TestSuite(name: "LiteralFallbackIllegalSurface", cases: [

        // Class A primary regression — multi-anchor pollution that
        // either fails an existing sanitizer predicate
        // (`uue`/`uuar`/`iauu`) or carries 2+ independent-vowel
        // anchors in a no-separator vowel-only buffer
        // (`aaoo`/`iueii`).
        TestCase("classA_sanitizerViolatorsPromoteLiteralToRankZero") { ctx in
            let engine = emptyEngine()
            for buffer in ["uue", "uuar", "iauu", "aaoo", "iueii"] {
                let state = engine.update(buffer: buffer, context: [])
                let topSurface = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    topSurface == buffer,
                    buffer,
                    detail: "expected literal '\(buffer)' at rank 0; got '\(topSurface)' [\(hex(topSurface))]; panel=\(surfaces(state.candidates))"
                )
            }
        },

        // Class A guard — `iauu` literal must be present in the
        // panel at all. (Probe shows the literal can be missing
        // from the visible top-N before the fix.)
        TestCase("classA_iauu_literalPresentInPanel") { ctx in
            let engine = emptyEngine()
            let state = engine.update(buffer: "iauu", context: [])
            ctx.assertTrue(
                state.candidates.contains { $0.surface == "iauu" },
                "iauu",
                detail: "literal 'iauu' missing from panel; got \(surfaces(state.candidates))"
            )
        },

        // Class B primary regression — right-shrink collapse
        // shapes. The rank-0 Myanmar candidate has dropped 60–80%
        // of the buffer's keystrokes; the literal must take rank 0.
        TestCase("classB_extremeCollapsePromotesLiteralToRankZero") { ctx in
            let engine = emptyEngine()
            for buffer in [
                "kaaaaaaaaa",
                "k+k+k+k+k+k",
                "k+k+k+k+k+k+k+k",
                "aaaaa",
            ] {
                let state = engine.update(buffer: buffer, context: [])
                let topSurface = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    topSurface == buffer,
                    buffer,
                    detail: "expected literal '\(buffer)' at rank 0; got '\(topSurface)' [\(hex(topSurface))]; panel=\(surfaces(state.candidates))"
                )
            }
        },

        // Carve-out: well-behaved Burmese parses keep their
        // Myanmar-leading rank-0 — the literal stays at the bottom.
        TestCase("carveOut_wellBehavedMyanmar_literalAtBottom") { ctx in
            let engine = emptyEngine()
            // Every entry in this corpus must produce an Myanmar
            // surface at rank 0 and the literal at the bottom of
            // the panel (length >= 2).
            let cases: [String] = ["tablet", "aungc"]
            for buffer in cases {
                let state = engine.update(buffer: buffer, context: [])
                ctx.assertTrue(
                    state.candidates.count >= 2,
                    buffer,
                    detail: "expected ≥2 candidates; got \(surfaces(state.candidates))"
                )
                let topSurface = state.candidates.first?.surface ?? ""
                let topIsMyanmar = topSurface.unicodeScalars.contains {
                    $0.value >= 0x1000 && $0.value <= 0x109F
                }
                ctx.assertTrue(
                    topIsMyanmar,
                    buffer,
                    detail: "expected rank-0 Myanmar; got '\(topSurface)' [\(hex(topSurface))]"
                )
                ctx.assertTrue(
                    state.candidates.last?.surface == buffer,
                    buffer,
                    detail: "expected literal '\(buffer)' at bottom; got '\(state.candidates.last?.surface ?? "")'; panel=\(surfaces(state.candidates))"
                )
            }
        },

        // Carve-out: `kya` produces multi-Myanmar candidates and the
        // literal at the bottom.
        TestCase("carveOut_kya_literalAtBottom") { ctx in
            let engine = emptyEngine()
            let state = engine.update(buffer: "kya", context: [])
            ctx.assertTrue(
                state.candidates.count >= 2,
                "kya",
                detail: "expected ≥2 candidates; got \(surfaces(state.candidates))"
            )
            let topSurface = state.candidates.first?.surface ?? ""
            let topIsMyanmar = topSurface.unicodeScalars.contains {
                $0.value >= 0x1000 && $0.value <= 0x109F
            }
            ctx.assertTrue(
                topIsMyanmar,
                "kya",
                detail: "expected rank-0 Myanmar; got '\(topSurface)' [\(hex(topSurface))]"
            )
            ctx.assertTrue(
                state.candidates.last?.surface == "kya",
                "kya",
                detail: "expected literal 'kya' at bottom; got '\(state.candidates.last?.surface ?? "")'; panel=\(surfaces(state.candidates))"
            )
        },

        // Carve-out: `kbbbbbbbbb` is a lossless 1:1 letter-by-letter
        // mapping (every input char becomes one Myanmar consonant).
        // The rank-0 surface has the same scalar count as the buffer,
        // so Class B does NOT fire. Literal stays at bottom.
        TestCase("carveOut_kbbbbbbbbb_literalAtBottom") { ctx in
            let engine = emptyEngine()
            let state = engine.update(buffer: "kbbbbbbbbb", context: [])
            let topSurface = state.candidates.first?.surface ?? ""
            ctx.assertTrue(
                topSurface != "kbbbbbbbbb",
                "kbbbbbbbbb",
                detail: "literal must NOT take rank 0 for lossless parse; got '\(topSurface)' [\(hex(topSurface))]"
            )
            let topIsMyanmar = topSurface.unicodeScalars.contains {
                $0.value >= 0x1000 && $0.value <= 0x109F
            }
            ctx.assertTrue(
                topIsMyanmar,
                "kbbbbbbbbb",
                detail: "expected rank-0 Myanmar; got '\(topSurface)' [\(hex(topSurface))]"
            )
        },

        // Carve-out: `lekkale` is a full-buffer parse with a Pali-
        // stack rendering (every input char accounted for). The
        // rank-0 surface is structurally legal and longer than the
        // buffer, so neither Class A nor Class B fires.
        TestCase("carveOut_lekkale_literalAtBottom") { ctx in
            let engine = emptyEngine()
            let state = engine.update(buffer: "lekkale", context: [])
            let topSurface = state.candidates.first?.surface ?? ""
            ctx.assertTrue(
                topSurface != "lekkale",
                "lekkale",
                detail: "literal must NOT take rank 0 for full parse; got '\(topSurface)' [\(hex(topSurface))]"
            )
            let topIsMyanmar = topSurface.unicodeScalars.contains {
                $0.value >= 0x1000 && $0.value <= 0x109F
            }
            ctx.assertTrue(
                topIsMyanmar,
                "lekkale",
                detail: "expected rank-0 Myanmar; got '\(topSurface)' [\(hex(topSurface))]"
            )
        },

        // Carve-out: lexicon-hit at rank 0 → no literal added at
        // all, regardless of any Class A / Class B signal. (TASK-043
        // rule 4 — the strong "user is composing intentional
        // Burmese" signal.)
        TestCase("carveOut_lexiconHitAtRankZero_noLiteralAdded") { ctx in
            let engine = BurmeseEngine(
                candidateStore: FixedCandidateStore(byPrefix: [
                    "mingalarpar": [Candidate(
                        surface: "မင်္ဂလာပါ",
                        reading: "min+galarpar",
                        source: .lexicon,
                        score: 1000
                    )],
                ]),
                languageModel: NullLanguageModel()
            )
            let state = engine.update(buffer: "mingalarpar", context: [])
            ctx.assertFalse(
                state.candidates.contains { $0.surface == "mingalarpar" },
                "mingalarpar",
                detail: "literal should NOT be added when lexicon hits rank 0; got \(surfaces(state.candidates))"
            )
        },

        // De-dup: even when promoting to rank 0, the literal must
        // appear at most once in the panel.
        TestCase("classA_literalNotDuplicated") { ctx in
            let engine = emptyEngine()
            for buffer in ["uue", "iauu", "aaoo"] {
                let state = engine.update(buffer: buffer, context: [])
                let count = state.candidates.filter { $0.surface == buffer }.count
                ctx.assertTrue(
                    count == 1,
                    buffer,
                    detail: "expected exactly 1 literal candidate; got \(count); panel=\(surfaces(state.candidates))"
                )
            }
        },

        // De-dup: same for Class B.
        TestCase("classB_literalNotDuplicated") { ctx in
            let engine = emptyEngine()
            for buffer in ["kaaaaaaaaa", "k+k+k+k+k+k", "aaaaa"] {
                let state = engine.update(buffer: buffer, context: [])
                let count = state.candidates.filter { $0.surface == buffer }.count
                ctx.assertTrue(
                    count == 1,
                    buffer,
                    detail: "expected exactly 1 literal candidate; got \(count); panel=\(surfaces(state.candidates))"
                )
            }
        },

        // Synthesised literal still has source `.grammar` and
        // score 0 — the promotion only changes its position, not
        // its identity.
        TestCase("classA_promotedLiteralProperties") { ctx in
            let engine = emptyEngine()
            let state = engine.update(buffer: "uue", context: [])
            let literal = state.candidates.first { $0.surface == "uue" }
            ctx.assertTrue(literal != nil, "uue", detail: "literal not present")
            ctx.assertTrue(
                literal?.source == .grammar,
                "uue",
                detail: "expected source=.grammar; got \(String(describing: literal?.source))"
            )
            ctx.assertTrue(
                literal?.score == 0.0,
                "uue",
                detail: "expected score=0; got \(String(describing: literal?.score))"
            )
        },
    ])
}
