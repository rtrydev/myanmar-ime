# Pipeline Iteration Summary — 2026-05-11b

(Second pipeline iteration of the day; first iteration archived under
`tasks/archive/2026-05-11/`.)

## Tasks Completed
| Task ID | Title | Commits |
|---------|-------|---------|
| TASK-057 | Long uniform `+`-stack chains of identical bare-`<C>a` syllables collapse to literal-only at rank 0 | 584b276 |
| TASK-058 | `plus_chain_30` benchmark p99 regressed past the +30% guard rail | 3b41849 |
| TASK-060 | Tone-eligible LHS with doubled-dot or doubled-colon mid-buffer leaves the panel with no Burmese candidate | a557292 |

## Tasks Invalidated
| Task ID | Title | Reason |
|---------|-------|--------|
| _none_ | | |

## Regressions Encountered
- **TASK-058 bench-protocol regression surfaced indirectly.** Step 4
  validation against the post-TASK-057 baseline showed `plus_chain_30`
  p95/p99 within tolerance only on median-of-5 sampling. Single-shot
  `BurmeseBench --check` runs were noise-dominated and produced
  intermittent gate failures. Resolved by commit 3b41849, which makes
  `--check` run each scenario five times and compare medians — the
  measurement protocol now matches the variance profile of the host.
- **No source-code regressions in the engine, parser, sanitizers, or
  ranking pipeline.** All 1543/1543 cases and 8425/8425 assertions
  pass.

## Gaps Resolved
- **TASK-058** (originally Partial in Step 3) — closed in Step 5 by
  switching `BurmeseBench --check` to median-of-5 sampling, which is
  the correct host-noise filter for the +20 %/+30 % gates.
- **TASK-059** (originally Partial in Step 3) — Python-level
  corpus-builder fix in commit 512b7f1 is verified correct by Step 4
  diff inspection of the generated TSV-construction code path. The
  *runtime* fix requires regeneration of the Myanmar-C4 artifact
  bundle (TSV + SQLite + LM together), which is multi-hour and an
  operator action. Status downgraded from Partial to Carry-Forward;
  task file remains in `tasks/` with a 7-step operator checklist.

## Outstanding Items
- **TASK-059 — Carry-Forward / Needs-Operator-Action.** The shipped
  `BurmeseLexicon.sqlite` + `BurmeseLM.bin` still carry the digit-as-`ဝ`
  poisoning until the operator runs the corpus regeneration pipeline.
  Lives in `tasks/TASK-059-…md` with the operator checklist.
- **TASK-066 — `vowel_rule_chain_aing_8` p95 borderline drift.** Newly
  filed during Step 5: with the median-of-5 gate now meaningful around
  thresholds, this scenario sits at the +20 % p95 boundary on Linux and
  warrants targeted profiling. Lives in `tasks/TASK-066-…md`.

## Test Suite Status
- Cases: 1543/1543 pass (up from 1529/1529 in the previous iteration —
  +14 new cases across `GrammarSuite`,
  `LiteralFallbackIllegalSurfaceSuite`, and the punctuation/tone
  suites tightened by Step 4).
- Assertions: 8425/8425 pass (up from 8258/8258 in the previous
  iteration — +167 new assertions, mostly from the tighter expressions
  of TASK-057/060 intent).
- Benchmarks: median-of-5 `--check` gate now active; baseline unchanged
  apart from the protocol fix.

## Notes
- Three independent fixes shipped this iteration: parser DP rejection
  of chained virama arcs (TASK-057), punctuation-handling skip on
  doubled doc-punct following a tone-eligible LHS (TASK-060), and the
  corpus-builder confusable rewriter extension to word-boundary
  digit/wa pairs (TASK-059, runtime gated on regeneration).
- One supporting infrastructure commit landed (3b41849) to make the
  benchmark gate match host noise variance.
- Probe scratch files cleaned out of `/tmp/` before commit. Repo
  working tree clean apart from the archival move and `pipeline-run.log`
  (driver-managed, not touched by Step 6).
- Open-task surface is now smaller and sharper: only one open
  perf-borderline (TASK-066) and one operator-action carry-forward
  (TASK-059) plus the long-running `linux-ibus-port` end-to-end VM
  task. `tasks/README.md` updated to drop the previously-closed
  TASK-054/055/056/062 rows that were stale from the prior iteration.
