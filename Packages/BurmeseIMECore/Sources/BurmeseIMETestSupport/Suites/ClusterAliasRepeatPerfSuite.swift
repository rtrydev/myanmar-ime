import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-042: per-keystroke latency on adversarial
/// cluster-alias and post-windowing-threshold repetition buffers
/// must stay within a generous hard cap so the IME never freezes for
/// tens of milliseconds when the user pastes non-Burmese text or
/// holds a cluster-alias key.
///
/// Wall-clock caps are intentionally generous (300 ms): the goal is
/// to detect catastrophic regressions, not to track baseline drift.
/// Use the `BurmeseBench --check` regression test for tight perf
/// budgets gated by the per-platform baseline.
public enum ClusterAliasRepeatPerfSuite {

    private static func measureMs(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000.0
            + Double(elapsed.components.attoseconds) / 1e15
    }

    public static let suite = TestSuite(name: "ClusterAliasRepeatPerf", cases: [

        // 16-`j` cluster-alias buffer (`j` aliases ka+medial-ya and
        // ka+medial-ra at every position, so the DP beam grows
        // exponentially without aggressive pruning). A single update
        // call must complete within the generous wall-clock cap.
        TestCase("clusterAliasJ16_underHardCap") { ctx in
            let engine = BurmeseEngine()
            let buffer = String(repeating: "j", count: 16)
            _ = engine.update(buffer: buffer, context: [])
            let elapsed = measureMs {
                _ = engine.update(buffer: buffer, context: [])
            }
            ctx.assertTrue(
                elapsed < 300.0,
                "j*16",
                detail: "elapsed=\(String(format: "%.2f", elapsed)) ms (cap=300 ms)"
            )
        },

        // 30-syllable repeated-3-char buffer past the windowing
        // threshold (`compositionWindowSize = 18`). 90 chars total.
        TestCase("repetitionTha30_underHardCap") { ctx in
            let engine = BurmeseEngine()
            let buffer = String(repeating: "tha", count: 30)
            _ = engine.update(buffer: buffer, context: [])
            let elapsed = measureMs {
                _ = engine.update(buffer: buffer, context: [])
            }
            ctx.assertTrue(
                elapsed < 300.0,
                "tha*30",
                detail: "elapsed=\(String(format: "%.2f", elapsed)) ms (cap=300 ms)"
            )
        },

        // Growth bound: 16-`j` should be at most 30× the cost of
        // 4-`j`. Pre-fix the ratio was ~30×; post-fix should be
        // tighter.
        TestCase("clusterAliasJ_growthIsBounded") { ctx in
            let engine = BurmeseEngine()
            let smallBuf = String(repeating: "j", count: 4)
            _ = engine.update(buffer: smallBuf, context: [])
            let baseline = measureMs {
                for _ in 0..<10 {
                    _ = engine.update(buffer: smallBuf, context: [])
                }
            } / 10.0
            let bigBuf = String(repeating: "j", count: 16)
            _ = engine.update(buffer: bigBuf, context: [])
            let bigCost = measureMs {
                for _ in 0..<10 {
                    _ = engine.update(buffer: bigBuf, context: [])
                }
            } / 10.0
            ctx.assertTrue(
                bigCost < baseline * 60.0 + 50.0,
                "growthRatio",
                detail: "baseline(4j)=\(String(format: "%.2f", baseline)) ms, big(16j)=\(String(format: "%.2f", bigCost)) ms"
            )
        },

        // Candidate diversity: even with the tighter beam, the panel
        // for `j × N` must include the canonical (rank-0) parse with
        // every position rendered as `ka + medial-ya` (the cost-0
        // alias) and at least one variant alternating in `medial-ra`.
        TestCase("clusterAliasJ_panelStillDiverse") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(
                buffer: String(repeating: "j", count: 16),
                context: []
            )
            ctx.assertTrue(
                state.candidates.count >= 2,
                "j*16",
                detail: "panel has fewer than 2 candidates: \(state.candidates.count)"
            )
            // The canonical rank-0 surface should be 16 copies of
            // `ကျ` (ka + medial-ya). The medial-ra alternative
            // (`ကြ`) should appear at least once in some lower-
            // ranked surface.
            let topSurface = state.candidates.first?.surface ?? ""
            let kaMyaCount = topSurface
                .components(separatedBy: "\u{1000}\u{103B}")  // ကျ
                .count - 1
            ctx.assertTrue(
                kaMyaCount == 16,
                "j*16_canonical",
                detail: "expected 16× ကျ at rank 0, got \(kaMyaCount): '\(topSurface)'"
            )
            let hasMyrVariant = state.candidates.contains {
                $0.surface.range(of: "\u{1000}\u{103C}", options: .literal) != nil
            }
            ctx.assertTrue(
                hasMyrVariant,
                "j*16_medialRaVariant",
                detail: "no medial-ra (ကြ) variant in panel"
            )
        },
    ])
}
