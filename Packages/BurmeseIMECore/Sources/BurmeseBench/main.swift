import Foundation
import BurmeseIMECore

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

// MARK: - JSON I/O

func emitJSON(_ measurements: [Measurement], commit: String?) -> String {
    let frags = measurements.map { $0.jsonFragment() }.joined(separator: ",\n          ")
    let commitField = commit ?? "unknown"
    let date = ISO8601DateFormatter().string(from: Date())
    return """
    {
      "scenarios": [
          \(frags)
      ],
      "meta": {
        "commit": "\(commitField)",
        "date": "\(date)"
      }
    }
    """
}

struct BaselineEntry {
    let scenario: String
    let p95Us: Double
    let p99Us: Double
}

func parseBaseline(_ path: String) -> [BaselineEntry]? {
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let scenarios = json["scenarios"] as? [[String: Any]]
    else { return nil }
    return scenarios.compactMap { s in
        guard let name = s["scenario"] as? String,
              let p95 = s["p95_us"] as? Double,
              let p99 = s["p99_us"] as? Double
        else { return nil }
        return BaselineEntry(scenario: name, p95Us: p95, p99Us: p99)
    }
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

let json = emitJSON(results, commit: currentCommit())

if let path = updatePath {
    try? json.write(toFile: path, atomically: true, encoding: .utf8)
    FileHandle.standardError.write(Data("wrote baseline to \(path)\n".utf8))
    exit(0)
}

if let path = checkPath {
    guard let baseline = parseBaseline(path) else {
        FileHandle.standardError.write(Data("could not read baseline at \(path)\n".utf8))
        exit(2)
    }
    var regressions: [String] = []
    for m in results {
        guard let b = baseline.first(where: { $0.scenario == m.scenario }) else { continue }
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
    if !regressions.isEmpty {
        FileHandle.standardError.write(Data("\nREGRESSIONS:\n".utf8))
        for r in regressions {
            FileHandle.standardError.write(Data("  \(r)\n".utf8))
        }
        exit(1)
    }
    FileHandle.standardError.write(Data("no regressions\n".utf8))
    exit(0)
}

print(json)
