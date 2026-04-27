# Pipeline Iteration Summary — 2026-04-27

## Tasks Completed
| Task ID | Title | Commits |
|---------|-------|---------|
| TASK-010 | Pali-stack inference skips bare independent vowels other than `a` | 24ac643 |
| TASK-011 | Explicit `+` between two vowel-bearing syllables is silently discarded | 62558db |
| TASK-012 | Windowed prefix emits illegal independent-vowel + virama at rank 0 | 4a017c8 |
| TASK-013 | Repeated single-letter buffers degrade per-keystroke latency to 10ms+ | 7073ba9 |
| TASK-014 | Bare consonant + `:` produces literal colon instead of visarga heavy tone | 6442909 |
| TASK-015 | Onsetless vowel clusters in sequence produce malformed multi-anchor surfaces | be5a0d6 |
| TASK-016 | Repeated `a` letters after a consonant silently collapse to one syllable | abb4ee6 |

## Tasks Invalidated
| Task ID | Title | Reason |
|---------|-------|--------|
| (none) | | |

## Regressions Encountered
No regressions were reported by step 4. The benchmark `--check` passed for all
tasks. One intentional test-case narrowing occurred in TASK-015:
`BareVowelRepetitionSuite.repeatedBareVowels_parserNativeSiblingReachable` had
its `o` and `u` sub-cases removed because the parser-native shapes (`ဦဦ` /
`ဩဩ`) now violate the new class-1 adjacent-independent-vowel invariant and are
correctly filtered. Only `e` and `i` retain a parser-native sibling in the
panel. This regression was intentional and consistent with the bug class the
task targets.

## Gaps Resolved
Step 5 was skipped — step 4 reported no gaps requiring follow-up work. All
tasks reported FULLY_COVERED except TASK-015, which was PARTIAL by design (see
Outstanding Items below).

## Outstanding Items
TASK-015 class-3 invariant (precomposed independent vowel immediately after a
dependent-vowel sign, e.g. `muur` → `မူဦရ`, `i+u` → `အီဦ`) was deliberately
not enforced. The same scalar shape arises from the legitimate two-syllable
`thiu`-style independent-particle pattern (`thi` + `u`), which is exercised by
existing passing tests (`Punctuation.engine_thiuDot_producesStandaloneBu_whenEnabled`,
`Ranking.issueA_rarthiuOffersIndependentVowelVariant`). Enforcing the invariant
broadly would break those tests. If a future user-reported case confirms that
class-3 malformation occurs in inputs that do not share the independent-particle
pattern, a narrower follow-up task should be opened scoped to onsetless leading
positions only.

## Test Suite Status
- Total test cases: 912 (TestRunner)
- Total assertions: 2846
- Pass rate: 100% (912/912 cases, 2846/2846 assertions)
- Benchmark: no regressions vs. committed baseline (`--check` passed)
- Coverage delta: new suites added — `BareVowelPaliStackSuite` (8 cases,
  TASK-010), `AdjacentIndependentVowelSuite` (4 cases, TASK-015); existing
  `BareVowelRepetitionSuite` narrowed by 2 sub-cases (TASK-015 intentional).
  New benchmark scenarios `repetition_t16` and `plus_chain_30` added (TASK-013).

## Notes
- The TASK-011 reshape (`<C>a+<C>` → `<C>+<C>a`) in `collapseConnectorRuns`
  eliminated the original TASK-012 reproduction path as a side-effect; the new
  `sanitizeIndepVowelVirama` sanitizer (TASK-012) is the belt-and-suspenders
  guard for future regressions through different code paths.
- TASK-013 tightened the DP beam multiplier (16x to 4x) only for buffers with a
  longest same-letter run >= 6; normal Burmese input retains the original wide
  beam. Benchmark baseline was updated to include the two new repetition/chain
  scenarios.
- TASK-016's inherent-A arc rejection guard is scoped to post-consonant
  contexts; buffer-leading bare-`aa` runs (no consonant ancestor) are preserved
  so the leading-A promotion path keeps producing U+1021 for inputs like
  `aa`/`aaa`.
