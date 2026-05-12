import Foundation
import BurmeseIMECore

/// Per-platform baseline must list a production-equivalent bench
/// scenario (`_prod` suffix) for every shipped real-pipeline scenario.
/// `BurmeseBench` exercises both the bare-engine scenarios (parser-only
/// fast paths) and the production-equivalent scenarios that load
/// `BurmeseLexicon.sqlite` + `BurmeseLM.bin` so per-keystroke
/// regressions in lexicon prefix-scan / LM scoring / history merge
/// trip the regression gate.
///
/// This suite is analogous to `BenchBaselineFormatSuite` — it does not
/// run the bench, it only asserts the baseline JSON's scenario-name
/// list. When the bench scenario list grows, the maintainer must
/// capture numbers for both platforms via
/// `swift run -c release BurmeseBench --update Tests/Benchmarks/baseline.json`
/// (or insert a TASK-061 placeholder row for the platform where they
/// cannot capture). Either way, the new scenario name must be present
/// in both platform sections so a contributor adding a scenario can't
/// forget to update one of them.
public enum ProductionBenchScenarioParitySuite {

    /// Production-equivalent scenarios that must be present in every
    /// shipped platform's baseline section. Mirrors the `_prod` entries
    /// declared in `Sources/BurmeseBench/main.swift`. When the bench's
    /// `_prod` list grows, append the new name here too.
    static let requiredProdScenarios: [String] = [
        "short_prod",
        "medium_prod",
        "long_prod",
        "incremental_prod",
        "garbage_incremental_prod",
        "vowel_rule_chain_in_10_prod",
    ]

    public static let suite: TestSuite = {
        var cases: [TestCase] = []

        for platform in ["linux", "macos"] {
            for scenario in requiredProdScenarios {
                cases.append(TestCase("\(platform)_baseline_lists_\(scenario)") { ctx in
                    let candidates = [
                        "Tests/Benchmarks/baseline.json",
                        "Packages/BurmeseIMECore/Tests/Benchmarks/baseline.json",
                    ]
                    var loadedNames: Set<String>? = nil
                    for path in candidates {
                        guard let data = FileManager.default.contents(atPath: path),
                              let json = try? JSONSerialization.jsonObject(with: data)
                                  as? [String: Any]
                        else { continue }
                        if let names = BenchBaselineFormat.scenarioNames(
                            from: json,
                            platformKey: platform
                        ) {
                            loadedNames = names
                            break
                        }
                    }
                    guard let names = loadedNames else {
                        ctx.fail(
                            "baseline_unreadable",
                            detail: "could not read '\(platform)' section of "
                                + "baseline.json at any of \(candidates)"
                        )
                        return
                    }
                    ctx.assertTrue(
                        names.contains(scenario),
                        scenario,
                        detail: "'\(platform)' baseline section is missing prod "
                            + "scenario '\(scenario)'. Run "
                            + "`swift run -c release BurmeseBench --update "
                            + "Tests/Benchmarks/baseline.json` on \(platform), "
                            + "or insert a placeholder row "
                            + "(\"placeholder\": true) so the drift guard sees "
                            + "the name."
                    )
                })
            }
        }

        return TestSuite(name: "ProductionBenchScenarioParity", cases: cases)
    }()
}
