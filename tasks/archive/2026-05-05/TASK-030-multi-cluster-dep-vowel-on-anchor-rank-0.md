# TASK-030: Chained vowel-rule arcs surface a structurally illegal multi-cluster dep-vowel shape at rank 0

## Status
Completed

## Problem Description
When a user types an onset (or no onset) followed by two or more vowel-rule
keys back-to-back (`<C>ay<vowel-rule>`, `<C><single-vowel><vowel-rule>`, or
`<vowel-rule><vowel-rule>` standalone), the engine emits a rank-0 surface
that contains **either two dependent-vowel clusters on the same anchor
without an intervening base, or a same-category dep-vowel duplicate on a
single anchor**. The shape violates the orthographic invariant that a
single Burmese syllable carries exactly one dependent-vowel cluster (with
two narrow allow-listed exceptions: the o-cluster `102D 102F` and the
leading-`1031` + aa-family pair). Same-category duplicates on consonant-
only buffers (`kii`, `kuu`, `koo`) were filtered by TASK-028 / the
existing `RepeatedDepVowelSuite`, but the chained-rule path
(`<C>ay<vowel>`, `<C><vowel><vowel>`, onsetless `<vowel><vowel>`)
produces a fresh class of violator that escapes both the parser's
`scanOutputLegality` filter (the sanitizer's "preserve violators when no
clean sibling exists" fallback retains them) and the engine's Class A
literal-fallback promotion (which is gated to vowel-only alphabetic
buffers, so consonant-prefixed cases never trigger it).

The user sees, e.g., `kayoo` → `ကေိုို` (`1000 1031 102D 102F 102D 102F`) at
rank 0 — a single `က` base carrying `1031` (e-kar), `102D 102F` (o-cluster),
*and another* `102D 102F`. Real Burmese never spells this; every parsed
candidate fails `scanOutputLegality`, so none of the existing sanitizers can
promote a clean sibling above it.

Concrete observed rank-0 surfaces under the production-equivalent engine
(verified via `/tmp/validate-030`):

| Buffer | Production rank 0 | Bare-engine rank 0 |
|---|---|---|
| `kayoo` | `ကေိုို` (1000 1031 102D 102F 102D 102F) | `ကေအိုယ်အိုယ်` |
| `kayii` | `ကေီီ` (1000 1031 102E 102E) | `ကေည်အီ` |
| `kayuu` | `ကေူူ` (1000 1031 1030 1030) | `ကေအူဦ` |
| `ngayoo` | `ငေိုို` (1004 1031 102D 102F 102D 102F) | `ငေအိုယ်အိုယ်` |
| `ngaii` | `ငီီ` (1004 102E 102E) | `ငီည်` |
| `kuoo` | `ကူိုို` (1000 1030 102D 102F 102D 102F) | `ကူအိုယ်အိုယ်` |
| `kioo` | `ကီိုို` (1000 102E 102D 102F 102D 102F) | `ကီအိုယ်အိုယ်` |
| `iuu` | `အီူူ` (1021 102E 1030 1030) | (literal `iuu` — no Burmese parse) |
| `uii` | `အူီီ` (1021 1030 102E 102E) | (literal `uii`) |
| `ouu` | `အိုူူ` (1021 102D 102F 1030 1030) | (literal `ouu`) |
| `ooi` | `အိုိုီ` (1021 102D 102F 102D 102F 102E) | (literal `ooi`) |
| `uua` | `အူူ` (1021 1030 1030) | (literal `uua`) |

Note the bare-engine column: for vowel-only buffers (`iuu`, `uii`, `ouu`,
`ooi`, `uua`) the bare engine has no Burmese parse and falls through to
the literal — that is the correct behaviour. The production engine,
once the LM/lexicon is wired in, surfaces violator parses from
deeper buckets that the bare path correctly rejected.

## Root Cause
Three defenses miss this class:

1. **`Parser/Finalization.swift::scanOutputLegality`** correctly returns
   `false` for these surfaces (verified via `@_spi(Testing)` probe — see
   Notes), so they should never reach rank 0.
2. **`Engine/SurfaceSanitizers.swift::sanitizeMalformedMyanmarMarks`** runs
   that scan as a filter, but its policy is *"only filter when at least one
   candidate is clean"*. For these chained-rule buffers, every parser
   candidate (`ကေိုို`, `ကဧိုို`, …) fails the scan, so the policy keeps
   them all — including at rank 0.
3. **`Engine/BurmeseEngine.swift::isClassALiteralPromotionTrigger`** is
   gated to `isVowelOnlyAlphaBuffer` (only `a`/`e`/`i`/`o`/`u`/`r` chars).
   Buffers with consonants (`kayoo`, `kuoo`, `thayoo`, `ngayoo`) bypass
   the gate; even pure-vowel inputs (`iuu`, `ouu`, `uua`, `ooi`) escape
   because the existing predicates the trigger consults
   (`surfaceViolatesIndependentVowelInvariant`,
   `surfaceContainsDoubledCodaChain`, `surfaceHasIndepVowelVirama`,
   `isOrphanCombiningMarkSurface`, `isOrphanZwnjMark`,
   `indepVowelCount >= 2`) do not match the multi-cluster-on-one-anchor
   shape.

The shape exists only because the parser's DP allows arc chains that
materialise the second cluster — `<vowel-rule>` arcs after another
`<vowel-rule>` arc on the same base concatenate their dep-vowel scalars
without ever inserting a fresh anchor.

## Burmese Language Rule Reference
A Burmese syllable on a single consonant or independent-vowel base may
carry **at most one dependent-vowel cluster**. The legal multi-scalar
cluster shapes on a single anchor are:

- The o-cluster `102D 102F` (i + u),
- The leading-`1031` Unicode storage order `1031 102B|102C` for the
  `aw` / `aung` / `aing` family.

Any other repeat or combination — `102E 102E`, `102F 1030`, `1030 1030`,
`102D 102F 102D 102F`, `1031 102D 102F 102D 102F`, `102E 1030`,
`102D 102F 1030`, `102D 102F 102E`, etc. — is malformed and never appears
in attested Burmese text. The previously-fixed TASK-028 covers the
single-cluster cross-category case (`102C 102D` etc.); this task covers
the chain that produces *multiple* otherwise-legitimate clusters
back-to-back without an intervening base.

## Steps to Reproduce
Use the production-equivalent engine
(`BurmeseEngine(candidateStore: SQLiteCandidateStore(...), languageModel: TrigramLanguageModel(...))`)
and inspect the rank-0 surface scalars for any of:

- Onset + chained vowel rule: `kayoo`, `kayii`, `kayuu`, `thayoo`,
  `thayuu`, `ngayoo`, `ngaii`, `kuoo`, `kioo`, `kaayoo`.
- Onsetless chain: `iuu`, `uii`, `ouu`, `ooi`, `uua`, `ayoo`.

Rank-0 contains a `102D 102F 102D 102F` / `102E 102E` / `1030 1030` /
`102D 102F 1030 1030` / similar repeated-cluster sequence with no fresh
consonant base, virama, or asat between the duplicates.
`SyllableParser.scanOutputLegality(<rank-0 surface>)` returns `false` for
every one of them — confirming the parser-level invariant rejects them
but the engine still ships them. The same-category-on-single-anchor
predicate `hasRepeatedDepVowelOnSameBase` (already used internally by
`RepeatedDepVowelSuite` to assert that consonant-only buffers like `kii`
/ `kuu` / `koo` clean up) returns `true` for every observed bug-class
production rank-0 surface — re-using that predicate (or its underlying
logic) at the engine layer is the canonical fix shape.

## Current State
- Rank-0 surface for the bug-class buffers is a structurally illegal
  Myanmar string the user can see, select, and commit.
- `sanitizeMalformedMyanmarMarks` retains the violator under its
  "preserve when no clean exists" fallback because every candidate
  fails `scanOutputLegality`.
- The literal fallback is appended at the bottom of the panel (TASK-043
  default position) but never promoted to rank 0 — the consonant-bearing
  buffers fail the Class A vowel-only-buffer gate, and the pure-vowel
  buffers' multi-cluster shape isn't recognised by Class A's predicates.

## Desired State
- Rank-0 surface for any input contains at most one dep-vowel cluster
  per anchor (one of the legal shapes from the language rule reference
  above). Chained vowel-rule arcs that would produce
  `<base><cluster><cluster>` shapes are either rejected at the parser
  legality gate so a different parse wins, or trigger a literal
  promotion / clean re-segmentation when no clean parser sibling
  exists.
- For pathological cases where no Burmese parse can possibly be valid
  (`iuu`, `uua`, `ooi`), the literal fallback rises to rank 0 (Class A
  promotion), matching the user's intent of typing characters that
  don't form a Myanmar word.

## Acceptance Criteria
- A structural predicate (extend `surfaceViolatesIndependentVowelInvariant`,
  add a sibling like `surfaceContainsMultiClusterOnSingleAnchor`, or
  hoist `hasRepeatedDepVowelOnSameBase` from `RepeatedDepVowelSuite` to
  engine scope) detects the violator shape: either more than one
  dep-vowel cluster on a single base, or a same-category dep-vowel
  duplicate within a single base run, with no fresh consonant /
  virama-stack / asat / independent-vowel break between them. Tested
  to reject `1000 1031 102D 102F 102D 102F`, `1000 1031 102E 102E`,
  `1000 1031 1030 1030`, `1004 102E 102E`, `1000 102E 102D 102F 102D 102F`,
  `1000 1030 102D 102F 102D 102F`, `1021 102E 1030 1030`,
  `1021 1030 102E 102E`, `1021 102D 102F 1030 1030`, `1021 1030 1030`,
  `1021 102D 102F 102D 102F 102E`, while accepting legal multi-cluster
  shapes the orthography does permit (separate syllables divided by a
  fresh anchor / asat / virama: `1021 102D 102F 1021 102D 102F` is two
  separate `o`-cluster syllables, both anchored; `ကိုယ်အိုယ်` etc.
  with `103A` between clusters is one well-formed two-syllable
  surface).
- Engine-level cases in a new suite (using the bundled-engine helper
  pattern — see `AnchorStabilitySuite.bundledEngine`, since the bug
  is only reproducible under production-equivalent ranking) cover the
  bug-class buffers (`kayoo`, `kayii`, `kayuu`, `thayoo`, `thayuu`,
  `ngayoo`, `ngaii`, `kuoo`, `kioo`, `kaayoo`, `iuu`, `uii`, `ouu`,
  `ooi`, `uua`, `ayoo`) and assert that, for each, the rank-0 surface
  either:
    - contains no same-category-duplicate dep-vowel and no two
      dep-vowel clusters on a single anchor, OR
    - equals the raw buffer (literal-fallback promotion fired —
      acceptable for vowel-only buffers like `iuu`, `uua`, `ooi`).
- `swift run TestRunner` passes — existing suites
  (`OoSuffixOrphanChainSuite`, `LeadingAaTrailingVowelSuite`,
  `RepeatedDepVowelSuite`, `CrossCategoryDepVowelLegalitySuite`,
  `BareVowelRepetitionSuite`) continue to pass without modification.
- `swift run -c release BurmeseBench --check` reports no regression.

## Notes
- Probe (`/tmp/explore-probe13.swift`) confirmed
  `SyllableParser.scanOutputLegality` rejects every observed bug-class
  surface — so the parser-level invariant is correct; the gap is at
  the engine sanitizer / fallback layer.
- The Class A literal-fallback gate
  (`isClassALiteralPromotionTrigger` in
  `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`,
  lines ~2616–2660) is the natural extension point: add the new
  multi-cluster predicate to its early-return list and broaden the
  vowel-only-alpha gate to also fire for buffers whose composable
  prefix triggers the predicate (or run the predicate independently
  of the gate).
- An alternative fix point is the parser DP itself: reject arc
  transitions that would produce two consecutive vowel-rule arcs
  whose combined emission contains more than one dep-vowel cluster on
  the same base. This would clean the candidate pool before ranking
  and avoid the sanitizer's "preserve violators" fallback entirely.
- Related (but distinct):
  - TASK-028 fixed cross-category dep-vowel duplicates *within a
    single cluster*; this task addresses the case where two
    legitimate-by-themselves clusters end up stacked on one anchor.
  - TASK-029 addressed onsetless doubled-bare-vowel + tone marker;
    overlapping shapes (`uua`, `oou`) carry similar multi-cluster
    risk but in the no-tone path.
- Code locations:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`
    — `sanitizeMalformedMyanmarMarks`,
    `surfaceViolatesIndependentVowelInvariant` (predicate to extend or
    sibling).
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`
    — `isClassALiteralPromotionTrigger` (gate to broaden),
    `injectLiteralFallback` (consumer of `class_A_violation`).
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/NBestDP.swift`
    — DP transition gate (alternative fix point).

## Validation Notes
- **Verdict: Valid.** Reproduced every listed bug-class buffer under
  the production-equivalent engine. Probe transcript at
  `/tmp/validate-030`.
- **Changes during review:**
  - Removed `kayyii` from the example list — production rank 0 for
    this buffer is `ကေယီ` (`1000 1031 101A 102E`), which is
    structurally legal (the second `y` becomes a base `101A`, so the
    `102E` has a fresh anchor). It is not a member of the bug class.
  - Added a concrete "Production rank 0 vs bare-engine rank 0" table
    so the fixing agent can pick the right layer to test against. The
    bare-engine column reveals an important fact: for vowel-only
    buffers (`iuu`, `uii`, `ouu`, `ooi`, `uua`) the bare engine
    produces only the literal — the violator surfaces are introduced
    by the LM/lexicon ranking layer in production. This narrows the
    fix to the engine sanitizer / promotion path, not the parser DP.
  - Broadened the "structural predicate" criterion to acknowledge
    that the bug class includes both same-category duplicates
    (`102E 102E`, `1030 1030`) and chained-cluster shapes
    (`102D 102F 102D 102F`). The same-category subset overlaps with
    what `RepeatedDepVowelSuite::hasRepeatedDepVowelOnSameBase`
    already implements; calling that out gives the fixing agent a
    ready-made predicate to lift to engine scope.
  - Added `ngaii`, `thayuu`, `ayoo` to the test-suite buffer list —
    they were already in *Steps to Reproduce* but missing from the
    suite assertion list, leaving a coverage gap.
  - Tightened the "accept" examples to include `ကိုယ်အိုယ်`-shaped
    two-syllable surfaces where `103A` (asat) provides a real
    syllable break between two clusters.
- **Open question (resolved):** TASK-028's filter (in
  `Parser/Finalization.swift::scanOutputLegality`) does correctly
  reject every bug-class surface — the parser knows these are
  illegal. The gap is that
  `Engine/SurfaceSanitizers.swift::sanitizeMalformedMyanmarMarks`
  only filters when at least one candidate passes; when *every*
  parser candidate is illegal (the chained-rule case, where the LM
  has surfaced violators from deeper buckets the bare path
  rejected), the sanitizer's "preserve when nothing clean exists"
  fallback retains all of them. The fix lives at the engine layer.
- **Pre-existing related task:** Same-category duplicate filtering
  on consonant-only buffers (`kii`, `kuu`, `koo`, `uu`, `ii`, `oo`)
  is already shipping via `RepeatedDepVowelSuite`. The task's job
  is to extend that protection to (a) chained vowel-rule buffers
  with a vowel rule preceding the duplicate (`kayii`, `kioo`), and
  (b) onsetless-vowel buffers under the LM-ranked production engine
  (`iuu`, `uua`, …) where the bare-engine path was already correct.

## Validation Report

### Verdict: PARTIAL (regression introduced + perf regression)

### State of work
Step 3 produced uncommitted code in the working tree:
- New `MultiClusterDepVowelOnAnchorSuite.swift` (predicate + bundled-engine
  test cases — well-structured, consistent with task spec).
- New `surfaceContainsMultiClusterOnSingleAnchor` predicate in
  `Engine/SurfaceSanitizers.swift` (`@_spi(Testing) public`).
- New `sanitizeMultiClusterOnSingleAnchor` filter, wired into
  `BurmeseEngine` at three points: outer `update` post-fallback
  re-pass, the bare-engine main pipeline pre-promotion pass, and
  the affixed-buffer sanitizer chain (between
  `sanitizeInterleavedComposingPunct` and `sanitizePhantomMidAnchor`).
- Class A literal-promotion gate (`isClassALiteralPromotionTrigger`)
  now also fires on `surfaceContainsMultiClusterOnSingleAnchor`.

### Test results
- `swift run TestRunner`: **1109/1110 cases passed, 1 assertion failed.**
  - Failing: `ComprehensiveRanking.sentence_longArticle_literaryInfluence`
    asserts `noLatinLeak` — top candidate now leaks raw Latin at
    intermediate buffer prefixes `thueiooz`, `thueiooza`,
    `thueioozar`, `thueioozark`. Confirmed regression: stashing the
    Step-3 changes restores the pre-Step-3 baseline of 1107/1107.
  - Mechanism: extending the Class A gate to fire on the new
    multi-cluster predicate causes intermediate prefixes containing
    `oo`/`ii` chains to surface the literal raw buffer at rank 0
    even when the user is mid-typing a longer sentence.
- New `MultiClusterDepVowelOnAnchorSuite` cases (predicate sanity +
  rank-0 invariant on bug-class buffers): all pass.

### Performance
- `swift run -c release BurmeseBench --check Tests/Benchmarks/baseline.json`:
  **EXIT 1** — `plus_chain_30` p95 370.4us > baseline*1.20 = 317.3us
  (+17%); p99 387.8us > baseline*1.30 = 356.5us (+9%). Stashing the
  changes returns p95 to 306.5us (well under budget). The new sanitizer
  is run unconditionally on every candidate list at three places, and
  `surfaceContainsMultiClusterOnSingleAnchor` walks the full scalar
  array — that overhead shows up on the 30-segment plus-chain case.

### Acceptance criteria coverage
- Structural predicate: implemented, tested in
  `predicate_rejectsBugClassSurfaces` /
  `predicate_acceptsLegalSurfaces` — both pass.
- Bundled-engine suite covering all 16 bug-class buffers: implemented,
  passes (`rank0_neverMultiClusterOnSingleAnchor`).
- `swift run TestRunner` clean: **fails** — `ComprehensiveRanking`
  regression as above.
- `BurmeseBench --check` clean: **fails** — `plus_chain_30` regression
  as above.

### Required follow-up
1. Narrow the Class A gate so the literal raw buffer is not promoted
   to rank 0 mid-typing of a longer Myanmar sentence — the current
   implementation triggers on any prefix whose rank-0 surface fails
   the multi-cluster predicate, which is too aggressive when the
   user is still typing. Options: (a) gate the new trigger on the
   existing `isVowelOnlyAlphaBuffer` predicate or (b) require a
   minimum buffer-length stability window before firing.
2. Reduce sanitizer overhead on the hot path. Either skip the new
   sanitizer entirely when no candidate has a dep-vowel cluster
   (cheap pre-check), cache the predicate result against the surface
   string, or avoid running it at three engine points (one
   late-pipeline placement may suffice).
3. Re-run the comprehensive sentence regression and `BurmeseBench
   --check` after the fix.

### Status
Code changes are uncommitted and incomplete. TASK-030 is **PARTIAL**.

## Gap Fix Notes

Step 5 closed the two gaps Step 4 identified:

1. **ComprehensiveRanking regression at mid-sentence prefixes
   (`thueiooz…`).** The Step-3 fix promoted the literal raw buffer
   to rank 0 whenever the top Myanmar surface failed the broad
   multi-cluster predicate. That predicate matches both bug-class
   surfaces (`ကေိုို` for `kayoo`) AND legitimate mid-typing
   parses (`သူယ်ီိုိုဇ` for the `thueiooz` prefix of
   `သူ၏ဩဇာကြီးမား…`), where the orphan-anchor sub-cluster
   between the asat and the next consonant resolves as the user
   keeps typing. Step 5 added a tighter predicate
   `surfaceIsWhollyMultiClusterOnSingleAnchor` (single-anchor /
   no internal asat/virama / multi-cluster shape) and used it at
   the Class A literal-promotion gate; the broader
   `surfaceContainsMultiClusterOnSingleAnchor` only fires at the
   merge-time sanitizer where the "preserve when no clean exists"
   fallback already protects mid-typing. Wholly-single-anchor
   bug-class surfaces (`ကေိုို`, `ကေီီ`, `အူူ`, `အိုိုီ`, …)
   still match; multi-anchor mid-typing surfaces (`သူယ်ီိုိုဇ`)
   no longer trigger the literal promotion. Removed the post-
   fallback re-pass at the outer `update(...)` wrapper that Step 3
   had added.

2. **`plus_chain_30` p95 +17% / p99 +9% perf regression.** The
   Step-3 predicate did `Array(surface.unicodeScalars).map(\.value)`
   per call (allocates), maintained a heap-allocated
   `[Int] clusterCategories` per call, and called nested
   `@inline(__always)` closures (which the optimizer can't reliably
   inline). The sanitizer ran the full `filter` pass even when no
   candidate carried the violator shape (the common case on the
   hot `plus_chain_30` path). Step 5 rewrote the predicate to
   iterate `surface.unicodeScalars` directly, hoisted the
   `task030DepVowelCategory` / `task030IsBase` helpers out of the
   closure-trap into static module-scope functions, replaced the
   `[Int] clusterCategories` with a 5-bit `UInt8 clusterBitset`
   (no allocation), and added a fast pre-scan that counts
   dep-vowel scalars and bails out at <2. The sanitizer now
   short-circuits with a single linear walk when no candidate
   matches, which is the case for every keystroke on
   `plus_chain_30`. Re-checked: `BurmeseBench --check` reports
   "no regressions" across multiple runs; `plus_chain_30` p95
   sits at ~265us (baseline 264us, 20% budget = 317us).

Final state:
- `swift run TestRunner` — 1110/1110 cases, 5198/5198 assertions
  passing. `MultiClusterDepVowelOnAnchorSuite` (predicate sanity +
  16-buffer rank-0 invariant) all green.
- `swift run -c release BurmeseBench --check
  Tests/Benchmarks/baseline.json` — no regressions.
- Bug-class buffers (`kayoo`, `kayii`, `kayuu`, `thayoo`,
  `thayuu`, `ngayoo`, `ngaii`, `kuoo`, `kioo`, `kaayoo`, `iuu`,
  `uii`, `ouu`, `ooi`, `uua`, `ayoo`) all produce a clean rank-0
  per the acceptance criterion (literal-buffer commit OR clean
  Myanmar; no multi-cluster-on-single-anchor surface).
- Mid-typing prefixes of long sentences keep their Myanmar
  rank-0 surface — `noLatinLeak` holds across every prefix of
  `ComprehensiveRanking.sentence_longArticle_literaryInfluence`.
