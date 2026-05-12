import Foundation
import BurmeseIMECore
import BurmeseIMETestSupport

// MARK: - Scenarios

struct Scenario {
    let name: String
    let kind: Kind
    let iterations: Int
    let profile: Profile

    enum Kind {
        /// Same buffer rendered `iterations` times with a fresh engine each
        /// run — measures cold-path parse + rank cost.
        case fullBuffer(String)
        /// `buffer` typed one character at a time; each per-keystroke call is
        /// one sample. `iterations` is clamped to `buffer.count`.
        case incremental(String)
    }

    /// Engine construction shape exercised by the scenario. `bare` is the
    /// parser-only fast path; `prod` loads the bundled `BurmeseLexicon.sqlite`
    /// + `BurmeseLM.bin` and a fresh tempfile-backed `UserHistoryStore`, so
    /// per-keystroke regressions in lexicon prefix-scan / LM scoring / history
    /// merge land on the gate. `prod` scenarios skip cleanly when the bundled
    /// artifacts are absent (fresh checkout, no `LexiconBuilder` run yet).
    enum Profile: Equatable {
        case bare
        case prod
    }

    init(name: String, kind: Kind, iterations: Int, profile: Profile = .bare) {
        self.name = name
        self.kind = kind
        self.iterations = iterations
        self.profile = profile
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

    // TASK-077: production-equivalent scenarios. Each one constructs a
    // `BurmeseEngine` with the bundled `BurmeseLexicon.sqlite` +
    // `BurmeseLM.bin` and a fresh tempfile-backed `SQLiteUserHistoryStore`
    // so the lexicon prefix-scan, LM scoring, and history-merge code
    // paths are in the hot loop — the same shape the macOS IMK and Linux
    // IBus engines run. `BundledArtifacts` is `nil`-safe; the runner
    // skips these scenarios cleanly on a fresh checkout where the
    // lexicon / LM artifacts have not been built yet.
    Scenario(name: "short_prod",
             kind: .fullBuffer("mingal"),
             iterations: 1000,
             profile: .prod),
    Scenario(name: "medium_prod",
             kind: .fullBuffer("mingalarpar"),
             iterations: 1000,
             profile: .prod),
    Scenario(name: "long_prod",
             kind: .fullBuffer("mingalarparshinbyarthwarmaylay"),
             iterations: 500,
             profile: .prod),
    Scenario(name: "incremental_prod",
             kind: .incremental("mingalarparshinbyarthwarmaylaynaykaun"),
             iterations: 500,
             profile: .prod),
    // Bash-string keyboard-bashing under the full stack. Lexicon is
    // all-miss but the LM still scores every parser-emitted sibling,
    // so this scenario surfaces LM scoring / fallback ranking
    // regressions a bare-engine bench can't see.
    Scenario(name: "garbage_incremental_prod",
             kind: .incremental("jeiowfgneiorngieorndmfsoigjeiorngieorjgjerogijeqoprjgpojergpoj"),
             iterations: 500,
             profile: .prod),
    // Worst-case bare-engine scenario reshaped under the full stack —
    // sets the realistic per-keystroke ceiling the user could hit.
    Scenario(name: "vowel_rule_chain_in_10_prod",
             kind: .fullBuffer(String(repeating: "in", count: 10)),
             iterations: 200,
             profile: .prod),
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

/// Cached production-engine artifact paths. Resolving the bundled
/// lexicon + LM via `BundledArtifacts` is `nil`-safe — when either
/// artifact is missing on the running host, every `prod` scenario
/// skips cleanly with exit code 0 (same pattern the bundled-data
/// test suites use). The paths are computed once at process start
/// so a fresh-checkout sweep doesn't repeat the disk probe per
/// scenario.
let bundledLexiconPath: String? = BundledArtifacts.lexiconPath
let bundledTrigramLMPath: String? = BundledArtifacts.trigramLMPath
let productionArtifactsAvailable: Bool =
    bundledLexiconPath != nil && bundledTrigramLMPath != nil

/// Per-bench-run scratch directory for the production `SQLiteUserHistoryStore`.
/// Created lazily on first use and removed at process exit so a
/// `BurmeseBench` run can never accidentally read from or write to the
/// user's real `~/Library/Application Support/.../UserHistory.sqlite`.
let benchHistoryTempDir: URL = {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("BurmeseBench-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    atexit_b {
        try? FileManager.default.removeItem(at: dir)
    }
    return dir
}()

/// Construct an engine for `profile`. For `.bare`, returns the parser-only
/// configuration used by the original scenarios. For `.prod`, returns an
/// engine wired with the bundled lexicon, the bundled trigram LM, and a
/// fresh tempfile-backed `SQLiteUserHistoryStore`. Returns `nil` when
/// `profile == .prod` but the bundled artifacts are missing — callers
/// should treat that as "skip this scenario".
func makeEngine(profile: Scenario.Profile) -> BurmeseEngine? {
    switch profile {
    case .bare:
        return BurmeseEngine()
    case .prod:
        guard let lexPath = bundledLexiconPath,
              let lmPath = bundledTrigramLMPath,
              let store = SQLiteCandidateStore(path: lexPath),
              let lm = try? TrigramLanguageModel(path: lmPath)
        else { return nil }
        // Fresh per-engine tempfile so concurrent / repeated `--samples`
        // runs don't fight over the same history DB and so we never
        // touch the user's real history file. The temp DB is opened
        // empty; the production code path that records new history is
        // not exercised by `bench.update(...)` reads, so the file
        // stays empty for the lifetime of the bench process.
        let historyURL = benchHistoryTempDir
            .appendingPathComponent("UserHistory-\(UUID().uuidString).sqlite")
        let historyStore: any UserHistoryStore =
            SQLiteUserHistoryStore(path: historyURL.path) ?? EmptyUserHistoryStore()
        return BurmeseEngine(
            candidateStore: store,
            historyStore: historyStore,
            languageModel: lm
        )
    }
}

func runScenario(_ s: Scenario) -> Measurement? {
    // Warm-up: 50 iterations discarded.
    let warmup = 50
    guard let engine = makeEngine(profile: s.profile) else { return nil }

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
    func singlePass() -> [UInt64]? {
        guard let engine = makeEngine(profile: s.profile) else { return nil }
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
                guard let engine = makeEngine(profile: s.profile) else { return nil }
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

    guard let p1 = singlePass(), let p2 = singlePass(), let p3 = singlePass()
    else { return nil }
    let runs = [p1, p2, p3]
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
    // TASK-077: `_prod` scenarios skip cleanly when bundled lexicon /
    // LM artifacts are absent. If a scenario was skipped this run but
    // a prior captured number exists in the running platform's
    // section, preserve it verbatim — a partial run on a fresh checkout
    // should NOT wipe valid baseline rows the rest of the fleet
    // relies on. The measured scenarios overwrite, the rest are
    // copied through.
    var preservedFragments: [String] = []
    let measuredNames = Set(measurements.map { $0.scenario })
    if let existing = existingDocument,
       let platforms = existing["platforms"] as? [String: Any],
       let currentSection = platforms[currentPlatformKey] as? [String: Any],
       let priorScenarios = currentSection["scenarios"] as? [[String: Any]] {
        for entry in priorScenarios {
            guard let name = entry["scenario"] as? String,
                  !measuredNames.contains(name)
            else { continue }
            if let serialized = try? JSONSerialization.data(
                withJSONObject: entry,
                options: [.prettyPrinted, .sortedKeys]
            ),
               let pretty = String(data: serialized, encoding: .utf8) {
                preservedFragments.append(pretty)
            }
        }
    }
    let measuredFragments = measurements.map { $0.jsonFragment() }
    let allFragments = measuredFragments + preservedFragments
    let frags = allFragments.joined(separator: ",\n          ")
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
      --samples N        Repeat the full scenario sweep N times and use the
                         per-scenario median measurement (default: 1, or 5
                         when --check is given). Multi-sample mode protects
                         the regression gate against host-noise flakiness
                         around the threshold; the median is robust to a
                         single anomalously slow run while still failing on
                         any consistent regression.
    """
    FileHandle.standardError.write(Data(u.utf8))
    exit(2)
}

var checkPath: String?
var updatePath: String?
var singleScenario: String?
var samplesOverride: Int?

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
    case "--samples":
        guard let v = args.first, let n = Int(v), n > 0 else { usage() }
        args.removeFirst()
        samplesOverride = n
    case "-h", "--help":
        usage()
    default:
        FileHandle.standardError.write(Data("unknown arg: \(arg)\n".utf8))
        usage()
    }
}

// TASK-058: the per-keystroke bench is fundamentally noisy on Linux dev
// hosts. A single `--check` run trips the 1.30× p99 guard ~1/5 times on
// `plus_chain_30` even when the underlying perf state is healthy. The
// regression gate must be median-of-N to remain meaningful — a single
// noisy run is not evidence of a regression, and the gate must not
// false-positive on noise.
//
// `--update` and ad-hoc human runs default to a single sample so the
// captured numbers reflect a fresh measurement. `--check` defaults to
// 5 samples so the regression gate is robust by default.
let sampleCount: Int = samplesOverride ?? (checkPath != nil ? 5 : 1)

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

if sampleCount > 1 {
    FileHandle.standardError.write(Data(
        "Running \(toRun.count) scenario(s) × \(sampleCount) samples (median selection)...\n".utf8
    ))
} else {
    FileHandle.standardError.write(Data("Running \(toRun.count) scenario(s)...\n".utf8))
}

/// Median of an odd-or-even array of `Double`. For even counts we use
/// the lower-of-the-two middle values, which is intentionally
/// conservative against `--check` false-positives: median selection is
/// already a noise filter, and biasing toward the lower value when
/// samples is even avoids inflating the reported number on a 4-fast +
/// 1-slow split (median of 5 is strictly the middle, no bias).
func median(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    let sorted = xs.sorted()
    return sorted[(sorted.count - 1) / 2]
}

func combineSamples(_ samples: [Measurement]) -> Measurement {
    precondition(!samples.isEmpty)
    let first = samples[0]
    return Measurement(
        scenario: first.scenario,
        iterations: first.iterations,
        p50Us: median(samples.map { $0.p50Us }),
        p95Us: median(samples.map { $0.p95Us }),
        p99Us: median(samples.map { $0.p99Us }),
        maxUs: median(samples.map { $0.maxUs }),
        allocations: 0
    )
}

// Per-scenario sample buffers, ordered to match `toRun` so JSON output
// preserves the scenario ordering the rest of the pipeline expects.
var perScenario: [[Measurement]] = Array(repeating: [], count: toRun.count)
var skippedScenarios: [String] = []
for sample in 0..<sampleCount {
    if sampleCount > 1 {
        FileHandle.standardError.write(Data(
            "Sample \(sample + 1)/\(sampleCount):\n".utf8
        ))
    }
    for (idx, s) in toRun.enumerated() {
        FileHandle.standardError.write(Data("  \(s.name)... ".utf8))
        guard let m = runScenario(s) else {
            // TASK-077: `.prod` scenarios skip cleanly when the
            // bundled lexicon / LM artifacts are missing on the
            // running host. Record the name so a fresh-checkout
            // run logs which scenarios were skipped without
            // crashing the gate.
            FileHandle.standardError.write(Data("skipped (artifacts missing)\n".utf8))
            if !skippedScenarios.contains(s.name) {
                skippedScenarios.append(s.name)
            }
            continue
        }
        FileHandle.standardError.write(Data(
            "p50=\(String(format: "%.1f", m.p50Us))us p95=\(String(format: "%.1f", m.p95Us))us p99=\(String(format: "%.1f", m.p99Us))us\n".utf8
        ))
        perScenario[idx].append(m)
    }
}
// Preserve `toRun` order even after dropping skipped scenarios so JSON
// output keeps the scenario list stable between runs.
let results: [Measurement] = perScenario
    .filter { !$0.isEmpty }
    .map { combineSamples($0) }
if sampleCount > 1 {
    FileHandle.standardError.write(Data("Per-scenario medians:\n".utf8))
    for m in results {
        FileHandle.standardError.write(Data(
            "  \(m.scenario): p50=\(String(format: "%.1f", m.p50Us))us p95=\(String(format: "%.1f", m.p95Us))us p99=\(String(format: "%.1f", m.p99Us))us\n".utf8
        ))
    }
}
if !skippedScenarios.isEmpty {
    let joined = skippedScenarios.joined(separator: ", ")
    FileHandle.standardError.write(Data(
        "Skipped \(skippedScenarios.count) scenario(s) (no bundled artifacts): \(joined)\n".utf8
    ))
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
