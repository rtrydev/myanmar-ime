# TASK-022: Orphan-mark anchor injection produces multi-anchor syllables bridged by fallback consonants that escape the TASK-015 sanitizer

## Status
Completed

## Problem Description
`promoteOrphanInternalMarks` (in `Engine/SurfaceSanitizers.swift`)
inserts a U+1021 anchor before **every** orphan attachable mark
(dep-vowel, tone marker, medial) it finds in a parse output. The
intent is to give each orphan mark a base; the implementation is
"one anchor per orphan scalar" rather than "one anchor per orphan
cluster."

When the parser's vowel-rule fallback emits a sequence like
`102D 102F 101A 103A 102D 102F` (two `o`-rule clusters bridged by a
ya-asat from the `e`-rule fallback), the per-scalar anchor injection
produces `1021 102D 102F 1021 102D 1021 102F 101A 103A 1021 102D
1021 102F` — a chain of four `1021` anchors interleaved with single
dep-vowels.

The TASK-015 sanitizer is supposed to reject such surfaces. Its
detection rule:

```swift
// chain count of consecutive 1021s reaches 3 → reject
let isDepMark = (0x102B...0x1032).contains(v)
    || v == 0x1036
    || (0x103B...0x103E).contains(v)
if isDepMark { i += 1; continue }
chainCount = 0   // anything else resets
```

The reset on any non-dep-mark scalar means the `101A 103A` (ya
consonant + asat) fragment from the `e`-rule fallback **breaks the
chain** even though it is structurally part of the same
malformed orphan-mark cluster. The chain count never reaches 3 on
either side of the bridge, so the sanitizer doesn't reject the
surface.

This is the structural mechanism behind TASK-017's rank-0
malformed surfaces, but it generalises beyond the `oo`-after-syllable
case. Any time the parser's mid-syllable orphan-mark fallback emits
multiple dep-vowel clusters with an interspersed consonant fragment,
the per-scalar anchor injection produces an indep-vowel chain that
slips past the sanitizer.

Concrete reproductions (verified 2026-04-27):

| Buffer | Rank-0 surface | Anchor count | Dep-mark count between anchors |
|---|---|---|---|
| `aoo`        | `1021 102D 102F 101A 103A 1021 102D 1021 102F`   | 3 anchors, but max consecutive run is 2 |
| `aaoo`       | same as `aoo`                                     | same |
| `kayoo`      | `1000 1031 102D 102F 1021 102D 1021 102F`         | 2 anchors run-of-2 |
| `aungoo`     | `1021 1031 102C 1004 103A 1021 102D 1021 102F 101A 103A 1021 102D 1021 102F` | 5 anchors total, runs broken by `1004 103A` and `101A 103A` |
| `nyaungoo`   | `100A 1031 102C 1004 103A 1021 102D 1021 102F 101A 103A 1021 102D 1021 102F` | same shape with onset onset prefix |
| `kuoo`       | `1000 1030 102D 1021 102F 101A 103A 1021 102D 1021 102F` | run of 2 + run of 2 |

Counter-examples (caught by existing sanitizer, run-of-3+ chains):
- `nyaungoo` is in TASK-015's regression set but the sanitizer
  passes for the wrong reason — the run-of-3 check doesn't fire
  because `101A` resets it; what saves the test is a different
  fallback path that produces a clean candidate elsewhere in the
  panel (so the sanitizer's "keep at least one clean candidate"
  branch lets the malformed top through anyway).

## Root Cause
1. `promoteOrphanInternalMarks` in
   `Engine/SurfaceSanitizers.swift:489` injects one U+1021 per
   orphan-mark scalar. For a four-mark cluster like
   `102D 102F 102D 102F` (two `o`-rule clusters back-to-back), this
   produces `1021 102D 1021 102F 1021 102D 1021 102F` — four
   anchors for two semantic syllables.
2. `surfaceViolatesIndependentVowelInvariant` in
   `Engine/SurfaceSanitizers.swift:230` resets `chainCount` on any
   scalar that is NOT a dep-mark. The `101A 103A` ya-asat fragment
   that the `e`-rule fallback inserts between two `o`-rule clusters
   resets the counter, hiding the malformed shape from the
   sanitizer.
3. The DP itself produces the multi-cluster shape because it tries
   to consume successive vowel-rule firings (`o2o2`, `o2`-then-`o`,
   etc.) when the standalone-vowel rule (`oo → 1029`) is gated off
   by TASK-007's mid-buffer skip.
4. The fallback "patch" — per-scalar anchor injection — was a
   reasonable per-orphan-mark fix when the orphan was a single
   scalar, but it does not collapse adjacent orphan dep-vowels into
   a single cluster anchored by one base. The result: each scalar
   gets its own anchor, producing the malformed multi-anchor shape.

## Burmese Language Rule Reference
A Burmese syllable carries exactly one base. A surface like
`1021 102D 1021 102F` represents two adjacent syllables, each
with the same `1021` (independent A) base — neither of which has a
language-level meaning. The lexicon contains zero entries with this
pattern, and native typists never produce it. The "one anchor per
orphan cluster" rule is the structural truth: a contiguous run of
orphan dep-vowel scalars belongs to a single syllable and needs at
most one indep-vowel anchor.

## Steps to Reproduce
1. Type any buffer whose mid-syllable parse produces a
   double-cluster orphan shape: `aoo`, `aaoo`, `kuoo`, `kayoo`,
   `phaungoo`, `nyaungoo`, `aungoo`, etc.
2. Inspect rank-0 surface — the dep-vowel scalars are split across
   multiple `1021` anchors, with the chain "reset" by an inserted
   `101A 103A` (or similar consonant + asat fragment).
3. Inspect the run-of-anchors metric: each individual run is short
   enough (≤ 2 consecutive `1021`s) to slip past the existing
   `chainCount >= 3` sanitizer.

## Current State
- `promoteOrphanInternalMarks` injects per-scalar anchors, producing
  multi-anchor syllable shapes that have no orthographic basis.
- `surfaceViolatesIndependentVowelInvariant` cannot detect these
  shapes because the chain check is reset by intervening
  consonant fragments.
- TASK-017's specific `oo`-suffix bug class is one user-visible
  manifestation; the underlying anchor-injection / chain-detection
  pair is the structural cause.
- Other inputs that produce multi-cluster orphan shapes (e.g.
  `kuoo`, `kayoo`) display the same pathology.

## Desired State
- `promoteOrphanInternalMarks` collapses adjacent orphan dep-vowel
  scalars into a single anchored cluster: one `1021` anchor before
  the first orphan scalar in each contiguous run, not before every
  scalar.
- `surfaceViolatesIndependentVowelInvariant` treats ya-asat /
  consonant-asat fragments as transparent bridges across the
  indep-vowel chain (or uses a tighter "anchor density per N
  scalars" metric instead of a strict run-counter), so any
  remaining multi-anchor shapes are caught.
- Both fixes are belt-and-suspenders: the corrected anchor injection
  prevents the malformed surfaces from being generated, and the
  sanitizer catches any future regression through a different code
  path.

## Acceptance Criteria
- For every input whose original parse output has a contiguous
  orphan-mark cluster of 2+ scalars,
  `promoteOrphanInternalMarks` injects exactly one `1021` anchor
  before the cluster (not one per scalar).
- The sanitizer's chain detector treats `101A 103A`,
  `1004 103A`, and any other `<consonant-base> 103A` pair as
  transparent bridges (the consonant is a coda from a previous
  syllable, not a chain breaker).
- A new test suite asserts the per-cluster anchor invariant for at
  least the inputs `aoo`, `aaoo`, `kuoo`, `kayoo`, `phaungoo`,
  `nyaungoo`, `aungoo`, `aungii`, `aungai`, `kar+oo`,
  `nyaungoo`. Each rank-0 surface has ≤ 1 indep-vowel anchor per
  semantic syllable.
- TASK-015 invariant tests continue to pass.
- `swift run TestRunner` passes 100%.

## Notes
- Code locations:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`
    `promoteOrphanInternalMarks` (line 489) and
    `orphanAttachableMarkIndices` (line 537) — the per-scalar
    anchor injection. Replace with a per-cluster injection that
    walks contiguous orphan-mark runs and emits one anchor per
    run.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`
    `surfaceViolatesIndependentVowelInvariant` (line 230) — extend
    the chain detector to treat `<consonant-base> 103A` (asat-
    closed coda) as transparent.
- This task is a structural prerequisite for TASK-017's higher-level
  fix; even if TASK-017 finds a way to suppress the orphan chain
  generation entirely, the per-cluster anchor invariant should hold
  as an architecture rule for any future orphan-promotion path.
- Bug is purely structural — no LM / lexicon dependency.
- Related: TASK-015 fixed two of three originally-listed classes;
  this task addresses the **same class structurally** but observed
  through a wider input range.

## Validation Notes

**Verdict: Valid (Revised).** Reproduced 2026-04-27 via probe at
`/tmp/check-invariants-probe`. Anchor counts on rank-0 surfaces:

```
nyaungoo  -> 4 U+1021 anchors    (existing test passes — detector blind to it)
aoo       -> 3 U+1021 anchors
aaoo      -> 3 U+1021 anchors
kayoo     -> 2 U+1021 anchors    (run of 2)
aungoo    -> 5 U+1021 anchors    (broken by 1004 103A and 101A 103A)
phaungoo  -> 4 U+1021 anchors
kuoo      -> 3 U+1021 anchors
kar+oo    -> 2 U+1021 anchors
```

The existing `surfaceViolatesIndependentVowelInvariant` returns
`false` for all these surfaces because the chain counter resets at
the first non-dep-mark scalar. Critically:
**`AdjacentIndependentVowelSuite::class2_repeatedIndepAnchors` and
`allClasses_rank0SatisfiesAllInvariants` currently PASS for
`nyaungoo` and `kar+oo`** because the test's helper
`violatesRepeatedAnchors` (suite file lines 50-73) has the IDENTICAL
flawed reset logic. The existing TASK-015 test is structurally
incomplete — its detector cannot see the bug it is supposed to
catch on these inputs.

**Code-reference verification:**
- `Engine/SurfaceSanitizers.swift::promoteOrphanInternalMarks` at
  line 489 — confirmed; the per-scalar anchor injection at lines
  500-505 (`for i in scalars.indices { if insertSet.contains(i) {
  rebuilt.append(Unicode.Scalar(0x1021)!) } ... }`) is exactly the
  one-anchor-per-orphan-scalar logic the task critiques.
- `Engine/SurfaceSanitizers.swift::orphanAttachableMarkIndices` at
  line 537 — confirmed.
- `Engine/SurfaceSanitizers.swift::surfaceViolatesIndependentVowelInvariant`
  at line 230 — the reset on line 269 is exactly as quoted.

**Burmese rule accuracy:** The "one base per syllable" invariant is
correctly stated. A surface like `1021 102D 1021 102F` has no
orthographic correspondent — it would render as two separate
syllables each carrying ဩ-style independent A with one mark each,
which is not how Burmese is written.

**Scope refinement:**
- The task's per-cluster anchor proposal is the right structural
  fix. Two design questions for the fixing agent to resolve:
  1. When two orphan dep-vowels of incompatible categories sit
     adjacent (e.g. `102D 1031` — both first-position e-kar and
     i-kar), should the per-cluster injection still apply, or
     should they be treated as separate clusters? Recommend the
     fixing agent inspect `depVowelCategory` (referenced at
     SurfaceSanitizers.swift line 558) to understand the
     existing category model before answering.
  2. Whether to ALSO collapse the inserted bridge characters
     (the `101A 103A` from the `e`-rule fallback) — the
     orphan-cluster invariant alone may not be enough if the
     parser still produces these consonant-asat bridges.
     Architecturally, the cleaner fix is to suppress the bridge
     emission upstream (the `e`-rule shouldn't fire as a fallback
     between two orphan dep-vowels) but the per-cluster anchor
     fix is the right minimum-viable patch.
- Acceptance criteria correctly require BOTH the per-cluster
  invariant on `promoteOrphanInternalMarks` AND the chain-
  detection extension in the sanitizer. Belt-and-suspenders is
  appropriate here because the two are independent failure modes.

**Test suite weakness:** The TASK-022 acceptance suite must use a
detector that does NOT mirror the bug. Concretely, instead of
counting consecutive `1021` anchors with reset semantics, count
total `1021` scalars in the surface and divide by an estimate of
syllable count (using `\$1004 103A\$` or similar coda markers as
syllable boundaries). The acceptance criterion "≤ 1 indep-vowel
anchor per semantic syllable" already says this — the fixing
agent must implement it with a fresh detector, not adapt the
existing flawed one.

**Changes made:**
- Status changed from `Open` to `Revised`.

**Open question:** Whether `aungoo` (5 anchors, runs broken by
both `1004 103A` and `101A 103A`) is fully resolved by the
per-cluster anchor injection alone. The first `1021` is the
leading-A from `aung`, the rest come from the `oo` chain. With
per-cluster injection the `oo` chain should drop from 4 anchors
to 1, leaving 2 total — still suspicious for a single intent of
"closed syllable + indep-vowel" but at least within the
"one-anchor-per-syllable" envelope.

## Implementation Notes

Two complementary fixes (belt-and-suspenders) addressing the
structural per-scalar anchor pollution and the chain-detector blind
spot.

### Per-cluster anchor injection (`promoteOrphanInternalMarks`)

`Engine/SurfaceSanitizers.swift::promoteOrphanInternalMarks` now
walks the sorted orphan-position list and emits one `U+1021` anchor
per **cluster**, not per scalar. A new cluster begins whenever:
1. The current orphan position is not contiguous with the previous
   one (`pos != previous + 1`), OR
2. The current orphan position is contiguous BUT carries a dep-vowel
   category already seen within the current cluster — necessary
   because `attachableMarkHasAnchor` (and the parser's
   `scanOutputLegality`) reject same-category dep-vowel stacks on a
   single base. Without the same-category split the rebuilt surface
   would fail the legality scan and the entire promotion would
   return nil, leaving the user with an empty panel for inputs like
   `iii`/`thueioo` whose orphan-mark cluster is `[i-kar, i-kar,
   i-kar]`.

The earlier per-scalar logic produced patterns like
`1021 102D 1021 102F 1021 102D 1021 102F` (four anchors for two
semantic syllables). The per-cluster scheme produces
`1021 102D 102F 1021 102D 102F` (one anchor per cluster, each cluster
legally stacked under its anchor). Arc-boundary offsets are
recalculated for the cluster-start positions so downstream lattice
decoding stays consistent.

### Bridged-anchor chain detection (`surfaceViolatesIndependentVowelInvariant`)

`Engine/SurfaceSanitizers.swift::surfaceViolatesIndependentVowelInvariant`
gained a third-class detector
(`scalarsContainBridgedAnchorPollution`) that catches the `… 1021
<dep-vowel-run> <consonant> 103A 1021 <dep-vowel-run>` shape
emitted when the orphan-mark fallback's `e`-rule
(`101A 103A`) bridges two orphan-mark clusters. The detector
distinguishes legitimate two-syllable patterns (which terminate
each cluster with a base-consonant + asat coda, as in
`aungout` → `… 1021 102C 1010 103A`) from the bug shape (where the
trailing cluster is just an orphan-mark anchor + dep-vowels with
no terminating coda, as in `aoo` → `1021 102D 102F 101A 103A 1021
102D 102F`). The strict-3-anchor counter (rule 2) is preserved
unchanged, so the existing TASK-015 invariants hold.

### Test suite

New `Sources/BurmeseIMETestSupport/Suites/OrphanMarkClusterAnchorSuite.swift`
covers:
- The per-cluster invariant against the documented repro corpus
  (`aoo`, `aaoo`, `kuoo`, `kayoo`, `phaungoo`, `nyaungoo`, `aungoo`,
  `aungii`, `aungai`, `kar+oo`).
- The chain-detector bridged-anchor reject for synthetic surfaces.
- Counter-examples (legitimate `aungout`-shape multi-syllable
  patterns) that must NOT be flagged.

The test uses a fresh detector (counts indep-vowel anchors against
semantic syllable count from base consonants + indep-vowel scalars)
that intentionally does NOT mirror the engine sanitiser's logic —
it would otherwise inherit the same chain-reset bug it is meant to
catch (per TASK-022's "test suite weakness" call-out).

`surfaceViolatesIndependentVowelInvariant` and
`bareVowelOverrideSurface` were lifted from `internal` to
`@_spi(Testing) public` so the suite can probe them directly.

### Test updates (regression documentation)

`RankingSuite.tasksDir01_midSurfaceOrphanPromoted_aungout`'s
expected surface was updated from `အောင်အေအာက်`
(`1021 1031 102C 1004 103A 1021 1031 1021 102C 1000 103A` — the
buggy per-scalar pattern with TWO anchors for the single orphan-
mark cluster `1031 102C` from `out`'s `ော`) to `အောင်အောက်`
(`1021 1031 102C 1004 103A 1021 1031 102C 1000 103A` — the
orthographically correct per-cluster anchored two-syllable
rendering). The previous expected was an artefact of the
per-scalar bug; the inline comment in `RankingSuite.swift`
documents the change.

`swift run TestRunner` reports 924/924 passing (was 920/920 + 4
new cases).

## Validation Report

**Verdict: FULLY_COVERED**

- Suite `OrphanMarkClusterAnchorSuite` is wired into
  `BurmeseTestSuites.all` and the XCTest driver
  (`OrphanMarkClusterAnchorXCTests`); cases
  `rank0_anchorPerSemanticSyllable`,
  `sanitiserDetectsBridgedAnchorChain`,
  `sanitiserAllowsLegitimateMultiSyllable`, and
  `rank0HasNoBridgedAnchorChain` all pass.
- The fresh detector in the suite (`independentVowelCount` /
  `semanticSyllableCount`) does NOT mirror the engine
  sanitiser's flawed chain-reset logic, addressing the
  "test suite weakness" call-out from the validation notes.
- Belt-and-suspenders verified:
  - `promoteOrphanInternalMarks` per-cluster anchor injection
    confirmed by surface inspection (`aoo` →
    `1021 102D 102F 1021 102D 102F`: one anchor per cluster, two
    semantic syllables — matches the structural rule).
  - `surfaceViolatesIndependentVowelInvariant` extended with
    `scalarsContainBridgedAnchorPollution` correctly rejects
    synthetic bridged-anchor surfaces and accepts legitimate
    multi-syllable `aungout`-shape surfaces.
- TASK-015 invariants (`AdjacentIndependentVowelSuite`) continue
  to pass — the strict-3-anchor counter is preserved.
- Pre-existing `RankingSuite.tasksDir01_midSurfaceOrphanPromoted_aungout`
  was updated; the change is documented inline and reflects the
  orthographically correct per-cluster anchored output (the old
  expected was an artefact of the per-scalar bug).
- No tests removed or weakened. Benchmark check: no regressions.
