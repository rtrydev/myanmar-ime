import Foundation
import BurmeseIMECore

/// TASK-040: per-platform baseline format. The bench gate is
/// meaningless across hosts (Apple Silicon vs. x86_64 Linux
/// p95 deltas of 1.4–2.4× on every scenario), so each shipping
/// platform has its own baseline section. The suite covers the
/// parser's recognition of both the legacy flat schema (for
/// backward compat with archived baselines) and the new
/// per-platform schema, plus the platform-key auto-detect on the
/// running host.
public enum BenchBaselineFormatSuite {

    public static let suite = TestSuite(name: "BenchBaselineFormat", cases: [

        // Legacy flat schema (`{"scenarios": [...]}`) — when no
        // `platforms` envelope exists, the parser ignores
        // `platformKey` and reads scenarios directly.
        TestCase("parses_legacyFlatSchema") { ctx in
            let json: [String: Any] = [
                "scenarios": [
                    [
                        "scenario": "short",
                        "p95_us": 111.42,
                        "p99_us": 120.79,
                    ],
                    [
                        "scenario": "medium",
                        "p95_us": 338.54,
                        "p99_us": 348.25,
                    ],
                ],
                "meta": ["commit": "abc", "date": "2026-04-27T09:54:31Z"],
            ]
            let entries = BenchBaselineFormat.entries(from: json, platformKey: "linux")
            ctx.assertTrue(
                entries != nil,
                "legacy_returns_entries",
                detail: "expected non-nil entries from legacy flat schema"
            )
            ctx.assertEqual(entries?.count ?? 0, 2, "legacy_count")
            ctx.assertEqual(entries?.first?.scenario, "short", "legacy_first_name")
            ctx.assertEqual(entries?.first?.p95Us, 111.42, "legacy_first_p95")
        },

        // Per-platform schema: only the matching section is
        // returned.
        TestCase("parses_perPlatformSchema_matchingSection") { ctx in
            let json: [String: Any] = [
                "platforms": [
                    "linux": [
                        "scenarios": [
                            [
                                "scenario": "short",
                                "p95_us": 288.39,
                                "p99_us": 336.30,
                            ],
                        ],
                        "meta": ["commit": "lin1", "date": "2026-05-03T15:00:00Z"],
                    ],
                    "macos": [
                        "scenarios": [
                            [
                                "scenario": "short",
                                "p95_us": 111.42,
                                "p99_us": 120.79,
                            ],
                        ],
                        "meta": ["commit": "mac1", "date": "2026-04-27T09:54:31Z"],
                    ],
                ],
            ]
            let linuxEntries = BenchBaselineFormat.entries(from: json, platformKey: "linux")
            let macosEntries = BenchBaselineFormat.entries(from: json, platformKey: "macos")
            ctx.assertEqual(linuxEntries?.first?.p95Us, 288.39, "linux_p95")
            ctx.assertEqual(macosEntries?.first?.p95Us, 111.42, "macos_p95")
        },

        // Per-platform schema: a missing section returns nil so
        // the bench gate can surface a clear error rather than
        // silently passing on an unbaselined host.
        TestCase("parses_perPlatformSchema_missingSectionReturnsNil") { ctx in
            let json: [String: Any] = [
                "platforms": [
                    "macos": [
                        "scenarios": [
                            [
                                "scenario": "short",
                                "p95_us": 111.42,
                                "p99_us": 120.79,
                            ],
                        ],
                    ],
                ],
            ]
            let linuxEntries = BenchBaselineFormat.entries(from: json, platformKey: "linux")
            ctx.assertTrue(
                linuxEntries == nil,
                "linux_missing_nil",
                detail: "expected nil for missing platform section, got \(String(describing: linuxEntries))"
            )
        },

        // Platform key auto-detect resolves to one of the
        // recognised keys on every host the suite runs on.
        TestCase("currentPlatformKey_recognised") { ctx in
            let key = BenchBaselineFormat.currentPlatformKey
            ctx.assertTrue(
                key == "linux" || key == "macos" || key == "unknown",
                "platform_key_recognised",
                detail: "got '\(key)'"
            )
            #if os(Linux)
            ctx.assertEqual(key, "linux", "linux_host_returns_linux")
            #elseif os(macOS)
            ctx.assertEqual(key, "macos", "macos_host_returns_macos")
            #endif
        },

        // The committed baseline file at Tests/Benchmarks/baseline.json
        // contains a section for the running platform. (This guards
        // against accidentally stripping the running platform's
        // baseline when the format is regenerated.)
        TestCase("committedBaseline_hasCurrentPlatform") { ctx in
            // Walk up from the package's source-relative path so the
            // test runs identically under `swift run TestRunner` and
            // XCTest harness.
            // The package root contains `Tests/Benchmarks/baseline.json`.
            // We don't know the absolute path at compile time, so
            // try a small set of relative roots.
            let candidates = [
                "Tests/Benchmarks/baseline.json",
                "Packages/BurmeseIMECore/Tests/Benchmarks/baseline.json",
            ]
            var loaded: [BenchBaselineFormat.ScenarioEntry]? = nil
            for path in candidates {
                if let entries = BenchBaselineFormat.entries(
                    atPath: path,
                    platformKey: BenchBaselineFormat.currentPlatformKey
                ), !entries.isEmpty {
                    loaded = entries
                    break
                }
            }
            ctx.assertTrue(
                loaded != nil,
                "current_platform_baseline_present",
                detail: "no baseline section for '\(BenchBaselineFormat.currentPlatformKey)' "
                    + "at \(candidates)"
            )
        },

        // TASK-061 (gap fix): placeholder entries are visible to the
        // parser with `isPlaceholder == true` so the bench gate can
        // treat them as missing (exit 1 + loud diagnostic) while the
        // drift guard still sees their scenario names for parity.
        TestCase("parses_placeholderFlag_isExposed") { ctx in
            let json: [String: Any] = [
                "platforms": [
                    "macos": [
                        "scenarios": [
                            [
                                "scenario": "real_one",
                                "p95_us": 100.0,
                                "p99_us": 110.0,
                            ],
                            [
                                "scenario": "placeholder_one",
                                "p95_us": 200.0,
                                "p99_us": 220.0,
                                "placeholder": true,
                            ],
                            [
                                "scenario": "absent_flag_defaults_false",
                                "p95_us": 300.0,
                                "p99_us": 330.0,
                            ],
                        ],
                    ],
                ],
            ]
            let entries = BenchBaselineFormat.entries(from: json, platformKey: "macos")
            ctx.assertEqual(entries?.count ?? 0, 3, "placeholder_count")
            let real = entries?.first(where: { $0.scenario == "real_one" })
            let placeholder = entries?.first(where: { $0.scenario == "placeholder_one" })
            let defaulted = entries?.first(where: { $0.scenario == "absent_flag_defaults_false" })
            ctx.assertEqual(real?.isPlaceholder, false, "real_isPlaceholder_false")
            ctx.assertEqual(placeholder?.isPlaceholder, true, "placeholder_isPlaceholder_true")
            ctx.assertEqual(
                defaulted?.isPlaceholder,
                false,
                "missing_flag_defaults_false"
            )
            // Placeholder entries are still listed by `scenarioNames`
            // so the cross-platform drift guard sees them as part of
            // the platform's name set — that is the whole point of
            // the placeholder mechanism.
            let names = BenchBaselineFormat.scenarioNames(from: json, platformKey: "macos")
            ctx.assertEqual(names?.count ?? 0, 3, "drift_guard_sees_placeholder_names")
            ctx.assertTrue(
                names?.contains("placeholder_one") ?? false,
                "drift_guard_includes_placeholder",
                detail: "scenarioNames should include placeholder rows"
            )
        },

        // TASK-061: cross-platform baseline drift guard. When the
        // bench scenario list grows in `BurmeseBench/main.swift`,
        // both maintainers must capture the new numbers via
        // `--update` on their respective host before merging. The
        // drift guard catches the case where one platform's section
        // got the new scenario but the other did not — silently
        // dropping the perf gate for the missed platform until the
        // next time someone notices.
        TestCase("committedBaseline_scenarioSetsMatchAcrossPlatforms") { ctx in
            let candidates = [
                "Tests/Benchmarks/baseline.json",
                "Packages/BurmeseIMECore/Tests/Benchmarks/baseline.json",
            ]
            var json: [String: Any]? = nil
            for path in candidates {
                guard let data = FileManager.default.contents(atPath: path),
                      let parsed = try? JSONSerialization.jsonObject(with: data)
                          as? [String: Any]
                else { continue }
                json = parsed
                break
            }
            guard let json else {
                ctx.assertTrue(
                    false,
                    "could_not_read_baseline",
                    detail: "no baseline.json at \(candidates)"
                )
                return
            }
            let platforms = BenchBaselineFormat.platformKeys(from: json)
            // Skip when only one platform exists — the suite isn't
            // checking richness, just consistency between sections
            // that DO exist. Brand-new repositories or single-host
            // iterations don't need to fail this check.
            guard platforms.count >= 2 else { return }
            var perPlatform: [String: Set<String>] = [:]
            for platform in platforms {
                guard let names = BenchBaselineFormat.scenarioNames(
                    from: json, platformKey: platform
                ) else { continue }
                perPlatform[platform] = names
            }
            // Pairwise compare every section against the union to
            // surface every missing scenario, not just the first
            // diverging pair.
            let union = perPlatform.values.reduce(Set<String>()) { $0.union($1) }
            for (platform, names) in perPlatform {
                let missing = union.subtracting(names).sorted()
                ctx.assertTrue(
                    missing.isEmpty,
                    "platform_\(platform)_complete",
                    detail: "platform '\(platform)' is missing scenario(s) "
                        + "\(missing) — run `swift run -c release BurmeseBench "
                        + "--update Tests/Benchmarks/baseline.json` on "
                        + "'\(platform)' to capture them"
                )
            }
        },
    ])
}
