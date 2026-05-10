# Pipeline Iteration Summary — 2026-05-10c

## Tasks Completed
| Task ID | Title | Commits |
|---------|-------|---------|
| TASK-045 | Implicit kinzi inference fully suppressed when any explicit `+` is present in buffer | 564291c |
| TASK-046 | Bare vowel-rule chains (no onset) of length 4+ produce malformed trailing syllables | 478138c, 41b18a9 |
| TASK-047 | Explicit `+` before vowel-rule silently merged into single syllable | e9cb177 |

## Tasks Invalidated
| Task ID | Title | Reason |
|---------|-------|--------|
| (none) | — | — |

## Regressions Encountered
None. All existing suites remained green throughout the iteration. The `vowel_rule_chain_aing_8` benchmark baseline was intentionally updated (+30% p50) in the gap-fix commit (41b18a9) because the fixed windowing path lands at a syllable-aligned split position that produces a longer parseable tail; this is a correct-behavior cost increase, not a regression. All other benchmark scenarios remained within thresholds.

## Gaps Resolved
TASK-046 entered Step 4 with a PARTIAL verdict: the initial fix (478138c) asserted only panel-reachability of the all-anchored leading two-syllable prefix for windowed cases (N ∈ {5..8}), rather than the strict rank-0 N-fold equality called for in the acceptance criteria.

Step 5 traced the gap to `FrozenPrefixCache.swift::splitProducesStableMerge`, which over-rejected syllable-aligned splits through bare-vowel-rule chains because the partial-buffer parser emits U+200C (ZWNJ, orphan-vowel placeholder) at the split boundary while the full-buffer parser had already injected U+1021 (independent vowel anchor) between adjacent bare-diphthong arcs. The fix (41b18a9) accepts the merge as stable when the only divergence is exactly that boundary-position scalar swap; the engine's downstream `promoteOrphanZwnjToImplicitA` post-process then rewrites the ZWNJ to U+1021, producing the full N-fold anchored surface.

`BareVowelRuleChainSuite` was strengthened: windowed cases now assert strict rank-0 equality for `aing × N` and `aung × N` for all N ∈ {2..8}, and the U+1021 anchor count is directly checked for each N. `ai × N` reachability was tightened from panel-presence to top-3. Total assertions increased from 7387 to 7415 (+28).

## Outstanding Items
- The `ai × N` (bare short-`ai` rule repeated) chain still loses rank 0 to the literal fallback for N ≥ 2. Promoting rank 0 there would require sanitizer or literal-promoter changes outside this task's scope; the current top-3 reachability assertion satisfies CLAUDE.md §7. A follow-up task could address the rank-0 promotion specifically.
- No other carry-forward items from this iteration.

## Test Suite Status
- Final test count: 1479/1479 cases, 7415/7415 assertions pass (`swift run TestRunner`)
- Coverage delta: +124 cases, +28 assertions added (net from 1355/5721 at iteration start)
- New suites added: `PlusDisjointKinziInferenceSuite` (TASK-045), `BareVowelRuleChainSuite` (TASK-046), `PlusBeforeVowelRuleSuite` (TASK-047)
- Modified suites: `ExplicitPlusVowelChainSuite` (strengthened `ka+u` expectation per TASK-047 structural rule)
- Benchmark status: all scenarios within thresholds; `vowel_rule_chain_aing_8` macOS baseline intentionally updated (p50: 660→870 µs, p95: 696→920 µs, p99: 736→970 µs)

## Notes
- The three tasks in this iteration all touch the explicit-`+` boundary-signal path. The fixes are layered: TASK-047 makes the parser respect `+` as a hard boundary before vowel rules; TASK-045 makes implicit kinzi inference operate per-segment when `+` is present; TASK-046 (and its gap fix) makes the windowing system honour syllable-aligned splits through bare-vowel-rule chains. These interact at `InputNormalization`, `NBestDP`, `Finalization`, and `FrozenPrefixCache` — the combination leaves the explicit-`+` signal consistently respected across all engine layers.
- All probe files listed in the step 6 inputs (`probe_task046.swift`, `Task046ProbeSuite.swift`, `probe45.swift`, `_TempProbeSuite.swift`, `repro_tasks_45_46_47.swift`) were absent from the working tree at archive time — they were never committed or were cleaned up during the implementation steps.
