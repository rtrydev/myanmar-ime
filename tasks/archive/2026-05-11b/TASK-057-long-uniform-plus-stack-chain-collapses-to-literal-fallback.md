# TASK-057: Long uniform `+`-stack chains of identical bare-`<C>a` syllables collapse to literal-only at rank 0

## Status
Completed

## Implementation Notes
Fixed at the parser DP level (`Parser/NBestDP.swift`):

1. Added `.viramaStackLower` case to `SoftBoundaryContext` and extended
   `softBoundaryContext` to detect when a bare `onsetOnly(C)` sits as
   the lower of an existing virama stack — i.e. its parent ended on a
   virama vowel (either `onsetVowel(_, virama)` or `vowelOnly(virama)`).
   In that context the user's next `+` is admitted as a soft-boundary
   arc unconditionally so the parser produces a "break-the-chain"
   alternative instead of building a structurally illegal triple
   stack.

2. Zeroed the per-arc legality of `vowelOnly(virama)` and the paired
   `onsetVowel(_, virama)` transitions when the previous arc would
   chain a second virama. Three structural shapes trigger the
   rejection:
   - `previous = onsetOnly(C)` whose parent ended in a virama vowel,
   - `previous = onsetVowel(_, virama)` (the paired arc already emitted
     `<C><virama>`),
   - `previous = vowelOnly(virama)` (the split path already emitted
     the first stack's virama).
   With these arcs marked `isLegal = false`, the break-the-chain
   alternative becomes the lowest-syllableCount LEGAL parse and the
   standard min-tier finalize filter surfaces it at rank 0 without
   requiring any widening or rescue path.

The DP-level fix means the existing `parseLongestAcceptablePrefix`
and `finalizeStates` continue to work without changes. The fix also
helps TASK-058's `plus_chain_30` perf budget because the parser no
longer wastes DP work on the now-illegal chained-virama states (they
propagate `isLegal=false` through `pruneBucket`'s `isBetterDP`
comparator).

The fix changes two pre-existing test assertions that pinned the
old (incorrect) literal-only behaviour for these buffers:

- `Grammar.parse_tripleViramaStack_pPlusPPlusPa_isIllegal`: was
  asserting `parseCandidates("p+p+pa").first.legalityScore == 0`
  (the parser surfacing the triple-stack form). The test now asserts
  the top-1 surface has no chained-virama signature — the intent
  (triple stack illegal) is preserved, the assertion just reflects
  the new break-the-chain top-1.
- `LiteralFallbackIllegalSurface.classB_extremeCollapsePromotesLiteralToRankZero`:
  was including `k+k+k+k+k+k` and `k+k+k+k+k+k+k+k` in its Class B
  collapse list. With the fix these now produce full-chain Burmese
  surfaces at rank 0, so they moved to a new sibling test
  (`classB_plusChainKeepsBurmeseAtRankZero`) that asserts the
  Burmese rank-0 with the literal reachable lower in the panel.

A new test suite `UniformPlusChainStackSuite` covers the bug class
end-to-end (4-stack control, 5+ stack chains, trailing tone, mixed
heterogeneous control, triple-stack absence at rank 0).

## Problem Description
When the user types five or more identical bare-`<C>a` syllables joined
by explicit `+` (`ka+ka+ka+ka+ka`, `twa+twa+twa+twa+twa`,
`ka+ka+ka+ka+ka+ka.`, …), the parser fails to materialise any complete
multi-stack Myanmar surface for the chain. Rank 0 is the literal raw
buffer; the only Burmese candidates that appear in the panel are
short-prefix shapes (single `က္က` stack, etc.) covering only a small
fraction of what the user typed.

This is **distinct from** archived TASK-035, which addressed identical
**medial-bearing open-syllable** chains (`kya+kya+kya`, `pwa+pwa+pwa`)
under the production engine's lexicon ranking. The present task is a
**parser-level** failure — it reproduces on the bare engine
(`BurmeseEngine()`, no LM/lexicon) — and applies to bare-`<C>a` chains
without any medial.

The threshold is sharp:

| Buffer                    | Stacks | Rank-0 surface (hex)                                  | Pass? |
|---------------------------|--------|-------------------------------------------------------|-------|
| `ka+ka`                   | 1      | `က္က` (`1000 1039 1000`)                              | ✓     |
| `ka+ka+ka`                | 2      | `က္ကက` (`1000 1039 1000 1000`)                        | ✓     |
| `ka+ka+ka+ka`             | 3      | `က္ကက္က` (`1000 1039 1000 1000 1039 1000`)            | ✓     |
| `ka+ka+ka+ka+ka`          | 4      | literal `ka+ka+ka+ka+ka` (5 chars × 5)               | **FAIL** |
| `ka+ka+ka+ka+ka+ka`       | 5      | literal `ka+ka+ka+ka+ka+ka`                          | **FAIL** |
| `ka+ka+ka+ka+ka+ka+ka`    | 6      | literal `ka+ka+ka+ka+ka+ka+ka`                       | **FAIL** |
| `tar+tar+tar+tar+tar`     | 4 (vowel-r) | `တာတာတာတာတာ` (`1010 102C × 5`)                       | ✓ (open vowel keeps chain alive) |
| `ka+ta+ka+ta+ka`          | 4 (heterogeneous) | `ကတကတက`                                       | ✓ (heterogeneous) |
| `twa+twa+twa+twa+twa`     | 4 (medial bare-a) | literal only at rank 0                       | **FAIL** |
| `ka+ka+pa+ka+ka`          | 4 (one different letter) | `က္ကပက္က`                              | ✓ (heterogeneity breaks the trap) |

The pattern is **uniform identical bare-`<C>a` syllables** chained by
`+`, length ≥5 syllables. As soon as ANY syllable in the chain differs
from the others (`ka+ka+pa+ka+ka`) or carries a vowel rule that
materialises a non-`a` mark (`tar+tar+...`), the chain parses cleanly.

Adding a trailing tone marker does NOT rescue the chain:

| Buffer                | Rank-0 surface (hex)                                 |
|-----------------------|------------------------------------------------------|
| `ka+ka+ka+ka.`        | `က္ကက္က့` (`1000 1039 1000 1000 1039 1000 1037`) ✓ |
| `ka+ka+ka+ka+ka.`     | literal `ka+ka+ka+ka+ka.` ✗ (tone scalar lost too)   |
| `ka+ka+ka+ka+ka+ka.`  | literal ✗                                            |

So the trailing-tone variant of `MultiStackTrailingToneSuite` only
covers up to 4 stacks; the bug class begins exactly at 5.

## Root Cause
The parser's N-best DP (`Packages/BurmeseIMECore/Sources/BurmeseIMECore/
Parser/NBestDP.swift`) appears to collapse states aggressively when the
prefix-equal beam is filled with identical-letter parses. For uniform
identical-letter chains the DP bucket at every stack column contains
the SAME `<C>` arc multiple times, and the bucket-pruning step
(`pruneBucket`) drops competing partial parses that would otherwise
extend the stack chain.

When the chain length crosses a threshold (~4 segments / 14+ chars but
still under `compositionWindowSize = 18`), the surviving DP states no
longer cover the full input span, so `Finalization` returns no full
parse — the literal-fallback path then runs and emits the raw buffer at
rank 0.

The bare-engine reproduction proves the bug is in the parser layer, not
the LM/lexicon ranker. The `MultiStackTrailingToneSuite` tests up to
`ka+ka+ka+ka.` (4 stacks + tone) and currently passes — the bug fires
one rung beyond.

## Burmese Language Rule Reference
CLAUDE.md §6 ("Explicit `+`"): *"User-typed `+` is a hard syllable /
stack boundary."* The user has explicitly requested N-1 stacks across N
syllables; the engine must materialise a Myanmar surface for the entire
chain or fall back to the literal at rank 0 ONLY when the chain is
genuinely unparseable. A chain of identical bare-`<C>a` stacks IS
trivially parseable (each segment maps to `<C> 1039 <C>` repeated), so
the literal-only outcome is wrong.

CLAUDE.md §7 ("General reachability rule"): *"the user's intended
conversion must appear in the candidate panel at all, top 3 strongly
preferred."* For these inputs the full-chain Burmese surface does not
appear at ANY rank in the panel — only short-prefix surfaces do. This
is a hard reachability failure, not a soft ranking issue.

## Steps to Reproduce
1. Build the bare engine `BurmeseEngine()` (the bug reproduces without
   the lexicon/LM).
2. For each buffer in `{ka+ka+ka+ka+ka, ka+ka+ka+ka+ka+ka,
   twa+twa+twa+twa+twa, ka+ka+ka+ka+ka.}`, call
   `engine.update(buffer: input, context: [])`.
3. Inspect `state.candidates`. Confirm that no candidate's surface
   contains `<C>1039<C>` repeated ⌊N/2⌋ times where N = input syllable
   count.
4. Compare to `ka+ka+ka+ka` (one stack fewer) — that produces
   `က္ကက္က` at rank 0 cleanly. Compare to `ka+ka+pa+ka+ka` (one letter
   different) — that produces `က္ကပက္က` at rank 0 cleanly. The bug is
   triggered specifically by uniformity at length ≥5.

## Current State
- 5+ identical bare-`<C>a` `+`-chained syllables: rank 0 = literal
  raw buffer; full-chain Burmese surface absent from the panel.
- 1–4 identical bare-`<C>a` stacks: parses correctly.
- Heterogeneous chains of any length: parses correctly.
- Adding a trailing tone marker does not rescue the chain.

## Desired State
- For `ka+ka+ka+ka+ka`, rank 0 should be `က္ကက္ကက` (`1000 1039 1000
  1000 1039 1000 1000`) — extending the 4-stack pattern.
- For `ka+ka+ka+ka+ka+ka`, rank 0 should be `က္ကက္ကက္က` (3 stacks ×
  2 + 1) or equivalent canonical multi-stack surface.
- For `twa+twa+twa+twa+twa`, rank 0 should contain 5 `တွ` (`1010 103D`)
  segments joined by `1039` virama as appropriate.
- For `ka+ka+ka+ka+ka.`, rank 0 should be the 5-stack chain followed
  by a creaky tone scalar.
- The literal raw buffer remains reachable in the panel (it is the
  current rank-0; demoting it to a lower rank is acceptable).

## Acceptance Criteria
- For each buffer in `{ka+ka+ka+ka+ka, ka+ka+ka+ka+ka+ka,
  ka+ka+ka+ka+ka+ka+ka, twa+twa+twa+twa+twa, ka+ka+ka+ka+ka.,
  ka+ka+ka+ka+ka:}`, the panel contains at least one Myanmar candidate
  whose surface span covers the entire input chain (count of `1000` or
  `1010` base-consonant scalars in the surface ≥ count of `+`-separated
  bare-`<C>a` syllables in the input).
- For each buffer, rank 0 may be either that full-chain Myanmar
  candidate OR the literal raw buffer (current behaviour); panel
  presence is the hard requirement, rank 0 is preferred.
- Adding the new test cases must NOT regress
  `MultiStackTrailingToneSuite` (existing 4-stack-plus-tone behaviour
  stays at rank 0).
- Adding the new test cases must NOT regress
  `IdenticalMedialPlusChainSuite` (medial chains).
- Adding the new test cases must NOT regress `RepeatedLetterPerfSuite`
  or `BurmeseBench` `plus_chain_30` (see TASK-058 — perf regression on
  the same scenario).

## Notes
- Code locations to investigate:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/NBestDP.swift`
    — `pruneBucket`, the DP-bucket equality / state-fingerprint code.
    Likely the bucket coalesces identical `<C>` partial parses across
    successive stack columns, eliminating the path that would extend
    the chain through column N+1.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/SyllableParser.swift`
    — the wiring of stack arcs (`+` segment-separator) feeding into
    the DP.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`
    — `compositionWindowSize = 18`. The 5-segment `ka+ka+ka+ka+ka` is
    14 chars (under the threshold), so windowing is NOT involved in
    the failure; it is a pure parser bucket-pruning issue.
- Probe outputs (current `main`, commit `0f1a871`, bare engine):
  ```
  ka+ka+ka+ka       -> [0] က္ကက္က (1000 1039 1000 1000 1039 1000)         ✓
  ka+ka+ka+ka+ka    -> [0] ka+ka+ka+ka+ka (literal)                        ✗
                       [1] က္က (1000 1039 1000)            ← short prefix only
  ka+ka+ka+ka+ka.   -> [0] ka+ka+ka+ka+ka. (literal)                       ✗
                       [1] က္က့ (1000 1039 1000 1037)
  twa+twa+twa+twa+twa -> [0] literal                                       ✗
                       [1] တွ (1010 103D)                  ← short prefix only
  ka+ka+pa+ka+ka    -> [0] က္ကပက္က (1000 1039 1000 1015 1000 1039 1000)   ✓ (heterogeneity)
  tar+tar+tar+tar+tar -> [0] တာတာတာတာတာ (1010 102C × 5)                  ✓ (open-vowel `r`)
  ```
- This bug is correctness-disruptive but practically rare in real
  Burmese typing — uniform identical-letter stack chains are not a
  natural language shape. However it surfaces in the perf bench
  scenario `plus_chain_30` (`ka+` × 10), so any fix should also help
  TASK-058's perf budget.
- The closely-related `MultiStackTrailingToneSuite.swift:80-105` pins
  4-stack behaviour as the explicit acceptance ceiling; this task
  extends the ceiling by one rung and on uniform shapes generally.

## Validation Report

**Verdict:** FULLY_COVERED

- **Acceptance Criteria:** All buffers (`ka+ka+ka+ka+ka`, `…+ka+ka`,
  `ka+ka+ka+ka+ka+ka+ka`, `twa+twa+twa+twa+twa`, `ka+ka+ka+ka+ka.`,
  `ka+ka+ka+ka+ka:`) covered by `UniformPlusChainStackSuite` cases
  `uniformPlusChain_panelHasFullChainSurface` and
  `uniformPlusChain_rank0IsFullChainOrLiteral`. Counts use the
  base-consonant-scalar predicate from the task body, which is
  unambiguous and resilient to canonical-form drift.
- **Test rigor:** 6 cases in `UniformPlusChainStackSuite` cover panel
  presence, rank-0 promotion, literal reachability, heterogeneous
  contrast, trailing-tone behavior, 4-stack control, and
  triple-virama-stack absence. The new `noTripleViramaStackAtRank0`
  case adds a structural-shape sanity check that complements the
  per-buffer `≥N base-consonants` count.
- **Test rewrite review:** `Grammar.parse_tripleViramaStack…` was
  rewritten from `legalityScore == 0` (which pinned the buggy
  triple-stack top-1) to a structural assertion that the top-1
  surface contains no `<C> 1039 <C> 1039 <C>` chain. The new
  assertion is a tighter expression of the original intent
  ("triple stack illegal") — not a weakening. It would catch any
  regression where the parser starts emitting that scalar shape
  again.
  `LiteralFallbackIllegalSurface.classB_extremeCollapsePromotes…`
  removed two buffers (`k+k+k+k+k+k`, `k+k+k+k+k+k+k+k`) that no
  longer Class-B-collapse, and added a sibling case
  `classB_plusChainKeepsBurmeseAtRankZero` asserting both that rank-0
  is Burmese AND the literal stays in the panel. Net coverage is
  strengthened: same 4 buffers, but the new case asserts
  rank-0-Burmese (a stronger property than the old "literal at top").
- **Regressions:** None. Full suite 1543/1543 passes.
- **Side benefit:** TASK-058 perf budget largely recovered as a side
  effect (see TASK-058 validation).

## Validation Notes
- **Validity:** Confirmed valid against current `main`. Reproduced on
  bare engine with `BurmeseEngine()` (no LM/lexicon). The threshold is
  exact and sharp: rank-0 is the full-chain Burmese surface for 1–4
  identical bare-`<C>a` syllables joined by `+`, and is the literal raw
  buffer at exactly 5+. Heterogeneous chains (`ka+ka+pa+ka+ka`,
  `ka+ta+ka+ta+ka`) parse correctly at any length tested.
- **Step 2 probe outputs** (commit `fdd6541`, bare engine):
  ```
  ka+ka+ka+ka       -> [0] က္ကက္က                        OK
  ka+ka+ka+ka+ka    -> [0] literal, [1] က္က              FAIL
  ka+ka+ka+ka+ka+ka -> [0] literal, [1] က္က              FAIL
  twa+twa+twa+twa+twa -> [0] literal, [1] တွ              FAIL
  ka+ka+pa+ka+ka    -> [0] က္ကပက္က                       OK (heterogeneous)
  tar+tar+tar+tar+tar -> [0] တာတာ္တာတာတာ                 OK (open vowel keeps chain alive)
  ka+ka+ka+ka.      -> [0] က္ကက္က့                       OK (4 stacks + tone)
  ka+ka+ka+ka+ka.   -> [0] literal                         FAIL (5 stacks + tone)
  ```
  All outputs match the task's reported behaviour exactly.
- **Scope:** Correctly scoped. The threshold is precisely "≥5 uniform
  identical bare-`<C>a` syllables joined by `+`". The task already
  covers the relevant variations (medial-bearing `twa`, trailing tone,
  heterogeneity counter-examples). No widening or splitting needed.
- **Acceptance criteria:** Already testable and reasonable. The criteria
  use the `1000` / `1010` scalar count predicate, which is unambiguous
  and resistant to canonical-form drift.
- **Burmese rule references:** CLAUDE.md §6 (explicit `+` is a hard
  syllable boundary) and §7 (general reachability rule) are correctly
  cited. The task correctly notes this is a hard reachability failure,
  not a soft ranking issue.
- **Application feature deliberation:** Could the literal-only outcome
  be a deliberate "uniform-letter pathological input → emit literal"
  decision? No. CLAUDE.md §2 says literal is rank 0 only when (a) the
  candidate list is empty, (b) the rank-0 Burmese surface is illegal,
  or (c) rank 0 is mostly-unconverted ASCII. None apply here:
  `ka+ka+ka+ka+ka` is structurally legal and has 4-stack siblings
  proven by length-4 working. The 5-stack threshold is a parser bug,
  not a deliberate cap.
- **Changes made:** Status updated to `Revised`. No content changes
  required — the task is well-formed and accurately described.
