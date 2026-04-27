# TASK-013: Repeated single-letter buffers degrade per-keystroke latency to 10ms+

## Status
Completed

## Implementation Notes
- New helper `SyllableParser.beamWidth(for:maxResults:)` halves the
  DP beam multiplier (16× → 4×) when the buffer's longest same-letter
  run is ≥ 6. Highly redundant input still gets `max(maxResults * 4,
  64)` per bucket, which preserves the surviving N-best (every
  pruned state shares its aliasCost / score tier with another state
  that survives) but cuts the per-position transition / sort cost
  by ~4×. Normal Burmese input (no run ≥ 6) keeps the original wide
  beam.
- `parseLongestAcceptablePrefix` reuses the same redundant-buffer
  detection so the right-shrink probe also benefits — that's the
  call that dominated the `t*16` profile (8.5 ms → ~2.5 ms).
- Added two new benchmark scenarios in
  `Sources/BurmeseBench/main.swift`: `repetition_t16` (16-`t`
  buffer) and `plus_chain_30` (`(ka+) × 10`). Baseline updated:
  `repetition_t16` p99 ~2.78 ms, `plus_chain_30` p99 ~0.37 ms —
  both well under the 5 ms target. Pre-fix `repetition_t16` was
  ~10.7 ms.
- New suite `RepeatedLetterPerfSuite` asserts wall-clock budgets
  with generous caps (300 ms hard cap on length-30 input, 30×
  growth ratio between length-6 and length-16). The caps are
  intentionally loose to avoid CI flakiness — the benchmark
  baseline is the authoritative perf budget.
- All existing benchmark scenarios remain within their ±20% p95 /
  ±30% p99 thresholds.

## Problem Description
Buffers consisting of a single consonant character repeated many
times — e.g. `tttttt…`, `ka+ka+ka+ka+…` — incur per-keystroke
processing latency that grows ~exponentially with length and
exceeds the configured benchmark targets by an order of magnitude
once the buffer reaches 8–16 characters. A 16-`t` buffer takes
~13 ms per keystroke; a 30-character `ka+ka+…` chain takes ~14 ms.
The committed baseline targets are p99 ≤ 2.1 ms on the
`incremental` scenario and ≤ 0.4 ms on `garbage`, so the repeated
inputs miss budget by 6–35×.

The pathology is reproducible in release-built engine probes (no
debug overhead) and is concentrated on letters whose romanization
key participates in many vowel-suffix and consonant-onset rules
(`t`, `k`, `s`, `d`, `m`, `n`, `p`). Letters with fewer rule
participations (`b`, `f`) do not exhibit the same blowup.

## Root Cause
The DP / inference stack runs in three phases on every keystroke:

1. `SyllableParser.parseCandidates` builds a beam-pruned N-best DP
   over onset+vowel rule matches.
2. `BurmeseEngine.inferImplicitStackMarkers` scans the buffer for
   Pali-stack inference sites and produces sibling parses for each
   inferred form.
3. `parseLongestAcceptablePrefix` walks the DP buckets back to
   find the right-shrink-acceptable length.

For repeated letters that match many onset / vowel keys, every
position of the buffer matches multiple rules and the DP carries
a dense beam at every column. The beam-pruning logic
(`pruneBucket`) keeps `beamWidth` states per bucket, but each
state encodes a different combination of medials and vowels, so
the surviving beam at column `k` regenerates a similarly dense
beam at column `k+1`. With 16 columns of `t` and ~5 rule matches
per position, the DP traverses on the order of 10⁵ state
transitions, each performing string materialisation work.

The `+`-chain case is the same shape: each `+ka` introduces
a soft-boundary transition plus a stack-inference candidate site,
so 10 `+ka` segments compound the per-position branching factor.

The worst-affected scenario is **not currently in
`Tests/Benchmarks/baseline.json`**, so regressions land silently.
The committed `garbage` scenario uses a long string of mixed
random letters which doesn't expose the same compounding because
no single letter repeats more than a handful of times.

## Burmese Language Rule Reference
N/A — this is a performance issue that does not affect correctness
of well-formed input. However, it does affect users who paste
malformed text (text encoded in a non-Myanmar script) into the IME
or who hold down a key by accident: the IME freezes for
double-digit milliseconds per keystroke.

## Steps to Reproduce
On a release-built `BurmeseEngine`, time the call:

```swift
let engine = BurmeseEngine()
_ = engine.update(buffer: String(repeating: "t", count: 16), context: [])
```

Repeat for buffer lengths 1..20. Latency grows from ~100 us at
length 1 to ~13 000 us at length 16, with the alternating
even/odd cache pattern (even lengths cost ~2× odd lengths).

Concrete latencies (verified 2026-04-27, release build, M-series
Mac):

| Buffer | Length | p50 latency |
|---|---|---|
| `t…` (16 t's) | 16 | 13 040 us |
| `t…` (10 t's) | 10 | 11 700 us |
| `t…` (8 t's) | 8 | 5 100 us |
| `k…` (16 k's) | 16 | 120 us |
| `ka+ka+…` (×8, 23 chars) | 23 | 3 500 us |
| `ka+ka+…` (×10, 30 chars) | 30 | 14 000 us |
| `atatatatatatatat` | 16 | 1 650 us |
| `mingalarpar`-incremental p99 (full sentence) | 54 | 9 100 us |

The `incremental` benchmark scenario's recent committed p99 is
~2 100 us, so the longest natural Burmese sentence in the
scenario already grazes 4–5× over budget on a single keystroke.

## Current State
- Real-world keystroke latency on long natural Burmese sentences
  occasionally spikes above 5 ms.
- Pasting non-Burmese text containing repeated letters causes
  the IME to freeze for tens of milliseconds per character.
- The benchmark `--check` reports no regression because no
  scenario covers the repeated-letter / `+`-chain pathology.

## Desired State
- p99 per-keystroke latency on the existing `short` / `medium` /
  `long` / `incremental` scenarios stays within 20% of baseline.
- New repeated-letter and `+`-chain benchmark scenarios are
  added (`repetition_t16`, `plus_chain_30`) and their p99 stays
  under a defensible budget (target: ≤ 5 ms — 10× over baseline
  is acceptable for adversarial input as long as the engine
  doesn't lock up).
- The DP / inference stack does not regenerate a dense beam at
  every column when the input is highly redundant.

## Acceptance Criteria
- New benchmark scenarios (added to
  `Sources/BurmeseBench/main.swift`):
  - `repetition_t16`: full-buffer pass on `String(repeating: "t", count: 16)`.
  - `plus_chain_30`: full-buffer pass on `String(repeating: "ka+", count: 10)`.
  Both scenarios committed to `Tests/Benchmarks/baseline.json`
  with p95/p99 captured after the fix lands.
- After the fix, both new scenarios report p99 ≤ 5 ms (improved
  from the current ≥ 13 ms).
- All existing scenarios stay within the configured ±20% p95
  / ±30% p99 thresholds.
- A new test under
  `Sources/BurmeseIMETestSupport/Suites/RepeatedLetterPerfSuite.swift`
  asserts wall-clock budgets on the same inputs (using a
  generous tolerance to avoid CI flakiness — e.g. 50 ms hard cap
  on a length-30 input).
- `swift run TestRunner` continues to pass at 100 %.

## Notes
- Investigation pointers:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/NBestDP.swift`
    `runDP` / `insertState` / `pruneBucket` — the per-bucket
    beam currently is `max(maxResults * 16, 64)` (the `> 20`
    long-input check halves it to `max(maxResults * 4, 32)`).
    The redundant-input case probably needs a tighter
    duplicate-state collapse (states whose materialised surface
    differs only by a final inherent-A arc could be merged).
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/InputNormalization.swift`
    `inferImplicitStackMarkers` — the inference loop scans every
    position of the buffer and may produce many candidate sites
    on a `+`-chain. Adding a per-buffer site cap (e.g. ≤ 6
    insertions) would limit the worst-case work without
    affecting natural inputs that rarely have more than 2–3
    inferred sites.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/FrozenPrefixCache.swift`
    — the frozen-prefix cache should already help the
    `ka+ka+ka+...` incremental case. The fact that incremental
    p99 is also high suggests the cache is missing on every
    keystroke, possibly because the `+`-bearing input doesn't
    hit a stable cache key.
- This is a perf bug, not a correctness bug — the produced
  outputs are not ideal (see TASK-012 for the related illegal
  surface) but the latency itself is the disruptive issue.
- Probe (2026-04-27, release build):
  ```swift
  for n in 1...20 {
      let buf = String(repeating: "t", count: n)
      let start = ContinuousClock.now
      _ = engine.update(buffer: buf, context: [])
      let elapsed = ContinuousClock.now - start
      // n=10 → ~12 ms; n=16 → ~13 ms; n=8 → ~5 ms.
  }
  ```

## Validation Notes
- Validity: **Valid performance bug, confirmed via probe (2026-04-27).**
  Note: probe was run in **debug build** (the validation environment
  was already built debug for the iteration), so absolute numbers are
  larger than the task's release-build numbers. The shape (super-linear
  growth, plateau-then-explosion behaviour) matches:
  | Input | Length | Debug-build elapsed |
  |---|---|---|
  | `t*1`  | 1  | 0.06 ms |
  | `t*4`  | 4  | 0.47 ms |
  | `t*8`  | 8  | 7.2 ms |
  | `t*10` | 10 | 20.8 ms |
  | `t*12` | 12 | 24.8 ms |
  | `t*14` | 14 | 30.4 ms |
  | `t*16` | 16 | 35.6 ms |
  | `t*20` | 20 | 40.5 ms |
  | `(ka+)*3` | 9  | 0.29 ms |
  | `(ka+)*5` | 15 | 1.84 ms |
  | `(ka+)*7` | 21 | 33.7 ms |
  | `(ka+)*9` | 27 | 63.6 ms |

  The release-build numbers in the task body (~13ms at length 16)
  are roughly 3-5× faster than debug, which matches typical
  Swift release-vs-debug ratios. The task's release-build figures
  remain trustworthy.

- Code-path verification: The investigation pointers are accurate.
  `Parser/NBestDP.swift::pruneBucket` is the correct beam-pruning
  site, and `Engine/InputNormalization.swift::inferImplicitStackMarkers`
  is correctly identified as a per-position scan that compounds
  the per-syllable branching.

- Scope calibration: The task is correctly scoped as a *perf*
  problem and explicitly says it is not a correctness problem
  (cross-references TASK-012 for the related correctness issue).
  Adding two new benchmark scenarios (`repetition_t16`,
  `plus_chain_30`) is a reasonable scope.

- Acceptance criteria refinement: The "p99 ≤ 5 ms" target on the
  new scenarios is reasonable for adversarial input. However,
  the proposed test in `RepeatedLetterPerfSuite.swift` with a 50ms
  hard cap on length-30 input may be flaky on slower CI hardware
  or under thermal throttling. Recommend the fixing agent take an
  upper-bound based on a debug build measurement (e.g. cap at
  300ms or 500ms in debug, with a release-build assertion in
  the benchmark harness only).

- Burmese rule reference correctly notes N/A — perf, not
  correctness.

- Open consideration (resolved): the new benchmark scenarios
  must NOT be committed to baseline.json before the fix lands,
  otherwise the `--check` regression test passes spuriously.
  The task already requires "scenarios committed to
  Tests/Benchmarks/baseline.json with p95/p99 captured after
  the fix lands" — this ordering is correct. Fixing agent should
  add the scenarios first to confirm they reproduce the
  pathology, then ship the fix, then update baseline.

- No open questions.

## Validation Report
- **Verdict: FULLY_COVERED.**
- Two new benchmark scenarios committed to
  `Tests/Benchmarks/baseline.json`:
  - `repetition_t16` — p99 ≈ 2.78 ms (target ≤ 5 ms; pre-fix ≥ 13 ms).
  - `plus_chain_30` — p99 ≈ 0.37 ms.
  Both well under the 5 ms target.
- All existing scenarios (`short`/`medium`/`long`/`incremental`/
  `garbage`/`garbage_incremental`) stay within the configured ±20%
  p95 / ±30% p99 thresholds. `swift run -c release BurmeseBench
  --check Tests/Benchmarks/baseline.json` reports no regressions.
- Debug-build probe (warmup + 10 iterations averaged):
  | Input    | Length | Avg latency (debug) |
  |---|---|---|
  | `t*1`     | 1      | 0.09 ms |
  | `t*8`     | 8      | 5.7 ms  |
  | `t*12`    | 12     | 7.6 ms  |
  | `t*16`    | 16     | 10.8 ms |
  | `t*20`    | 20     | 8.7 ms  |
  | `(ka+)*5` | 15     | 0.27 ms |
  | `(ka+)*10`| 30     | 1.95 ms |
  Pre-fix `t*16` was ~35 ms in debug; post-fix is 10.8 ms — a 3-4×
  improvement that translates to the targeted ~2.7 ms in release.
- New `RepeatedLetterPerfSuite` (3 cases) asserts wall-clock budgets
  with a generous 300 ms hard cap so CI variability doesn't induce
  flake; the benchmark `--check` is the authoritative perf budget.
- All 912 TestRunner cases pass.
- No regressions or weakened assertions.
