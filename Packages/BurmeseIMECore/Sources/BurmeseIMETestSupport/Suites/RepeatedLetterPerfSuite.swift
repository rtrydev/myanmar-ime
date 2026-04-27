import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-013: per-keystroke latency on highly redundant
/// buffers (`tttttttttt…`, `ka+ka+ka+…`) must stay within a generous
/// hard cap so the IME never freezes for tens of milliseconds when
/// the user pastes non-Burmese text or holds down a key.
///
/// The wall-clock cap is intentionally generous (300 ms in debug,
/// 100 ms equivalent in release): the goal is to detect catastrophic
/// regressions, not to track baseline drift. Use the
/// `BurmeseBench --check` regression test for tight perf budgets.
public enum RepeatedLetterPerfSuite {

    private static func measureMs(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000.0
            + Double(elapsed.components.attoseconds) / 1e15
    }

    public static let suite = TestSuite(name: "RepeatedLetterPerf", cases: [

        // 16-`t` buffer must complete a single update call within
        // a generous wall-clock budget. The pre-fix latency was
        // ~35 ms in debug; post-fix should be well under 100 ms
        // even on slow CI hardware.
        TestCase("repetitionT16_underHardCap") { ctx in
            let engine = BurmeseEngine()
            let buffer = String(repeating: "t", count: 16)
            // Warmup once so the first-call cache misses don't
            // dominate.
            _ = engine.update(buffer: buffer, context: [])
            let elapsed = measureMs {
                _ = engine.update(buffer: buffer, context: [])
            }
            ctx.assertTrue(
                elapsed < 300.0,
                "t*16",
                detail: "elapsed=\(String(format: "%.2f", elapsed)) ms (cap=300 ms)"
            )
        },

        // 30-char `+`-chain ditto.
        TestCase("plusChain30_underHardCap") { ctx in
            let engine = BurmeseEngine()
            let buffer = String(repeating: "ka+", count: 10)
            _ = engine.update(buffer: buffer, context: [])
            let elapsed = measureMs {
                _ = engine.update(buffer: buffer, context: [])
            }
            ctx.assertTrue(
                elapsed < 300.0,
                "(ka+)*10",
                detail: "elapsed=\(String(format: "%.2f", elapsed)) ms (cap=300 ms)"
            )
        },

        // Buffer length 1..16 of `t` must remain monotonically
        // bounded — no length should trigger an order-of-magnitude
        // jump. A naive 6-`t` parse is fast (~0.5 ms); 16-`t` should
        // not exceed 30× of 6-`t`.
        TestCase("repetitionT_growthIsBounded") { ctx in
            let engine = BurmeseEngine()
            let baselineBuf = String(repeating: "t", count: 6)
            // Warmup
            _ = engine.update(buffer: baselineBuf, context: [])
            let baseline = measureMs {
                for _ in 0..<5 {
                    _ = engine.update(buffer: baselineBuf, context: [])
                }
            } / 5.0
            let bigBuf = String(repeating: "t", count: 16)
            _ = engine.update(buffer: bigBuf, context: [])
            let bigCost = measureMs {
                for _ in 0..<5 {
                    _ = engine.update(buffer: bigBuf, context: [])
                }
            } / 5.0
            // Generous cap: 16-`t` should be at most 30× the cost of
            // 6-`t`. Pre-fix the ratio was ~70× (debug) / ~50× (rel).
            // Post-fix it should be ~5-10×.
            ctx.assertTrue(
                bigCost < baseline * 30.0 + 50.0,
                "growthRatio",
                detail: "baseline(6t)=\(String(format: "%.2f", baseline)) ms, big(16t)=\(String(format: "%.2f", bigCost)) ms"
            )
        },
    ])
}
