# Pipeline Iteration Summary — 2026-05-11c

(Third pipeline iteration of the day; first archived under
`tasks/archive/2026-05-11/`, second under `tasks/archive/2026-05-11b/`.)

## Tasks Completed
| Task ID | Title | Commits |
|---------|-------|---------|
| TASK-067 | Uniform `<C>+<C>+...` chains of 10+ segments bypass TASK-057 break-the-chain guard and produce illegal triple-virama-stack at rank 0 | aa728f0 |
| TASK-068 | Mid-buffer unsupported ASCII letters (`f`, `q`, `x`, `c`-not-as-`ch`) silently dropped from rank-0 surface and replaced with phantom `1021` anchor | deee2ac |
| TASK-069 | Bare `a*` (and `aa*`/`aaa*`/`+a*`) produces illegal `1021 103A` orphan-asat-on-independent-vowel surface; existing sanitizers cover all sibling shapes except this one | 8f74edd |

Supporting commit:
- 882e15e — Sync CLAUDE.md test-runner baseline with post-iteration counts.

## Tasks Invalidated
| Task ID | Title | Reason |
|---------|-------|--------|
| _none_ | | |

## Regressions Encountered
- **No regressions.** Step 4 validation showed all three fixes narrowly
  scoped. Pre-existing test adjustments (`anaconda`, `ace`/`acer`
  dropped from carve-out fixtures) are correct un-pinning of pre-fix
  bug behavior, not regressions. `BurmeseBench --check --samples 5`
  reports no benchmark regressions against the platform baseline.

## Gaps Resolved
- _None._ Step 5 was skipped — Step 4 reported zero gaps across all
  three completed tasks.

## Outstanding Items
- **TASK-059 — Carry-Forward / Needs-Operator-Action.** The shipped
  `BurmeseLexicon.sqlite` + `BurmeseLM.bin` still carry the digit-as-`ဝ`
  poisoning until the operator runs the corpus regeneration pipeline.
  Lives in `tasks/TASK-059-…md` with its operator checklist.
- **TASK-066 — `vowel_rule_chain_aing_8` p95 borderline drift.** Still
  open; targeted profiling not yet performed. Lives in
  `tasks/TASK-066-…md`.

## Test Suite Status
- Cases: 1556/1556 pass (up from 1543/1543 in the previous iteration —
  +13 new cases across the parser-DP, sanitizer, and literal-fallback
  suites added by TASK-067/068/069).
- Assertions: 8581/8581 pass (up from 8425/8425 in the previous
  iteration — +156 new assertions).
- Benchmarks: median-of-5 `--check --samples 5` clean against the
  platform baseline; no scenario regressed.

## Notes
- Three independent fixes shipped this iteration, all tightening
  rank-0 surface legality:
  - TASK-067 extends the windowed-chain guard to drop chained
    virama-stack surfaces from uniform plus-chains.
  - TASK-068 promotes the literal at rank 0 when a mid-buffer
    unsupported ASCII letter would otherwise be silently dropped
    behind a phantom `1021` anchor.
  - TASK-069 drops the bare-independent-vowel + asat surface
    (`1021 103A` family) from the candidate panel — the last
    orphan-asat sanitizer gap that sibling shapes already covered.
- Minor docstring lag fix at
  `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/LiteralFallbackPrefixedRepetitionSuite.swift:32`
  — header comment still listed `anaconda` as a carve-out target;
  updated to match the in-body TASK-068 explanation that the
  buffer is now correctly handled by the mid-buffer-unsupported-letter
  promotion path.
- `/tmp/` probe scratch files (`validate_task67/68/69.swift`,
  `probe_task067*.swift`, `probe067.swift`, `run_probes.swift`,
  `validate_step3.swift`) cleaned out before commit.
- Repo working tree clean apart from the archival move and
  `pipeline-run.log` (driver-managed, not touched by Step 6).
- Open-task surface unchanged in shape: still one perf-borderline
  (TASK-066) and one operator-action carry-forward (TASK-059) plus
  the long-running `linux-ibus-port` end-to-end VM task.
