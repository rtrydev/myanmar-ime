# Pipeline Iteration Summary — 2026-05-05

## Tasks Completed
| Task ID | Title | Commits |
|---------|-------|---------|
| TASK-030 | Chained vowel-rule arcs surface a structurally illegal multi-cluster dep-vowel shape at rank 0 | d9efec7 |
| TASK-031 | Explicit user-typed `+` between `<C>in/an/en` and a stack lower is displaced from rank 0 by an LM-favoured cross-class segmentation | 93e0a0b |

## Tasks Invalidated
| Task ID | Title | Reason |
|---------|-------|--------|
| (none) | | |

## Regressions Encountered

**TASK-030 — Step 3 regression (resolved in Step 5).**
Step 3's implementation extended the Class A literal-fallback gate
(`isClassALiteralPromotionTrigger`) to fire on the new broad
`surfaceContainsMultiClusterOnSingleAnchor` predicate. This caused
intermediate buffer prefixes of long Myanmar sentences (e.g. `thueiooz`,
`thueiooza`, `thueioozar`, `thueioozark` from the `ComprehensiveRanking`
sentence test) to trigger literal raw-buffer promotion at rank 0, because
the mid-typing parse surface happened to contain a multi-cluster fragment
that would resolve once more characters were typed. Result: 1 assertion
failure (`ComprehensiveRanking.sentence_longArticle_literaryInfluence`
noLatinLeak) and a `plus_chain_30` perf gate failure (+17% p95, +9% p99).

Step 5 resolved both:
- Introduced a tighter predicate `surfaceIsWhollyMultiClusterOnSingleAnchor`
  (single-anchor, no internal asat/virama, multi-cluster shape) for use
  at the Class A gate; the broader predicate is retained only for the
  merge-time sanitizer where the "preserve when no clean exists" policy
  already protects mid-typing cases.
- Rewrote the predicate to avoid heap allocation per call (direct
  `unicodeScalars` iteration, 5-bit `UInt8` cluster bitset instead of
  `[Int]`, fast dep-vowel count pre-scan that bails at <2). The
  `plus_chain_30` p95 returned to ~265us against a 317us budget (baseline
  264us).
- Removed the post-fallback re-pass at the outer `update(...)` wrapper
  that Step 3 had added.

## Gaps Resolved

**TASK-030 gap (Step 4 PARTIAL → Step 5 Completed).**
The Step 3 implementation was structurally correct (new
`MultiClusterDepVowelOnAnchorSuite`, new predicate, wiring at three
engine points) but introduced the two regressions described above.
Step 5 narrowed the Class A gate predicate and optimized the hot path;
all 16 bug-class buffers (`kayoo`, `kayii`, `kayuu`, `thayoo`, `thayuu`,
`ngayoo`, `ngaii`, `kuoo`, `kioo`, `kaayoo`, `iuu`, `uii`, `ouu`,
`ooi`, `uua`, `ayoo`) now produce a clean rank-0 surface per the
acceptance criterion with no mid-sentence regression.

**TASK-031 gap (Step 4 NOT_IMPLEMENTED → Step 5 Completed).**
Step 3 exhausted its usage limit before touching TASK-031. Step 5
implemented it from scratch with three changes:
1. A new populate path for `strictInferredStackOutputs` on
   explicit-`+` buffers, using a new reading-match discriminator
   (`readingMatchesUserLiteralAcrossInherentVowels`) that allows the two
   specific inherent-vowel `a`-insertion patterns the parser applies
   (`a` immediately before a `+`, and trailing `a` after a bare trailing
   consonant) while rejecting any other segmentation-altering `a`.
2. Lifting the `!input.contains("+")` early-out at
   `bestStrictInferredStackIndex` so explicit-`+` buffers route through
   the same rank-0 promotion path as inferred-`+` cases, with a narrow
   carve-out when a lexicon candidate already sits at rank 0.
3. A new `ExplicitPlusKinziDisplacementSuite` (production-equivalent)
   covering the kinzi family, the asat-closure family, scalar-level
   assertions, baseline-preservation guards, cross-class loanword
   preservation, and discriminator-helper sanity tests.

## Outstanding Items

None from this iteration. All bug-class buffers for both tasks are
resolved and all acceptance criteria are met.

## Test Suite Status

- Cases: 1118/1118 passing (up from 1110 after TASK-030, up from 1110 before TASK-031)
- Assertions: 5242/5242 passing
- Coverage delta: added `MultiClusterDepVowelOnAnchorSuite` (TASK-030)
  and `ExplicitPlusKinziDisplacementSuite` (TASK-031)
- `BurmeseBench --check`: no regressions across all 15 scenarios on macOS

## Notes

- The Step 3 usage-limit hit is documented here as a process note. The
  pipeline handled it gracefully: Step 4 identified the two gaps (one
  regression, one not-yet-started task), and Step 5 closed both cleanly.
- The TASK-031 fix revealed a subtle asymmetry in the engine: user-typed
  `+` was paradoxically *weaker* than inferred `+` at keeping the
  intended kinzi/stack form at rank 0. The fix makes explicit-`+` at
  least as strong as implicit inference, which is the correct semantics.
- Probe files under `/tmp/` from this iteration were removed as part of
  archival cleanup (71 `.swift` source files and approximately 33
  compiled binaries).
