import Foundation
import BurmeseIMECore
import BurmeseIMETestSupport

// MARK: - Scenarios

struct Scenario {
    let name: String
    let kind: Kind
    let iterations: Int

    enum Kind {
        /// Same buffer rendered `iterations` times with a fresh engine each
        /// run — measures cold-path parse + rank cost.
        case fullBuffer(String)
        /// `buffer` typed one character at a time; each per-keystroke call is
        /// one sample. `iterations` is clamped to `buffer.count`.
        case incremental(String)
    }
}

let scenarios: [Scenario] = [
    Scenario(name: "short", kind: .fullBuffer("mingal"), iterations: 1000),
    Scenario(name: "medium", kind: .fullBuffer("mingalarpar"), iterations: 1000),
    Scenario(name: "long", kind: .fullBuffer("mingalarparshinbyarthwarmaylay"), iterations: 500),
    Scenario(name: "incremental",
             kind: .incremental("mingalarparshinbyarthwarmaylaynaykaun"),
             iterations: 500),
    // Keyboard-bashing: long stream of characters that don't form legal
    // syllables. Guards against pathological fallthrough paths — the DP
    // must not blow up on junk input.
    Scenario(name: "garbage",
             kind: .fullBuffer("jeiowfgneiorngieorndmfsoigjeiorngieorjgjerogijeqoprjgpojergpoj"),
             iterations: 200),
    Scenario(name: "garbage_incremental",
             kind: .incremental("jeiowfgneiorngieorndmfsoigjeiorngieorjgjerogijeqoprjgpojergpoj"),
             iterations: 500),
    // TASK-013: pathological repeated-letter buffer. Letters whose
    // romanization key participates in many onset/vowel rules
    // (`t`, `k`, `s`, `d`, `m`, `n`, `p`) produce a dense DP beam
    // at every column when repeated; without aggressive duplicate-
    // state collapse the per-keystroke latency grows super-linearly
    // with buffer length. This scenario locks in the budget for
    // 16-`t` buffers, the worst-case shape from the task's
    // reproduction table.
    Scenario(name: "repetition_t16",
             kind: .fullBuffer(String(repeating: "t", count: 16)),
             iterations: 200),
    // TASK-013: long `+`-chain (10 segments × 3 chars = 30 chars).
    // The TASK-011 reshape collapses each `<C>a+<C>` to `<C>+<C>a`
    // so the chain rarely materialises a deep DP, but the scenario
    // still locks in the budget for adversarial input.
    Scenario(name: "plus_chain_30",
             kind: .fullBuffer(String(repeating: "ka+", count: 10)),
             iterations: 200),
    // TASK-042: repeated cluster-alias letter `j`. The `j` alias
    // expands to `ka` + medial-ya (`gya`/`jya`) which contributes
    // multiple competing parses per position, so the DP beam grows
    // super-linearly with buffer length. 16 chars is a representative
    // adversarial shape from real fuzz / accidental key-repeat input.
    Scenario(name: "cluster_alias_j16",
             kind: .fullBuffer(String(repeating: "j", count: 16)),
             iterations: 200),
    // TASK-042: repeated 3-char syllable past the windowing threshold
    // (`compositionWindowSize = 18`). 30 repetitions of `tha` is a
    // 90-char buffer — every keystroke past the threshold pays
    // active-tail-only DP cost. The scenario locks in the budget for
    // long incremental sessions.
    Scenario(name: "repetition_tha30",
             kind: .fullBuffer(String(repeating: "tha", count: 30)),
             iterations: 200),
    // TASK-051: repeated nga-asat-emitting vowel rules. Each `aing`,
    // `aung`, `in` rule feeds the implicit-stack inference scan
    // (`inferImplicitStackMarkers`) which in turn drives up to three
    // parser passes per keystroke (full / strict-only / promotable-
    // only siblings). Without per-onset memoisation the cost
    // compounds super-linearly with the number of vowel-rule sites
    // in the active tail. These three scenarios lock in a
    // post-fix budget on the worst-case shapes.
    Scenario(name: "vowel_rule_chain_aing_8",
             kind: .fullBuffer(String(repeating: "aing", count: 8)),
             iterations: 200),
    // Slope-control sibling for `vowel_rule_chain_aing_8`. The
    // TASK-051 acceptance criterion is `aing × 8` p50 ≤ 4 ×
    // `aing × 4` p50, so this scenario locks in the linear-or-better
    // scaling that the fix preserves. Pre-fix the ratio was ~7×
    // and growing.
    Scenario(name: "vowel_rule_chain_aing_4",
             kind: .fullBuffer(String(repeating: "aing", count: 4)),
             iterations: 200),
    // No-regression floor sibling. The TASK-051 acceptance criterion
    // requires `aing × 2` post-fix p50 to stay within 25% of the
    // pre-fix number, so a fix that flattens the steep tail by
    // adding constant-factor overhead to short inputs is rejected.
    Scenario(name: "vowel_rule_chain_aing_2",
             kind: .fullBuffer(String(repeating: "aing", count: 2)),
             iterations: 200),
    Scenario(name: "vowel_rule_chain_aung_8",
             kind: .fullBuffer(String(repeating: "aung", count: 8)),
             iterations: 200),
    Scenario(name: "vowel_rule_chain_in_10",
             kind: .fullBuffer(String(repeating: "in", count: 10)),
             iterations: 200),
]

// MARK: - Timing

@inline(__always)
func nowNanos() -> UInt64 {
    #if canImport(Darwin)
    return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    #else
    return UInt64(DispatchTime.now().uptimeNanoseconds)
    #endif
}

// MARK: - Measurement

struct Measurement {
    let scenario: String
    let iterations: Int
    let p50Us: Double
    let p95Us: Double
    let p99Us: Double
    let maxUs: Double
    let allocations: Int

    func jsonFragment() -> String {
        """
        {
            "scenario": "\(scenario)",
            "iterations": \(iterations),
            "p50_us": \(String(format: "%.2f", p50Us)),
            "p95_us": \(String(format: "%.2f", p95Us)),
            "p99_us": \(String(format: "%.2f", p99Us)),
            "max_us": \(String(format: "%.2f", maxUs)),
            "allocations": \(allocations)
          }
        """
    }
}

func percentile(_ sorted: [UInt64], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = min(sorted.count - 1, Int(Double(sorted.count - 1) * p))
    return Double(sorted[idx]) / 1000.0
}

func runScenario(_ s: Scenario) -> Measurement {
    // Warm-up: 50 iterations discarded.
    let warmup = 50
    let engine = BurmeseEngine()

    switch s.kind {
    case .fullBuffer(let buf):
        for _ in 0..<warmup { _ = engine.update(buffer: buf, context: []) }
    case .incremental(let buf):
        for _ in 0..<warmup {
            for i in 1...buf.count {
                _ = engine.update(buffer: String(buf.prefix(i)), context: [])
            }
        }
    }

    // Three passes, pick the middle distribution (median of three by p95).
    func singlePass() -> [UInt64] {
        let engine = BurmeseEngine()
        var samples: [UInt64] = []
        switch s.kind {
        case .fullBuffer(let buf):
            samples.reserveCapacity(s.iterations)
            for _ in 0..<s.iterations {
                let t0 = nowNanos()
                _ = engine.update(buffer: buf, context: [])
                let t1 = nowNanos()
                samples.append(t1 - t0)
            }
        case .incremental(let buf):
            let chars = buf.count
            let runs = max(1, s.iterations / chars)
            samples.reserveCapacity(runs * chars)
            for _ in 0..<runs {
                let engine = BurmeseEngine()
                for i in 1...chars {
                    let prefix = String(buf.prefix(i))
                    let t0 = nowNanos()
                    _ = engine.update(buffer: prefix, context: [])
                    let t1 = nowNanos()
                    samples.append(t1 - t0)
                }
            }
        }
        samples.sort()
        return samples
    }

    let runs = [singlePass(), singlePass(), singlePass()]
    let p95s = runs.map { percentile($0, 0.95) }
    let middleIdx = Array(0..<3).sorted(by: { p95s[$0] < p95s[$1] })[1]
    let sorted = runs[middleIdx]

    return Measurement(
        scenario: s.name,
        iterations: sorted.count,
        p50Us: percentile(sorted, 0.50),
        p95Us: percentile(sorted, 0.95),
        p99Us: percentile(sorted, 0.99),
        maxUs: Double(sorted.last ?? 0) / 1000.0,
        allocations: 0
    )
}

// MARK: - Platform detection

/// Per-host baseline key. The bench gate is meaningless across hosts
/// (Apple Silicon vs. x86_64 Linux differ by 1.4–2.4× on every
/// scenario), so each shipping platform has its own baseline section
/// and `--check` only compares against the matching host (TASK-040).
let currentPlatformKey: String = BenchBaselineFormat.currentPlatformKey

// MARK: - JSON I/O

func emitJSON(
    _ measurements: [Measurement],
    commit: String?,
    existingDocument: [String: Any]? = nil
) -> String {
    let frags = measurements.map { $0.jsonFragment() }.joined(separator: ",\n          ")
    let commitField = commit ?? "unknown"
    let date = ISO8601DateFormatter().string(from: Date())
    let sectionBody = """
        "scenarios": [
            \(frags)
        ],
        "meta": {
          "commit": "\(commitField)",
          "date": "\(date)"
        }
    """
    var platformSections: [String: String] = [:]
    // Preserve every other platform's section so a `--update` on Linux
    // doesn't drop the macOS baseline (and vice versa). We only
    // re-emit the section for `currentPlatformKey`.
    if let existing = existingDocument,
       let platforms = existing["platforms"] as? [String: Any] {
        for (platform, raw) in platforms where platform != currentPlatformKey {
            guard let dict = raw as? [String: Any] else { continue }
            if let serialized = try? JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            ),
               let pretty = String(data: serialized, encoding: .utf8) {
                platformSections[platform] = pretty
            }
        }
    }
    platformSections[currentPlatformKey] = "{\n    \(sectionBody)\n  }"
    let platformBlocks = platformSections
        .keys
        .sorted()
        .map { key in
            "    \"\(key)\": \(platformSections[key] ?? "{}")"
        }
        .joined(separator: ",\n")
    return """
    {
      "platforms": {
    \(platformBlocks)
      }
    }
    """
}

typealias BaselineEntry = BenchBaselineFormat.ScenarioEntry

/// Parse a baseline JSON document. Supports both the original
/// flat schema (`{"scenarios": [...], "meta": {...}}`) and the
/// per-platform schema introduced in TASK-040
/// (`{"platforms": {"linux": {...}, "macos": {...}}}`). When the
/// document is in per-platform form, only the `platformKey`
/// section is read; if the section is missing, returns `nil` so
/// `--check` can surface a clear error rather than silently
/// passing on a host that has no baseline yet.
func parseBaseline(_ path: String, platformKey: String) -> [BaselineEntry]? {
    return BenchBaselineFormat.entries(atPath: path, platformKey: platformKey)
}

/// Read an existing baseline document so `--update` can preserve
/// per-platform sections that are not the current host. Returns
/// nil when the file is missing or unreadable.
func readBaselineDocument(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json
}

// MARK: - Git commit

func currentCommit() -> String? {
    let pipe = Pipe()
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = ["git", "rev-parse", "--short", "HEAD"]
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - CLI

func usage() -> Never {
    let u = """
    Usage: burmese-bench [options]
      --check PATH       Compare against baseline; exit 1 on regression
      --update PATH      Write current results to baseline path
      --scenario NAME    Run a single scenario (short|medium|long|incremental)
    """
    FileHandle.standardError.write(Data(u.utf8))
    exit(2)
}

var checkPath: String?
var updatePath: String?
var singleScenario: String?

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--check":
        guard let v = args.first else { usage() }
        args.removeFirst()
        checkPath = v
    case "--update":
        guard let v = args.first else { usage() }
        args.removeFirst()
        updatePath = v
    case "--scenario":
        guard let v = args.first else { usage() }
        args.removeFirst()
        singleScenario = v
    case "-h", "--help":
        usage()
    default:
        FileHandle.standardError.write(Data("unknown arg: \(arg)\n".utf8))
        usage()
    }
}

let toRun: [Scenario]
if let name = singleScenario {
    toRun = scenarios.filter { $0.name == name }
    if toRun.isEmpty {
        FileHandle.standardError.write(Data("no such scenario: \(name)\n".utf8))
        exit(2)
    }
} else {
    toRun = scenarios
}

FileHandle.standardError.write(Data("Running \(toRun.count) scenario(s)...\n".utf8))
var results: [Measurement] = []
for s in toRun {
    FileHandle.standardError.write(Data("  \(s.name)... ".utf8))
    let m = runScenario(s)
    FileHandle.standardError.write(Data(
        "p50=\(String(format: "%.1f", m.p50Us))us p95=\(String(format: "%.1f", m.p95Us))us p99=\(String(format: "%.1f", m.p99Us))us\n".utf8
    ))
    results.append(m)
}

let updateExisting = updatePath.flatMap { readBaselineDocument($0) }
let json = emitJSON(results, commit: currentCommit(), existingDocument: updateExisting)

if let path = updatePath {
    try? json.write(toFile: path, atomically: true, encoding: .utf8)
    FileHandle.standardError.write(Data(
        "wrote \(currentPlatformKey) baseline to \(path)\n".utf8
    ))
    exit(0)
}

if let path = checkPath {
    guard let baseline = parseBaseline(path, platformKey: currentPlatformKey) else {
        FileHandle.standardError.write(Data(
            "could not read \(currentPlatformKey) baseline at \(path) — run `--update` to capture one\n".utf8
        ))
        exit(2)
    }
    var regressions: [String] = []
    var missingFromBaseline: [String] = []
    for m in results {
        guard let b = baseline.first(where: { $0.scenario == m.scenario }) else {
            // TASK-061: surface the missing-scenario case loudly
            // rather than silently skipping. A scenario added to
            // the bench code but never captured in the running
            // platform's baseline section was previously ignored
            // here, so per-platform regressions in newly-added
            // scenarios went uncaught until a contributor on
            // another host ran `--check`.
            missingFromBaseline.append(m.scenario)
            continue
        }
        if b.isPlaceholder {
            // TASK-061 (gap fix): a placeholder entry exists in the
            // JSON only to satisfy the cross-platform drift guard
            // (scenario name parity). Its p95/p99 numbers are
            // inherited from another host and have no calibration
            // value here. Treat it identically to an absent entry
            // so the gate surfaces the gap rather than silently
            // false-negativing against synthetic numbers.
            missingFromBaseline.append(m.scenario)
            continue
        }
        let p95Bound = b.p95Us * 1.20
        let p99Bound = b.p99Us * 1.30
        if m.p95Us > p95Bound {
            regressions.append("\(m.scenario) p95: \(String(format: "%.1f", m.p95Us))us > baseline*1.20 = \(String(format: "%.1f", p95Bound))us")
        }
        if m.p99Us > p99Bound {
            regressions.append("\(m.scenario) p99: \(String(format: "%.1f", m.p99Us))us > baseline*1.30 = \(String(format: "%.1f", p99Bound))us")
        }
    }
    print(json)
    if !missingFromBaseline.isEmpty {
        FileHandle.standardError.write(Data(
            "\nMISSING FROM \(currentPlatformKey) BASELINE:\n".utf8
        ))
        for s in missingFromBaseline {
            FileHandle.standardError.write(Data("  \(s)\n".utf8))
        }
        FileHandle.standardError.write(Data(
            "  → run `swift run -c release BurmeseBench --update \(path)` on \(currentPlatformKey) to capture them\n".utf8
        ))
    }
    if !regressions.isEmpty {
        FileHandle.standardError.write(Data("\nREGRESSIONS:\n".utf8))
        for r in regressions {
            FileHandle.standardError.write(Data("  \(r)\n".utf8))
        }
        exit(1)
    }
    if !missingFromBaseline.isEmpty {
        // Treat missing baseline entries as a gate failure so
        // the per-platform baseline-drift bug TASK-061 documents
        // can no longer hide silently. Same exit code as a real
        // regression so CI lanes that only check the exit status
        // still surface the issue.
        exit(1)
    }
    FileHandle.standardError.write(Data("no regressions\n".utf8))
    exit(0)
}

print(json)
