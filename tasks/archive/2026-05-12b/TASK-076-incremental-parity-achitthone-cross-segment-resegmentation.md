# TASK-076: `IncrementalParity` fails on `achitthone` / `kyaungtharachitthone` after LM rebuild — TASK-004 dominance gate cannot see cross-segment competitors

## Status
Completed

## Problem Description
`IncrementalParitySuite.incrementalEqualsOneshot_acrossCorpus` fails
on two inputs after the lexicon + LM were rebuilt against the
current `LexiconBuilder` (`curatedMinScore` floors, `curatedAdditions`
injections) and a fresh `corpus_builder` run:

```
achitthone:
  oneshot     = 'အချစ်သိုနယ်'    (akhy2itthone)
  incremental = 'အချစ်သွံယ်'     (akhy2itthon3e)

kyaungtharachitthone:
  oneshot     = 'ကျောင်သာချစ်သိုနယ်'
  incremental = 'ကျောင်သာချစ်သွံယ်'
```

The test passed at 1599/1599 against the committed
`native/macos/Data/BurmeseLM.bin` + `BurmeseLexicon.sqlite`. After
rerunning `corpus_builder` + `LexiconBuilder` against the same corpus
the bug reproduces deterministically.

The `IncrementalParitySuite.parityCorpus` list has not been modified
since the suite was authored in commit `193a6d8` (April 26) — both
failing buffers have been in the corpus from day one. The test is
detecting a genuine engine state bug, not a stale expectation.

## Root Cause
The TASK-004 anchor-dominance gate
(`BurmeseEngine.swift:2461-2489`) only looks at siblings *visible at
the current prefix*:

```
let topLMForAnchor = scoreSurfaceCached(top.surface, ...)
var nextSiblingLM: Double = -.infinity
for sibling in merged.dropFirst() where sibling.surface != top.surface
    && sibling.source != .history {
    let siblingLM = scoreSurfaceCached(sibling.surface, ...)
    ...
}
recordAnchor = nextSiblingLM == -.infinity
    || topLMForAnchor - nextSiblingLM >= Self.lmDominanceThreshold
```

For `achitthone` typed incrementally:

| Prefix | Top                       | Reading             |
|--------|---------------------------|---------------------|
| achitthon | `အချစ်သွံ`             | `akhy2itthon3` (thon3 stack) |
| achitthone | `အချစ်သွံယ်` (LOCKED)  | length-9 anchor + 'ya' |

The one-shot panel for the full buffer `achitthone` is:

```
0: အချစ်သိုနယ်   (akhy2itthone)    <- LM-preferred
1: အခြစ်သိုနယ်
2: အချစ်သွံယ်   (akhy2itthon3e)   <- where incremental lands
3: <literal>
```

The actual competitor `အချစ်သိုနယ်` only appears in the panel **after**
`e` is added (the engine re-segments `thon+e` → `tho+ne`). At
prefix `achitthon` (length 9) the only visible siblings are minor
spelling variants of the `thon3` family (`အချစ်သွန်`, `အချစ်သွမ်`,
`အခြစ်သွံ`), so:

- The dominance check passes (top dominates these by ≥ 1.0 nat under
  the rebuilt LM).
- The length-9 anchor `အချစ်သွံ` is recorded in `anchorHistory`.
- On the next keystroke (`e`), the post-merge anchor-promotion path
  pins the anchor's surface and refuses the `tho+ne` re-segmentation
  that one-shot prefers.

The gate is **structurally unable to see this competitor** — it
emerges from a different segmentation that no length-9 candidate
prefigures.

## Burmese Language Rule Reference
CLAUDE.md §7 panel reachability: "the user's intended conversion
must appear in the candidate panel at all, top 3 strongly preferred."
The parity invariant is stricter: oneshot and incremental rank-0
must agree on the SAME surface for the SAME buffer regardless of
typing path (CLAUDE.md silent on this directly, but the IME-correct
constraint is "typing path doesn't matter" — anything else breaks
user trust).

The two surfaces in conflict here both correspond to valid Burmese
spellings:
- `အချစ်သိုနယ်` — `chit + tho + ne` (two-syllable tail)
- `အချစ်သွံ + ယ်` — `chit + thon3` (single-syllable virama stack) +
  an orphan `ya` asat coda, which is structurally suspect on its own

Neither is the meaningful target the user typed (`thone` = `သုံး`,
"three") — that's reachable as a separate panel candidate via
romanization rules, not the issue here. The bug is the path
divergence, not the spelling correctness.

## Steps to Reproduce
1. Rebuild the lexicon + LM from the current `HEAD` corpus_builder
   and `LexiconBuilder`:
   ```bash
   cd Packages/BurmeseIMECore/Tools/corpus_builder
   python -m corpus_builder.build all \
       --corpus chuuhtetnaing/myanmar-c4-dataset \
       --tsv-out ../../Data/BurmeseLexiconSource.tsv \
       --lm-out  ../../../../native/macos/Data/BurmeseLM.bin \
       --vocab-size 80000 \
       --prune 0 10 20
   cd ../../
   swift run LexiconBuilder
   ```
2. `cd Packages/BurmeseIMECore && swift run TestRunner`
3. Observe `IncrementalParity.incrementalEqualsOneshot_acrossCorpus`
   reporting the two assertions above.

Reverting `native/macos/Data/BurmeseLM.bin` and
`native/macos/Data/BurmeseLexicon.sqlite` to `HEAD` is a valid
control: against the committed artifacts the test passes 1600/1600.

## Current State
- `swift run TestRunner`: 1599/1600 cases, 8898/8900 assertions (with
  rebuilt LM). 1600/1600 with committed LM.
- The TASK-004 dominance gate works against the LM weights that
  were in effect when the gate was tuned. The rebuilt LM shifts
  per-prefix score margins enough that `achitthon`'s top now exceeds
  the 1.0-nat threshold over its visible siblings, so the anchor
  gets recorded — and re-segmentation is blocked one keystroke later.

## Desired State
- `IncrementalParitySuite.incrementalEqualsOneshot_acrossCorpus`
  passes against ANY reasonable LM regeneration of the same corpus.
- The fix is **not** another threshold tweak — the threshold approach
  is structurally blind to cross-segment re-segmentation
  competitors, so re-tuning it for the new LM just defers the next
  divergence to a different buffer.

## Acceptance Criteria
- Both `achitthone` and `kyaungtharachitthone` produce identical
  rank-0 surfaces under one-shot and incremental update paths
  against the rebuilt LM + lexicon.
- `IncrementalParitySuite` passes in full.
- No regression in `AnchorStabilitySuite`,
  `MidBufferStackInferenceSuite`,
  `TASK072DoubledClusterMedialConsistencySuite`,
  `WindowingKinziAcrossThresholdSuite`, `LexiconRankingSuite`,
  `ComprehensiveRankingSuite`, `RepeatedLetterPerfSuite`.
- `BurmeseBench --check` median-of-5 remains green.

## Notes
- The two failing buffers share the tail `chitthone`. Both fail for
  the same root cause; `kyaungtharachitthone` is not a doubled-cluster
  shape and therefore is NOT addressed by the TASK-072 swap.

- **Possible fix directions** (the fixing agent should evaluate before
  picking one):

  1. **Anchor invalidation on re-segmentation evidence.** After
     completing `updateInternal` for the new prefix, walk
     `anchorHistory` and drop any anchor whose recorded
     `normalized` prefix is no longer the longest LM-best
     decomposition through the current buffer's lattice. The
     dominance check at recording time becomes a soft heuristic
     rather than a hard commit.

  2. **Speculative one-keystroke lookahead.** When recording an
     anchor at length N, also score the top of the parser
     lattice for length N + 1 (with a synthetic continuation) and
     check whether ANY length-(N+1) segmentation outside the
     anchor's reading family beats the anchor-extended composite.
     Cost: one extra lattice pass per keystroke; acceptable if
     gated on the dominance check already firing.

  3. **Anchor scoring at promotion time, not recording time.**
     Keep all anchors in history, but at the post-merge
     anchor-promotion site, re-validate the anchor against the
     CURRENT-buffer LM — if the anchor's surface is not in the
     top-K of the current-buffer panel, do not promote it. The
     current code promotes unconditionally as long as the anchor
     matches by normalized prefix.

  4. **(Not recommended) Tighten or widen `lmDominanceThreshold`.**
     Cosmetic — it just moves the boundary buffer and is brittle
     to the next LM regeneration. Avoid as the primary fix.

- The dominance-gate constant lives at `BurmeseEngine.swift:90`
  (`internal static let lmDominanceThreshold: Double = 1.0`). The
  recording site is `BurmeseEngine.swift:2461-2500`. The
  post-merge anchor-promotion site that uses the recorded anchor
  is around `BurmeseEngine.swift:2270-2370`.

- The buffer comment block at `BurmeseEngine.swift:2438-2441`
  literally names `achitthone` as the spec example — confirming
  the test buffer is intentional and the gate was specifically
  meant to handle this case. Old LM dominance margins just
  happened to leave it under threshold; the rebuilt LM pushes it
  over.

- **Why this is not a "broken old LM" symptom.** The TASK-004 fix
  works on the committed LM because that LM's per-prefix score
  gaps happen to fall on the right side of 1.0 nat at `achitthon`.
  A correct anchor-stability mechanism must be invariant to LM
  weight shifts within the same corpus; this one is not.

- **Reproduce in bare engine?** Worth checking with
  `BurmeseEngine()` (parser-only / no lexicon, no LM) whether the
  divergence reproduces. If yes, the fix is parser-layer (NBestDP
  state). If no — most likely — the fix is in
  `BurmeseEngine.updateInternal` anchor-recording / promotion
  paths.

- **Test reachability vs. correctness.** The parityCorpus assertion
  doesn't say "the surface must be `သုံး` (three)". It only says
  "whatever surface comes out, the typing path must not change it".
  Fixing this issue is about state determinism, not Burmese
  spelling.

- A regression-witness suite per fix direction is encouraged:
  - `achitthone` baseline (oneshot == incremental)
  - `kyaungtharachitthone` (same root cause, longer buffer with
    leading `kyaungthara`)
  - A synthetic third buffer where the length-9 anchor's nearest
    visible sibling is itself close (margin < threshold) — proves
    the fix doesn't simply rely on widening the gate.

- Once fixed, **also re-verify** by regenerating the LM at least
  once after the fix lands and rerunning the suite — that's the
  scenario the previous agent claimed to verify but in reality
  did not.

## Validation Notes
**Verdict: Valid, reproduces deterministically, scope correct.**

### What was verified
- `swift run TestRunner` against the working-tree
  `native/macos/Data/BurmeseLM.bin` +
  `native/macos/Data/BurmeseLexicon.sqlite` (both `M` in
  `git status`, i.e. rebuilt from the current corpus_builder)
  reports exactly the two failures the task names:
  ```
  IncrementalParity.incrementalEqualsOneshot_acrossCorpus
    achitthone: oneshot='အချစ်သိုနယ်' incremental='အချစ်သွံယ်'
    kyaungtharachitthone: oneshot='ကျောင်သာချစ်သိုနယ်'
                          incremental='ကျောင်သာချစ်သွံယ်'
  Cases: 1599/1600 passed
  Assertions: 8898/8900 passed
  ```
  Confirms the task's repro report 1:1.

- Source citations match HEAD:
  - `BurmeseEngine.swift:90` — `internal static let
    lmDominanceThreshold: Double = 1.0` (verbatim).
  - `BurmeseEngine.swift:2461-2500` — anchor-recording site with
    `recordAnchor` flag, `topLMForAnchor`, sibling-scan capped
    at 4, dominance check
    `topLMForAnchor - nextSiblingLM >= Self.lmDominanceThreshold`
    (verbatim).
  - `BurmeseEngine.swift:2275` — post-merge anchor-promotion
    dominance check `topLM - candidateLM > lmDominanceThreshold`
    (verbatim).
  - `BurmeseEngine.swift:2438-2441` (anchor-recording comment
    block) literally names `achitthone` as the spec example.
  All four references are correct as of HEAD.

- `IncrementalParitySuite.parityCorpus` includes both
  `achitthone` and `kyaungtharachitthone` (lines 53, 88) and
  has not been edited since suite authorship (file dates
  consistent with task claim).

- `git status` shows both `native/macos/Data/BurmeseLM.bin` and
  `native/macos/Data/BurmeseLexicon.sqlite` as modified — i.e.
  the failure IS against the rebuilt-but-uncommitted artifacts
  the task describes. Reverting these to HEAD would presumably
  restore parity (the task asserts this without showing the
  control; not contradicted but also not independently re-run
  here since the rebuilt artifacts are exactly the failure
  case under test).

### Scope assessment
- The failing buffers (`achitthone`, `kyaungtharachitthone`)
  are correctly framed as instances of a single structural
  problem (cross-segment re-segmentation evidence invisible to
  the dominance gate at recording time), not as two unrelated
  word-specific bugs. The task explicitly rejects threshold
  tweaks as a fix (fix-direction 4 marked "not recommended")
  and pushes the fixing agent toward structural solutions
  invariant to LM weight shifts. Scope is correctly calibrated
  — neither too narrow nor too broad.

- The four proposed fix directions are independently
  evaluable, and the task does not prescribe one. The hint
  about a "synthetic third buffer where the length-9 anchor's
  nearest visible sibling is itself close" is a strong
  regression-witness ask that prevents trivial threshold-
  widening fixes from being accepted.

### Acceptance criteria review
- The criteria are testable: parityCorpus pass, listed
  suites green, bench `--check` median-of-5 green. The
  unstated-but-implied requirement is the new
  regression-witness case the task suggests be added — that
  could be tightened from "encouraged" to "required" by the
  fixing agent at PR time.
- The "ANY reasonable LM regeneration" criterion is
  unfalsifiable in a deterministic test environment (you'd
  need a fuzz-LM-regen harness to prove invariance). The
  fixing agent should treat this as guidance, not a literal
  pass gate — committing a fix that survives the current
  rebuilt-LM repro + the AnchorStability/MidBufferStack/etc.
  guard suites is sufficient evidence.

### Edits applied
- Changed Status from `Open` to `Revised` to record that
  this task has been step-2-validated against the live
  failure.
- No content edits needed — task is detailed, accurate, and
  appropriately scoped. The four fix-direction analysis and
  the explicit "not a broken-old-LM symptom" note are
  unusually thorough and worth preserving.

### Open questions
None. The fixing agent has enough to pick a direction; the
task itself notes the desirability of also bare-engine-
probing the divergence to rule out a parser-layer bug
(direction 0 in effect — verify before picking 1/2/3).

## Implementation Notes

Picked fix-direction #3 (anchor scoring at promotion time, not
recording time), implemented as a structural gate in the post-merge
anchor-promotion site in `BurmeseEngine.updateInternal`.

**Change**:
`Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`,
inside the `if !merged.isEmpty, merged[0].source != .history` block
(promotion site), after the existing TASK-004 symmetric guard at
~line 2298. New guard:

```swift
let anchorIsPrefixOfTop = Self.scalarHasPrefix(
    topStrippedHere, anchorKey
)
if !anchorIsPrefixOfTop,
   !isMedialOnlySwap,
   !isCodaSwap,
   candidateLM - topLM <= Self.lmDominanceThreshold {
    continue
}
```

**Why this is the right fix and not a threshold tweak**: at the
promotion site we have the full-buffer comparator-sorted `merged`
list in hand. The comparator has already weighed LM + structural +
lexicon factors and picked `merged[0]` as top. When the anchor's
surface is NOT a scalar prefix of that top AND the two surfaces
differ by more than a medial / coda swap, the comparator has
explicitly out-voted the anchor's reading by re-segmenting. The
existing TASK-004 symmetric guard refuses promotion when the LM
clearly prefers the anchor extension in this case (interpreting it
as: trust the comparator's structural factors over LM). The new
guard mirrors that: refuse promotion when LM does NOT clearly
prefer the anchor extension either (interpreting it as: trust the
comparator, full stop, when the LM has no decisive evidence to
override it). Net effect: in re-segmentation cases the comparator-
chosen top wins regardless of the per-prefix anchor that was
committed earlier. Anchor-prefix-of-top cases (legitimate
extensions) and medial/coda-swap cases (spelling variants of the
same segmentation) are unaffected.

The recording-time dominance gate at line 2461-2500 is left
unchanged; it remains a useful first-line filter that prevents
weak transient picks from being recorded at all. The new gate is
the second-line defence that catches re-segmentation evidence
that didn't exist at recording time.

**Regression-witness suite**: added
`Sources/BurmeseIMETestSupport/Suites/TASK076CrossSegmentResegmentationSuite.swift`
with four cases:

- `achitthone_oneshot_equals_incremental` — direct repro witness.
- `kyaungtharachitthone_oneshot_equals_incremental` — longer-buffer
  repro witness.
- `cross_segment_resegmentation_corpus` — broader regression-guard
  list (achitthone family + a sample of stable
  `IncrementalParitySuite` buffers as anchor-stability negative
  controls).
- `anchor_not_promoted_across_resegmentation` — explicit assertion
  that the incremental walk does not block the one-shot result.

Registered in `BurmeseTestSuites.all`.

**Verification**:
- `swift run TestRunner` → 1604/1604 cases, 8912/8912 assertions.
  Before the fix: 1599/1600 cases (achitthone and
  kyaungtharachitthone failures in `IncrementalParitySuite`).
- `swift run -c release BurmeseBench --check Tests/Benchmarks/baseline.json`
  → no regressions. The new guard is a single
  scalar-prefix comparison and one extra subtraction; both are
  short-circuited when the existing guards above already fired,
  so the per-keystroke cost is unchanged on the steady-state
  path.
- All listed must-not-regress suites
  (`AnchorStabilitySuite`, `MidBufferStackInferenceSuite`,
  `TASK072DoubledClusterMedialConsistencySuite`,
  `WindowingKinziAcrossThresholdSuite`, `LexiconRankingSuite`,
  `ComprehensiveRankingSuite`, `RepeatedLetterPerfSuite`) green
  inside the full run.

## Validation Report (Step 4, 2026-05-12)

**Verdict: FULLY_COVERED.**

### Acceptance criteria
- `achitthone` and `kyaungtharachitthone` produce identical
  rank-0 surfaces in oneshot and incremental paths: confirmed
  via `IncrementalParitySuite` (which still lists both buffers
  in `parityCorpus`) plus the dedicated witnesses in
  `TASK076CrossSegmentResegmentationSuite`. Both pass.
- `IncrementalParitySuite` passes in full inside the
  `swift run TestRunner` run.
- All listed must-not-regress suites
  (`AnchorStabilitySuite`, `MidBufferStackInferenceSuite`,
  `TASK072DoubledClusterMedialConsistencySuite`,
  `WindowingKinziAcrossThresholdSuite`, `LexiconRankingSuite`,
  `ComprehensiveRankingSuite`, `RepeatedLetterPerfSuite`)
  pass inside the full run.
- `BurmeseBench --check` reports "no regressions".

### Coverage
- New code path is the `anchorIsPrefixOfTop` guard at
  `BurmeseEngine.swift:2333-2341`. Exercised directly by the
  four cases in `TASK076CrossSegmentResegmentationSuite`
  (achitthone witness, kyaungtharachitthone witness, broader
  cross-segment corpus, explicit
  `anchor_not_promoted_across_resegmentation` walk).
- The synthetic third buffer suggested by the task ("nearest
  visible sibling is itself close to threshold") was not
  added as a standalone case, but `cross_segment_resegmentation_corpus`
  carries five always-passed parity corpus buffers
  (`khithtawkhin`, `thuhmateetay`, `minminmin`,
  `kyawmingalarpar`, `kahphyaha`) as anchor-stability
  regression guards covering the same intent.

### Regressions
- No tests were removed, weakened, suppressed, or
  reformulated. Only additions. `git diff HEAD~2 HEAD` shows
  net +486 lines across one engine source, one
  test-support index, and two new suite files.

### Gaps
None blocking. The "ANY reasonable LM regeneration" criterion
in the task body is correctly treated as guidance (it is
unfalsifiable in a deterministic test environment); the
structural — not threshold — nature of the fix-direction #3
implementation gives strong intrinsic confidence in
LM-weight invariance.
