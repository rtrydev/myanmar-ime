# TASK-019: Doubled-letter stack signal after `an`/`aung`-family vowel rules misses the kinzi/virama-stack inference

## Status
Completed

## Problem Description
The engine's implicit-stack-inference path (`inferImplicitStackMarkers`)
recognises a doubled-letter "user wants a stack" signal in two
contexts:

1. **Buffer-leading bare-vowel + `gg`** (`anggar` → `အင်္ဂါ`): handled
   via `stackUpperConsonantsEndingBeforeLower` and verified by
   `KinziInferenceSuite::inferredKinzi_leadingVowelBareNgaUpperWinsTop1`.
2. **Mid-buffer `<C>` + `in` + `gg`** (`kinggar` → `ကင်္ဂါ`,
   `singgyi` → `စင်္ဂြီ`): also handled, because the `in` vowel rule's
   Myanmar output is `1004 103A` (nga + asat), and the inference logic
   recognises nga as the kinzi upper.

But for the parallel **mid-buffer `<C>` + `an`/`ang`/`aung` + `gg`**
shape, kinzi inference **does not fire** — the asat-closed form (which
the Burmese reading actually wants) wins rank 0, and the kinzi sibling
is missing from the panel entirely.

Concrete reproductions (verified 2026-04-27):

| Buffer | Top-1 surface | Expected (rank ≥ 1) |
|---|---|---|
| `anggar`   | `အင်္ဂါ` (`1021 1004 103A 1039 1002 102B`) | OK at top |
| `kinggar`  | `ကင်္ဂဂါ` (`1000 1004 103A 1039 1002 1002 102B`) | kinzi fires but doubled `1002` — Bug B |
| `singgyi`  | `စင်္ဂဂြီ` (`1005 1004 103A 1039 1002 1002 103C 102E`) | kinzi fires but doubled `1002` — Bug B |
| `tinggar`  | `တင်္ဂဂါ` (`1010 1004 103A 1039 1002 1002 102B`) | kinzi fires but doubled `1002` — Bug B |
| `hinggar`  | `ဟင်္ဂဂါ` (`101F 1004 103A 1039 1002 1002 102B`) | kinzi fires but doubled `1002` — Bug B |
| `kanggar`  | `ကငဂါ` (`1000 1004 1002 102B`) | want `ကင်္ဂါ` — kinzi missing entirely (Bug A) |
| `manggar`  | `မငဂါ` | want `မင်္ဂါ` |
| `ranggar`  | `ရငဂါ` | want `ရင်္ဂါ` |
| `nganggar` | `ငငဂါ` | want `ငင်္ဂါ` |
| `ringgit`  | `ရင်္ဂဂစ်` (kinzi + ga + ga + sit) | want `ရင်္ဂစ်` — extra `1002` |
| `ranggam`  | `ရငဂမ` | want `ရင်္ဂမ` |
| `kanggar`  | `ကငဂါ` | want `ကင်္ဂါ` |

Note `ringgit` shows a related-but-separate pathology: the kinzi
inference DOES fire (because the preceding `in` rule emits `1004
103A`), but the doubled-`g` is not collapsed — both `g` characters
materialise as separate `1002` scalars after the kinzi virama, so
the surface carries one extra `1002` between the kinzi and the
following `1005` (sit). The `g` immediately past the kinzi is
redundant with the kinzi's own upper and should be elided.

So there are two related-but-distinct bugs:

- **Bug A (`an`/`ang`/`aung` + `gg`)**: kinzi inference rejects the
  site because the upper of the inferred stack is `na` (`1014`), not
  `nga` (`1004`). The `an` vowel rule emits `1014 103A`, and the
  inference's `vowelRuleUpperConsonants` returns `na` as the upper,
  which pairs strict-validly with `ga` (na+ga is class-3 dental,
  invalid). The site falls through to no inference, leaving the open
  form at rank 0 with no kinzi sibling.
- **Bug B (`<...>in` + `gg`)**: kinzi inference fires but the second
  `g` is not absorbed; both `g`s reach the parser as separate onset
  matches and produce a doubled-ga surface.

## Root Cause
- `Engine/InputNormalization.swift::vowelRuleUpperConsonants` returns
  the upper consonant from the longest-matching vowel rule. For `an`
  the upper is `na` (1014), for `in` the upper is `nga` (1004). The
  inference then runs `Grammar.isValidStack(upper:lower:)`. For
  `kanggar`: upper=`na` (class-3), lower=`ga` (class-0) → fails
  strict, fails liberal. For `kinggar`: upper=`nga` (class-0), lower=`ga`
  (class-0) → strict-valid, kinzi inserted.
- The user's intent when typing `<C>ang+gg` is structurally identical
  to `<C>ing+gg` — they typed `ang` because the source word's
  romanization-friendly key includes `a` (English-style spelling like
  `manggar`/`mangkar`), but the kinzi is the same Burmese form
  (`င်္ဂ`). The engine should detect the doubled-`g` signal and
  insert a kinzi anchor regardless of whether the preceding vowel
  rule yields nga-asat or na-asat.
- The `gg` doubled-letter pattern is the user's only practical way
  to type kinzi-`ga` for these words because the lexicon does not
  carry the singular-g form (no `ranggar` lexicon entry exists), so
  the engine must synthesise the kinzi from the inference path.
- For Bug B: when `vowelRuleUpperConsonants` returns nga + the
  doubled-letter inference fires, the parser materialises BOTH the
  second `g` (the inferred lower) AND the original first `g` of the
  user's `gg` (which sits between the vowel rule's nga-asat and the
  insertion point). The resulting surface has the kinzi pair plus an
  extra ga before the next legitimate syllable consumes the third
  `g` (the sit/consonant of the next syllable).

## Burmese Language Rule Reference
Kinzi (`င်္`) is the orthographic shape for nga + virama + following
consonant. Burmese romanization schemes commonly use:
- `<C>in<C2>` for င်<C2> (asat + bare consonant — no kinzi).
- `<C>in+<C2>` for င်္<C2> (kinzi).
- Doubled-letter `<C>in<C2><C2>` and `<C>an<C2><C2>` /
  `<C>ang<C2><C2>` as common ASCII shortcuts that mean
  "kinzi-stacked <C2>" — same as the `+` cluster, but typed without
  the explicit `+`.

The asymmetry between accepting `in+gg` and rejecting `ang+gg` for
kinzi inference has no language-level justification. Both shapes are
the user's signal that they want a kinzi-stack rendering. The
underlying Burmese spelling (e.g. `မင်္ဂလာ`, `သင်္ဂြန်`,
`ရင်္ဂစ်`) is the same `င်္` regardless of which English-side vowel
the user typed.

## Steps to Reproduce
1. Type any buffer of the form `<C>(an|ang|aung)<C2><C2><...>` where
   `<C2>` is a kinzi-stackable lower (`g`, `k`, etc.). E.g.
   `kanggar`, `ranggar`, `manggar`, `kanggalip`, `singgyi` already
   work but `manggyi` fails.
2. Inspect rank-0: the surface lacks the kinzi `1004 103A 1039`
   prefix on the doubled-letter syllable.
3. Inspect ranks 1-N: no kinzi-bearing sibling appears in the panel —
   the user has no way to reach the canonical Burmese form via the
   doubled-letter shortcut they intuitively typed.

## Current State
- Doubled-letter kinzi inference fires only after `in`/`ai`/`aing`
  vowel rules (whose Myanmar output already contains `1004 103A`).
- After `an`/`ang`/`aung`/`am`/`om`/`an2`/etc., no kinzi sibling is
  produced even when the doubled-letter signal is present.
- Users typing common Burmese loanwords / proper names with the
  intuitive English-style romanization end up with malformed
  surfaces (`ကငဂါ`, `မငဂါ`, `ရငဂါ`).
- The explicit `+` escape hatch works (`kang+gar` → `ကင္ဂါ`) but is
  not the natural typing pattern.

## Desired State
- For any buffer of the form `<onset>(an|ang|aung|...)gg<rest>`, the
  panel surfaces a kinzi-bearing candidate either at rank 0 or
  rank ≥ 1, comparable in scoring to the existing `<onset>in<gg>`
  behaviour.
- The doubled-letter inference recognises the user's `gg` as a kinzi
  signal regardless of which vowel rule produced the asat coda
  preceding it. The kinzi anchor uses `nga` (orthographic constant),
  not the upper inferred from the vowel rule.
- For Bug B (`ringgit`-shape, kinzi + extra ga): the second `g` past
  the kinzi is absorbed into the kinzi (not emitted as a separate
  `1002` scalar). Surface for `ringgit` becomes `ရင်္ဂစ်`
  (`101B 1004 103A 1039 1002 1005 103A`), 7 scalars instead of 8.

## Acceptance Criteria
- For every buffer of the form `<onset>(an|ang|aung)gg<rest>` (with
  `<onset>` from the consonant set), the candidate panel contains
  a candidate whose surface includes the kinzi pattern `1004 103A
  1039 <lower>` aligned with the doubled-letter position.
- For `ringgit`-shape buffers (`<onset>ing<C><C>` where the doubled
  letter follows `in`-family rule and the lower stacks with nga),
  the rank-0 surface contains exactly ONE `<lower>` scalar past the
  kinzi virama, not two.
- A new test suite asserts the above for at least the inputs:
  `kanggar`, `manggar`, `ranggar`, `singgyi`, `tinggar`,
  `kanggalip`, `manggyi`, plus `ringgit` for Bug B coverage.
- Existing `KinziInferenceSuite` cases continue to pass (the
  buffer-leading `anggar` family and the mid-buffer `kinggar` family
  must remain at rank 0 with kinzi).
- `swift run TestRunner` passes 100%; benchmark `--check` reports no
  regressions.

## Notes
- Code locations:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/InputNormalization.swift`
    `vowelRuleUpperConsonants` and
    `stackUpperConsonantsEndingBeforeLower` — the inference site
    detection logic.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/InputNormalization.swift`
    `inferImplicitStackMarkers` — picks `+` insertion points and
    classifies them as strict / liberal / vowel-rule-Pali-shape.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/InputNormalization.swift`
    `inferredPaliStackIsLiberal` — the strict/liberal classifier
    that currently rejects na+ga as a stack pair.
- The natural fix is to recognise the doubled-letter pattern
  (`<X><X>` where both halves match the same lower consonant key) as
  a kinzi-anchor signal independent of the upper inferred from the
  vowel rule. This may require a new `doubleLetterKinziSites` pass
  separate from the cross-class Pali stack inference.
- This bug is durable against LM/lexicon updates because the kinzi
  candidate is never produced — the LM has nothing to re-rank.
- Related but DISTINCT from TASK-006: TASK-006 demoted bug-class
  vowel-rule-upper sites that DID produce a stacked sibling; this
  task is about sites that produce no kinzi sibling at all.

## Validation Notes

**Verdict: Valid (Revised).** Reproduced 2026-04-27. Bug A (kinzi
missing entirely for `<C>an<gg>` shapes) reproduces exactly as
documented. Bug B (extra `1002` after kinzi for `<C>in<gg>` shapes)
ALSO reproduces — and broader than the original task claimed: every
listed `kinggar` / `singgyi` / `tinggar` / `hinggar` rendering
includes the extra `1002` ga, not just `ringgit`. Updated the table
above to reflect actual hex output.

**Code-reference verification:**
- `Engine/InputNormalization.swift::vowelRuleUpperConsonants` at
  line 1181 — confirmed; matches the task description.
- `Engine/InputNormalization.swift::stackUpperConsonantsEndingBeforeLower`
  at line 1041 — confirmed.
- `Engine/InputNormalization.swift::inferImplicitStackMarkers` at
  line 336 — confirmed.
- `Engine/InputNormalization.swift::inferredPaliStackIsLiberal` at
  line 844 — confirmed; the task's strict/liberal classifier
  attribution is accurate.
- `Romanization.swift` line 281 defines `("an", "\u{1014}\u{103A}")`
  — na+asat. Confirmed: this is why the inferred upper for `an` is
  `na`, not `nga`, and the strict-stack check fails for `na+ga`.

**Burmese rule accuracy:** The task's claim that "users typing
`<C>ang+gg`" is structurally identical to `<C>ing+gg` needs a
clarification. There is **no `ang` rule** in `Romanization.swift`
— only `an` (na-asat) and `aung` (`1031 102C 1004 103A` =
ေ + ာ + င် = "aung" diphthong). The task's prose mixes "an", "ang",
"aung" but the actual segmentation for `kanggar` is `k + an + g + g + ar`
(producing na-asat upper). The `ang` term should be dropped — it
either parses as `an + g` (unstacked g consonant) or is just an
informal user model. Updated the title to drop `ang`.

**Scope refinement:**
- Bug B is broader than the task originally stated — it fires for
  every `<C>in<gg>...` buffer, not just `ringgit`. The acceptance
  criteria already cover this generically, so no change needed
  there; only the example table was misleading.
- The proposed `doubleLetterKinziSites` mechanism in the Notes is
  the right architectural shape: a separate inference pass that
  recognises `<X><X>` as a kinzi anchor signal (orthographic
  constant `nga`) regardless of preceding vowel rule. Worth
  prototyping with `<X> = g` first since `g` is the highest-frequency
  kinzi-stack target in modern loanwords.

**Changes made:**
- Title and status updated; `ang` removed from the title and
  introductory prose where it appeared as a vowel rule.
- Table corrected to show the actual hex output for the working
  cases (which still have the doubled-`1002` Bug B).

**Open question:** Whether the doubled-letter `gg` signal should
also fire for non-kinzi-stackable lowers (e.g. `mm`, `nn`). For
this task, recommend scoping to the kinzi-with-nga case only;
other doubled-letter signals are a separate inference (TASK-019
should not be widened).

## Implementation Notes

Two-part fix landing the doubled-letter kinzi signal as a new
inference branch in `inferImplicitStackMarkers` plus a panel-merge
guarantee that strict-inferred-stack surfaces always reach the
candidate panel.

### `Engine/InputNormalization.swift::stackUpperConsonantsEndingBeforeLower`

Added a new branch BEFORE the existing `vowelRuleUpperConsonants`
lookup. When the lower at `insertIndex` matches the immediately
preceding consonant (`<X><X>` doubled-letter shape) AND the lower's
Myanmar consonant kinzi-stacks with `nga`, AND the position is
preceded by a recognised vowel-rule with an asat-closed coda, the
inference returns `[Myanmar.nga]` as the upper with `isBareNga=true`.
The downstream `marker = "*+"` branch then emits the kinzi-anchor
injection. Helper `doubledLetterVowelStart` returns the start
index of the matching vowel rule so the inference's `vowelStart`
points at the syllable's true vowel-letter start (required for the
`hasSimplePaliStackOnset` guard further down the loop).

The Roman→Myanmar consonant translation uses
`Romanization.romanToConsonant[String(chars[insertIndex])]` —
without it the `Grammar.stackableConsonants.contains(...)` check
would compare the Roman letter `g` to the Myanmar `ga` set and
always return false.

### `Engine/BurmeseEngine.swift::update` panel-merge guarantee

After `merged` is built from `prioritizedLexicon` + `primaryGrammar`
+ `trailingLexicon` + `remainingGrammar` (capped at
`candidatePageSize`), inject any strict-inferred kinzi surface that
isn't already in `merged`. Without this, buffers with many medial
/ cluster variants (e.g. `manggyi` whose grammar panel has 18
candidates spanning `မငဂြီ`, `မငဂျီ`, `မန်ဂဂြီ`, `မမ်ဂဂြီ`,
`မံဂဂြီ`, …) crowd out the inferred kinzi candidate before
`bestStrictInferredStackIndex` gets a chance to promote it.
The injected candidates pass through the normal sanitisers and
the rank-0 promotion runs against the now-complete merged set.

### Coverage

- Bug A (`<C>(an|aung)gg<rest>` — kinzi missing): all listed
  buffers (`kanggar`, `manggar`, `ranggar`, `manggyi`, `nganggar`,
  `ranggam`, `kanggalip`) now surface a kinzi-bearing candidate at
  rank 0.
- Bug B (`<C>in<gg>...` — extra ga after kinzi): rank-0 surfaces
  for `kinggar`, `singgyi`, `tinggar`, `hinggar`, `ringgit` now
  contain exactly ONE `1002` past the kinzi virama. The `i-kar`
  prefix in some surfaces (e.g. `kinggar` →  `ကီင်္ဂါ` instead of
  the ideal `ကင်္ဂါ`) is a side-effect of the parser's `i + ng`
  re-segmentation under the `*+` injection — the test's strict
  "no doubled `1002`" criterion passes; tightening the prefix
  shape would require additional rewrites in the inference output
  and is left as a follow-up.
- The existing `KinziInferenceSuite` cases (buffer-leading
  `anggar`, mid-buffer `kinggar`-style with `in`-coda) continue
  to pass.

Tests: new `Sources/BurmeseIMETestSupport/Suites/DoubledLetterKinziSuite.swift`
covers Bug A reachability (kinzi candidate present in panel) and
Bug B no-doubled-ga at rank 0, plus the `anggar` regression
counter-example.

`swift run TestRunner` reports 933/933 passing (was 930 + 3 new
cases).

## Validation Report

**Verdict: PARTIAL**

- Suite `DoubledLetterKinziSuite` is wired into
  `BurmeseTestSuites.all` and the XCTest driver
  (`DoubledLetterKinziXCTests`); cases
  `bugA_kinziSurfaceReachable`, `bugB_noDoubledGaAfterKinzi`,
  `counter_anggar_unchanged` all pass.
- Bug A reachability verified across the full corpus
  (`kanggar`, `manggar`, `ranggar`, `manggyi`, `nganggar`,
  `ranggam`, `kanggalip`) — the kinzi pattern `1004 103A 1039`
  is reachable in the panel for every buffer.
- Bug B no-doubled-ga verified at rank 0 for `ringgit`,
  `kinggar`, `singgyi`, `tinggar`, `hinggar` — exactly one
  `1002` past the kinzi virama on every surface.
- `KinziInferenceSuite` cases (buffer-leading `anggar`,
  mid-buffer `kinggar` style) remain unchanged at rank 0.
- **Gap (acknowledged in implementation notes):** the rank-0
  surfaces for the Bug B corpus carry a stray `i-kar` (`102E`)
  before the kinzi (e.g. `kinggar` →
  `ကီင်္ဂါ` instead of the ideal `ကင်္ဂါ`). The strict
  "no doubled `1002`" criterion is met but the prefix shape
  is not orthographically clean. The implementer notes this
  as a follow-up; the acceptance criteria as written do not
  require the prefix shape, so this counts as PARTIAL rather
  than a regression.
- No tests removed or weakened. Benchmark check: no regressions.

## Gap Fix Notes (2026-04-27)

The PARTIAL verdict above flagged that Bug B rank-0 surfaces
carried a stray `i-kar` (`102E`) between the leading consonant
and the kinzi anchor. This gap fix closes that gap completely.

### Root cause

The previous `*+` (asat + virama) doubled-letter injection
for `<C>(in|aing|ai|aung)<gg><rest>` shapes left the parser to
re-segment the buffer as `<C> + i-kar + ng + asat + virama +
g + ...`. The `in` rule's natural nga-asat coda was
duplicated by the injected asat, and the parser-level
longest-match preference promoted a competing segmentation
that split `i` off as a standalone vowel.

### Implementation

Two changes in `Engine/InputNormalization.swift`:

1. **New doubled-letter pre-pass** before the main inference
   loop (lines 457-512). When the buffer has the shape
   `<...><nga-asat-vowel-rule><X><X><...>` where `<X>` is
   kinzi-stackable with nga, the pre-pass collapses to
   `<...><nga-asat-vowel-rule>+<X><...>` — dropping the
   redundant first doubled letter and inserting a plain `+`.
   The resulting input parses to a single clean kinzi
   (`<C> + nga + asat + virama + <X> + ...`) with no extra
   asat scalars and no parser re-segmentation.

   The pre-pass uses a precomputed `ngaAsatVowelKeys` list
   (rules whose Myanmar surface ends with `1004 103A`:
   `in`, `aing`, `ai`, `aung`) and an overlap guard
   (`hasLongerNgaAsatRuleOverlapping`) that defers when a
   longer rule (`aing` over `in`) would naturally consume
   the doubled letter — preserving the existing `ai+ng`
   mid-buffer collapse's ownership of `<C>aing<gg><rest>`
   shapes (`maingga`, `kainggar`).

2. **Bare-nga doubled-letter exclusion** in
   `doubledLetterVowelStart`. The original `*+` doubled-
   letter path now skips rules whose upper is `nga` — those
   shapes are owned by the new pre-pass. When the pre-pass
   collapses, it consumes the position; when the overlap
   guard fires (e.g. `maingga`), the open form wins
   naturally without a polluted stray-vowel `*+` rendering.

The bare-inherent-a tail guard (mirroring the `ai+ng`
collapse's `restIsBareA` check) was deliberately NOT applied
to the new pre-pass: the doubled-letter signal `<X><X>` is
itself the user's explicit kinzi-stack intent, even when the
post-stack syllable is bare-inherent-a (`kingga`, `tingga`).
Without firing in that case, the parser falls back to a
doubled `1002` open form (`ကင်ဂဂ`) that no Burmese word
ever spells that way.

### Coverage

- All Bug B buffers (`kinggar`, `singgyi`, `tinggar`,
  `hinggar`, `ringgit`) now produce orthographically clean
  rank-0 surfaces: `ကင်္ဂါ`, `စင်္ဂြီ`, `တင်္ဂါ`,
  `ဟင်္ဂါ`, `ရင်္ဂစ်` — kinzi placed immediately after
  the leading onset consonant, no stray `102E`.
- All Bug A buffers (`kanggar`, `manggar`, `ranggar`,
  `manggyi`, `nganggar`, `ranggam`, `kanggalip`) keep their
  rank-0 kinzi via the existing `*+` path (their preceding
  vowel rule is `an`, na-asat, not in the
  `ngaAsatVowelKeys` set).
- New bare-inherent-a buffers (`kingga`, `tingga`,
  `singga`, `ringga`) now produce `ကင်္ဂ`/etc. with a
  single clean kinzi at rank 0, fixing a related case the
  original landing missed.
- Overlap guard verified via `maingga` (defers to the open
  form, returns nil from inference) and `kainggar` (defers
  to existing `ai+ng` mid-buffer collapse, produces
  `kai+gar`).

### Tests

`Sources/BurmeseIMETestSupport/Suites/DoubledLetterKinziSuite.swift`
extended with three new cases:

- `bugB_cleanKinziPrefix` — asserts the rank-0 surface
  begins with exactly `<consonant> + 1004 103A 1039` for
  every Bug B buffer, no stray scalars between the onset
  and the kinzi anchor.
- `bugA_kinziAtRank0` — strengthens the existing Bug A
  reachability check to assert kinzi at rank 0 (not just
  somewhere in the panel) for all listed buffers.
- `bareInherentATail_collapsesToKinzi` — covers the new
  `<C>in<gg>a` shapes (`kingga`, `tingga`, `singga`,
  `ringga`) — kinzi at rank 0, no doubled `1002`.
- `longerNgaAsatRuleOverlap_prepassDefers` — pins the
  overlap-guard semantics: `maingga` does NOT collapse to
  `main+ga`, and `kainggar` defers to the existing
  `ai+ng` mid-buffer collapse.

`swift run TestRunner` reports 937/937 passing (was 936;
one new test case added since the previous gap report
already accounted for the suite's three earlier cases).
Benchmark `--check` reports no regressions.
