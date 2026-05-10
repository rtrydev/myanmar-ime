# Pipeline Iteration Summary — 2026-05-10e

## Tasks Completed
| Task ID | Title | Commits |
|---------|-------|---------|
| TASK-051 | Mid-buffer digit immediately followed by dep-vowel/medial/e-kar produces illegal Unicode storage order at rank 0 | 771dd14 |
| TASK-052 | Explicit user-typed `+` between two bare-vowel rules is silently discarded, collapsing the buffer into a single syllable | 3e4615a, db60dc1 |
| TASK-053 | Explicit kinzi `<C>{a,i}n+<C>` shape loses kinzi rank-0 promotion when a trailing tone marker (`.`/`:`) or digit is appended | ffcfcb0 |

## Tasks Invalidated
| Task ID | Title | Reason |
|---------|-------|--------|
| (none) | | |

## Regressions Encountered
- `RankingSuite` cases `task10_midDigit_*`, `task10_taIn_preservesI`, `task10_digitBetweenMedial_k2yun`: these cases were documenting the storage-order-illegal shape that TASK-051 fixed. Expectations were updated to the corrected anchor-bearing form (`<digit><U+1021><dep-vowel>`) — a justified update, not a weakening.

## Gaps Resolved
- **TASK-052 (Step-5 follow-up):** Step-4 flagged that the 25-cell `<bare-v>+<bare-v>` cross-product was approximated rather than exhaustively enumerated in the Step-3 suite. Step-5 closed the gap by:
  - Adding a second virama-`+` arc demotion in the DP gate for bare-vowel-LHS contexts so the soft-`+` arc wins cleanly;
  - Extending `1021` anchor injection in `Finalization.materialize` for consonant-base RHS (`e`→`101A 103A`, `i2`→`100A 103A`) and inherent-`a` RHS;
  - Adding five new suite cases covering the full 25-cell cross-product, the `e+i` particle assertion, and the panel-wide no-multi-cluster-or-orphan invariant.
  - Commit: db60dc1; 1512/1512 cases, 8131/8131 assertions.

## Outstanding Items
- **TASK-050** (`ein`/`oun` phonetic alias and associated illegal-panel-surface bug) remains in `tasks/` with status "Needs Clarification". It requires a product decision on three sub-questions before any code changes: (1) whether to add `ein`/`oun` as romanization aliases of `ain`/`own`, (2) the rank-0 vs. panel-reachable policy for the alias outputs, and (3) whether to sanitize the `<C>oun` illegal cross-category dep-vowel chains independently of the alias question. The actual-bug portions (illegal surfaces and missing literal fallback for `ein`) are well-documented in the task file and ready to implement once the design call is made. Carry this task forward to the next iteration after user clarification.

## Test Suite Status
- Final: 1512/1512 cases, 8131/8131 assertions (after Step-5 gap closure)
- Step-3 midpoint: 1507/1507 cases, 7969/7969 assertions (after TASK-051, TASK-052, TASK-053 initial fixes)
- Coverage delta: +24 cases, +162 assertions added this iteration
- No benchmark regressions (`BurmeseBench --check` clean)
- `FUZZ_BUDGET_MS=2000` clean

## Notes
- Probe files reported in diagnostics (_Tmp052Probe.swift, _TmpRegProbe.swift, _Tmp052Final.swift, probe1.swift) were not found on disk — no cleanup needed.
- The `invalid/` subdirectory is empty this iteration; retained for structural consistency with prior archives.
- TASK-052 required two commits across Step-3 and Step-5 because the 25-element cross-product coverage gap was non-trivial: the virama-`+` vs. soft-`+` tie in the DP gate caused the right-shrink probe to reject the explicit-`+` parse for certain bare-vowel-LHS cells.
- TASK-053's fix is surgical: it adds a tone-/digit-stripped second comparison to the `readingMatchesUserLiteralAcrossInherentVowels` discriminator without relaxing the existing exact-match path. Low regression risk.
