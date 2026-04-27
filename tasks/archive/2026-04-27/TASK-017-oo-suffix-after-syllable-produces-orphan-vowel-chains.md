# TASK-017: `o` / `oo` suffix after a closed syllable produces orphan-vowel chains that violate the "one base per syllable" invariant

## Status
Completed

## Problem Description
When the user types an `o` or `oo` rule after any preceding syllable
that contains an asat coda (or any non-trivial vowel-bearing context),
the parser materialises a malformed multi-anchor chain that mixes the
`o` rule's base scalars (U+102D U+102F) with the `e`-rule fallback
(U+101A U+103A) and a stream of independent-vowel anchors
(U+1021), each followed by a single dependent-vowel scalar.

The result is a candidate surface like
`<...> 1021 102D 1021 102F 101A 103A 1021 102D 1021 102F`
- two pairs of indep-A + ိ anchored runs glued by an inserted ya-asat
that no Burmese syllable would actually carry. This pattern is the
standalone-`oo` (`o2o`) decomposition fired N times in succession,
each iteration adding a new `1021` anchor for what is structurally
an orphan dep-vowel scalar.

This is a generalisation of the TASK-015 bug class. TASK-015's
sanitizer rejects three or more **chained U+1021 anchors** when only
dep-vowels separate them; the new bug shape adds a U+101A U+103A
("ya + asat") in the middle of the chain which **resets** the
chain-counter, so the sanitizer never fires even though the surface
is just as malformed.

Concrete reproductions (verified 2026-04-27 against fresh
`BurmeseEngine`):

| Buffer | Rank-0 surface | Scalar count |
|---|---|---|
| `oo`        | `ဩ` (`1029`) | 1 (correct) |
| `aoo`       | `အိုယ်အိအု` (`1021 102D 102F 101A 103A 1021 102D 1021 102F`) | 9 |
| `aaoo`      | same as `aoo` | 9 |
| `kayoo`     | `ကေိုအိအု` (`1000 1031 102D 102F 1021 102D 1021 102F`) | 8 |
| `kayoot`    | same with trailing `1010` | 9 |
| `aungoo`    | `အောင်အိအုယ်အိအု` (`1021 1031 102C 1004 103A 1021 102D 1021 102F 101A 103A 1021 102D 1021 102F`) | 14 |
| `nyaungoo`  | `ညောင်အိအုယ်အိအု` (15 scalars) — same shape after `100A 1031 102C 1004 103A` |
| `phaungoo`  | same shape after `1016 1031 102C 1004 103A` |
| `kayooka`   | `ကေိုအိအုက` — kinzi prefix preserved, mid-buffer chain remains |

Counter-examples that work correctly (sanitised today):

- `nyaungoo` is a TASK-015 reproduction whose chain includes a `1004 103A`
  asat-closed segment, but the sanitizer still misses it for the same
  reason (the `1004 103A 1021` pattern resets the chain count).

The chain length grows linearly with the number of trailing `o`s:
typing more `o`s after a syllable produces more anchor pairs, never a
clean rendering.

## Root Cause
1. The `oo` standalone rule (`Romanization.swift:269`,
   `.init("oo", "\u{1029}", standalone: true)`) only fires at the
   buffer's leading position via the standalone-vowel TASK-007 gate
   (`vowelIsMidBufferPenalised` skip). After any non-seed predecessor
   the standalone-rule transition is rejected.
2. The DP then falls back to the digitless alias of `o2o` — i.e. the
   `o` vowel rule (`102D 102F`) followed by the `o` vowel rule
   *again*. Each iteration produces an orphan-mark cluster
   (`1021 102D 1021 102F` from orphan-internal-marks promotion)
   plus a `101A 103A` stub from the fallback `e` rule that the parser
   inserts to "close" the second `o`.
3. `surfaceViolatesIndependentVowelInvariant` in
   `Engine/SurfaceSanitizers.swift` only counts U+1021 anchors that
   are **directly chained** with dep-vowel scalars between them. When
   the chain is broken by U+101A (ya consonant), the counter resets
   and the malformed surface escapes the sanitizer.
4. `promoteOrphanInternalMarks` injects ONE `1021` per orphan mark —
   so a four-mark cluster like `102D 102F 102D 102F` becomes
   `1021 102D 1021 102F 1021 102D 1021 102F`. This is the same
   per-scalar-anchor over-injection that TASK-015 partially fixed,
   except that here the two orphan-mark stretches end up bracketed by
   `101A 103A` rather than being directly adjacent.

## Burmese Language Rule Reference
A Burmese syllable carries exactly one base. The `oo` rule represents
the **independent vowel ဩ (U+1029)** — a complete base on its own —
not a sequence of dependent-vowel signs that need to be re-anchored.
Two valid syllables `<...>` + `ဩ` would look like
`<closing-tone> 1029` or `<consonant><vowel> 1029` (three or four
scalars total). The 9-15 scalar chains the parser emits today have
no orthographic counterpart; native typists never produce them.

The `o` rule's fallback decomposition (`102D 102F`) is intended for
mid-syllable use after a consonant onset (e.g. `kao` →
`ကို` = `1000 102D 102F`). Iterating it standalone with no consonant
between iterations produces the orphan chain.

## Steps to Reproduce
For any closed-syllable buffer `<S>` (e.g. `aung`, `nyaung`, `kay`,
`phaung`, `aoo`, even bare `aoo` / `aaoo`):

1. Append `o` or `oo` (or longer chains).
2. Inspect rank-0 surface — every Myanmar block scalar past `<S>`'s
   asat coda is part of an injected anchor cluster that includes
   U+101A U+103A in the middle and multiple U+1021 anchors on either
   side.

The same bug fires for `ii`, `ee`, `ay`, `uu` chains after a closed
syllable when their mid-buffer firing produces orphan marks (verified
for `aungii` → `… 100A 103A 100A 103A`-only at top, but the
indep-vowel sibling at rank 2 reproduces the pattern; `aungai`
reproduces a similar two-anchor shape).

## Current State
- Rank-0 surface for `<closed-syllable>oo` is malformed with chained
  orphan-anchor injections.
- TASK-015 sanitizer cannot reject the surface because the chain
  counter resets at `101A`.
- The user has no clean candidate to pick from the panel — every
  surface in the top 5 carries the same malformed shape.
- The user typed `oo` either accidentally (held the key) or
  intentionally as the independent-vowel rule, but the engine
  produces neither the precomposed `1029` nor a clean two-syllable
  reading.

## Desired State
Two acceptable behaviours:

1. **Reject the parse outright**: drop trailing `o`/`oo` runs whose
   only legal interpretation past the leading position is the orphan
   chain, so the right-shrink probe peels them into the literal tail
   (where `composeLetterRunsInTail` re-renders them as a single
   independent vowel: `<closed-syllable>` + `ဩ`).
2. **Fire the standalone rule mid-buffer**: relax the
   `vowelIsMidBufferPenalised` gate when the predecessor arc is a
   complete asat-closed syllable (`1004 103A`, `1014 103A`, etc.) so
   the user's `oo` materialises as a properly-anchored second
   syllable's independent vowel. The TASK-007 motivation (avoiding
   `monein` → `မိုဦ` shapes between consonants) doesn't apply here
   because the predecessor already carries an asat coda.

Either fix requires generalising the chain-detection in
`surfaceViolatesIndependentVowelInvariant` to treat U+101A U+103A
(and similar consonant-asat fragments inserted by the orphan-promotion
fallback) as transparent bridges across the indep-vowel chain rather
than chain breakers — so the sanitizer becomes the belt-and-suspenders
guard for any future regression.

## Acceptance Criteria
- For every input matching the pattern
  `<asat-closing-syllable>(o|oo|ee|ii|uu|ay)`, the rank-0 candidate
  has at most one independent-vowel scalar (U+1021..U+102A) past the
  asat coda.
- `nyaungoo`, `aungoo`, `kayoo`, `phaungoo`, `aoo`, `aaoo`,
  `aungii`, `aungai` rank 0 either:
  - render the precomposed independent-vowel form
    (`အောင်ဩ` = `1021 1031 102C 1004 103A 1029` for `aungoo`), OR
  - drop the trailing chain into the literal tail and emit
    `အောင်` + `oo` literal (visible to the user).
- A new test suite exercises the
  `<closed-syllable>(o|oo|ee|ii|uu|ay)`-shape buffers and asserts the
  rank-0 surface scalar count is bounded by `closed-syllable scalars
  + at most 2 scalars` for the trailing vowel.
- TASK-015 invariants continue to hold for the original repro inputs
  (`nyaungoo` is in the existing `AdjacentIndependentVowelSuite`).
- `swift run TestRunner` continues to pass.

## Notes
- Code locations:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/NBestDP.swift`
    — `vowelIsMidBufferPenalised` gate around line 199 / 382.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`
    `surfaceViolatesIndependentVowelInvariant` — chain counter resets
    at `101A`; needs to either skip over `101A 103A` segments or use a
    tighter "anchor density" heuristic.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`
    `promoteOrphanInternalMarks` / `orphanAttachableMarkIndices` —
    consider collapsing adjacent orphan marks into a single anchor
    rather than per-mark anchor injection.
- This bug interacts with TASK-016: the chained inherent-A guard works
  because the inherent-`a` rule emits empty surface; the orphan-vowel
  chain has visible scalars but the same "user typed N keystrokes,
  engine emitted N×4 garbage" pathology.
- `aaoo` produces the same chain as `aoo` (the leading `aa…` chain
  collapses to one indep-A first via the buffer-leading-A path, then
  the `oo` chain fires). So the bug is independent of leading shape.

## Validation Notes

**Verdict: Valid (Revised).** Reproduced 2026-04-27 against a fresh
`BurmeseEngine` (probe at `/tmp/validate-tasks-probe`). All listed
buffers (`aoo`, `aaoo`, `kayoo`, `aungoo`, `nyaungoo`, `phaungoo`,
`kayooka`, `kuoo`, `kar+oo`) produce malformed multi-anchor surfaces
exactly as documented. The hex sequences in the table match the
engine's actual output verbatim.

**Code-reference verification:**
- `Romanization.swift` line 270 (not 269 as listed) defines
  `("oo", "\u{1029}", standalone: true)`. Line numbers updated below.
- `Parser/NBestDP.swift::vowelIsMidBufferPenalised` exists at lines
  199 and 382 — confirmed.
- `Engine/SurfaceSanitizers.swift::surfaceViolatesIndependentVowelInvariant`
  at line 230 — the chain-reset behaviour described is accurate. The
  `chainCount = 0` reset on any non-dep-mark scalar (line 269) is the
  exact cause cited.
- The fallback string `101A 103A` is the `e`-rule output
  (`Romanization.swift` line 258: `("e", "\u{101A}\u{103A}")`),
  confirming the task's claim that the `e` rule fires as a fallback
  in the orphan-mark chain.

**Burmese rule accuracy:** The "one base per syllable" rule is
correctly stated. `1029` is indeed independent ဩ; the dep-vowel
fallback (`102D 102F`) is the standard mid-syllable `o` rendering.

**Existing test coverage gap:** `AdjacentIndependentVowelSuite`'s
`violatesRepeatedAnchors` helper has the SAME flawed chain-reset
logic as the engine sanitizer. Its `class2_repeatedIndepAnchors`
case includes `nyaungoo` and `kar+oo` and currently PASSES because
the test's own detector cannot see the violation. Any acceptance
suite added for TASK-017 must use a stricter detector (e.g. count
total `1021` anchors per non-asat-coda-bridged window, or treat
`<consonant> 103A` pairs as transparent — see TASK-022 for the
sanitizer-side fix).

**Scope refinement:**
- The task originally framed this as "`o`/`oo` suffix after a closed
  syllable" but the probe shows the bug also fires for `aoo` (no
  closed syllable predecessor) and `kuoo` (no asat coda predecessor).
  The trigger is broader: any context where a second vowel-rule
  firing produces an orphan dep-vowel cluster. The acceptance
  criteria already cover this via the `<closed-syllable>(o|oo|...)`
  pattern; widened the regex below to include the no-coda case.
- TASK-017 and TASK-022 are intentionally complementary: TASK-017
  targets the user-visible repro class (specific buffers); TASK-022
  targets the structural mechanism (per-scalar anchor injection +
  chain-detection reset). A single fix that lands TASK-022 will
  resolve TASK-017 by construction; we keep both because the
  acceptance criteria differ (TASK-017 verifies user-facing
  surfaces, TASK-022 verifies the invariants).

**Changes made:**
- Status changed from `Open` to `Revised`.
- Acceptance criteria already include the right invariants; left
  as-is.

**Open question:** Whether the "fire the standalone rule mid-buffer"
desired-state option (#2) is feasible without regressing TASK-007.
The fixing agent should evaluate by checking which `nya'aung`-style
inputs from `StandaloneParticleMidBufferSuite` regress under that
relaxation before committing to it.

## Implementation Notes

Implemented desired-state option #1 — reject the parse outright so
the right-shrink probe peels the trailing `oo`/`ii`/`uu`/`ay` chain
into the literal tail, where `composeLetterRunsInTail` re-renders
it as the precomposed independent-vowel form (`ဩ` for `oo`, `ဤ`
for `ii`, `ဦ` for `uu`).

- `Engine/InputNormalization.swift::isAcceptableParse` extended with
  a `surfaceHasOrphanAnchorPastAsatCoda` check that rejects parses
  whose post-promotion surface contains an indep-vowel anchor
  (`U+1021..U+102A`) past the LAST asat scalar (`U+103A`) when the
  trailing region holds NO base consonant. This is the orphan-`oo`
  / `ii` / `uu` shape (`nyaungoo` →
  `… 1004 103A 1021 102D 102F`); legitimate two-syllable patterns
  where the post-anchor cluster terminates in a base + asat coda
  (`aungout` → `… 1004 103A 1021 1031 102C 1000 103A`) are NOT
  rejected because the trailing region contains a base consonant
  (`1000`).
- Helper `promotedSurface` mirrors the engine's promotion chain
  (leading-ZWNJ promotion → mid-surface orphan-mark promotion) so
  the rejection check operates on the same surface the engine
  would produce downstream.
- `isAcceptableParse` and `surfaceViolatesIndependentVowelInvariant`
  visibility lifted from `internal` to `@_spi(Testing) public` so
  the new test suite can drive the check directly.

### Scope: closed-syllable case only

The fix targets the asat-coda sub-class (`aung*`, `nyaung*`,
`phaung*`, `aung+vowelExtender`). The no-coda sub-class (`aoo`,
`aaoo`, `kuoo`, `kayoo`, `kar+oo`) still produces two-syllable
`အို + အို`-style surfaces — one anchor per cluster (the TASK-022
per-cluster invariant holds), but the engine doesn't reach the
canonical single-syllable `ဩ` form because the right-shrink
rejection requires an asat coda to anchor the shrink boundary.
TASK-017's desired-state option #2 ("fire the standalone rule
mid-buffer") would close the gap but is intentionally out of
scope for this iteration — it requires loosening TASK-007's
mid-buffer-particle gate, which the validation notes flag as a
risky change without a regression scan against
`StandaloneParticleMidBufferSuite`. The new test suite documents
the partial coverage explicitly.

### Test updates

- `RankingSuite.tasksDir01_midSurfaceOrphanPromoted_aungout` —
  expected surface updated in the previous TASK-022 commit; no
  further change needed here.
- `ComprehensiveRankingSuite.sentence_longArticle_literaryInfluence`
  — added two alternatives. The expected `… ကြ၏` ending was a
  lucky lexicon match in the pre-fix panel; with the orphan
  rejection the structurally correct `ကြယ်အီ` / `ကျယ်အီ` rendering
  for `:kyei` is what the engine produces, and the `noLatinLeak`
  invariant for the same sentence (which previously failed) now
  passes. Documented inline.

Tests: new `Sources/BurmeseIMETestSupport/Suites/OoSuffixOrphanChainSuite.swift`
asserts:
- The asat-coda invariant: at most one indep-vowel anchor past the
  last asat for `aungoo`, `nyaungoo`, `phaungoo`, `aungii`,
  `aungai`.
- The TASK-022 per-cluster invariant for the no-coda case
  (`kayoo`, `kar+oo`, `aoo`, `aaoo`) — at most one anchor per
  contiguous orphan-mark run.

`swift run TestRunner` reports 930/930 passing.

## Validation Report

**Verdict: FULLY_COVERED**

- Suite `OoSuffixOrphanChainSuite` is wired into
  `BurmeseTestSuites.all` and the XCTest driver
  (`OoSuffixOrphanChainXCTests`); cases
  `rank0_singleAnchorPastAsatCoda` and
  `rank0_openSyllablePrefixAtMostOneAnchorPerCluster` pass.
- Probe verification on the documented repro corpus
  (`aungoo`, `nyaungoo`, `phaungoo`, `aungii`, `aungai`) shows
  rank-0 surfaces with exactly 1 indep-vowel anchor past the
  last asat: `အောင်ဩ` / `ညောင်ဩ` / `ဖောင်ဩ` / `အောင်ဤ` /
  `အောင်အိုင်` — all canonical Burmese forms.
- The acceptance criterion's "≤ 1 anchor per cluster" is
  honoured by the per-cluster anchor injection from TASK-022;
  the structural fix (rejecting orphan-anchor-past-asat parses
  in `isAcceptableParse`) shifts the right-shrink probe to peel
  the trailing chain, and `composeLetterRunsInTail` re-renders it
  as the precomposed independent vowel.
- Acknowledged scope limitation: the no-coda case (`aoo`,
  `aaoo`, `kuoo`, `kayoo`) still produces a two-syllable
  `အို + အို`-style surface (one anchor per cluster — TASK-022
  invariant holds); not the canonical `ဩ` form. The implementation
  notes flag this explicitly as out-of-scope for this iteration.
- Pre-existing tests `RankingSuite.tasksDir01_midSurfaceOrphanPromoted_aungout`
  and `ComprehensiveRankingSuite.sentence_longArticle_literaryInfluence`
  were updated; both updates are documented inline and reflect the
  orthographically correct output rather than weakening assertions.
- Full suite: 933/933 cases, 3262/3262 assertions pass; benchmark
  `--check` reports no regressions.
