import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-050: the Class B literal-fallback rank-0 promotion
/// trigger (TASK-047) must fire on buffers shaped as a short consonant
/// prefix followed by a long same-letter run, even though those buffers
/// carry 3+ distinct content characters. The pre-fix Class B gate
/// `distinctContentChars.count <= 2` excluded this entire family while
/// the meaningful collapse signals (long same-letter run +
/// `scalarCount * 3 < rawCount` collapse ratio) already identified them
/// as pathological.
///
/// Reproduction inputs:
///
/// | Input               | Buffer chars | Rank-0 surface | Surface scalars | Ratio |
/// |---------------------|--------------|----------------|-----------------|-------|
/// | `thaaaaaa`          | 8            | `သအ`           | 2               | 4.0×  |
/// | `khaaaaaa`          | 8            | `ခအ`           | 2               | 4.0×  |
/// | `khaaaaaaa`         | 9            | `ခအ`           | 2               | 4.5×  |
/// | `ngaaaaaa`          | 8            | `ငအ`           | 2               | 4.0×  |
/// | `myaaaaaa`          | 8            | `မြအ`          | 3               | 2.7×  |
/// | `kyaaaaaa`          | 8            | `ကျအ`          | 3               | 2.7×  |
/// | `mnyaaaaa`          | 8            | `မညအ`          | 3               | 2.7×  |
/// | `mngaaaaa`          | 8            | `မငအ`          | 3               | 2.7×  |
/// | `akhaaaaa`          | 8            | `အခအ`          | 3               | 2.7×  |
/// | `tha+a+a+a+a+a+a+a` | 17           | `သအ`           | 2               | 8.5×  |
///
/// Carve-outs (must NOT change behaviour from TASK-047):
///   - `kbbbbbbbbb` — lossless 1:1, literal stays at the bottom.
///   - `kya`, `kac`, `aungc`, `kaakaa` — borderline, ASCII-ratio path.
///   - `mingalarpar`, `kyaung` — real Burmese, never trigger Class B.
///   - `tablet`, `mahabodhi`, `anaconda` — no collapse, no Class B.
///   - `thaaaa` (4-letter run, scalarCount=2 — fails same-letter floor
///     OR collapse ratio; stays out under both gates).
public enum LiteralFallbackPrefixedRepetitionSuite {

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

    /// Reproduction inputs that the pre-fix Class B gate
    /// (`distinctContentChars.count <= 2`) excluded but every other
    /// pathological-collapse signal already identified.
    private static let prefixedRepetitionInputs: [String] = [
        "thaaaaaa",
        "khaaaaaa",
        "khaaaaaaa",
        "ngaaaaaa",
        "myaaaaaa",
        "kyaaaaaa",
        "mnyaaaaa",
        "mngaaaaa",
        "akhaaaaa",
        "tha+a+a+a+a+a+a+a",
    ]

    public static let suite = TestSuite(name: "LiteralFallbackPrefixedRepetition", cases: [

        // Primary regression — buffers with 3+ distinct content
        // characters but a long same-letter run plus extreme
        // collapse must promote the literal to rank 0.
        TestCase("prefixedRepetition_promotesLiteralToRankZero") { ctx in
            let engine = emptyEngine()
            for buffer in prefixedRepetitionInputs {
                let state = engine.update(buffer: buffer, context: [])
                let topSurface = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    topSurface == buffer,
                    buffer,
                    detail: "expected literal '\(buffer)' at rank 0; got '\(topSurface)' [\(hex(topSurface))]; panel=\(surfaces(state.candidates))"
                )
            }
        },

        // De-dup: the promoted literal must appear exactly once.
        TestCase("prefixedRepetition_literalNotDuplicated") { ctx in
            let engine = emptyEngine()
            for buffer in prefixedRepetitionInputs {
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
        // score 0 — promotion only changes its position.
        TestCase("prefixedRepetition_promotedLiteralProperties") { ctx in
            let engine = emptyEngine()
            let state = engine.update(buffer: "thaaaaaa", context: [])
            let literal = state.candidates.first { $0.surface == "thaaaaaa" }
            ctx.assertTrue(literal != nil, "thaaaaaa", detail: "literal not present")
            ctx.assertTrue(
                literal?.source == .grammar,
                "thaaaaaa",
                detail: "expected source=.grammar; got \(String(describing: literal?.source))"
            )
            ctx.assertTrue(
                literal?.score == 0.0,
                "thaaaaaa",
                detail: "expected score=0; got \(String(describing: literal?.score))"
            )
        },

        // TASK-047 carve-out — `kbbbbbbbbb` is a lossless 1:1
        // mapping; no collapse, so Class B does NOT fire even with
        // the relaxed gate. The literal stays at the bottom.
        TestCase("carveOut_kbbbbbbbbb_unchanged") { ctx in
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

        // TASK-047 carve-out — well-behaved short Burmese parses
        // keep their Myanmar-leading rank-0; literal stays at the
        // bottom.
        TestCase("carveOut_wellBehavedMyanmar_unchanged") { ctx in
            let engine = emptyEngine()
            for buffer in ["tablet", "aungc", "kya", "kaakaa"] {
                let state = engine.update(buffer: buffer, context: [])
                let topSurface = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    topSurface != buffer,
                    buffer,
                    detail: "literal must NOT take rank 0; got '\(topSurface)' [\(hex(topSurface))]; panel=\(surfaces(state.candidates))"
                )
            }
        },

        // TASK-047 carve-out — buffers that have ≥3 distinct chars
        // and don't collapse aggressively (`mahabodhi`) must NOT
        // promote the literal. They fail the collapse-ratio gate
        // (`scalarCount * 3 < rawCount` is false) so the relaxed
        // distinct-char ceiling is irrelevant.
        //
        // TASK-068: `anaconda` was previously in this carve-out
        // set, but it contains a lone `c` (between `a` and `o`,
        // not followed by `h`) that the pre-fix parser silently
        // absorbed into a phantom `1021` anchor — the same bug
        // TASK-068 addresses. The lone-`c` makes `anaconda` a
        // bug-class buffer, not a carve-out target, so the new
        // mid-buffer-unsupported-letter promotion path
        // (`class_E_unsupportedLetterMidBuffer`) correctly elevates
        // the literal to rank 0. Test reduced to `mahabodhi`
        // (no unsupported letters) as the regression baseline.
        TestCase("carveOut_nonCollapseBuffers_unchanged") { ctx in
            let engine = emptyEngine()
            for buffer in ["mahabodhi"] {
                let state = engine.update(buffer: buffer, context: [])
                let topSurface = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    topSurface != buffer,
                    buffer,
                    detail: "literal must NOT take rank 0 for non-collapse buffer; got '\(topSurface)' [\(hex(topSurface))]"
                )
            }
        },

        // TASK-047 carve-out — `thaaaa` (4-letter run) sits exactly
        // at the boundary (`maxSameLetterRun = 4 < 5`) and must
        // continue to NOT trigger Class B promotion. This case is
        // the lower bound of the fix.
        TestCase("carveOut_shortRun_thaaaa_unchanged") { ctx in
            let engine = emptyEngine()
            let state = engine.update(buffer: "thaaaa", context: [])
            let topSurface = state.candidates.first?.surface ?? ""
            ctx.assertTrue(
                topSurface != "thaaaa",
                "thaaaa",
                detail: "literal must NOT take rank 0 below same-letter-run floor; got '\(topSurface)' [\(hex(topSurface))]"
            )
        },
    ])
}
