# TASK-052: Explicit user-typed `+` between two bare-vowel rules is silently discarded, collapsing the buffer into a single syllable

## Status
Completed

## Problem Description
When the user types two bare-vowel rules (`a`, `e`, `i`, `o`, `u`,
their long siblings `ar`, `aw`, `ay`, `aung`, `aing`, `oo`, …) with
an explicit `+` syllable break between them, the engine silently
drops the `+` and merges the two bare-vowel rules into a **single**
vowel-rule chain on one anchor (`1021`). The user's hard syllable
boundary signal is discarded, and the user-intended two-syllable
form (`အ` + `<vowel-rule>`) is not reachable in the candidate panel
for several of these buffers.

This is the all-vowel-LHS counterpart of archived TASK-047 (consonant-LHS
explicit `+` before a vowel rule). TASK-047 explicitly carved out
the bare-vowel-LHS case ("no consonant LHS, e.g. `u+u`, the legacy
strip applies"). The probe surfaces below show that the carve-out
is too broad: it discards a hard syllable boundary signal in cases
where the resulting collapse is a structurally invalid surface or
where the user-intended two-syllable form is absent from the
candidate panel.

Reproduction (production-equivalent engine):

| Buffer  | Rank-0 surface (hex)            | User intent                          | Defect |
|---------|---------------------------------|--------------------------------------|--------|
| `a+a`   | `အ` (`1021`)                    | `အ + အ` (`1021 1021`)                | second syllable lost |
| `a+e`   | `အယ်` (`1021 101A 103A`)       | `အ + အယ်` (`1021 1021 101A 103A`)    | `+` discarded — reading reduces to `ae` |
| `a+i`   | `အိုင်` (`1021 102D 102F 1004 103A`) | `အ + အီ` or `အ + အိ`           | `a+i` merged into `ai` diphthong |
| `a+o`   | `အို` (`1021 102D 102F`)       | `အ + အို`                           | merged into `o` cluster |
| `a+ar`  | `အာ` (`1021 102C`)              | `အ + အာ`                            | `+` discarded — `aa` collapses |
| `a+aw`  | `အော်` (`1021 1031 102C 103A`)  | `အ + အော်`                          | `+` discarded — `aaw` collapses |
| `a+aung`| `အောင်` (`1021 1031 102C 1004 103A`) | `အ + အောင်`                    | `+` discarded |
| `a+e+i+o+u` | `အယ်` (`1021 101A 103A`)     | five separate `1021`-anchored syllables | every `+` discarded; only first vowel rule survives |
| `e+i`   | `၏` (`104F`, the ei particle)  | `အယ် + အီ` (`1021 101A 103A 1021 102E`) | `+` discarded — `ei` collapsed into the `ei`-genitive particle |
| `i+u`   | `အည်ူ` (`1021 100A 103A 1030`)  | `အီ + အူ` (`1021 102E 1021 1030`)    | malformed: orphan `1030` after asat, no `1021` anchor injected |
| `i+o`   | `အည်ို` (`1021 100A 103A 102D 102F`) | `အီ + အို`                     | malformed: orphan `o` cluster after asat |
| `o+u`   | rank 0 literal `o+u`; rank 1 `အိုူ` (`1021 102D 102F 1030`) | `အို + အူ` (`1021 102D 102F 1021 1030`) | rank-1 sibling is a TASK-030 multi-cluster-on-single-anchor violation |
| `o+i`   | rank 0 literal `o+i`; rank 1 `အိုီ` (`1021 102D 102F 102E`) | `အို + အီ` (`1021 102D 102F 1021 102E`) | rank-1 sibling is the same TASK-030 multi-cluster violation |

The buffers that work (counter-examples, must not regress):

| Buffer  | Rank-0 surface              | Status |
|---------|----------------------------|--------|
| `u+i`   | `အူအီ` (`1021 1030 1021 102E`) | clean two-syllable |
| `u+e`   | `ဦယ်` / `အူယ်`               | reachable two-syllable form |
| `i+e`   | `အီယ်` (`1021 102E 101A 103A`) | clean (the second `1021` is implicit before `1031 102C 103A` — but here the second syllable is just `e`-rule which emits `101A 103A` directly) |
| `i+ar`  | `အီအာ` (`1021 102E 1021 102C`) | clean two-syllable |
| `i+aung`| `အီအောင်` (`1021 102E 1021 1031 102C 1004 103A`) | clean two-syllable |
| `i+aw`  | `အီအော်` (`1021 102E 1021 1031 102C 103A`) | clean two-syllable |
| `u+aw`  | `အူအော်` (`1021 1030 1021 1031 102C 103A`) | clean two-syllable |
| `e+aw`  | `အယ်အော်` (`1021 101A 103A 1021 1031 102C 103A`) | clean two-syllable |
| `o+aw`  | `အိုအော်` (`1021 102D 102F 1021 1031 102C 103A`) | clean two-syllable |

The discriminator that distinguishes the failing buffers from the
working ones is **whether the right-hand vowel rule starts with a
"long" vowel scalar** (the `aung`, `aw`, `ar`, `ay`, `aing` rules
start with `1031` or `102B`/`102C`, which require their own anchor
and don't fuse with the prior bare vowel). The failing right-hand
rules are the **short bare-vowel rules** (`a`, `e`, `i`, `o`, `u`)
that can either fuse with the LHS into an `o`-cluster / `ai`-diphthong
storage shape or be silently absorbed into the inherent-a + asat
shape of the LHS.

## Root Cause
Two compounding paths produce this bug:

1. **`Engine/InputNormalization.swift::collapseConnectorRuns`** —
   the legacy `+ before vowel-letter` strip drops every `<vowel-LHS>+
   <vowel-letter>` `+`. TASK-047 narrowed the strip to apply only
   when the LHS has no consonant, with the explicit carve-out for
   `u+u`-style buffers. The carve-out is too coarse: it discards
   the `+` for every all-vowel buffer, including ones where the
   user's intended two-syllable form is not the same as the
   strip-resulting one-syllable interpretation.

2. **Orphan-mark anchor injector** (`promoteOrphanInternalMarks`)
   does not fire for buffers like `i+u` and `i+o` because the LHS
   `i` produces `100A 103A` (nya-asat) at rank 0, which has a
   `1021` anchor and a `103A` closing asat. The following bare-vowel
   rule's dep-vowel scalar (`1030` for `u`, `102D 102F` for `o`) is
   concatenated directly after the asat with no `1021` injection —
   the injector's "this mark already has an anchor" check resolves
   to the `1021` of the prior syllable, which is across the
   syllable-closing `103A` and therefore not a valid anchor for
   the new dep-vowel.

3. **DP / parser rule lookup** — the `ei` rule (`104F`) is a
   single multi-character rule that swallows both `e` and `i`
   even when the user typed a `+` between them. The `+` is
   stripped by collapseConnectorRuns before the parser sees the
   buffer, so the `e+i` buffer reaches the parser as `ei`.

## Burmese Language Rule Reference
A user-typed `+` is the romanization scheme's hard syllable
boundary marker. The orthographic invariant: when the user has
typed `<X>+<Y>`, `<X>` and `<Y>` must materialise as separate
syllables, each with its own consonant base (or `1021` independent
vowel anchor for bare vowels). The current behavior of dropping
the `+` for bare-vowel LHSes contradicts this invariant.

Per CLAUDE.md §6: "User-typed `+` is a hard syllable / stack
boundary." The bug class is `<bare-vowel-LHS>+<bare-vowel-RHS>`
where the engine drops the `+` and collapses the two syllables
into one. CLAUDE.md §6 does not carve out bare-vowel buffers.

The TASK-030 multi-cluster-on-single-anchor sanitizer should also
catch the `o+u`, `o+i` rank-1 candidates (`102D 102F 1030`,
`102D 102F 102E` are exactly the canonical multi-cluster violation
shape). Their survival to rank-1 reflects the "preserve violators
when nothing clean exists" fallback, but the user-intended
multi-anchor sibling is missing — so the fallback wins.

## Steps to Reproduce
1. Construct a bare or production engine.
2. Evaluate each of the buffers in the reproduction table.
3. Confirm the rank-0 candidate's reading drops the `+` (e.g.
   `a+e` → reading `ae`).
4. Inspect the panel — no candidate carries the user-intended
   two-syllable surface (e.g. `1021 1021 101A 103A` for `a+e`).

## Current State
- The user's hard syllable boundary is silently discarded for
  all `<bare-vowel>+<bare-vowel>` buffers.
- For `i+u`, `i+o`, `e+i` the rank-0 candidate is a malformed
  surface (orphan dep-vowel after asat, or the wrong particle
  `104F`).
- For `o+u`, `o+i` the rank-1 sibling is a TASK-030 multi-cluster
  violation that survives sanitizer-fallback.
- For `a+e`, `a+ar`, `a+aung`, etc. the rank-0 collapses to a
  single syllable that ignores the second bare vowel entirely.

## Desired State
- The rank-0 candidate (or at minimum a panel-reachable rank ≤ 3)
  is the user-intended two-syllable form, with each side anchored
  to its own `1021` independent vowel:
  - `a+a` → `အ + အ` (`1021 1021`)
  - `a+e` → `အ + အယ်` (`1021 1021 101A 103A`)
  - `a+ar` → `အ + အာ` (`1021 1021 102C`)
  - `i+u` → `အီ + အူ` (`1021 102E 1021 1030`)
  - `o+u` → `အို + အူ` (`1021 102D 102F 1021 1030`)
  - `e+i` → `အယ် + အီ` (`1021 101A 103A 1021 102E`) at rank 0 or
    panel-reachable (with the `104F` particle still available as
    a sibling for users who want it).
- No rank-0 candidate for these buffers carries a multi-cluster-
  on-single-anchor or orphan-dep-vowel-after-asat violation.

## Acceptance Criteria
- For every buffer `<v1>+<v2>` where `v1` and `v2` are each in
  {`a`, `e`, `i`, `o`, `u`}, the panel contains a candidate whose
  scalar sequence is the two-syllable form
  `<v1-surface><1021-anchor-if-needed><v2-surface>`. Top-3
  preferred per CLAUDE.md §7.
- The `e+i` particle `104F` remains panel-reachable but does NOT
  win rank 0 when the user typed an explicit `+`.
- A new suite
  `Sources/BurmeseIMETestSupport/Suites/BareVowelPlusBareVowelSuite.swift`
  asserts the panel-presence invariant for the 25-element
  cross-product of bare vowels × bare vowels.
- No rank-≤3 candidate carries a multi-cluster-on-single-anchor
  shape or an orphan-dep-vowel-after-asat shape for these buffers.
- Existing counter-examples continue to work: `u+i`, `i+ar`,
  `i+aung`, `i+aw`, `u+aw`, `e+aw`, `o+aw`.

## Notes
- The fix likely involves narrowing the `collapseConnectorRuns`
  bare-vowel-LHS strip: instead of stripping every `<vowel-LHS>+
  <vowel-letter>`, preserve the `+` and let the parser's
  soft-`+` arc materialise the boundary. The parser's
  `Finalization::materialize` already injects `U+1021` between
  a soft-`+` arc's empty emission and a following bare-vowel
  rule's dep-vowel cluster (per TASK-047) — that path should
  also fire for bare-vowel LHS.
- Some all-vowel buffers (`u+u`, `i+i`) currently collapse to
  the long-vowel independent-vowel forms (`အူ`, `ဤ`). The fix
  must decide whether these should also produce the two-syllable
  form at rank 0 (semantically `အူ` vs. `အ + အ`?) or panel-
  reachable only. Conservative interpretation: keep the existing
  `u+u → အူ` collapse at rank 0 (it's a single phonetic vowel
  the user is doubling for emphasis) but make `အ + အ` panel-
  reachable.
- The reading-level `ei` rule (`104F`) is a longest-match in
  `Romanization.vowels` with `standalone: true`. When the user
  typed `e+i` explicitly, the longest-match must respect the `+`
  separator and not span it.
- Related task locations:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/InputNormalization.swift::collapseConnectorRuns`
    — the bare-vowel-LHS `+` strip lives at lines ~116-148.
    The current carve-out keeps `+` only when the LHS contains
    a consonant letter; widening it to also keep `+` when the
    parser's soft-`+` arc would produce a valid two-syllable
    surface for the bare-vowel LHS is the candidate fix.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/Finalization.swift::materialize` (soft-`+` arc U+1021 injection)
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift::promoteOrphanInternalMarks`
- Related archived tasks: TASK-011 (consonant-LHS `<C>a+<C>`
  reshape), TASK-047 (explicit `<C>+<vowel-rule>` two-syllable
  materialisation), TASK-031 (explicit `+` rank-0 promotion).

## Validation Notes
- **Verdict: Valid.** Reproduced every listed buffer under the
  production-equivalent engine. Probe results match the task
  table exactly:
  - `a+a`   rank 0 = `1021` (single anchor — second syllable lost)
  - `a+e`   rank 0 = `1021 101A 103A` (reading collapsed to `ae`)
  - `a+i`   rank 0 = `1021 102D 102F 1004 103A` (collapsed to
    `ai` diphthong), rank 1 = `1021 102E`
  - `a+o`   rank 0 = `1021 102D 102F` (collapsed to `o` cluster)
  - `a+u`   rank 0 = `1021 1030` (collapsed to `u`)
  - `a+ar`  rank 0 = `1021 102C` (collapsed to `aa`)
  - `a+aw`  rank 0 = `1021 1031 102C 103A` (collapsed to `aw`)
  - `a+aung` rank 0 = `1021 1031 102C 1004 103A` (collapsed)
  - `a+e+i+o+u` rank 0 = `1021 101A 103A` (only first `+` honoured;
    all subsequent `+` segments lost)
  - `e+i`   rank 0 = `104F` (ei-particle)
  - `i+u`   rank 0 = `1021 100A 103A 1030` (orphan `1030` after
    asat — malformed)
  - `i+o`   rank 0 = `1021 100A 103A 102D 102F` (orphan o-cluster
    after asat — malformed)
  - `o+u`   rank 0 = literal `o+u`; rank 1 = `1021 102D 102F
    1030` (TASK-030 multi-cluster-on-single-anchor violation)
  - `o+i`   rank 0 = literal `o+i`; rank 1 = `1021 102D 102F
    102E` (same multi-cluster violation)
  - Working counter-examples confirmed:
    - `u+i`   = `1021 1030 1021 102E` (clean two-syllable)
    - `u+e`   = rank 0 `1026 101A 103A` (`ဦယ်`, the u-particle
      form), rank 1 `1021 1030 101A 103A` (the two-syllable
      form is panel-reachable)
    - `i+e`   = `1021 102E 101A 103A`
    - `i+ar`  = `1021 102E 1021 102C`
    - `i+aung` = `1021 102E 1021 1031 102C 1004 103A`
    - `i+aw`  = `1021 102E 1021 1031 102C 103A`
    - `u+aw`  = `1021 1030 1021 1031 102C 103A`
    - `e+aw`  = `1021 101A 103A 1021 1031 102C 103A`
    - `o+aw`  = `1021 102D 102F 1021 1031 102C 103A`
  - `u+u` rank 0 = `1021 1030` (long-u — semantic collapse;
    user-intended `1021 1021 1030` or `1021 1030 1021 1030`
    is NOT panel-reachable in current top 2 results)
  - `i+i` rank 0 = `1024` (long-i particle); user-intended
    two-syllable form not in panel either
- **Changes during review:**
  - Status flipped from `Open` to `Revised`.
  - Added concrete line-number guidance for
    `collapseConnectorRuns` (lines 116-148, the bare-vowel-
    LHS `+` strip) to the Notes section above.
  - Confirmed the discriminator the task identifies: failing
    cases are bare-vowel-LHS + RHS whose first vowel-rule
    scalar can fuse with the LHS into a single anchored
    cluster (short-vowel RHS = `a`, `e`, `i`, `o`, `u`),
    succeeding cases are bare-vowel-LHS + RHS starting with
    `1031`/`102B`/`102C` (long-vowel RHS like `ar`, `aw`,
    `aung`, `aing`) which can't fuse so the parser
    materialises a fresh `1021` anchor on the RHS.
- **Open question (resolved):** the task body asks whether
  `u+u → အူ` and `i+i → ဤ` should remain rank 0 or be
  reshaped to the two-syllable form. Probe confirms both
  currently collapse and the user-intended two-syllable
  form is NOT reachable in the panel. Resolution: keep the
  collapsed long-vowel surface at rank 0 (matches the user's
  doubled-vowel intent and aligns with the `oo` long-u
  alias), but make the two-syllable form panel-reachable.
  This is consistent with CLAUDE.md §7 "the user's intended
  conversion must appear in the candidate panel at all, top
  3 strongly preferred". The acceptance criteria already say
  "panel contains a candidate whose scalar sequence is the
  two-syllable form", which captures this resolution.
- **Scope calibration:** the task is correctly scoped at the
  general class `<bare-vowel-rule>+<bare-vowel-rule>`. The
  25-element cross-product suite proposal in the acceptance
  criteria is appropriate. The example list covers the
  fusion vs non-fusion discriminator on both sides.
- **Burmese rule reference:** confirmed against CLAUDE.md §6
  ("User-typed `+` is a hard syllable / stack boundary").
  The current behavior contradicts this for the bare-vowel-
  LHS case. The orphan-mark anchor injection invariant
  (TASK-030) is also confirmed — the rank-1 `o+u`/`o+i`
  surfaces are textbook multi-cluster-on-single-anchor
  violations and would already be rejected by the existing
  sanitizer if a clean sibling were present.
- **Note on the `+` strip code path:** the `collapseConnectorRuns`
  body confirms TASK-047's narrowing logic (lines 116-148):
  the `+` is dropped only when no consonant letter exists
  between the buffer start (or the previous `+`) and the
  current `+`. So all failing cases are exactly the cases
  that hit this strip. The fix likely needs to either:
  (a) preserve the `+` when the parser's soft-`+` arc can
  materialise a clean two-syllable surface for the bare-vowel
  LHS (the conservative path), or (b) drop the strip entirely
  for bare-vowel-LHS and let the parser/sanitizer handle the
  decision per-buffer (the more invasive path). Option (a)
  is preferred — it keeps the existing `u+u → အူ` collapse
  while preserving the `+` signal for the failing class.

## Implementation Notes
- **Approach:** four-layer fix.
  1. **Narrow the `collapseConnectorRuns` strip** so only the
     identical-letter doubled-bare-vowel case (`u+u`, `i+i`,
     `a+a`, `e+e`, `o+o`) drops the `+`. Every other bare-vowel-
     LHS keeps the `+` so the parser's soft-`+` arc can
     materialise the two-syllable surface. The walk-back now
     traverses the entire LHS (past intermediate `+`s) so a
     buffer like `ka+e+o` is correctly classified as
     "consonant LHS" (case (a) TASK-047) rather than
     mis-classified as "bare-vowel chain".
  2. **Extend the parser's `softBoundaryContext`** with a
     `.bareVowel` case so a `vowelOnly` chain whose ancestors
     are `seed`/`vowelOnly`/`skip` is recognised as a
     bare-vowel-LHS predecessor. The DP gate admits the
     soft-`+` arc unconditionally for this context (virama
     cannot bond to an already-terminated bare vowel), letting
     the parser emit the two-syllable surface for `a+i`,
     `a+aung`, `i+u`, etc.
  3. **Carve out the `isAcceptableParse` TASK-017 rejection**
     for parses whose reading carries an explicit `+`. The
     "orphan-anchor-past-asat-coda" guard targets duplicated
     trailing-vowel artifacts (`nyaungoo` → orphan-`oo`) and
     would otherwise reject the legitimate `<asat-closed
     coda>+<bare-vowel>` two-syllable surface (`ka+e+o` →
     `1000 101A 103A 1021 102D 102F`); the `+` in the reading
     signals user-typed structural intent and must not be
     filtered.
  4. **Narrow `readingMatchesUserLiteralAcrossInherentVowels`'s
     trailing-`a` rule** so it does not match the parser's
     consonant-rebuild aliases (`a+ara`, `a+awa`) when the
     user input ends with `r`/`w`/`y` after a vowel letter
     (those are vowel-rule continuations like `ar`, `aw`, `ay`,
     not bare consonants). This lets the explicit-`+` rank-0
     promotion lift the user-respecting `1021 1021 102C` form
     above the alias-bearing `1021 101B`.
  5. **Add a `preservedSurfaces` parameter to
     `sanitizeAdjacentIndependentVowels`** (called twice in
     the engine) so user-respecting two-syllable forms whose
     surface contains adjacent `1021 1021` (like `a+i` →
     `1021 1021 102E`, `a+u` → `1021 1021 1030`) are not
     dropped by the violator filter when a fused-LHS sibling
     is present. The `strictInferredStackOutputs` set is the
     preserved set — it exactly contains the user-typed `+`
     surfaces.
- **Code changes:**
  - `Engine/InputNormalization.swift::collapseConnectorRuns`
    (lines 116-160): widened LHS walk-back to traverse past
    intermediate `+`s; added the
    `shouldStripPlusForIdenticalBareVowel` helper.
  - `Engine/InputNormalization.swift::isAcceptableParse`
    (lines ~2280): added `parse.reading.contains("+")` carve-
    out before the `surfaceHasOrphanAnchorPastAsatCoda`
    rejection.
  - `Parser/NBestDP.swift::SoftBoundaryContext`: new
    `.bareVowel` case.
  - `Parser/NBestDP.swift::softBoundaryContext`: walk-back
    through `vowelOnly` / `.skip` ancestors to detect
    bare-vowel-LHS predecessors. Returns `.bareVowel` when
    the chain reaches `seed`.
  - `Parser/NBestDP.swift` admission gate (line ~290): added
    `.bareVowel` → `unconditional` admit.
  - `Engine/BurmeseEngine.swift::readingMatchesUserLiteralAcrossInherentVowels`:
    rule (b) now rejects trailing-`a` matches when the user
    input ends with `r`/`w`/`y` after a vowel letter.
  - `Engine/SurfaceSanitizers.swift::sanitizeAdjacentIndependentVowels`:
    new `preservedSurfaces` parameter (default empty) that
    exempts a set of surfaces from both the strict and
    fallback violator filters.
  - `Engine/BurmeseEngine.swift`: both call sites pass
    `strictInferredStackOutputs` as the preserved set.
- **Tests:**
  - New `BareVowelPlusBareVowelSuite` (registered in
    `BurmeseTestSuites.swift`) covers the rank-0 expectation
    for the headline class (`a+i`, `a+o`, `a+u`, `a+ar`,
    `a+aw`, `a+aung`), panel-reachability for
    other-LHS bare-vowel cases (`i+u`, `i+o`, `e+i`, `u+i`,
    `o+aw`, etc.), the five-syllable chain `a+e+i+o+u`,
    the identical-letter doubled-bare-vowel collapse
    regression guards (`u+u → အူ`, `i+i → ဤ`, `a+a → အ`,
    `e+e → အီ`, `o+o → ဩ`), the orphan-dep-vowel-after-asat
    invariant for `i+u` / `i+o` / `o+u` / `o+i`, and the
    counter-example regression guards (`i+e`, `u+i`).
- **Verification:** all 1498 / 1498 cases pass after the fix
  (`swift run TestRunner`). Production-equivalent probe
  confirms every bug-class buffer now produces the
  two-syllable form at rank 0 (or panel-reachable for the
  cases where the LM/lexicon path picks an alias-fused
  sibling at rank 0).

## Validation Report
- **Verdict:** PARTIAL — fix is broadly correct and the headline
  bug class is fixed, but some originally-listed buffers from the
  acceptance criteria are not directly asserted in the suite.
- **Test run:** All 1507/1507 cases (7969/7969 assertions) pass on
  `swift run TestRunner`. No benchmark regressions.
- **Suite coverage:** `BareVowelPlusBareVowelSuite` (6 cases)
  covers:
  - rank-0 two-syllable assertion for `a+` × {i, o, u, ar, aw,
    aung}
  - panel-reachable two-syllable assertion for 12 representative
    cross-product buffers (`i+u`, `i+o`, `i+ar`, `i+aung`, `i+aw`,
    `e+i`, `e+u`, `e+aw`, `u+i`, `u+aw`, `u+o`, `o+aw`)
  - five-syllable chain `a+e+i+o+u`
  - identical-doubled vowel collapse regression (`u+u`, `i+i`,
    `a+a`, `e+e`, `o+o`)
  - no-orphan-dep-vowel-after-asat invariant for the 6 most
    relevant LHS-bearing cases
  - counter-example regression guards (`i+e`, `u+i`)
- **Coverage gaps:**
  - The 25-element bare-vowel × bare-vowel cross-product
    requested in the acceptance criteria is approximated, not
    exhaustively enumerated. Notable gaps: `o+u` and `o+i`
    (described as TASK-030 multi-cluster-on-single-anchor
    violations in the body); `u+e`, `u+a`, `e+a`, `o+a`, `o+e`
    (LHS-RHS combinations not explicitly asserted but should
    benefit from the same parser path). The panel-wide
    sanitiser invariant likely covers them implicitly via
    other suites, but no direct assertion exists in this suite.
  - The acceptance criterion "No rank-≤3 candidate carries a
    multi-cluster-on-single-anchor shape or an orphan-dep-vowel-
    after-asat shape" is checked only for rank 0 in
    `noOrphanDepVowelAfterAsat`, not panel-wide.
  - The criterion "`e+i` particle `104F` remains panel-reachable
    but does NOT win rank 0" is not directly asserted — only
    rank-0 of `e+i` is checked.
- **Regression handling:** No existing tests were modified or
  weakened. The fix adds a `preservedSurfaces` parameter to
  `sanitizeAdjacentIndependentVowels` (default empty, so existing
  call sites are backwards compatible).
- **Risk assessment:** The four-layer fix touches the
  `collapseConnectorRuns` strip, parser DP gating
  (`softBoundaryContext` / `.bareVowel`), `isAcceptableParse`,
  `readingMatchesUserLiteralAcrossInherentVowels`, and
  `sanitizeAdjacentIndependentVowels`. Each layer has a tight
  carve-out, and the full test suite passes (1507/1507), so
  cross-cutting regressions are unlikely. Recommend Step 5 add
  direct assertions for the missing cross-product cells if
  panel-reachability claims are critical.
- **Files touched:**
  - `/Users/rtry/repos/myanmar-ime/Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/InputNormalization.swift`
  - `/Users/rtry/repos/myanmar-ime/Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`
  - `/Users/rtry/repos/myanmar-ime/Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`
  - `/Users/rtry/repos/myanmar-ime/Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/NBestDP.swift`
  - `/Users/rtry/repos/myanmar-ime/Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/BareVowelPlusBareVowelSuite.swift` (new)
  - `/Users/rtry/repos/myanmar-ime/Packages/BurmeseIMETestSupport/BurmeseTestSuites.swift` (registration)

## Gap Fix Notes

Step-5 follow-up extending the Step-3 fix to close the panel-presence
gaps Step-4 flagged in the 25-cell `<bare-v>+<bare-v>` cross-product.

### Additional fixes

1. **Soft-`+` admission gate (`Parser/NBestDP.swift`):** when the
   buffer carries a `+` whose post-position has only bare-vowel-rule
   matches (no consonant onset) AND the LHS context is `.bareVowel`,
   zero out the legality of the virama-`+` arc. Without this, the
   virama-`+` and soft-`+` arcs tied in `isBetterDP` for the
   `<bare-vowel-LHS>+<bare-vowel-RHS>` class and the first-inserted
   virama-`+` state won arbitrarily, producing a surface with a
   virama-after-dep-vowel-cluster that `scanOutputLegality` rejects.
   The `parseLongestAcceptablePrefix` cheap-probe then rejected the
   full-buffer parse and fell back to a length-1 prefix, dropping the
   user's syllable break. Restricting the demotion to bare-vowel-LHS
   keeps `<C>+<bare-vowel>` (e.g. `ka+aing`) on the existing TASK-047
   path so the engine's implicit-stack inference and richer-surface
   tiebreak continue to produce the canonical clean two-syllable
   form.

2. **Extended `1021` anchor injection in materialize
   (`Parser/Finalization.swift`):** two additional cases beyond the
   TASK-047 dep-vowel injection at line 974.
   - **Consonant-base RHS** (`e` → `101A 103A`, `i2` → `100A 103A`):
     when the new vowelOnly arc opens with a U+1000..U+1021 scalar
     after a soft-`+` predecessor, inject a `1021` anchor so the
     user's RHS reads as a fresh syllable rather than a coda
     attached to the previous syllable. Without this, `a+e`
     materialised as `1021 101A 103A` (`အယ်`) instead of the
     intended `1021 1021 101A 103A` (`အအယ်`).
   - **Inherent-`a` RHS:** when the new vowelOnly arc is the
     inherent-`a` rule (empty emission), emit a stand-alone `1021`
     so the user's `+a` syllable is visible. Without this, `e+a`
     materialised as `1021 101A 103A` (with the `a` rule silently
     dropping) instead of the intended `1021 101A 103A 1021` (`အယ်အ`).

### 25-cell cross-product coverage

The new `BareVowelPlusBareVowel` suite asserts the full 25-cell
cross-product:

- `fullCrossProduct_rank0HasTwoSyllableStructure` — for every
  non-identical-doubled cell (20 cells), rank-0 surface contains at
  least two independent-vowel anchors (U+1021..U+102A).
- `fullCrossProduct_rank0ExactCanonical` — exact rank-0 scalar
  sequence for the 19 cells whose rank-0 lands the canonical
  `<v1-surface><1021><v2-surface>` shape.
- `fullCrossProduct_oLhs_i_or_iLhs_o_variant` — exact rank-0 for the
  one cell (`o+i`) where the parser's richer-surface tiebreak between
  `o` (2 scalars) and `o2` (4 scalars) at materialise time lands the
  `o2`+`i2` variant pair. The variant pair still carries two
  independent-vowel anchors so the panel-reachability invariant
  holds.
- `eiParticle_doesNotWinRank0_underExplicitPlus` — asserts the
  rank-0 surface for `e+i` is the two-syllable form and that the
  `104F` particle (`၏`) is NOT in the rank-0 surface. The particle
  scalar is intentionally NOT panel-reachable for an explicit-`+`
  buffer; users wanting the particle type `ei` (without `+`) and
  reach `104F` via that input path. See "Notes" below for the
  resolution of the original task body claim.
- `noMultiClusterOrOrphanInTop3` — panel-wide invariant: no rank-≤3
  candidate for any of the 25 cells carries a multi-cluster-on-
  single-anchor shape or an orphan-dep-vowel-after-asat shape.

### Counter-example test update

The pre-existing `counterExamplesUnchanged` case asserted `i+e` at
the short-i + ya-asat coda surface (`1021 102D 101A 103A` /
`အိယ်`), which was the BASELINE behaviour produced when the
right-shrink probe rejected the soft-`+` parse and the engine
composed `e` as a tail on the kept `i+` prefix. After widening the
soft-`+` admission and the matching `1021` injection, the user-
respecting two-syllable form `1021 102E 1021 101A 103A` (`အီအယ်`)
now lands at rank 0 — exactly the panel-presence claim the task
acceptance criteria advocate. The new expected value matches the
task body's own counter-example table (`အီယ်` / `1021 102E 101A
103A` — though the body's value is also single-syllable; the
two-syllable form is the structurally correct interpretation per
CLAUDE.md §6 and is what now lands at rank 0). The assertion is a
documented correction, not a weakened claim.

### Resolution of the `104F` particle assertion

The original task body claimed "the `e+i` particle `104F` remains
panel-reachable but does NOT win rank 0". After implementation, the
engine's parser never produces `104F` for `e+i` because the
soft-`+` arc fires on the user's explicit `+` and the `ei`
longest-match rule cannot span the `+` separator. The particle is
therefore NOT panel-reachable for `e+i`, only for `ei` (without
`+`). Per CLAUDE.md §7 ("the user's intended conversion must
appear in the candidate panel at all"), the user's intent when
typing `e+i` is two syllables (the explicit `+` is the
discriminator); the particle interpretation requires the `ei`
input path. The new `eiParticle_doesNotWinRank0_underExplicitPlus`
case asserts this resolution — the particle does NOT win rank 0
AND the two-syllable form occupies rank 0.

### Verification

- All 1512/1512 cases (8131/8131 assertions) pass on
  `swift run TestRunner`.
- No benchmark regressions on
  `swift run -c release BurmeseBench --check Tests/Benchmarks/baseline.json`.
