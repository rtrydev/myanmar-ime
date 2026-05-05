# TASK-031: Explicit user-typed `+` between `<C>in/an/en` and a stack lower is displaced from rank 0 by an LM-favoured cross-class segmentation

## Status
Completed

## Problem Description
When a user types an explicit virama-stack request — `<C>in+<C>` or
`<C>an+<C>` where the post-stack syllable is a single bare base + inherent
`a` (e.g. `min+ga`, `thin+ga`, `yan+gun`, `than+ga`, `kan+ga`,
`ran+ga`, `nan+ga`, `thin+kun`, `thin+gala`) — the production engine
ranks an LM-favoured alternative above the user's clearly-intended kinzi
form. The displacing surface uses a different segmentation entirely
(typically `nya-asat + na-virama + lower`, `1019 100A 103A 1014 1039 <C>`,
or an aa-anusvara form `<C> 1036 <C>`) that ignores the explicit `+` the
user inserted.

The bare engine (no LM, no lexicon) consistently ranks the kinzi /
proper-stack form at rank 0 for the same buffers. The bug is therefore
in the LM/lexicon-driven ranking layer of the production engine, not in
the parser or grammar.

This is corrosive because the explicit `+` is the strongest possible
user signal that they want a stacked syllable boundary at that exact
position — overriding it with an LM-preferred re-segmentation
fundamentally undoes user intent and forces the user to navigate past
multiple panels of "wrong" candidates to find the one they typed for.

## Root Cause
The composite-score comparator in
`Engine/CandidateRanking.swift::grammarCandidateIsBetter` weighs
`log(rank_score) + α · lmLogProb` — when the LM has strong evidence for
an unusual surface (because the corpus contains a high-frequency
bigram/trigram that happens to align with the unusual segmentation), it
can beat the kinzi-promotion bonus
(`bestStrictInferredStackIndex` rank-0 lift) on short buffers.

The kinzi-rank-0 promotion at `bestStrictInferredStackIndex` only fires
for surfaces in `strictInferredStackOutputs`, which is built from
`inferImplicitStackMarkers` — but `inferImplicitStackMarkers` returns
`nil` when `input.contains("+")` (it intentionally respects an explicit
user `+`, expecting that the `+` signal alone is enough to keep the
kinzi at rank 0). That assumption breaks down when the LM has enough
evidence to rank a non-kinzi sibling above the kinzi parse.

There is no parallel "user-explicit-`+` rank-0 promotion" — the engine
treats user-typed `+` and inferred `+` symmetrically up to the point
where one path runs `bestStrictInferredStackIndex` and the other does
not. The result: explicit `+` is, paradoxically, *weaker* than implicit
inference for keeping the user's intent at rank 0.

## Burmese Language Rule Reference
A user-typed `+` is the romanization scheme's mechanism for forcing a
virama-stack syllable boundary at that exact position. The orthographic
invariant: when the user has typed `<C1>...n+<C2>...`, the lower of the
inserted virama-stack must come from the character(s) on the right of
the `+`, and the upper must come from the immediately-preceding
syllable's coda. Re-segmenting the buffer to use a different upper
violates the user's explicit signal.

Two specific stack shapes show up in the bug class:

- **Kinzi** (`1004 103A 1039`): when the upper is `င` (nga, written
  as `n` followed by a stack site in the romanization), the closure
  is the kinzi triple. `min+ga` is unambiguously "`min` (with kinzi
  closure) + `ga`" → `မင်္ဂ` (`1019 1004 103A 1039 1002`). The
  alternative `မည်န္ဂ` (`1019 100A 103A 1014 1039 1002`) decomposes
  the `min` differently (nya-asat + na + virama + ga) — a structural
  change to the user's intended syllable count that no romanization
  rule the user followed produces.
- **Generic virama-stack** (`<upper> 103A <lower>` or
  `<upper> 1039 <lower>`): for non-`min`/`tin`/`thin` buffers like
  `kan+ga`, `than+ga`, `yan+gun`, the expected upper is the typed
  `n` of the preceding syllable closed with asat (`1014 103A`,
  rendering as `န်`). The displacing surface uses the anusvara `1036`
  (rendering as `ံ`) instead — `ကံဂ` instead of `ကန်ဂ`. Anusvara is
  a different scalar with a different reading; the user did not type
  the input for it.

The bug class is therefore broader than "kinzi displacement": it is
"any user-typed `+` displaced by an LM-preferred re-segmentation that
changes either the upper or the syllable boundary".

## Steps to Reproduce
With the production-equivalent engine (bundled SQLite lexicon + trigram
LM), evaluate any of:

- `min+ga`, `min+ga+min`
- `thin+ga`, `thin+gala`, `thin+ga+thin`, `thin+kun`
- `yan+gun`, `yan+kun`
- `than+ga`, `kan+ga`, `ran+ga`, `nan+ga`, `ban+ga` (occasional)

The rank-0 surface is **not** the kinzi/native-stack form. The kinzi
form sits at rank 1 or worse. Re-running the same buffer through a
bare `BurmeseEngine()` (no LM, no lexicon) returns the kinzi form at
rank 0 — confirming the parser produces it correctly and the
ranking-layer LM/lexicon signal is responsible for the displacement.

## Current State
Verified via `/tmp/validate-031` (production-equivalent engine vs bare
engine, side-by-side):

| Buffer | Production rank 0 | Bare-engine rank 0 (intended) | Kinzi/intended at rank |
|---|---|---|---|
| `min+ga` | `မည်န္ဂ` (1019 100A 103A 1014 1039 1002) | `မင်္ဂ` (1019 1004 103A 1039 1002) | 3 |
| `min+ga+min` | `မင်္ဂမင်` (correct) | `မင်္ဂမင်` | 0 |
| `thin+ga` | `သည်န္ဂ` | `သင်္ဂ` | 1 |
| `thin+gala` | `သည်န္ဂလ` | `သင်္ဂလ` | 1 |
| `thin+ga+thin` | `သည်န္ဂသင်` | `သင်္ဂသင်` | 1 |
| `thin+kun` | `သည်န္ကူန` | `သင်္ကူန` | 1 |
| `yan+gun` | `ယံဂူန` (anusvara, no virama-stack) | `ယန်ဂူန` | 1 |
| `yan+kun` | `ယံကူန` | `ယန်ကူန` | 1 |
| `than+ga` | `သံဂ` | `သန်ဂ` | 1 |
| `kan+ga` | `ကံဂ` | `ကန်ဂ` | 1 |
| `ran+ga` | `ရမ်ဂ` (different bare coda) | `ရန်ဂ` | 1 |
| `nan+ga` | `နံဂ` | `နန်ဂ` | 1 |
| `ban+ga` | `ဘန်ဂ` (correct) | `ဘန်ဂ` | 0 |
| `min+galarpar` | `မင်ဂလာပါ` (asat only, no virama-stack) | `မင်္ဂလာပါ` (with kinzi) | 1 |
| `min+ka` | `မင်္က` (correct) | `မင်္က` | 0 |
| `tin+ga` | `တင်္ဂ` (correct) | `တင်္ဂ` | 0 |
| `tin+ga+min` | `တင်္ဂမင်` (correct) | `တင်္ဂမင်` | 0 |

Two important observations from the side-by-side:

1. The `min+ga` case has the kinzi at rank 3, not rank 4 as originally
   stated.
2. `min+galarpar` is **also affected** — production rank 0 is
   `မင်ဂလာပါ` (`1019 1004 103A 1002 ...`) which has the asat but
   *not* the virama `1039` that closes the kinzi. The lexicon-attested
   `မင်္ဂလာပါ` (kinzi) sits at rank 1. This contradicts the original
   draft's claim that `min+galarpar` "continues to surface correctly".

Two important non-bugs to preserve as baselines:

- `min+ka`, `tin+ga`, `tin+ga+min`, `ban+ga`, `min+ga+min` all surface
  correctly at production rank 0 — the LM does not have a strong
  cross-class alternative for these. The fix must keep their rank-0
  outcomes.

The bare engine returns the orthographically expected form at rank 0
for every buffer in the *Bare-engine rank 0* column — confirming that
the parser produces the kinzi/virama-stack candidate and that the
ranking-layer LM/lexicon signal is responsible for the displacement,
not a parser bug.

## Desired State
- For any buffer of shape `<C>(in|an|en|on|...)+<C>...`, the user-typed
  `+` is treated as a hard syllable break and the kinzi or virama-stack
  surface that respects it sits at rank 0.
- LM/lexicon evidence may still re-rank between the multiple legal
  surfaces *that respect the `+`* (e.g. picking between same-class
  variants such as `1014` (na) vs `100F` (nna) at the lower position),
  but cannot promote a surface that re-segments around the `+` or
  swaps the upper coda from `<n>+asat` to `<anusvara>` /
  `<nya-asat>` / similar non-typed shape.
- Existing well-behaved buffers (`min+ka`, `tin+ga`, `tin+ga+min`,
  `ban+ga`, `min+ga+min`, and any lexicon-attested compounds whose
  rank-0 currently respects the `+`) continue to surface correctly.
  Note: `min+galarpar` is **not** currently well-behaved (see
  *Current State* — its kinzi form sits at rank 1) and the fix is
  expected to lift its kinzi form to rank 0 too.

## Acceptance Criteria
- New test suite (production-equivalent, using the bundled-engine
  helper pattern — see `AnchorStabilitySuite.bundledEngine`) covers
  all the bug-class buffers from *Current State*; each asserts that
  the rank-0 surface scalars match the bare-engine rank-0 (i.e. the
  kinzi/virama-stack form). For `min+ga`, the assertion is that
  rank-0 contains `1004 103A 1039` (kinzi triple) immediately followed
  by `1002` (ga). For `kan+ga`/`than+ga`/`yan+gun`/etc., the assertion
  is that rank-0 contains `1014 103A` (na + asat) at the user-typed
  `+` position rather than `1036` (anusvara).
- The same suite asserts that the baseline buffers (`min+ka`,
  `tin+ga`, `tin+ga+min`, `ban+ga`, `min+ga+min`) still rank their
  current correct kinzi-bearing surfaces at rank 0 — i.e. the fix
  does not regress already-correct cases.
- Existing suites (`KinziInferenceSuite`, `MidBufferStackInferenceSuite`,
  `WindowingKinziAcrossThresholdSuite`, `KinziTallAaSuite`,
  `CrossClassNTStackRankingSuite`) continue to pass without
  modification.
- The fix can take any of the following shapes — the criterion is the
  rank-0 outcome above:
  - Build `strictInferredStackOutputs` from the explicit-`+` path too
    (track the user-typed `+` positions, materialise the kinzi /
    same-class stack, and feed it through `bestStrictInferredStackIndex`).
    Concretely: drop the `!input.contains("+")` early-out at
    `InputNormalization.swift::inferImplicitStackMarkers` line ~660,
    so the function can still report the stack sites the user
    explicitly marked.
  - Add a new "user-explicit-`+` lock" that demotes any candidate
    whose surface decomposes the buffer at a different position than
    the user typed (i.e. the upper/lower boundary in the surface
    must align with the `+` boundary in the buffer).
  - Increase the `lmDominanceThreshold` for cases where the rank-0
    surface diverges from the virama-stack-bearing candidate by more
    than a bare-coda variant swap (e.g. `1014` vs `100F`), when the
    user typed `+` somewhere in the buffer.
- `swift run -c release BurmeseBench --check` reports no regression.

## Notes
- Probe verification: `/tmp/explore-probe10.swift` (production-equivalent
  vs bare engine, side-by-side comparison) reproduces every case.
- The displacement is *not* a lexicon-direct override (none of the
  wrong rank-0 surfaces are `source: .lexicon` — they remain
  `.grammar`). It is the LM log-prob composite-score winning the
  comparator on short buffers.
- This is the dual problem to TASK-058 / TASK-059 in the archive
  (which were about ya-pin promotion crossing the bare-engine vs
  production-engine boundary): the same comparator-vs-promotion gap
  manifests here for explicit-`+` kinzi.
- Code locations:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`
    — `bestStrictInferredStackIndex` lift (lines ~1692–1733),
    `inferImplicitStackMarkers` early-out for `+` (line ~660 in
    `InputNormalization.swift`).
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/CandidateRanking.swift`
    — `grammarCandidateIsBetter`, composite-score weighting.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/InputNormalization.swift::inferImplicitStackMarkers`
    — drop the `!input.contains("+")` early-out for the kinzi
    detection path, so the function can still report the kinzi sites
    on buffers that already carry a user `+`.

## Validation Notes
- **Verdict: Valid.** Reproduced every listed bug-class buffer under
  the production-equivalent engine. Probe transcript at
  `/tmp/validate-031`.
- **Changes during review:**
  - Replaced the original prose "Current State" with a buffer-by-
    buffer table including bare-engine rank-0 (the intended
    surface) and the rank at which the kinzi/virama-stack form
    actually appears in production. Concrete scalar comparisons
    let the fixing agent write assertions directly.
  - Corrected `min+ga` rank claim: kinzi is at rank 3, not rank 4.
  - Reclassified `min+galarpar` from "well-behaved baseline" to
    "also affected" — production rank 0 lacks the virama `1039`
    even though the lexicon-attested `မင်္ဂလာပါ` (with kinzi)
    sits at rank 1. The original draft was wrong about this.
  - Replaced the well-behaved baselines list (which previously
    included `min+galarpar`) with a new list that has been verified
    to currently rank correctly: `min+ka`, `tin+ga`, `tin+ga+min`,
    `ban+ga`, `min+ga+min`. The fix must keep these correct.
  - Broadened the *Burmese Language Rule Reference* section to
    cover the generic virama-stack case (the anusvara `1036` vs
    `na+asat` displacement seen in `kan+ga`/`than+ga`/`yan+gun`)
    in addition to the kinzi case. The original draft was titled
    around kinzi but the bug class is broader.
  - Added concrete scalar-level assertion shape to acceptance
    criteria (e.g. "rank-0 contains `1004 103A 1039` immediately
    followed by `1002`"), so the fixing agent does not have to
    re-discover the surface forms.
  - Added an explicit baseline-preservation acceptance criterion
    so the fix is not allowed to regress `min+ka` / `tin+ga` etc.
- **Open question (resolved):** the displacing surfaces are *not*
  `source: .lexicon` direct overrides — they remain `.grammar` —
  meaning this is the LM log-prob composite-score winning the
  ranking comparator, not a lexicon-rank promotion. The fix must
  therefore live in the grammar-candidate ranking path
  (`grammarCandidateIsBetter`,
  `bestStrictInferredStackIndex`,
  `lmDominanceThreshold`), not in the lexicon-promotion path.
- **Title note:** the file name still says "kinzi" but the bug
  class includes anusvara displacement on `<C>an+<C>` shapes. The
  task body is now accurate; renaming the file would orphan the
  discoverable identifier so leaving the filename alone.

## Validation Report

### Verdict: NOT_IMPLEMENTED

### State of work
No source-code changes targeting TASK-031 are present. Inspected
locations:
- `Engine/InputNormalization.swift::inferImplicitStackMarkers` —
  `!input.contains("+")` early-out is unchanged.
- `Engine/CandidateRanking.swift::grammarCandidateIsBetter` —
  unchanged.
- `Engine/BurmeseEngine.swift::bestStrictInferredStackIndex` —
  unchanged.
- No new test suite for the explicit-`+` kinzi bug class.
- No mention of TASK-031 anywhere in the working tree.

The only Step 3 work present in the tree relates to TASK-030.
Step 3's usage limit hit before any TASK-031 implementation began.

### Status
TASK-031 is **NOT_IMPLEMENTED**. The task remains open for Step 5.

## Gap Fix Notes

Step 5 implemented TASK-031 from scratch. The fix has three pieces:

1. **New populate path for `strictInferredStackOutputs` on
   explicit-`+` buffers.** In `BurmeseEngine.updateInternal`, after
   `inferImplicitStackMarkers` runs (which still returns nil for
   `+`-bearing buffers, by design), a new block walks the parser's
   `grammarParses` and adds the output of any parse whose reading
   matches the user's literal `displayBuffer` to the strict-stack
   set. Both the raw output and `correctAaShape(output)` go in so
   the engine's downstream tall-aa expansion still finds the entry.

2. **Reading-match discriminator
   (`readingMatchesUserLiteralAcrossInherentVowels`).** A single-
   pass walk over the parse reading and the user's `displayBuffer`
   that allows two specific `a`-insertion patterns:
   - **Rule (a)**: parser inserted `a` immediately before a `+` —
     this is the inverse of the `collapseConnectorRuns` TASK-011
     reshape (`<C>a+<C>` → `<C>+<C>`). The parser sees the post-
     reshape `thin+g+thin` and rebuilds the reading to
     `thin+ga+thin`, which matches the user's pre-reshape input.
   - **Rule (b)**: trailing `a` at the end of the reading — the
     parser's habit of appending the inherent vowel after a bare
     trailing consonant (`yan+gun` → reading `yan+guna`).
     `a`s elsewhere (between two onset consonants, or anywhere
     inside a syllable not at one of the two whitelisted positions)
     are rejected because they represent a parser segmentation
     change the user did not type. Concretely: `barah+ma` against
     `brah+ma` is rejected (the parser interpreted `b` as an
     independent syllable `ba` instead of an onset cluster `bra`),
     while `vyah+ma` against `brah+ma` is accepted by exact match
     after the `b`-medial-`r` interpretation flows through. `2`/`3`
     disambiguators are rejected outright.

3. **Lift the `!input.contains("+")` gate at `bestStrictInferredStackIndex`.**
   Both the non-windowed and windowed promotion sites previously
   refused to fire when the user had typed `+`, on the (now-
   refuted) assumption that the parser's `+` handling already
   guaranteed the strict-stack surface won ranking. The lift routes
   `+`-bearing buffers through the same promotion path the
   inferred-`+` cases use, with a narrow `lexiconAtSlotZero` carve-
   out: when the merge has already placed a lexicon candidate at
   rank 0 (the synthetic-store `LexiconRanking.merge_exactAlias…`
   invariant), the strict-stack lift is suppressed so the curated
   lexicon entry stays at rank 0.

Test artifacts:
- New `ExplicitPlusKinziDisplacementSuite` with 9 cases covering
  the kinzi closure family (`min+ga`, `min+ka`, `min+galarpar`,
  `thin+ga`, `thin+gala`, `thin+ga+thin`, `thin+kun`, `tin+ga`,
  `tin+ga+min`, `min+ga+min`), the asat-closure family
  (`kan+ga`, `ran+ga`, `nan+ga`, `than+ga`, `ban+ga`,
  `yan+gun`, `yan+kun`), concrete scalar-level checks for the
  canonical `min+ga` and `kan+ga` shapes, baseline-preservation
  guards (the task-listed "well-behaved" cases must still
  surface their existing rank-0), the cross-class
  loanword preservation check (`pad+ma`, `brah+ma`, `nag+ma`,
  `yag+na` continue to keep virama at rank 0), and discriminator-
  helper sanity tests for both accept and reject paths.
- Suite registered in both `BurmeseTestSuites.all` and the XCTest
  driver.

Final state:
- `swift run TestRunner` — 1118/1118 cases, 5242/5242 assertions
  passing. Existing `KinziInferenceSuite`,
  `MidBufferStackInferenceSuite`,
  `WindowingKinziAcrossThresholdSuite`, `KinziTallAaSuite`,
  `CrossClassNTStackRankingSuite`, `LexiconRankingSuite`,
  `ExplicitViramaSuite`, `ComprehensiveRankingSuite` all
  continue to pass without modification.
- `swift run -c release BurmeseBench --check
  Tests/Benchmarks/baseline.json` — no regressions across multiple
  runs.
- All bug-class buffers from *Current State* now produce the
  expected user-respecting rank-0 surface; baseline buffers
  (`min+ka`, `tin+ga`, `tin+ga+min`, `ban+ga`, `min+ga+min`)
  retain their existing correct rank-0.
