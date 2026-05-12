# Pipeline Iteration Summary — 2026-05-12b

## Tasks Completed

| Task ID | Title | Commits |
|---------|-------|---------|
| TASK-076 | IncrementalParity fails on achitthone / kyaungtharachitthone — TASK-004 dominance gate cannot see cross-segment competitors | 7c7e4db |
| TASK-050 | Common Burmese syllables ein/oun/pein/koun unreachable (TASK-050b literal-fallback widening implemented; TASK-050a no-op justified; TASK-050c deferred) | 37bad6e |

## Tasks Invalidated

| Task ID | Title | Reason |
|---------|-------|--------|

(none this iteration)

## Regressions Encountered

None. Step 4 confirmed:
- BurmeseBench --check reported no regressions for either task.
- `garbage_incremental p95` flickered at the threshold both before and after the TASK-050b fix — confirmed by step 3 as pre-existing stale-baseline drift unrelated to this change.
- All must-not-regress suites (AnchorStabilitySuite, MidBufferStackInferenceSuite, TASK072DoubledClusterMedialConsistencySuite, WindowingKinziAcrossThresholdSuite, LexiconRankingSuite, ComprehensiveRankingSuite, RepeatedLetterPerfSuite) remained green throughout.

## Gaps Resolved

Step 5 was skipped (gaps_found=false from step 4). No gap-fixing work was required.

## Outstanding Items

- **TASK-050c** (romanization scheme expansion — should `ein`/`oun` be accepted as phonetic aliases of `ain`/`own`?): deferred pending explicit product/user decision. Analogous to open TASK-062. Must not be implemented by the automated pipeline; requires sign-off including reverse-romanizer canonicalization.
- **TASK-062** (phonetic `y` -> spelling `r` reading alias for native lemmas such as `hsayar -> ဆရာ`): remains open from prior iterations.

## Test Suite Status

- Final: 1612/1612 cases, 8935/8935 assertions (after both TASK-076 and TASK-050b landed).
- Prior state entering this iteration: 1599/1599 cases, 8828/8828 assertions.
- Net new cases: +13 cases, +107 assertions (TASK-076 suite: 4 cases; TASK-050 suite: 8 cases; plus previously-added cases from the commits in the prior 2026-05-12 iteration that were still being counted).
- Coverage delta: two new suite files added (TASK076CrossSegmentResegmentationSuite.swift, TASK050OunEinIllegalSurfaceSuite.swift).

## Notes

- TASK-076 used fix-direction #3 (anchor scoring at promotion time, not recording time) — the structural approach, not a threshold tweak. This makes the fix invariant to future LM weight shifts within the same corpus, which was the root requirement.
- TASK-050 required splitting the original task: only the literal-fallback widening (TASK-050b) was a clean engineering fix. The sanitizer extension (TASK-050a) was a justified no-op — the existing sanitizer already handles the oun/koun cases via its "preserve violators when no clean sibling exists" fallback policy. The romanization alias expansion (TASK-050c) is a product decision blocked pending user input.
- The rebuilt `native/macos/Data/BurmeseLM.bin` and `native/macos/Data/BurmeseLexicon.sqlite` remain as modified files in the working tree (modified relative to the previous commit). These are expected — they are the rebuilt artifacts that triggered TASK-076.
