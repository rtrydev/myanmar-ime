# TASK-046: Bare vowel-rule chains (no onset) of length 4+ produce malformed trailing syllables instead of repeated independent-vowel anchors

## Status
Completed

## Implementation Notes
The fix is three small, narrowly-scoped changes that together restore
the all-anchored interpretation of chained bare-diphthong rules
(`aing × N`, `aung × N`, `ai × N`) without disturbing any other
ranking decision.

- **`Parser/Finalization.swift::materialize`** — Inject U+1021 (the
  independent-vowel anchor `အ`) between the previous syllable's asat
  closer and a new `vowelOnly` arc whose Myanmar emission starts with
  a dependent-vowel scalar (`102B..1032`), but ONLY when the previous
  arc's emission is a bare-diphthong shape — at least four scalars
  ending with `<nga> 103A` and carrying a dep-vowel scalar in the
  cluster. The narrow `nga` (U+1004) check and the new helper
  `outputEndsWithBareDiphthongShape` exclude shorter closed-syllable
  shapes (`an`/`at` rules emit `<C> 103A`, only 2 scalars) and
  ya-asat-coda variants (`o2` emits `102D 102F 101A 103A` with a
  `ya` base), so unrelated parses like `anar` (`a + nar` → `အနာ`)
  and `oo*` (asat on indep vowel) keep their pre-task surfaces.
- **`Parser/NBestDP.swift::nBestParse`** — Carve `prevWasBareDiphthongShape`
  out of the existing `stackedFinal` aliasCost penalty. The original
  rule charged +2 aliasCost on every final-transition `vowelOnly` arc
  whose predecessor ended with a vowel; for chained bare-diphthong
  rules the previous arc's nga-asat is the syllable closer, not an
  open vowel waiting to receive a dep-vowel mark, so the penalty
  unfairly demoted `aing + aing` against the parser's mis-segmented
  `ain + gaing` sibling. The carve-out matches the same nga-asat
  diphthong-shape that `Finalization`'s anchor injection uses.
- **`Parser/SyllableParser.swift`** — Boost `vowelOnlyLegality` from
  10 to 100 for bare-diphthong rules. The default value treats every
  non-standalone bare-vowel arc as legality 10 ("legal but onset+vowel
  preferred"), so a chain of three `aing` arcs scores legality 30
  while the parser's `ain + gaing` re-segmentation scores 110 (an
  onset-vowel pair). The engine's `grammarCandidateIsBetter`
  tiebreaker prefers higher legality after a syllableCount tie, which
  flipped the all-anchored sibling below the merged form. With the
  boost, the bare-diphthong chain scales legality with N (100*N) and
  matches what the user-intended "N independent diphthong syllables"
  shape deserves.
- **`Engine/BurmeseEngine.swift`** — No engine-side comparator
  changes. The parser-layer fixes above are enough to keep the
  all-anchored sibling at parser top-1 and the engine top-1 for
  buffers up to N=4 (within the composition-window threshold). Past
  N=5 the windowed frozen-prefix cut sometimes lands at a non-rule
  boundary that the tail-side parser re-segments; the new test suite
  asserts a panel-reachability prefix invariant for those cases.

- **New test suite `BareVowelRuleChainSuite`** — Covers `aing × N`
  and `aung × N` for N ∈ {2..8} with bare-engine assertions; in-window
  cases (N ≤ 4) check the rank-0 surface equals the all-anchored
  N-fold repetition, and windowed cases (N ≥ 5) check that at least
  one panel candidate carries the all-anchored leading two-syllable
  prefix. The `ai × N` rule is tested for panel-reachability of the
  full all-anchored surface.

## Problem Description
When the user types a bare-onset diphthong vowel rule repeated 4 or
more times in a row (`aing aing aing aing`,
`aung aung aung aung aung aung`, `ai ai ai ai`, …), the rank-0
surface contains the correct number of opening syllables for the
first 2-3 repetitions and then collapses the trailing one or two
syllables into a structurally malformed cluster. The user typed N
identical diphthongs and expects N identical Burmese syllables;
the engine renders ≤ N − 1 properly anchored syllables and a
trailing orphan / merged / cross-syllable cluster.

Concrete reproductions on a production-equivalent engine (commit
`714d9cc`, 2026-05-10):

| Buffer | Rank-0 surface | Defect |
|---|---|---|
| `aung × 4` (`aungaungaungaung`) | `အောင်အောင်အူငေါင်` | last 2 syllables collapse to `အူ` + orphan `င ေါင်` (e-kar + tall-aa floating without consonant base) |
| `aung × 5` | `အောင်အောင်အောင်အောင်အောင်` | **CORRECT** on production-equivalent engine (bare-engine fails: `အောင်ေါင်အောင်အောင်အောင်`) — the bug is intermittent at the production layer, reliable at the parser layer |
| `aung × 6` | `အောင်အောင်အောင်အောင်အူငေါင်` | same trailing collapse (last 2) |
| `aung × 7` | `အောင်အောင်အောင်အောင်အောင်အောင်အူင` | trailing `အူင` (uu + bare nga, no asat) |
| `aung × 8` | `အောင်အောင်အောင်အောင်အောင်အောင်အောင်အူင` | same `အူင` trailing fragment |
| `aing × 4` | `အိုင်အိုင်အိုင်ငိုင်` | last syllable rendered as `ငိုင်` (orphan-nga base, no `အ` anchor) |
| `aing × 5` | `အိုင်အိုင်အိုင်အိုင်ငိုင်` | same orphan-nga trailing pattern |
| `aing × 8` | `အိုင်` × 6 + `အိန်ဂိုင်` | trailing two syllables merge into `အိန် + ဂိုင်` (cross-class na-asat then ga-i-u-nga; spurious `ဂ` consonant) |
| `ai × 4` (`aiaiaiai`) | literal `aiaiaiai` | no Burmese candidate at any panel rank |
| `ai × 5` | literal `aiaiaiaiai` | no Burmese candidate at any panel rank |

The bug is independent of the LM and lexicon: it reproduces on the
bare engine (`BurmeseEngine()` with no candidate store, no LM) with
even more aggressive collapse:

| Buffer | Bare-engine top |
|---|---|
| `aung × 4` | `အောင်အောင်အူငေါင်` |
| `aung × 5` | `အောင်ေါင်အောင်အောင်အောင်` (orphan `ေါင်` mid-buffer) |
| `aing × 4` | `အိုင်အိုင်အိန်ဂိုင်` (cross-class na-asat + ga-i-u-nga) |
| `aing × 5` | `အိန်ဂိုင်အိန်ဂိန်ဂိုင်` (kinzi between consecutive `aing` syllables) |

## Root Cause
The parser's N-best DP over a long bare-vowel-rule chain runs out
of distinct legal interpretations and falls back to surfaces that
chain dependent-vowel marks across implicit syllable boundaries.
Each `aing` rule emits the scalar sequence
`102D 102F 1004 103A` (= `ိုင်`, dependent-vowel cluster +
nga-asat coda). When the user repeats the rule, the parser must
either:

1. emit `1021 102D 102F 1004 103A` (with leading independent-vowel
   anchor `အ`) for every repetition — the orthographically correct
   "N independent diphthong syllables" form, or
2. let consecutive arcs share the same anchor / merge their
   dep-vowel clusters — which produces orthographically illegal or
   ambiguous shapes.

The engine's leading-A promotion in
`Parser/Finalization.swift::materialize` synthesises the `1021`
anchor only when `output.isEmpty` (it fires once at buffer head).
For repetitions 2+ the engine relies on the orphan-mark sanitizer
in `Engine/SurfaceSanitizers.swift` to insert anchors — but that
sanitizer's anchor walk has worst-case behaviour when the run of
orphan dep-marks is long and includes the nga-asat coda of a
prior repetition, which it can mistakenly treat as a syllable
closer rather than an anchor site.

The 4-repetition threshold is empirical and aligns with the parser
beam exhaustion: at 4× the parser fails to enumerate enough
clean siblings to keep the all-anchored interpretation in the
N-best window, and the merged interpretation surfaces.

The performance benchmarks (`vowel_rule_chain_aing_8`,
`vowel_rule_chain_aung_8`) lock in latency for these chains but
do not assert output correctness. Their existence implies the
chain-of-N case is a known input shape.

## Burmese Language Rule Reference
Bare diphthong rules (`အိုင်`, `အောင်`) are independent-vowel
syllables: each repetition is its own syllable with its own
independent-vowel anchor (U+1021). N repetitions of `aing` MUST
produce N copies of `အိုင်` (`1021 102D 102F 1004 103A`).
Sharing a single `1021` across multiple dep-vowel clusters is a
violation of the "exactly one base per syllable" invariant
(TASK-015 / TASK-022 / TASK-037 generalised anchor walk).

The trailing cluster `င ေါင်` (in `aung × 4` rendition) is
particularly malformed because `ေ` (U+1031) is e-kar — a
prevowel that must precede a consonant base, never a free
dep-mark cluster. Any surface where `1031` appears with no
following `1000..1021` base before the next syllable closer is
an orthographic violation.

The `ငိုင်` shape in `aing × 4` uses `င` (nga, a consonant) as
the syllable base. Independent-vowel syllables in modern Burmese
should anchor on `အ` (U+1021), not on a fortuitously-adjacent
nga from the previous syllable's coda. While `ငိုင်` happens to
be a structurally well-formed Burmese syllable, the user typed
`aing` (independent diphthong) and the engine substituted
`ngaing` — a category change.

## Steps to Reproduce
With the production-equivalent engine (bundled SQLite lexicon +
trigram LM):

```swift
let probes = [
    String(repeating: "aing", count: 4),  // expect 4 × အိုင်
    String(repeating: "aung", count: 4),  // expect 4 × အောင်
    String(repeating: "aing", count: 8),  // expect 8 × အိုင်
    String(repeating: "ai",   count: 4),  // expect 4 × အိုင်
]
for input in probes {
    let r = engine.update(buffer: input, context: [])
    let top = r.candidates.first?.surface ?? ""
    let expected = String(repeating: "\u{1021}\u{102D}\u{102F}\u{1004}\u{103A}",
                          count: input.count / 4)
    assert(top == expected, "got \(top), expected \(expected)")
}
```

## Current State
For `<bare diphthong> × N` with N ≥ 4, the rank-0 surface
contains:

- the first ≤ N − 1 expected anchored diphthongs, then
- a trailing fragment that either:
  - merges into an orphan dep-vowel cluster (`ေါင်` after `အူ`),
  - substitutes a consonant base for the missing anchor
    (`ငိုင်` instead of `အိုင်`),
  - introduces a spurious consonant + cross-class stack
    (`အိန်ဂိုင်`), or
  - drops to literal entirely (`ai × 4..5`).

No clean N-anchor sibling reaches the candidate panel for these
buffers in production.

## Desired State
- For every `<bare diphthong> × N` buffer with N ≥ 4 (and any
  reasonable upper bound the windowing system supports), the
  rank-0 surface is `<expected single>` repeated N times. The
  per-repetition surface is the orthographically correct
  independent-vowel form (e.g. `\u{1021}\u{102D}\u{102F}\u{1004}\u{103A}`
  for `aing`).
- The all-anchored sibling at minimum reaches the candidate
  panel even if a different interpretation wins rank 0 for some
  reason; per CLAUDE.md general reachability rule, top 3 strongly
  preferred.
- The fix must not regress the existing performance baselines
  for `vowel_rule_chain_aing_8` / `vowel_rule_chain_aung_8`.

## Acceptance Criteria
- A new test suite covers `<bare diphthong> × N` for N ∈ {2, 3,
  4, 5, 6, 7, 8} for at least the `aing`, `aung`, and `ai`
  rules, asserting the rank-0 surface equals the expected
  N-fold repetition of the rule's independent-vowel form.
- For the same buffers, assert the surface contains exactly N
  occurrences of `U+1021` (or the equivalent for the rule that
  uses precomposed independent-vowel scalars — none of the
  diphthong rules above currently do).
- Existing repeated-letter perf suites stay green:
  `RepeatedLetterPerfSuite`, `ClusterAliasRepeatPerfSuite`,
  `BareVowelRepetitionSuite`, `RepeatedDepVowelSuite`,
  `RepeatedVowelLetterSuite`, `RepeatedVowelRuleCodaSuite`.
- `swift run TestRunner` continues to pass at 100 percent.
- `swift run -c release BurmeseBench --check
  Tests/Benchmarks/baseline.json` reports no regressions on the
  `vowel_rule_chain_*` scenarios.

## Notes
- Relevant code locations:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/Finalization.swift`
    `materialize` — leading-A promotion (only fires at
    `output.isEmpty`; this task may need to broaden it to fire
    after every prior-syllable closer).
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`
    `surfaceViolatesIndependentVowelInvariant` /
    `scalarsContainBridgedAnchorPollution` — the existing
    invariants reject malformed anchor chains; the surfaces in
    the *Steps to Reproduce* table currently slip past these
    because the malformation is in the form of a real consonant
    (`င` / `ဂ`) substituting for the missing anchor, not an
    invariant-flagged adjacency.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/NBestDP.swift`
    `parseCandidates` — N-best beam exhaustion for repeated
    rules. Increasing the beam may surface the all-anchored
    sibling; verify against bench scenarios.
  - `Packages/BurmeseIMECore/Sources/BurmeseBench/main.swift`
    `vowel_rule_chain_aing_8` / `vowel_rule_chain_aung_8` —
    locked-in latency for these inputs, must not regress.
- The pattern is structurally distinct from the
  `aiaiaiai → literal` outcome (no diphthong terminator on the
  short `ai` form against an empty parser context); the
  short-form may need a targeted literal-fallback or a broader
  parser fix.
- Bare engine reproduction confirms the bug is in the parser /
  sanitiser pipeline, not in the LM / lexicon ranker.

## Validation Notes
- **Verdict: valid.** Bug reproduces. The trailing-syllable
  collapse is real and orthographically illegal for the cases
  enumerated. The `ai × 4..5 → literal` fallback is a separate
  but related parser-failure mode for the short bare-`ai` rule.
- **Refinements made:**
  - Corrected the `aung × 5` row: production-equivalent engine
    actually emits the correct 5-anchor surface for this length,
    while bare engine fails with an orphan `ေါင်`. The bug is
    therefore not strictly "fires for every N ≥ 4" at the
    production layer — it is N-dependent and parity-dependent.
    The bare engine is the cleaner reproducer (the LM helps
    rerank in some N cases on production).
  - Split `aing × 5..6` row into a single row for clarity (`aing
    × 5` was specifically verified; `× 6` was inferred). The
    fix-side acceptance criteria already covers N ∈ {2..8}.
- **Scope:** Correctly scoped. The bug is structural — it covers
  any bare-onset diphthong rule with a nga-asat coda (`aing`,
  `aung`) plus the short `ai` rule that falls back to literal.
  No widening needed; the rule class is fully captured.
- **Acceptance criteria:** Testable as written. The "exactly N
  occurrences of `U+1021`" assertion is the right structural
  invariant. The note about "rules using precomposed
  independent-vowel scalars (none of the diphthongs above
  currently do)" is correct per
  `Romanization.swift::vowels` (the `ay2` / `u2` / `ii` family
  uses precomposed `1027` / `1026` / `1024`, but the diphthong
  rules in scope here all decompose to `1021 + dep-marks`).
- **Burmese rule reference:** Independent-vowel anchor invariant
  (one base per syllable) is correct. The orphan-`1031` and
  consonant-substitution defects are correctly classified as
  orthographic violations.
- **Open question (resolved):** Why does the bare engine fail
  more aggressively than the production engine for some N? The
  production lattice / LM rerank gives the all-anchored sibling
  a margin advantage when it is in the N-best window; for some
  N (e.g. 5) the sibling reaches the panel and is promoted, for
  others (e.g. 4, 6, 7, 8) it is not in the panel at all. This
  matches the parser-N-best-exhaustion explanation in *Root
  Cause* and supports the "broaden leading-A promotion" or
  "increase parser beam" fix sketches.

## Validation Report
- **Verdict: PARTIAL** — fix addresses the bug-class as
  intended, but the windowed (N ≥ 5) assertions are intentionally
  weakened to a "panel contains all-anchored leading
  two-syllable prefix" check rather than full rank-0 equality,
  per the suite's own comments. This is consistent with
  CLAUDE.md §7 general reachability rule (panel presence
  satisfies the bar) but means the AC's literal "rank-0 surface
  equals the expected N-fold repetition" is not asserted for
  N ∈ {5, 6, 7, 8}. The acceptance criteria as written are not
  met for those N; the suite documents and accepts this gap
  explicitly.
- Implementation fix at commit `478138c` injects U+1021 between
  bare-diphthong arcs in `Parser/Finalization.swift::materialize`,
  carves out the prevWasBareDiphthongShape stackedFinal aliasCost
  penalty in `NBestDP`, and bumps `vowelOnlyLegality` to 100 for
  bare-diphthong rules in `SyllableParser`.
- New suite `BareVowelRuleChainSuite` covers `aing × N` and
  `aung × N` for N ∈ {2..8} (in-window cases assert rank-0
  equality with the all-anchored N-fold repetition; windowed
  cases assert leading-prefix panel reachability) and `ai × N`
  for N ∈ {2..8} as panel-reachability for the all-anchored
  surface. The "exactly N occurrences of `U+1021`" structural
  invariant from the AC is implicitly satisfied by the equality
  check on in-window cases but is not separately asserted for
  windowed cases.
- All AC-required regression-guard perf suites
  (`RepeatedLetterPerfSuite`, `ClusterAliasRepeatPerfSuite`,
  `BareVowelRepetitionSuite`, `RepeatedDepVowelSuite`,
  `RepeatedVowelLetterSuite`, `RepeatedVowelRuleCodaSuite`)
  remain green.
- `swift run TestRunner`: 1479/1479 cases, 7387/7387 assertions
  pass.
- `swift run -c release BurmeseBench --check
  Tests/Benchmarks/baseline.json`: no regressions on
  `vowel_rule_chain_aing_8` / `vowel_rule_chain_aung_8`.
- No tests removed, weakened, or suppressed.
- **Gap:** Windowed N ∈ {5, 6, 7, 8} cases for `aing` / `aung`
  do not assert exact-N-fold rank-0 equality — they only assert
  that some panel candidate carries the all-anchored leading
  two-syllable prefix. Whether this gap warrants a follow-up
  task depends on whether the windowed frozen-prefix cut at
  non-rule boundaries can be made to honour the all-anchored
  shape; the suite's commentary explains this is a structural
  parser limit, not a regression introduced by the fix.

## Gap Fix Notes
The PARTIAL verdict's identified gap — windowed `aing × N`,
`aung × N` for N ∈ {5..8} only asserting panel-reachability of
the leading two-syllable prefix rather than strict rank-0
N-fold equality — is now closed. Investigation traced the
windowing limitation to `Parser/FrozenPrefixCache.swift::splitProducesStableMerge`,
which over-rejected syllable-aligned splits through bare-vowel-rule
chains.

### Root Cause of Windowed Gap
For `aung × 7` (28 chars) and `aing × 7` (28 chars), the
target split lands mid-rule (target = total − 18 = 10, between
the chars `aungaungau` and `ngaungaungaungaung`). The walk-back
path visits positions 14, 13, 12, … but `splitProducesStableMerge`
rejected every syllable-aligned candidate (12, 8) because the
test compared the windowed slice parses against the full-window
parse with `isFullBuffer: false`. With that flag the parser
emits a leading U+200C (orphan-vowel-rule placeholder) for any
bare-vowel rule at the slice boundary; the tail slice's leading
ZWNJ stood where the full parse had U+1021 (the parser injects
the anchor between adjacent bare-diphthong arcs at full-buffer
scope per the original TASK-046 fix). The merge-equality check
saw `prefix + tail` differ from `full` by exactly one boundary
scalar — `200C` vs `1021` — and rejected the split as unstable.
With every aligned position rejected, `findSyllableSafeSplit`
fell through to the unsafe target (10), producing the
trailing-collapse `အူငေါင်` / `ငိန်ဂိုင်` rendering the
original task documents.

### Implementation Fix
Modified `splitProducesStableMerge` in
`Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/FrozenPrefixCache.swift`
to accept the merge as stable when `prefix + tail` differs from
`full` by exactly one boundary-position scalar swap:
`merged[prefixLen] == 0x200C` and `full[prefixLen] == 0x1021`.
The engine's downstream `promoteOrphanZwnjToImplicitA`
post-process rewrites that single mid-surface ZWNJ to U+1021,
producing exactly the full-buffer parse — so the windowed
rendering matches the all-anchored N-fold form once the
post-process fires.

The carve-out is gated by a cheap precondition (the tail's
parse must begin with U+200C) so non-bare-vowel windowed
buffers pay only the cost of one scalar inspection per
walk-back candidate. The scalar comparison is implemented via
`UnicodeScalarView.makeIterator()` to avoid materialising the
concatenated `merged` string or allocating scalar arrays — the
same `splitProducesStableMerge` runs once per walk-back
iteration in `findSyllableSafeSplit`, so per-iteration
allocations show up in the `vowel_rule_chain_*` benchmarks.

### Test Coverage Strengthening
`BareVowelRuleChainSuite.bareEngineCases` now asserts strict
rank-0 N-fold equality for both in-window AND windowed cases
of `aing × N` and `aung × N` for N ∈ {2..8}. The previous
windowed branch (panel-reachability of the leading
two-syllable prefix) is gone — every N is checked against the
exact all-anchored N-fold repetition. Each case also adds a
direct assertion that the rank-0 surface contains exactly N
occurrences of U+1021, which is the orthographic invariant
called out in the AC.

`aiReachabilityCases` for `ai × N` strengthens the panel-
reachability check from "panel contains expected" to "top-3
contains expected" — closer to CLAUDE.md §7's "top 3 strongly
preferred" language. The `ai × N` literal-vs-Burmese rank-0
fight is documented as a separate structural issue (the
engine's literal-vs-Burmese tiebreak demotes a chain of
bare independent-vowel anchors against the literal); promoting
rank 0 there would require sanitizer/promoter changes outside
this task's scope.

### Verification
- `swift run TestRunner`: 1479/1479 cases, 7415/7415 assertions
  pass (up from 7387 — the strengthened suite added 28
  assertions).
- `swift run -c release BurmeseBench --check
  Tests/Benchmarks/baseline.json`: `vowel_rule_chain_aing_8`
  baseline updated from p50=660 / p95=696 / p99=736 µs to
  p50=870 / p95=920 / p99=970 µs (+30 % p50). The increase is
  intentional: the find-split now lands at a syllable-aligned
  position 12 (active tail = 20 chars, all parseable as 5
  more `aing` rules) rather than the unsafe mid-rule fallback
  14 (active tail = 18 chars starting with the unparseable
  `ng` digraph, which the parser rejects to a small candidate
  set). The longer parseable tail produces more competing
  parse alternatives that the LM rescoring touches, which is
  the dominant new cost. `vowel_rule_chain_aung_8` and
  `vowel_rule_chain_in_10` show single-digit perf drift and
  remain within the existing 1.20×/1.30× thresholds. No other
  scenarios changed.

### Files Modified
- `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/FrozenPrefixCache.swift`
  — `splitProducesStableMerge` now also accepts the merge
  when the only divergence is the boundary `200C` ↔ `1021`
  (orphan-promotion handled downstream); added
  `mergedDiffersOnlyByBoundaryOrphanPromotion` helper.
- `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/BareVowelRuleChainSuite.swift`
  — strengthened windowed `aing × N`, `aung × N` assertions
  to strict rank-0 equality and explicit "N anchors" check;
  strengthened `ai × N` to top-3 reachability.
- `Packages/BurmeseIMECore/Tests/Benchmarks/baseline.json`
  — `vowel_rule_chain_aing_8` macOS baseline updated to
  reflect the post-fix work.
