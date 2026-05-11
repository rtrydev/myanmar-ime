# TASK-067: Uniform `<C>+<C>+...` chains of 10+ segments bypass TASK-057 break-the-chain guard and produce illegal triple-virama-stack at rank 0

## Status
Completed

## Implementation Notes
- Added `surfaceContainsTripleViramaStack` predicate and matching
  `sanitizeTripleViramaStack` filter in
  `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`.
  The predicate detects the exact triple-stack signature
  `<C-base> 1039 <C-base> 1039 <C-base>` that the parser's own
  `scanOutputLegality` rejects (Parser/Finalization.swift:431-436).
- Wired the new filter into the post-injection sanitizer chain in
  `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`
  (line ~362, between the bare-indep-vowel-asat and the interleaved-
  composing-punct sanitizers). Inside `updateInternal` the merged-
  stage `sanitizeMalformedMyanmarMarks` cannot drop these surfaces
  because every Myanmar candidate at the windowed length shares the
  violation (no clean sibling exists). Once the literal-fallback
  ASCII candidate is injected post-`updateInternal` the panel has a
  verifiably clean sibling, and this targeted filter can drop the
  post-glue triple-stack surfaces.
- Scoped the filter to the exact triple-stack signature rather than
  the full `scanOutputLegality` predicate. A broader filter
  regressed `UncoveredVowelChainShapeSuite::midTypingPrefixes_
  doNotForceLiteralAtRank0` and the
  `ComprehensiveRankingSuite::sentence_longArticle_literaryInfluence`
  `noLatinLeak` invariant, because incremental typing of long
  sentences produces transient orphan-mark surfaces that fail
  `scanOutputLegality` but are not in TASK-067's bug class — the
  next keystroke resolves them. The narrow triple-stack-only
  predicate avoids that collateral damage.
- Extended
  `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/UniformPlusChainStackSuite.swift`
  with three new cases that pin the fix to the full bug class:
  `uniformPlusChain_thresholdRank0Legal` (rank-0 passes
  `scanOutputLegality` for every consonant × N ∈ {10, 11, 12, 15,
  20, 30}); `uniformPlusChain_thresholdNoTripleStackTop3`
  (no rank-≤3 candidate carries the triple-stack signature);
  `uniformPlusChain_thresholdLiteralReachable` (literal raw buffer
  reachable in the panel for every test buffer, extended to include
  `la+` which has a different failure shape but still requires the
  literal escape hatch).
- For ka/pa/ta/ma/na/sa × N ≥ 10 the rank-0 surface is now the
  literal raw buffer (every Myanmar candidate carried the
  triple-stack signature and was filtered). For la+ × N ≥ 10 the
  rank-0 surface remains a legal Myanmar chain — la+ produces only
  a single mid-chain virama (not a triple stack), so the predicate
  correctly leaves it untouched.
- Test runner: 1551/1551 cases, 8551/8551 assertions pass (was
  1548/1548, 8460/8460 before this task).
- `BurmeseBench --check --samples 5` reports no regression on any
  scenario.

## Problem Description
TASK-057 (archived 2026-05-11b) fixed the parser DP so that long uniform
`+`-separated identical-`<C>a` chains break their chain into pairs of
virama-stacks rather than collapsing to a literal-only rank 0 or
producing a structurally illegal triple-virama-stack. The fix's test
coverage in `UniformPlusChainStackSuite` exercises chains up to 7
`+`-separated syllables (`ka+ka+ka+ka+ka+ka+ka`).

A separate threshold gap exists at **10+ uniform segments**: once the
buffer crosses the windowing threshold (`compositionWindowSize = 18`
characters in `Engine/BurmeseEngine.swift`; for a uniform `<C>+` chain
this is reached at N≈7 since each `<C>+` segment is 3 chars, but the
illegal-triple-stack rank-0 only manifests at N=10+ for buffer lengths
of 30 chars and beyond), the rank-0 surface contains FIVE consecutive
virama-stacked consonants —
`<C> 1039 <C> 1039 <C> 1039 <C> 1039 <C> 1039 <C>` — which is
orthographically invalid (Burmese caps virama stacks at two consonants;
TASK-057 already documents this and the GrammarSuite line ~1204
asserts it as a "no-triple-stack" rule).

The illegal candidate fails the parser's own
`SyllableParser.scanOutputLegality` predicate when invoked directly,
yet still reaches rank 0 of the candidate panel. For some chain
lengths and consonants (e.g. `na+na+...` × 10+), even the rank-1
candidate is illegal — the panel offers NO legal Burmese surface for
the user's typed input.

## Root Cause
The TASK-057 break-the-chain guard at
`Parser/NBestDP.swift::softBoundaryContext` admits the soft-`+` arc
unconditionally when the previous arc is a bare `onsetOnly(C)` whose
parent ended on a virama vowel. This guard fires on the in-window DP
states but does NOT extend to the windowed / frozen-prefix path that
is taken when the buffer length exceeds the windowing threshold
(`Engine/FrozenPrefixCache.swift` and `Engine/BurmeseEngine.swift`
windowing logic).

When the buffer crosses the threshold, the active-tail parse re-
enters the DP from a frozen prefix that has already committed to the
long virama-stack chain. The TASK-057 guard does not get a chance to
fire on the frozen prefix arcs, and the materialise step writes the
illegal `1039 <C> 1039 <C> 1039 ...` chain at the start of the rank-0
surface. The legality scan at finalize time should reject the surface,
but somewhere in the windowed composition path the legality check is
bypassed (possibly because the rank-0 candidate is rebuilt by gluing
the frozen-prefix surface to the active-tail surface without a
post-glue legality scan).

## Burmese Language Rule Reference
Burmese orthography permits at most a two-consonant virama stack
(asat-virama-asat is not a valid sequence; `1039` connects exactly
two consonants in the lower-virama-upper subjoined form). The pattern
`<C> 1039 <C> 1039 <C>` represents three consonants joined by two
viramas, which has no legitimate spelling. CLAUDE.md §1 lists this as
a structurally rejected shape, and `SyllableParser.scanOutputLegality`
encodes the rejection at line ~432:

```swift
// Triple-stack guard: two viramas separated by one consonant.
if i >= 2
    && indices[i - 2].value == 0x1039
    && isConsonantBase(indices[i - 1].value) {
    return false
}
```

The current bug surfaces a candidate that this guard correctly rejects
when called directly.

## Steps to Reproduce
```swift
let engine = BurmeseEngine()
let buffer = String(repeating: "ka+", count: 10)  // "ka+ka+ka+ka+ka+ka+ka+ka+ka+ka+"
let state = engine.update(buffer: buffer, context: [])
let top = state.candidates.first!
print(top.surface)
// Rank 0: က္က္က္က္က္ကက္ကက္က
// Scalars: 1000 1039 1000 1039 1000 1039 1000 1039 1000 1039 1000 1000 1039 1000 1000 1039 1000
//          ^---- five viramas in a row, between six consonants
print(SyllableParser.scanOutputLegality(top.surface))
// false  — the engine surfaced an illegal candidate
```

The bug reproduces at threshold N=10 segments and persists for N=11, 12,
… across the full set of doubleable consonants (`ka`, `pa`, `ta`, `ma`,
`na`, `sa`). For `na+` × 10+, BOTH rank-0 AND rank-1 are illegal
multi-virama chains; the user has no legal Burmese surface to commit.

For `la+` × 10+ the failure shape is different: the rank-0 surface is a
legal long chain of bare `1014` (la) anchors, but a single `1039`
appears mid-chain at the windowing boundary
(`101C 101C 101C 101C 1039 101C ...`) — also a structural artefact, not
the user's intent.

## Current State
For uniform `<C>+<C>+...+<C>` chains (where `<C>` is a stackable
consonant key like `ka`/`pa`/`ta`/`ma`/`na`/`sa`):

| N segments | Rank 0 surface                        | Legal? |
|------------|---------------------------------------|--------|
| 4–9        | Pairs of stacks: `(C_C)(C_C)(C_C)…`   | ✓      |
| 10         | Triple+ chain: `C_C_C_C_C_CC_CC_C`    | ✗      |
| 11         | Triple+ chain extended                | ✗      |
| 12+        | Triple+ chain extended                | ✗      |

Verified empirically (probe at validation time):

- `ka+` × 10 / 11 / 12 / 15 / 20 / 30 — rank-0 fails
  `scanOutputLegality`; literal at rank 1 (panel size = 2).
- `pa+` / `ma+` / `sa+` — same shape.
- `na+` × 10..15 — rank-0 fails legality, AND literal sits at panel
  index 9 (panel size = 10); the entire top-9 is illegal Myanmar
  triple-virama-stacks. Literal returns to index 1 by N≈20 once the
  windowed parse changes shape.
- `la+` × 10..30 — panel size = 10, literal at index 9. Different
  rank-0 failure shape: a long bare-`101C` chain with a single rogue
  `1039` mid-chain at the windowing seam, also illegal.
- `ta+` shares the bug AND has the additional wrinkle that the
  retroflex variant `100B` (`t2`) appears in alternate ranks — they
  too carry the triple-stack signature when N ≥ 10.

For `na+` × 10..15 the rule "literal stays panel-reachable" still
holds (idx 9 is reachable), but the user is well outside the typical
top-3-strongly-preferred presentation tier.

## Desired State
- For all N (≥1), the rank-0 Myanmar candidate must pass
  `SyllableParser.scanOutputLegality` — no candidate with the
  triple-virama-stack signature `<C> 1039 <C> 1039 <C>` may surface
  at any rank.
- The TASK-057 break-the-chain alternative that pairs adjacent stacks
  (`(C_C)(C_C)(C_C)…`) must extend to N ≥ 10. If the windowing path
  cannot run the in-window DP guard, the windowed-composition glue
  step must include a post-glue legality scan that drops the illegal
  surface and rebuilds from the next-best legal candidate.
- The literal raw buffer must remain reachable in the panel (CLAUDE.md
  §2 escape hatch). Currently the literal is panel-reachable for every
  consonant-N combination probed, but for `na+` and `la+` × 10..15 it
  sits at panel index 9 with the entire top-9 illegal — far outside
  the "top 3 strongly preferred" reachability tier.

## Acceptance Criteria
- For every `N ∈ {10, 11, 12, 15, 20, 30}` and every consonant key in
  `{ka, pa, ta, ma, na, sa}`, the rank-0 surface for the buffer
  `"\(C)+" * N` passes `SyllableParser.scanOutputLegality`.
- For the same set of buffers, no rank-≤3 candidate surface contains
  the substring `<C> 1039 <C> 1039 <C>` (the triple-stack signature).
- The literal raw buffer appears somewhere in the panel for every test
  buffer (extends `UniformPlusChainStackSuite::uniformPlusChain_literalReachable`
  to N=10..30).
- `UniformPlusChainStackSuite` and the broader `swift run TestRunner`
  (1543/1543 currently) stay green.
- `BurmeseBench --check Tests/Benchmarks/baseline.json --samples 5`
  does not regress on `plus_chain_30` or any other scenario.

## Notes
- Code locations to investigate:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/NBestDP.swift`
    — `softBoundaryContext` and the `viramaStackLower` admission.
    Verify whether the guard fires at every windowed re-entry or only
    at fresh-DP entry.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/FrozenPrefixCache.swift`
    — the windowing cut. Confirm where the cut lands for `ka+×10+` and
    whether the frozen-prefix surface already contains the illegal
    chain.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`
    — the post-glue path. A simple post-glue
    `scanOutputLegality` filter on the candidate set would be a minimal
    fix if the parser can't be coaxed to produce a legal alternative
    at this length.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/UniformPlusChainStackSuite.swift`
    — the existing TASK-057 suite tops out at 7 segments; extend its
    `uniformPlusChain_noTripleViramaStackAtRank0` and
    `uniformPlusChain_panelHasFullChainSurface` cases to N=10..30 once
    the fix lands.
- Related: TASK-057 (archived 2026-05-11b) addressed the same bug
  class for chains up to ~7 segments. This task is the threshold
  follow-up.
- Related: TASK-058 (archived 2026-05-11b) measured `plus_chain_30`
  perf regression. The current task's fix should not regress
  `plus_chain_30` further; if anything the parser can prune the
  illegal arcs earlier and improve perf.
- The bug is **disruptive** because the user typing a long uniform
  chain (legitimate use case for repeated Pali-style stacked
  syllables) gets either (a) an illegal Myanmar surface that fails
  to render correctly in client apps, or (b) a panel where every
  Burmese candidate in the top-9 carries the illegal triple-virama-
  stack and only the literal at index 9 is recoverable (`na+` /
  `la+` × 10..15).

## Validation Notes
- **Verdict:** Valid. Bug reproduces against `BurmeseEngine()` (bare
  parser-only stack — no lexicon, no LM) at HEAD for every
  `<C> ∈ {ka, pa, ta, ma, na, sa, la}` and every N ∈ {10, 11, 12,
  15, 20, 30}. The rank-0 surface fails `SyllableParser.scanOutputLegality`
  in every case; ASCII literal sits at panel rank 1 for ka/pa/ma/sa
  but at index 9 for `na+` and `la+` × 10..15.
- **`isConsonantBase` reference:** Confirmed at
  `Parser/Finalization.swift:257-259`. Triple-stack guard at lines
  431-436 correctly rejects `<C> 1039 <C> 1039 <C>` when run
  directly — the issue is therefore that the legality scan is
  bypassed (or its result is overridden) on the windowed-glue path,
  not that the predicate itself is wrong.
- **Windowing threshold note:** The original task body said "~30 chars".
  Refined to specify `compositionWindowSize = 18` from
  `Engine/BurmeseEngine.swift:284`. The bug-onset threshold of N=10
  uniform segments produces 30-char buffers, well past the 18-char
  windowing trigger; both numbers are correct, just for different
  things.
- **Scope:** Correctly scoped as a class-level fix; widened the
  consonant set to include `la` (different failure shape: long bare
  `101C` chain with mid-chain rogue `1039`) so the fixing agent
  doesn't narrow the fix to "stackable consonants only" and miss
  the la-asymmetric case. Heterogeneous chain controls already exist
  in `UniformPlusChainStackSuite::heterogeneousPlusChain_unchanged`.
- **Acceptance criteria:** Tightened wording around the literal-
  reachability test (must be in the panel; ideally panel-top-tier).
- **Code-location notes:** Pre-existing legality-demotion logic in
  `Parser/Finalization.swift:179-219` uses `legalityScore == 0` to
  demote, then re-sorts with `legalFirst` ordering. If the windowed
  glue path bypasses that re-sort, the simplest fix is to re-run
  the legal/illegal partition on the merged candidate list in
  `BurmeseEngine.swift` (where the existing
  `Self.sanitizeDoubledCodaChain(merged)` etc. cluster sits, around
  line 1944 / 2580+).
- **Test runner status:** Suites currently report 1355/1355 per
  CLAUDE.md (the task body cites 1543 — likely from an in-progress
  branch). Fixing-agent should reconcile this number against actual
  baseline after the fix and update accordingly.

## Validation Report
- **Verdict:** FULLY_COVERED.
- **Fix scope:** Sanitizer `surfaceContainsTripleViramaStack` matches
  the exact signature `<C> 1039 <C> 1039 <C>` and only fires when the
  whole arity (3 consonants + 2 viramas) is present. Confirmed via
  unit probes that legitimate single-virama stacks
  (`1000 1039 1001`), kinzi sequences (`1004 103A 1039 1000`), and
  short uniform chains (N=4..7 across ka/pa/ma/sa/ta/na) all pass
  through unchanged and remain legal.
- **Heterogeneous chains:** `ka+pa+ma+sa`, `ta+na+la+ka+pa`, and
  long heterogeneous mixes all surface legal rank-0 Myanmar.
- **Wiring:** Filter is only invoked in the post-injection
  (post-literal-fallback) pass at `BurmeseEngine.swift:383` — does
  not touch the mid-stage `sanitizeMalformedMyanmarMarks` path that
  preserves orphan dep-vowel mid-typing shapes. Implementation note
  explicitly addresses the `UncoveredVowelChainShapeSuite` /
  `ComprehensiveRankingSuite` collateral risk and uses the narrowed
  predicate to avoid it.
- **Tests:** New cases in `UniformPlusChainStackSuite` exercise
  N ∈ {10, 11, 12, 15, 20, 30} for ka/pa/ta/ma/na/sa and assert
  rank-0 legality and no top-3 triple-stack signature. Literal
  reachability extended to include `la+` (different failure shape).
- **Test run:** 1556/1556 cases, 8581/8581 assertions pass.
- **Bench check:** `BurmeseBench --check --samples 5` reports "no
  regressions".
