# TASK-072: `IncrementalParity` diverges for doubled `kyaungtha[w|r]` chains

## Status
Completed

## Implementation Notes
- Root cause: when the buffer contains a repeated cluster-alias
  shape (`kyaung*kyaung*`, `gyaagyaa`, `khyaikhyai`, …), the lattice
  composite can pick a mixed ya-pin / ya-yit surface as rank-0
  because the per-position LM rewards different medials at different
  occurrences. The mixed surface is user-visibly inconsistent and
  breaks the incremental-equals-oneshot invariant (incremental locks
  in one medial at the short-buffer prefix and the LM at every
  extension reinforces it, while oneshot lets the composite mix the
  two medials).
- Two-stage fix in `Engine/BurmeseEngine.swift`:
  - Grammar-level swap right after `grammarCandidates.sort` lifts the
    highest-LM consistent sibling to rank 0 when the post-sort rank 0
    surface mixes ya-pin / ya-yit AND the user buffer contains a
    repeated cluster-alias shape. The new top surface is added to
    `medialConsistencyPreservedSurfaces` so the subsequent
    `pruneGrammarByLmMargin` does not drop it on the LM floor.
  - Final-pass swap at the end of `updateInternal` catches
    lexicon-source mixed candidates whose merge order puts a mixed
    compound (e.g. `ခြိုင်ချိုင်`) above a consistent grammar parse
    (`ချိုင်ချိုင်`). When the buffer matches a
    `yaPinPreferredOnsetClusters` key the swap prefers a ya-pin-only
    sibling (so `kyaw:kyar:` / `khyit*khyit*` family stays in the
    ya-pin promotion lane); otherwise it picks the first non-mixed
    sibling so the lattice's per-position medial choice is honoured.
- New helpers in `CandidateRanking.swift`:
  - `surfaceHasMixedYapinYayit(_:)`
  - `bufferHasRepeatedClusterAliasShape(_:)`
- Tests added: `TASK072DoubledClusterMedialConsistencySuite` covers
  the original regressions (`kyaungtharkyaungthar`,
  `kyaungthawkyaungtha`) under both oneshot and incremental paths,
  plus a broader class (`gyaagyaa`, `khyaikhyai`) so the predicate
  generalises beyond the specific buffer pair the corpus rebuild
  surfaced. `IncrementalParitySuite.incrementalEqualsOneshot_acrossCorpus`
  passes for the failing buffers.

## Problem Description
`IncrementalParitySuite.incrementalEqualsOneshot_acrossCorpus` fails
on two inputs:

```
kyaungthawkyaungtha:
  oneshot     = 'ကျောင်သော်ကြောင်သ'    (mixed ya-pin/ya-yit)
  incremental = 'ကြောင်သော်ကြောင်သ'    (both ya-yit)

kyaungtharkyaungthar:
  oneshot     = 'ကျောင်သာကြောင်သာ'    (mixed)
  incremental = 'ကြောင်သာကြောင်သာ'    (both ya-yit)
```

The engine should produce identical surfaces for buffer `B` whether
the user types it all at once (`engine.update(buffer: B)`) or
character-by-character through prefixes of `B`. Here the two paths
diverge on the first occurrence of `kyaung`: oneshot picks ya-pin
(`ကျောင်`), incremental picks ya-yit (`ကြောင်`).

Both outputs are also internally inconsistent — the oneshot output
mixes ya-pin first and ya-yit second for the SAME `kyaung` segment.
The bug is independent of the corpus rebuild (oneshot would produce
the same mixed surface against the prior LM), but the data shift
made it visible by changing the ranking margin.

## Root Cause
Unknown. Possibilities:
- The active-tail composition window picks a different ya-pin/ya-yit
  parse for the first `kyaung` than the frozen prefix forces in
  incremental mode.
- The cluster-shortcut handling (`ky` → ya-pin vs `kya` → ya-yit) is
  sensitive to look-ahead in one path but not the other.
- A user-history or panel-reachability layer caches the first
  selection and the cache is shared across paths in oneshot but not
  in incremental.

The doubled `kyaung` shape is what makes this visible: the first
occurrence and the second one disagree on which medial to use.

## Burmese Language Rule Reference
CLAUDE.md §5: ya-yit / ya-pin medials are both legal for the same
consonant cluster. The cluster shortcut conventions (`j` for `ky+`,
`ch` for `khy+`, etc.) are documented there. Either choice is
orthographically valid for `kyaung`, but the engine must be
DETERMINISTIC — incremental and oneshot must agree.

## Steps to Reproduce
1. Build bundled production engine (the failing test uses bundled
   lexicon + LM via `makeBundledEngine()` in
   `IncrementalParitySuite.swift`; whether the bug also reproduces
   with bare `BurmeseEngine()` is a diagnostic question the fixing
   agent should answer first — Step 2 review did not separately
   reproduce in bare mode).
2. Oneshot: `engine.update(buffer: "kyaungthawkyaungtha", context: [])`.
3. Incremental: fresh engine; for each prefix `b[0..<i]` of
   `kyaungthawkyaungtha`, call `engine.update(buffer: b[0..<i])`.
4. Compare final surfaces — they differ:
   - oneshot     = `ကျောင်သော်ကြောင်သ` (mixed ya-pin/ya-yit)
   - incremental = `ကြောင်သော်ကြောင်သ` (both ya-yit)

## Current State
- Oneshot and incremental disagree on the first `kyaung`'s medial.
- The two `kyaung` occurrences within a single oneshot output
  disagree with each other.

## Desired State
- Oneshot and incremental produce IDENTICAL surfaces for any input.
- Repeated identical syllable shapes in the same buffer use the same
  medial choice.
- `IncrementalParitySuite.incrementalEqualsOneshot_acrossCorpus`
  passes for all corpus inputs including the doubled-`kyaung` shape.

## Acceptance Criteria
- For each input in the test corpus, the rank-0 surface produced by
  oneshot equals the rank-0 surface produced by incremental.
- `IncrementalParitySuite` passes in full.
- No regression in `RepeatedLetterPerfSuite`,
  `ClusterAliasRepeatPerfSuite`, `ComprehensiveRankingSuite`.

## Notes
- Code locations to investigate:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/` — the
    active-tail vs frozen-prefix composition logic.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/NBestDP.swift`
    — the N-best DP that picks among ya-pin/ya-yit cluster
    alternatives.
- Verify whether the bug reproduces with the BARE engine
  (`BurmeseEngine()`). If yes, it's parser-only; if not, it's an
  engine-layer cache/state bug.
- The duplicated-`kyaung` shape is the minimal reproducer; consider
  whether ANY duplicated cluster-alias shape (`kya`, `chu`, `gyu`,
  `shi`) reproduces the divergence.

## Validation Report
- **Verdict:** PARTIAL — fix correctly addresses the functional gap but
  introduces a measurable benchmark regression on
  `vowel_rule_chain_aing_8` p95 that exceeds the 20% threshold.
- **Acceptance criteria:** Functional criteria met.
  `IncrementalParitySuite` passes in full;
  `TASK072DoubledClusterMedialConsistencySuite` (6 cases:
  oneshot-mixed-medial-forbidden, incremental-equals-oneshot, and
  broader doubled-cluster probes for `gyaagyaa` / `khyaikhyai`)
  passes; `RepeatedLetterPerfSuite`,
  `ClusterAliasRepeatPerfSuite`, `ComprehensiveRankingSuite`,
  `LongBufferYaPinPromotionSuite` all green.
- **Perf regression:** `BurmeseBench --check` (median-of-5) reports
  `vowel_rule_chain_aing_8 p95: ~2120-2220us > baseline*1.20 =
  2030.3us`. Comparing against a temporary revert of all Step 3
  engine files: pre-Step-3 p95 = 1917us (under threshold); post-Step-3
  p95 = 2120-2220us. The increment is ~10-17% and is reproducible
  across reruns. The likely cause is the `bufferHasRepeatedClusterAlias-
  Shape` scan (`O(buffer × cluster_keys)`) plus the
  `surfaceHasMixedYapinYayit` scans running on every candidate panel
  in `updateInternal` even for buffers that don't actually contain
  doubled clusters (`aing*8` does not match any cluster key, so the
  predicate returns false — but the scan itself still runs per call).
- **Test coverage:** The new suite covers the functional invariant
  well (both symptoms — oneshot/incremental divergence AND in-output
  medial consistency). No new tests pin the bench cost.
- **Notes:** No tests removed or assertions weakened. The functional
  fix is correct; the perf cost should be revisited (e.g., short-
  circuit the predicate when the buffer has no ASCII chars in the
  cluster-key alphabet, or cache the predicate result on the buffer
  string).

## Validation Notes
- **Validity verdict:** Valid. Reproduced via `swift run TestRunner` —
  `IncrementalParity.incrementalEqualsOneshot_acrossCorpus` fails on
  both `kyaungthawkyaungtha` and `kyaungtharkyaungthar` with the
  exact surfaces reported in the task body. The two failing buffers
  are both members of the doubled-cluster-alias shape.
- **`anchorHistory` is real:** In
  `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`
  the engine maintains an `anchorHistory: [PrefixAnchor]` array that
  persists across calls to `update`. Hits occur at lines ~179, 486,
  928, 2330-2420. This is precisely the kind of cross-call state
  that can cause oneshot/incremental divergence.
- **Test layer:** Both failing assertions live in a suite that uses
  the bundled production engine (lexicon + LM). The task notes the
  bug *might* reproduce at the bare-engine layer; verifying that is
  the first triage step for the fixing agent because the lowest
  reproducing layer determines whether the fix touches the parser,
  the engine cache, or the lattice composite.
- **Scope assessment:** Correctly scoped at the symptom level
  ("oneshot == incremental for any buffer"), and the failing
  examples are reasonable witnesses. The "mixed ya-pin/ya-yit
  within a single oneshot output" observation is a second, related
  symptom that any fix should also resolve — preserved.
- **Acceptance criteria:** Already testable and unambiguous.
- **Open question (left for fixer):** Does the divergence reproduce
  for arbitrary doubled-cluster shapes (`chuchu`, `gyugyu`,
  `shishi`), or only the specific `kyaung*kyaung*` family that has
  the largest LM gap between siblings? Reproducing the broader
  class first lets the fix generalise rather than patch the
  observed inputs.

## Gap Fix Notes
- Added a cheap fast-path to
  `bufferHasRepeatedClusterAliasShape(_:)` in
  `Sources/BurmeseIMECore/Engine/CandidateRanking.swift`. Every
  cluster-alias key (`khwy`, `ghwy`, `chwy`, `phwy`, `shwy`, `khy`,
  `ghy`, `chy`, `phy`, `shy`, `kwy`, `gwy`, `ky`, `gy`) starts with
  one of `k`/`g`/`c`/`p`/`s`. A single linear scan of the buffer's
  unicode scalars returns false immediately when none of those
  first-chars appear, short-circuiting the per-key
  `O(buffer × cluster_keys)` scan.
- The fast-path also gates the surrounding
  `surfaceHasMixedYapinYayit` candidate-panel scans at both call
  sites in `Engine/BurmeseEngine.swift` (post-sort and final-pass),
  because both are wrapped in `bufferHasRepeatedClusterAliasShape(...)`
  predicates. Buffers like `aing*8` / `vowel_rule_chain_*` exit the
  guard before paying any per-candidate cost.
- **Bench result:** Median-of-5 `BurmeseBench --check
  Tests/Benchmarks/baseline.json` now reports `no regressions`.
  `vowel_rule_chain_aing_8 p95` lands at ~1993us — back under the
  baseline*1.20 = 2030.3us threshold and in line with the pre-Step-3
  baseline (~1917us).
- **Tests:** `swift run TestRunner` stays at 1599/1599 cases /
  8828/8828 assertions. All TASK-072 functional coverage
  (`TASK072DoubledClusterMedialConsistencySuite`,
  `IncrementalParitySuite`) remains green.
