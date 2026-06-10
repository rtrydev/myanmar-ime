# Pipeline Iteration Summary — 2026-06-10 (iteration 2)

## Tasks Completed
| Task ID | Title | Commits |
|---------|-------|---------|
| TASK-084 | Synthetic alias exact hits unrecognized — ah-/a- prefix convention crowd-out | 6813cef |
| TASK-085 | Doubled-coda sanitizer false-positives on loanword bare-consonant asat codas | 79ee94b |
| TASK-086 | Locative particle ၌ (U+104C) has no romanization — unwritable, silently dropped | 7af131c |
| TASK-087 | Structural tall/round-aa rewrite on virama-stack lowers fabricates unattested spellings | 5117d0d |

## Tasks Invalidated
| Task ID | Title | Reason |
|---------|-------|--------|
| (none) | | |

## Regressions Encountered
None. Step 4 (validation) confirmed no regressions across all four tasks. BurmeseBench --check
failed on the validation host but failed identically at the pre-Step-3 base commit a340c35 under
sustained background load (load avg ~3.2); the per-scenario differential between base and HEAD is
within the ±7% noise band in both directions — no code-attributable regression. The bench gate
should be re-certified on a quiet host before the next baseline update.

## Gaps Resolved
Step 5 was not run — Step 4 found no gaps or partial fixes requiring a second pass. All four tasks
were FULLY_COVERED at the end of Step 3.

## Outstanding Items
1. **TASK-086 data-pipeline rerun (pre-existing, explicitly out of scope per the generated-data
   non-negotiable):** The 21 ၌-bearing lexicon rows are still indexed under particle-less readings
   in the shipped store. The engine-side reverse mapping (`romanize("၌") → "hnite"`) is now in
   place, so the next full corpus regeneration will re-index them automatically. Until then, `to.`
   still ranks the mis-indexed `တို့၌` at rank 0 above bare `တို့` (documented, not worsened).
2. **BurmeseBench baseline re-certification:** The baseline should be re-measured on a quiet host
   before committing an updated `Tests/Benchmarks/baseline.json`.
3. **`a-`-prefix double-onset convention (penalty +2 rows):** The TASK-084 matched-alias mechanism
   covers this class (`aain` → `အိမ်` rank 0, `aaya` → `အရ` rank 1 verified), but no dedicated
   suite case pins the family. Minor gap; mechanism is shared with the `ah-` cases.
4. **`CandidateStore.lookupAliasExact` default protocol shim:** The compatibility-only default
   implementation (canonical-reading reconstruction semantics) is uncovered by tests — only the
   SQLite override is tested. Low risk (the protocol is internal), but worth a future note.

## Test Suite Status
- Baseline (pre-iteration): 1687/1687 cases, 9207/9207 assertions
- Final (post-all-four-tasks): 1711/1711 cases, 9320/9320 assertions
- Delta: +24 cases, +113 assertions (all new suites: SynthesizedAliasExactHitSuite,
  LoanwordBareConsonantCodaSuite, LocativeParticleReachabilitySuite,
  StackLowerAaShapeFidelitySuite; plus StandaloneParticleMidBufferSuite amended,
  KinziTallAaSuite two cases amended)
- Pass rate: 100% (all 1711/9320 green at HEAD)
- Coverage delta: new suites cover the ah-/a- prefix convention (TASK-084), the 453-entry
  loanword coda class (TASK-085), U+104C locative particle (TASK-086), and 153 stack-lower+aa
  disagreement sites (TASK-087)

## Notes
- Commits land in chronological order: 79ee94b (TASK-085), 5117d0d (TASK-087), 7af131c (TASK-086),
  6813cef (TASK-084). The ordering reflects the TDD red-green sequence; each commit left the full
  suite green before the next task started.
- TASK-084's trust gate (`Romanization.isExactTrustworthyRow`) is a durable correctness invariant:
  it keeps reading-under-covering corpus residue (digit-surface rows, Zawgyi rows, pre-mapping ၌
  rows) out of the new exact-privilege paths. It must be preserved when touching exact-match logic.
- TASK-087 amended two KinziTallAaSuite cases that pinned behavior this task establishes as wrong;
  the amendment is fully documented in the task file and was reviewed by Step 4.
- The `seg_probe.test.ts` file in /tmp pre-dates this iteration (2026-06-07) and was left in place
  (out-of-repo scratch, not this pipeline's artifact).
