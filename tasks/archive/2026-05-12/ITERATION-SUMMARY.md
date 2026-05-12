# Pipeline Iteration Summary — 2026-05-12

(First pipeline iteration of the day, immediate continuation of the
2026-05-11d carry-forward window. Six-step run that closed the entire
TASK-070..TASK-075 open queue.)

## Tasks Completed
| Task ID | Title | Commits |
|---------|-------|---------|
| TASK-070 | Mid-sentence `aha-` typing skips leading-A promotion, drops `အ` from `အ`-prefix syllables | `707a458` |
| TASK-071 | Mid-buffer apostrophe re-parses `r` after a consonant as `ra`-consonant instead of `aa`-vowel | `219bbbb` |
| TASK-072 | `IncrementalParity` diverges for doubled `kyaungtha[w\|r]` chains | `e76b55c`, `04937d9` |
| TASK-073 | Add `u.` (creaky) alias for independent vowel `ဥ` without breaking `u` → `ဥ` | `124c2c3` (with `40c396c` lexicon prep) |
| TASK-074 | `အံ` (anusvara) loses to `အန်` (n-asat) at rank 0 for reading `an` | `124c2c3` (with `40c396c` lexicon prep) |

## Tasks Invalidated
| Task ID | Title | Reason |
|---------|-------|--------|
| TASK-075 | Bare ya-yit `ကြီ` missing from corpus vocab; not reachable from `kyi` panel | Already fixed and passing in main as of step 2 — `LexiconBuilder` `curatedAdditions` injects `ကြီ` at `ky2i2` with floor 900.0 and known-OOV flag; `task13_yayit_still_in_panel_kyi` reports zero failures under `swift run TestRunner`. No engine change required this iteration. |

## Regressions Encountered
- **TASK-072 incremental fix (step 3 → step 4).** Commit `e76b55c`
  ("Enforce consistent ya-pin / ya-yit medial for repeated
  cluster-alias shapes") closed the user-visible parity divergence but
  pushed `vowel_rule_chain_aing_8` p95 ~10–17% over
  `baseline × 1.20`. Step 5 resolved it via commit `04937d9`
  ("Short-circuit doubled-cluster guard when buffer has no
  cluster-key letters") — a cheap first-character fast-path that
  avoids the doubled-cluster scan on the dominant well-formed-buffer
  shape. Median-of-5 `BurmeseBench --check` now passes; TestRunner
  remains 1599/1599.

## Gaps Resolved
- TASK-072 incremental parity gap (`kyaungthaw`/`kyaungthar` doubled
  chain) — closed by the same fast-path commit `04937d9` that resolved
  the perf regression.
- Side-effect during step 5: committed the pre-existing
  `TASK059LexiconWaBaCleanRankZeroSuite.swift` (commit `44b127d`,
  "Lock in TASK-059 lexicon wa/ba clean rank-0 invariant") to clear
  the working tree. The suite was authored in iteration 2026-05-11d
  but not yet committed at the start of this iteration.

## Outstanding Items
None. Open-task queue is empty at iteration end. `tasks/README.md` has
been updated to reflect the empty queue.

## Test Suite Status
- `swift run TestRunner`: **1599/1599 cases pass; 8828/8828 assertions pass.**
- `swift run -c release BurmeseBench --check Tests/Benchmarks/baseline.json`
  (median-of-5): pass; no per-scenario p95/p99 regressions remaining.
- CLAUDE.md test-runner baseline updated from 1556/1556 (8581/8581) to
  1599/1599 (8828/8828) in this iteration so it now matches reality.

## Notes
- This iteration finally clears the CLAUDE.md baseline drift flagged
  as an outstanding item in `2026-05-11d/ITERATION-SUMMARY.md`. The
  test-runner baseline in CLAUDE.md again matches the live count.
- TASK-073 and TASK-074 share commit `124c2c3` because both surfaces
  (`ဥ` from `u.`, `အံ` from `an`) ride the same curated-lexicon
  score-floor + OOV-allowed promotion mechanism added in `40c396c`.
- The TASK-072 fast-path is intentionally a cheap pre-filter that
  preserves the doubled-cluster guard's semantics for buffers
  containing any cluster-key letter; it is not a logic change to the
  guard itself. Worth keeping in mind if the cluster-key letter set
  expands later — the fast-path's letter set must track it.
