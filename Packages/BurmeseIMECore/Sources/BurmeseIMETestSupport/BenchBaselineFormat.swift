import Foundation

/// Per-host baseline format helpers shared between `BurmeseBench` and
/// the test suite that exercises them.
///
/// TASK-040: the bench gate compares per-keystroke timings against a
/// committed baseline. Hardware variance between Apple Silicon and
/// x86_64 Linux invalidates a single-host file (1.4–2.4× p95 deltas
/// observed on the dev Linux host). The baseline document now keys
/// per-platform and `--check` only reads the matching section for
/// the running host, while `--update` preserves untouched sections
/// for the other platforms.
public enum BenchBaselineFormat {

    public struct ScenarioEntry: Equatable {
        public let scenario: String
        public let p95Us: Double
        public let p99Us: Double
        /// TASK-061: placeholder entries appear in the JSON solely so
        /// the cross-platform drift guard can match scenario names
        /// across platforms before real numbers exist for one of
        /// them. They MUST NOT be used as a baseline by `--check` —
        /// the gate has to surface the missing-measurement case as
        /// loudly as a fully-absent entry. `BurmeseBench` filters
        /// placeholder entries out of the comparison list and
        /// reports them via the same "MISSING FROM <platform>
        /// BASELINE" diagnostic it uses for absent scenarios.
        public let isPlaceholder: Bool

        public init(
            scenario: String,
            p95Us: Double,
            p99Us: Double,
            isPlaceholder: Bool = false
        ) {
            self.scenario = scenario
            self.p95Us = p95Us
            self.p99Us = p99Us
            self.isPlaceholder = isPlaceholder
        }
    }

    /// Recognised platform key for the running host. Returns `"linux"`,
    /// `"macos"`, or `"unknown"`. The `unknown` value is intentionally
    /// not a fatal error — `--check` surfaces it as a missing-baseline
    /// diagnostic rather than crashing the gate.
    public static var currentPlatformKey: String {
        #if os(Linux)
        return "linux"
        #elseif os(macOS)
        return "macos"
        #else
        return "unknown"
        #endif
    }

    /// Read entries for `platformKey` from a baseline JSON document
    /// loaded as a top-level dictionary. Supports both the original
    /// flat schema (`{"scenarios": [...]}`) and the per-platform
    /// schema (`{"platforms": {"linux": {...}, "macos": {...}}}`).
    /// Returns `nil` when the platform's section is missing.
    public static func entries(
        from json: [String: Any],
        platformKey: String
    ) -> [ScenarioEntry]? {
        let scenarios: [[String: Any]]?
        if let platforms = json["platforms"] as? [String: Any] {
            guard let section = platforms[platformKey] as? [String: Any],
                  let s = section["scenarios"] as? [[String: Any]]
            else { return nil }
            scenarios = s
        } else {
            scenarios = json["scenarios"] as? [[String: Any]]
        }
        guard let scenarios else { return nil }
        return scenarios.compactMap { s in
            guard let name = s["scenario"] as? String,
                  let p95 = s["p95_us"] as? Double,
                  let p99 = s["p99_us"] as? Double
            else { return nil }
            let placeholder = (s["placeholder"] as? Bool) ?? false
            return ScenarioEntry(
                scenario: name,
                p95Us: p95,
                p99Us: p99,
                isPlaceholder: placeholder
            )
        }
    }

    /// Convenience: read entries for `platformKey` from a JSON file.
    public static func entries(
        atPath path: String,
        platformKey: String
    ) -> [ScenarioEntry]? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return entries(from: json, platformKey: platformKey)
    }

    /// Return the set of platform keys present in a per-platform
    /// baseline document. Returns an empty set for the legacy flat
    /// schema. TASK-061: the cross-platform baseline-drift guard
    /// uses this to enumerate platforms before comparing scenario
    /// name sets.
    public static func platformKeys(from json: [String: Any]) -> Set<String> {
        guard let platforms = json["platforms"] as? [String: Any] else {
            return []
        }
        return Set(platforms.keys)
    }

    /// Return the scenario names listed under `platformKey`.
    /// TASK-061: used by the drift guard to assert
    /// `set(linux.scenarios) == set(macos.scenarios)` so a future
    /// scenario addition that lands in only one platform's section
    /// is caught before merge.
    public static func scenarioNames(
        from json: [String: Any],
        platformKey: String
    ) -> Set<String>? {
        guard let scenarios = entries(from: json, platformKey: platformKey)
        else { return nil }
        return Set(scenarios.map(\.scenario))
    }
}
