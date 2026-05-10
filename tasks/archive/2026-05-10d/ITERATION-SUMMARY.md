# Pipeline Iteration Summary — 2026-05-10d

## Tasks Completed
| Task ID | Title | Commits |
|---------|-------|---------|
| TASK-048 | Anusvara + asat (`1036 103A`) adjacency emitted in panel for `<C>an*` patterns | 7b18a65 |
| TASK-049 | Medial + asat without intervening vowel (`<medial> 103A`) emitted at rank 0 for `<C><medial>*` patterns | 7b18a65 |

## Tasks Invalidated
| Task ID | Title | Reason |
|---------|-------|--------|
| (none) | — | — |

## Regressions Encountered
None. Two intentional test updates were made as direct consequences of the fix:

- `AsatAfterDepVowelSuite.regressionGuards` lost `kya*` (`1000 103B 103A`) and `kw*` (`1000 103D 103A`) from its legal-shape counter-example list. Those shapes were pre-fix assertions of the bug; the replacements (`kyan*`, `kwan*`) cover the legitimate medial-bearing closure form.
- `RedundantExplicitAsatSuite`'s `kya*kar` counter-example expectation changed from `1000 103B 103A 1000 102C` (malformed shape) to `1000 103B 1000 102C` (two-syllable, asat correctly dropped). This is the post-fix correct behavior.

No tests were removed, suppressed, or weakened beyond these two intentional updates. All other suites remained green.

## Gaps Resolved
Step 5 was skipped — Step 4 returned `gaps_found: false` for both tasks. Both tasks were FULLY_COVERED on first validation pass.

## Outstanding Items
- TASK-050 (`ein`/`oun`/`pein`/`koun` romanization and panel-candidate bugs) remains in `tasks/` at `Status: Needs Clarification`. The task was split into three sub-issues during validation: (a) malformed `<C>oun` panel candidates with cross-category dep-vowel chains (fixable bug, §1); (b) missing literal-fallback for `ein` family (fixable bug, §2); (c) `ein`/`oun` as phonetic aliases of `ain`/`own` (design question, needs product decision). None of the three sub-issues can proceed without user sign-off on the design question (sub-issue c), because the romanization-alias change constrains what sub-issues a and b should preserve.

## Test Suite Status
- Final test count: 1488/1488 cases, 7757/7757 assertions pass (`swift run TestRunner`)
- Coverage delta from iteration start (1355/5721): +133 cases, +2036 assertions
- New suites added: `AnusvaraPlusAsatRejectionSuite` (TASK-048), `MedialPlusAsatRejectionSuite` (TASK-049)
- Modified suites: `AsatAfterDepVowelSuite` (two counter-example corrections), `RedundantExplicitAsatSuite` (one counter-example correction)
- Benchmark status: no regressions; `swift run -c release BurmeseBench --check Tests/Benchmarks/baseline.json` passed clean

## Notes
- TASK-048 and TASK-049 share a single root-cause fix: the `sawVowelCluster` gate added to `SyllableParser.scanOutputLegality` in `Parser/Finalization.swift`. Both bug classes (anusvara `1036` and medials `103B..103E`) sit in the same backward-walk skippable-scalar loop; the gate makes those scalars skippable only when the `aw`-cluster (`1031 102B|102C`) has already been peeled. The single commit 7b18a65 covers both tasks.
- The fix is conservative: legitimate medial-bearing closures (`kyan*` → `1000 103B 1014 103A`, `kyaw*` → `1000 103B 1031 102C 103A`) remain fully legal because either the coda consonant (`1014`) is the direct asat target (not the medial), or the aw-cluster peel sets the gate before the medial is encountered in the walk.
- All probe/scratch files from Step 3 and Step 4 (`Step4Probe.swift`, `probe048.swift`, `repro_burmese`, `reproprobe`, `validate-step4`, and ~15 others) were removed from `/tmp` during Step 6 cleanup. No probe files were ever committed to the repository.
