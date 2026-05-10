# TASK-048: Anusvara + asat (`1036 103A`) adjacency emitted in panel for `<C>an*` patterns

## Status
Completed

## Implementation Notes
Tightened the asat backward-walk in
`Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/Finalization.swift::scanOutputLegality`
so the skippable scalars between an asat and its consonant base
(`U+1036` anusvara, `U+103B..U+103E` medials) are admitted ONLY
when a vowel-bearing cluster (the `aw`-cluster `1031 (102B|102C)`)
was peeled first. The pre-fix walk treated anusvara as
unconditionally skippable, letting `<C> 1036 103A` slip through
the legality scan as a "valid single-syllable" parse. The new
`sawVowelCluster` gate rejects the bare `<C>1036 103A` adjacency
while preserving the legitimate `<C><medial>1031<102B|102C>103A`
shape (e.g. `kyaw*` → `1000 103B 1031 102C 103A`).

Added regression suite
`Sources/BurmeseIMETestSupport/Suites/AnusvaraPlusAsatRejectionSuite.swift`
covering: (a) panel-presence invariant for the full standard
consonant-onset cross-product with `an*`; (b) mid-buffer
occurrences (`ka+kan*`, `paksan*`, `kan*sa`, `kankan*`); (c)
direct legality-scan rejection of the `<C> 1036 103A` scalar
shape; (d) reachability of the clean `<C>န်` / `<C> 1014 103A`
sibling per acceptance criterion; (e) counter-examples that the
fix must NOT regress (anusvara without trailing asat, na-asat
without anusvara, creaky/visarga after anusvara).

Verified the fix is part of TASK-049's combined parser change —
both bug classes share the same backward-walk site, so the patch
addresses both with a single gate.

## Problem Description
When the user types `<C>an*` — a consonant followed by `n` (the
`an` family) followed by `*` (the explicit asat marker) — the
candidate panel emits a surface containing the scalar pair
`1036 103A` (anusvara immediately followed by asat). This
sequence is not legitimate Burmese orthography: anusvara `ံ`
(U+1036) is a final nasal vowel-mark and cannot carry an asat
closure.

The bug fires consistently at rank 0 for most consonant onsets;
for a small number of onsets a lexicon-backed `<C>န်` reading
(or compound surface) wins rank 0 by LM/lexicon score, but the
illegal `1036 103A` shape still appears in the panel at rank 1
or 2. Either way the candidate is structurally invalid Burmese
and should not surface at all.

Verified rank-0 surfaces (production-equivalent engine, bundled
lexicon + LM):

| Buffer    | Rank-0 surface | Hex                       | Verdict  |
|-----------|----------------|---------------------------|----------|
| `kan*`    | `ကံ်`         | `1000 1036 103A`         | bug at rank 0 |
| `khan*`   | `ခံ်`         | `1001 1036 103A`         | bug at rank 0 |
| `ngan*`   | `ငံ်`         | `1004 1036 103A`         | bug at rank 0 |
| `pan*`    | `ပံ်`         | `1015 1036 103A`         | bug at rank 0 |
| `phan*`   | `ဖံ်`         | `1016 1036 103A`         | bug at rank 0 |
| `ban*`    | `ဘံ်`         | `1018 1036 103A`         | bug at rank 0 |
| `man*`    | `မံ်`         | `1019 1036 103A`         | bug at rank 0 |
| `yan*`    | `ယံ်`         | `101A 1036 103A`         | bug at rank 0 |
| `lan*`    | `လံ်`         | `101C 1036 103A`         | bug at rank 0 |
| `than*`   | `သံ်`         | `101E 1036 103A`         | bug at rank 0 |
| `han*`    | `ဟံ်`         | `101F 1036 103A`         | bug at rank 0 |
| `san*`    | `စံ်`         | `1005 1036 103A`         | bug at rank 0 |
| `nan*`    | `နံ်`         | `1014 1036 103A`         | bug at rank 0 |
| `dan*`    | `ဒံ်`         | `1012 1036 103A`         | bug at rank 0 |
| `tan*`    | `တန်`         | `1010 1014 103A`         | clean rank 0; bug `တံ်` at rank 1 |

`tan*` and other consonants whose lexicon contains a strong
multi-syllable hit (`ban*` reaches `ဘဏ်များ` etc.) push the
illegal `<C>ံ်` form below rank 0 — but the malformed candidate
is still in the panel and reachable. The bug is therefore
"illegal candidate present at all", not "always at rank 0".

Mid-buffer impact (`ka+kan*`, `paksan*`, `kan*sa`) shows the
same malformed surface in the panel.

Scope: every consonant onset paired with `an*` produces the
illegal adjacency in the panel; rank-0 placement varies by
lexicon coverage but is the most common case.

## Root Cause
The `an3` vowel rule in `Romanization.swift` maps to U+1036 (anusvara,
`ံ`). When the engine encounters `<C>an*`, two candidate
interpretations exist:

1. `<C> + an + asat` — `1014 103A` na-asat for the `an` rule plus
   the explicit asat — but the user-typed `*` is redundant with
   the asat that the `an` rule already produces, so the candidate
   for the digit-stripped `an*` is degenerate.
2. `<C> + an3 + asat` — `1036` for the `an3` rule plus the
   explicit asat — producing `1036 103A`, which is structurally
   illegal.

Both shapes survive the parser's legality scan because there is no
sanitizer that rejects the `1036 103A` adjacency. The composite-
score ranker then promotes the (2) shape to rank 0 because the
explicit `*` keystroke matches the `an3 + *` segmentation more
cleanly (the `an` rule already includes asat, so the trailing `*`
would be a no-op there).

The sanitizer pipeline in `Engine/SurfaceSanitizers.swift` enforces
many "asat after incompatible dependent vowel" rejections, but
anusvara (`1036`) specifically is not flagged. The parser legality
scan in `Parser/Finalization.swift` does not treat `1036` as
a dep-vowel that blocks subsequent asat.

## Burmese Language Rule Reference
Anusvara `ံ` (U+1036) is a final nasal vowel mark in Burmese — it
represents the syllable-final /m/ nasal sound and forms a complete
syllable with the preceding consonant + inherent `a` (e.g. `ကံ`
"karma" = `1000 1036`). It is a *coda*, not a consonant that can
be closed with asat.

Asat `်` (U+103A) is the "vowel killer" that suppresses the
inherent vowel of the consonant it attaches to (e.g. `က် ` =
"k closure"). It is only meaningful attached to a base consonant
(U+1000..U+1021 / U+103F) or to a coda consonant character that
can act as a closure (e.g. `1014 103A` na-asat = `န်`).

Per CLAUDE.md §1: "asat after tone, after a digit, or after an
incompatible dependent vowel" must be rejected. Anusvara is a
dependent vowel/nasal mark, so `1036 103A` is exactly the
forbidden shape.

## Steps to Reproduce
1. Build the production-equivalent engine
   (`BurmeseEngine(candidateStore: SQLiteCandidateStore(...),
   languageModel: TrigramLanguageModel(...))`).
2. For each consonant in
   `["k", "kh", "g", "ng", "p", "ph", "b", "m", "y", "l",
     "th", "h", ...]`, evaluate
   `engine.update(buffer: "\(c)an*", context: [])`.
3. Inspect rank-0 candidate's `surface` for the adjacent scalar
   pair `1036 103A`.

Observed: the bulk of consonants produce the illegal adjacency at
rank 0; the clean `<C>န်` form sits at rank 1.

## Current State
- Rank-0 surface for `<C>an*` contains `1036 103A` (anusvara +
  asat) for the majority of consonant onsets.
- Users typing `kan*`, `pan*`, `man*`, `than*`, etc. see a
  structurally illegal Burmese spelling at the top of the panel.
- The rank-1 candidate is the correct `<C>န်` form, but the user
  must page past the bug shape to find it.

## Desired State
- For any buffer of shape `<C>an*` (or mid-buffer occurrence of
  `<C>an*` between Myanmar runs), the rank-0 surface must NOT
  contain the adjacency `1036 103A`.
- Acceptable rank-0 surfaces include:
  - `<C>န်` (`<C> 1014 103A`) — na-asat, the canonical reading
    for the `an*` shape;
  - any other legal Burmese closure that does not place asat
    after a dependent vowel mark.
- The rank-1 (or later) panel may still contain the explicit
  anusvara-bearing surface `<C>ံ` (`<C> 1036`, no asat), but
  the `1036 103A` adjacency must never appear in any candidate.

## Acceptance Criteria
- For every standard consonant onset
  (`k`, `kh`, `g`, `ng`, `s`, `hs`, `z`, `t`, `ht`, `d`, `dh`,
  `n`, `p`, `ph`, `b`, `bh`, `m`, `y`, `r`, `l`, `v`, `th`, `h`),
  `engine.update(buffer: "<C>an*", context: []).candidates`
  contains **no candidate** whose surface contains the
  two-scalar window `1036 103A`. The illegal shape is filtered
  from the panel entirely, not merely demoted.
- The same invariant holds for mid-buffer occurrences:
  `ka+kan*`, `paksan*`, `kan*sa`, `kankan*`.
- The clean `<C>န်` (`<C> 1014 103A`) surface remains reachable
  in the panel for every tested buffer.
- A new suite under
  `Sources/BurmeseIMETestSupport/Suites/AnusvaraPlusAsatRejectionSuite.swift`
  registers the invariant for the full consonant cross-product
  and at least one mid-buffer occurrence per consonant family.
- Existing suites (`AsatAfterDepVowelSuite`, `KinziInferenceSuite`,
  `MidBufferStackInferenceSuite`, `LangAnusvaraSuite`) continue
  to pass.

## Notes
- Suspect fix sites:
  - `Engine/SurfaceSanitizers.swift` — add a `1036 103A`
    adjacency rejection to the existing "asat after incompatible
    dep-vowel" sanitizer family.
  - `Parser/Finalization.swift` — extend the legality scan so
    parses that emit `1036 103A` adjacency score below the
    legality threshold.
  - `Engine/CandidateRanking.swift` — if the parser-level fix is
    not feasible, ensure the comparator demotes any candidate
    whose surface contains `1036 103A`.
- The bug class is anusvara-specific. Other dep-vowel + asat
  combinations (`102C 103A`, `102D 103A`, etc.) are already
  blocked by the existing sanitizer; only `1036 103A` slips
  through.
- The explicit `*` in user input is the trigger. Without `*`,
  `<C>an` produces the clean rank-0 reading. With `*`, the
  parser/ranker prefers the `an3 + *` segmentation over the
  `an + redundant *` segmentation, which surfaces the illegal
  shape.
- This is orthogonal to TASK-014/TASK-024 (literal-punctuation
  leak after bare-consonant-tone), TASK-041 (asat-after-vowel-
  rule absorption), and TASK-040 (tone+asat leak) — those tasks
  fix different sanitizer paths and do not address the
  anusvara+asat adjacency.

## Validation Notes
**Verdict: Valid (revised).** The bug class is real and
reproduces exactly as documented under the production-equivalent
engine.

Verification probe (BurmeseBench shim, bundled lexicon + LM):
- 14 of 15 probed consonant onsets emit `<C>ံ်`
  (`<C> 1036 103A`) at rank 0 with `<C>န်` available at rank 1.
- 1 onset (`tan*`) gets a clean lexicon-backed rank 0
  (`တန်` `1010 1014 103A`) but the illegal `တံ်` shape still
  surfaces at rank 1 — the malformed candidate is in the panel
  but not at the top.

Changes made:
- Reframed the title and Problem Description from
  "rank-0 only" to "panel presence" — the structural bug is
  emission of a candidate whose surface contains the `1036 103A`
  adjacency, regardless of where it sits in the panel order.
  This avoids a too-narrow fix that just demotes the illegal
  form by one slot via ranking tuning while still leaving it
  reachable.
- Replaced the "Should be (rank 1)" column with an explicit
  "Verdict" column that captures both the rank-0 cases and the
  `tan*`-style cases where a stronger lexicon hit takes rank 0
  but the bug shape still appears.
- Tightened the Acceptance Criteria: the test must assert
  **no candidate** in the returned list carries the `1036 103A`
  adjacency, not just the rank-0 candidate.
- Added `san*`, `nan*`, `dan*`, `tan*` rows from the verification
  probe to ground the test matrix in observed data.

Suspect-fix sites confirmed:
- `Engine/SurfaceSanitizers.swift` already defines a private
  `isDepVowelOrTone(_:)` helper that includes `0x1036`
  (around line 393) — extending the existing
  "asat after dep-vowel" sanitizer to also flag the
  `1036 103A` adjacency is the natural fix.
- The current sanitizers do not blanket-reject `1036 103A`;
  several existing rejections are anchor- or chain-shaped
  rather than scalar-pair-shaped.

Burmese rule reference confirmed: anusvara `ံ` is a final nasal
mark; placing asat directly after it is structurally illegal.
Per CLAUDE.md §1 ("asat after incompatible dependent vowel" must
be rejected), `1036 103A` is the canonical example of the
forbidden shape and is not currently caught.

No outstanding clarification questions.

## Validation Report
**Verdict: FULLY_COVERED.**

Build / suite status:
- `swift build` — clean (no warnings or errors).
- `swift run TestRunner` — 1488/1488 cases, 7757/7757 assertions pass
  (was 1355/1355 / 5721/5721 pre-Step3; net +133 cases / +2036
  assertions including this task's suite).
- `swift run -c release BurmeseBench --check Tests/Benchmarks/baseline.json`
  — "no regressions".

Acceptance criteria coverage:
- AC1 (no candidate carries `1036 103A` for the standard consonant
  cross-product) — covered by
  `AnusvaraPlusAsatRejectionSuite.noCandidateSurface_carriesAnusvaraPlusAsat`
  using 23 onset entries (full cross-product from the task table).
- AC2 (mid-buffer `ka+kan*`, `paksan*`, `kan*sa`, `kankan*`) — covered
  by `noCandidateSurface_carriesAnusvaraPlusAsat_midBuffer`.
- AC3 (clean `<C>န်` remains reachable) — covered by
  `naAsatSibling_remainsReachable` over 21 onset entries.
- AC4 (new suite at the documented path) — present and registered in
  `BurmeseTestSuites.all`.
- AC5 (no regression in `AsatAfterDepVowelSuite`, `KinziInferenceSuite`,
  `MidBufferStackInferenceSuite`, `LangAnusvaraSuite`) — full-suite
  pass confirms.

Production-equivalent validation (additional, beyond the bare-engine
suites):
- Probed via temporary BurmeseBench shim with `SQLiteCandidateStore` +
  `TrigramLanguageModel`. 0 leaks across all 19 buffer probes (15 from
  the original task table + 4 mid-buffer cases). The clean
  `<C>န်` (`<C> 1014 103A`) sibling sits at rank 0 for every probed
  consonant; e.g. `kan*` → `ကန်` `1000 1014 103A`, `tan*` → `တန်`
  `1010 1014 103A`. The previously-bug rank-1 shape `<C>ံ်` no longer
  appears anywhere in the panel.

Regression analysis (commit 7b18a65):
- `AsatAfterDepVowelSuite`'s `regressionGuards` lost `kya*` and `kw*`.
  Justified: those scalar shapes (`1000 103B 103A`, `1000 103D 103A`)
  are now correctly rejected per TASK-049 — they were previously
  asserted as legal but represent the bug class. Replacement
  assertions in the same suite (`kyan*`, `kwan*`) cover the
  legitimate shape, and `MedialPlusAsatRejectionSuite` now positively
  asserts the rejection.
- `RedundantExplicitAsatSuite`'s `kya*kar` counter-example expected
  output changed from `1000 103B 103A 1000 102C` to
  `1000 103B 1000 102C` (two-syllable, asat dropped). Justified: the
  pre-fix expectation embedded the bug; the new expectation matches
  the post-fix two-syllable parse where the redundant `*` is dropped
  because the malformed `<medial>103A` parse is no longer legal.
- No tests removed, suppressed, or weakened beyond these two
  intentional updates.

Repo cleanliness:
- `git status` — clean.
- No probe / scratch files inside the repo (probes live under `/tmp/`
  per CLAUDE.md guidance).
- No SourceKit-only false positives observed.

Gaps: none.
