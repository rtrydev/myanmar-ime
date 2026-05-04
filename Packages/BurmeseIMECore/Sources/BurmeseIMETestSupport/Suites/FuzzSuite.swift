import Foundation
import BurmeseIMECore

/// Budget-capped fuzz runner. Reads `FUZZ_BUDGET_MS` from the environment
/// (default 1000ms). Runs random buffers through the engine and checks a set
/// of invariants until the wall-clock budget is exhausted. Pinned seed is
/// logged in the summary so any failure is reproducible.
public enum FuzzSuite {

    private static var budgetMs: Int {
        if let raw = ProcessInfo.processInfo.environment["FUZZ_BUDGET_MS"],
           let v = Int(raw) {
            return max(50, v)
        }
        return 1000
    }

    private static func stripInvisibles(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.value != 0x200B && $0.value != 0x200C })
    }

    /// True iff `surface` has a Latin letter that appears *before* the last
    /// Myanmar character — i.e., Latin interleaved with a composed run.
    /// Trailing literal tail is allowed.
    private static func hasInterleavedLatin(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        var lastMyanmarIdx = -1
        for (i, s) in scalars.enumerated()
        where s.value >= 0x1000 && s.value <= 0x109F {
            lastMyanmarIdx = i
        }
        guard lastMyanmarIdx >= 0 else { return false }
        for i in 0..<lastMyanmarIdx {
            let v = scalars[i].value
            if v < 0x80 && (v >= 0x41 && v <= 0x7A) {
                return true
            }
        }
        return false
    }

    /// TASK-052: `<digit>` (ASCII or Myanmar) immediately followed by
    /// U+103A (asat) — the asat needs a consonant base on its left,
    /// which digits never provide. Either direct adjacency or the
    /// indirect `<digit><1021><103A>` shape (the orphan-mark anchor
    /// injection) signals the bug.
    private static func hasDigitBeforeAsat(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        if scalars.count >= 2 {
            for i in 1..<scalars.count {
                let prev = scalars[i - 1]
                let isDigit = (prev >= 0x30 && prev <= 0x39)
                    || (prev >= 0x1040 && prev <= 0x1049)
                guard isDigit else { continue }
                if scalars[i] == 0x103A { return true }
            }
        }
        if scalars.count >= 3 {
            for i in 2..<scalars.count {
                let prev = scalars[i - 2]
                let isDigit = (prev >= 0x30 && prev <= 0x39)
                    || (prev >= 0x1040 && prev <= 0x1049)
                guard isDigit else { continue }
                if scalars[i - 1] == 0x1021 && scalars[i] == 0x103A { return true }
            }
        }
        return false
    }

    /// Alphabet used by the digit-asat fuzz case. Includes `*` and
    /// digits (which `BurmeseGenerators.composingAlphabet` excludes by
    /// design — it targets composable letter chains). Same letter set
    /// otherwise so the engine sees realistic ASCII context around
    /// each `*`.
    private static let digitAsatAlphabet: [Character] =
        Array("abcdefghijklmnopqrstuvwxyz0123456789*+:.")

    public static let suite = TestSuite(name: "Fuzz", cases: [

        TestCase("fuzz_randomBuffers_noCrashOrLeakage") { ctx in
            let seed: UInt64 = 0xF00D_BABE_DEAD_BEEF
            var rng = SeededRandom(seed: seed)
            let engine = BurmeseEngine()
            let deadline = Date().addingTimeInterval(Double(budgetMs) / 1000.0)
            var iterations = 0
            var failures = 0
            var firstFailure: String?

            while Date() < deadline {
                let len = Int(rng.next() % 32) + 1
                let buffer = BurmeseGenerators.randomBuffer(length: len, rng: &rng)
                let state = engine.update(buffer: buffer, context: [])
                // Invariant A: rawBuffer preserved verbatim.
                if state.rawBuffer != buffer {
                    failures += 1
                    if firstFailure == nil {
                        firstFailure =
                            "rawBufferDrift seed=\(String(seed, radix: 16)) buf=\(buffer) raw=\(state.rawBuffer)"
                    }
                    break
                }
                // Invariant B: no Latin interleaved inside a Myanmar run.
                for cand in state.candidates where hasInterleavedLatin(cand.surface) {
                    failures += 1
                    if firstFailure == nil {
                        firstFailure =
                            "latinInterleaved seed=\(String(seed, radix: 16)) buf=\(buffer) surface=\(cand.surface) source=\(cand.source)"
                    }
                    break
                }
                if firstFailure != nil { break }
                iterations += 1
            }
            ctx.assertEqual(failures, 0,
                            "fuzzInvariants_iters=\(iterations)_\(firstFailure ?? "ok")")
        },

        // TASK-052: budget-capped fuzz over an alphabet that includes
        // digits and `*` so a future regression that reintroduces the
        // `<digit>(1021)?103A` shape on a novel buffer surfaces here.
        TestCase("fuzz_noDigitBeforeAsat_acrossSources") { ctx in
            let seed: UInt64 = 0xD162_A5A7_8FAC_5252
            var rng = SeededRandom(seed: seed)
            let engine = BurmeseEngine()
            let deadline = Date().addingTimeInterval(Double(budgetMs) / 1000.0)
            var iterations = 0
            var failures = 0
            var firstFailure: String?
            while Date() < deadline {
                let len = Int(rng.next() % 24) + 1
                var chars: [Character] = []
                chars.reserveCapacity(len)
                for _ in 0..<len { chars.append(rng.pick(digitAsatAlphabet)) }
                let buffer = String(chars)
                let state = engine.update(buffer: buffer, context: [])
                for cand in state.candidates where hasDigitBeforeAsat(cand.surface) {
                    failures += 1
                    if firstFailure == nil {
                        firstFailure =
                            "digitBeforeAsat seed=\(String(seed, radix: 16)) buf=\(buffer) surface=\(cand.surface) source=\(cand.source)"
                    }
                    break
                }
                if firstFailure != nil { break }
                iterations += 1
            }
            ctx.assertEqual(failures, 0,
                            "digitAsatFuzz_iters=\(iterations)_\(firstFailure ?? "ok")")
        },

        TestCase("fuzz_incrementalTyping_stable") { ctx in
            let seed: UInt64 = 0x0BAD_CAFE_F00D_1234
            var rng = SeededRandom(seed: seed)
            let deadline = Date().addingTimeInterval(Double(budgetMs) / 1000.0)
            var iterations = 0
            var failures = 0
            var firstFailure: String?

            while Date() < deadline {
                let len = Int(rng.next() % 16) + 2
                let buffer = BurmeseGenerators.randomBuffer(length: len, rng: &rng)
                let engine = BurmeseEngine()
                // Type the buffer one char at a time; each call must return a
                // state whose rawBuffer equals the typed prefix.
                var drift = false
                for i in 1...buffer.count {
                    let prefix = String(buffer.prefix(i))
                    let state = engine.update(buffer: prefix, context: [])
                    if state.rawBuffer != prefix {
                        drift = true
                        if firstFailure == nil {
                            firstFailure =
                                "seed=\(String(seed, radix: 16)) buf=\(buffer) atLen=\(i) raw=\(state.rawBuffer)"
                        }
                        break
                    }
                }
                if drift {
                    failures += 1
                    break
                }
                iterations += 1
            }
            ctx.assertEqual(failures, 0,
                            "incrementalTyping_iters=\(iterations)_\(firstFailure ?? "ok")")
        },
    ])
}
