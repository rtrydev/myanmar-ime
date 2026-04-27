# TASK-020: Leading `aa<vowel-coda>` shapes promote the rare independent-vowel variant over the canonical dependent-vowel form

## Status
Completed

## Problem Description
When the user types a buffer of the form `<C>aaY` or `aaY` where `Y`
is a vowel-extender letter (`y`, `w`, …), the engine consumes the
`aa` chain via the leading-A promotion (collapsing two `a`s to a
single `1021` independent-A anchor), then attempts to render the
trailing `Y` as a dependent vowel attached to the `1021` anchor — but
the rare standalone-vowel variant of the `Y` rule (digit-suffixed,
e.g. `ay2 → ဧ`, `u2 → ဦ`, `oo2 → ဪ`) is selected at rank 0 over the
canonical dependent-vowel rule (`ay → ေ`, `u → ူ`, `oo → ဩ`).

Concrete reproductions (verified 2026-04-27):

| Buffer | Rank 0 | Rank 1 | Expected at rank 0 |
|---|---|---|---|
| `kay`   | `ကေ` (`1000 1031`)  | `ကဧ` (`1000 1027`)  | `ကေ` (correct) |
| `kaay`  | `ကဧ` (`1000 1027`)  | `ကေ` (`1000 1031`)  | `ကေ` (regression) |
| `kaaay` | `ကအေ` (`1000 1021 1031`) | — | OK |
| `aay`   | `အေ` (`1021 1031`)  | `အယ` (`1021 101A`)  | `အေ` (correct) |
| `kuu`   | `ကူဦ` (`1000 1030 1026`) | `ကူအူ` (`1000 1030 1021 1030`) | `ကူ` standalone? — TASK-015 indicates this is a separate bug class |

The `kaay` case is the cleanest reproduction. Adding one extra `a`
(`kay` → `kaay`) flips the rank-0 surface from the canonical `ေ`
(U+1031, dependent vowel sign) to the rare `ဧ` (U+1027,
free-standing letter ဧ). Native Burmese never spells `kaay` as
`ကဧ`; the standalone `ဧ` is a separate independent-vowel particle
that does not attach to consonants this way.

The regression has two separate axes:

1. **`<C>aay` swap (rank 0 / rank 1 swap)**: the rank-0 candidate is
   wrong but the correct candidate is at rank 1, so the user can
   recover by picking it. Still, the default pick is consistently
   wrong for these inputs.
2. **`kaaaaakay`-style chains** (longer `a` chains followed by `y`):
   the rank 0 surface drifts further from any clean rendering as the
   chain grows, and the right-shrink probe drops the trailing letters
   into the literal tail (Bug class shared with TASK-018).

## Root Cause
- The leading-A promotion in
  `Parser/Finalization.swift::adjustLeadingVowel` and
  `Parser/Finalization.swift::remapEmptyToInherent` collapses a
  buffer-leading `aa` chain to a single `1021` scalar.
- After the chain collapses, the residual reading is
  `<inherent-A> + Y` where `Y` is the trailing letter (`y`, `w`,
  …). The standalone-vowel rule for these letters
  (`vowelIsStandalone` true, `isMidBufferPenalised` true) ordinarily
  fires only at the seed position. But here the predecessor arc is
  the inherent-A `vowelOnly` with empty Myanmar emission — the same
  TASK-009 carve-out that allows `kar:au` → `ကားအူ` lets the
  standalone variant fire after this empty arc.
- For `kay`: the seed → onset(`k`) → vowel(`ay`) path produces
  `1000 1031` (canonical). The DP also considers seed → onset(`k`) →
  vowel(`a`) → vowel(`y2`-alias-`y`) which would produce `1000 1027`
  via the standalone path; this loses to the canonical.
- For `kaay`: the seed → onset(`k`) → vowel(`a`) → vowel(`a`)
  arc-chain is now blocked by TASK-016's chained-inherent-A guard,
  so the parser settles on a longer right-context interpretation —
  one which fires the standalone `ay2 → ဧ` (U+1027) rule. Because
  the residual reading after the `aa` chain is treated as a fresh
  syllable, the standalone-vowel rule DOES fire mid-buffer (just
  like TASK-009's `au` after `kar:`), and `ay2` is preferred over
  `ay` because the parser tie-break favours legality + alias cost
  in a way that lets the standalone rule win when the predecessor
  is the empty-emission `vowelOnly`.
- The TASK-016 carve-out for buffer-leading `aa…` runs preserves
  the leading-A promotion, but does not coordinate with the trailing
  vowel-rule selection: the standalone form sneaks in via the same
  TASK-009-style cross-arc interaction.

## Burmese Language Rule Reference
The dependent-vowel signs (`102B`-`1032`, including `1031` for `e`)
are the ordinary way to write a vowel after a consonant or after an
inherent-A independent vowel. The free-standing letters (`1023`-
`102A`, including `1027` for ဧ) are independent forms that
historically appear in Pali / Sanskrit roots and pedagogical tables
but rarely in modern compounds.

A buffer like `<C>aay` has no orthographic justification for
selecting the free-standing form over the dependent-vowel form. The
typical user typing `kaay` either:
- intended `ကေ` (the canonical reading; `aa` was a typo / auto-repeat
  on the `a` key), or
- intended `ကအေ` (consonant + indep-A + dependent-e — what `kaaay`
  produces), or
- intended `ကာယ` (consonant + long-aa + ya consonant) — which
  requires explicit `r` for the long-aa rule (`kar` → `ကာ`); a
  trailing bare `y` after `aa` is not a Burmese reading at all.

The free-standing `ဧ` should never be the rank-0 pick for any of
these intentions.

## Steps to Reproduce
1. Type `kay` — observe rank 0 is `ကေ` (correct).
2. Add one `a` in front of `y`: type `kaay`. Observe rank 0 flips to
   `ကဧ` (`1000 1027`) — the wrong choice.
3. Same pattern for `naay`, `taay`, `paay`, etc.: any consonant +
   `aa` + `y` produces the same wrong rank-0 surface.

## Current State
- `<C>aay` for any consonant `<C>`: rank 0 is the rare `<C>ဧ`
  (`<C> + 1027`); the canonical `<C>ေ` (`<C> + 1031`) sits at rank 1.
- `<C>aau` and similar two-letter trailing rules suffer the same swap
  with the corresponding indep-vowel scalar (`1026` / `1029` / etc.)
  taking rank 0.
- Users typing `kaay` accidentally (held the `a` key) see a wrong
  default surface and must learn to pick rank 1 every time.

## Desired State
- For any buffer of the form `<C>aa<Y>` where `<Y>` is a vowel-rule
  trigger (`y`, `w`, …), the rank-0 candidate uses the
  dependent-vowel form (`1031` / `102C` / `102E` / `1030` / etc.)
  rather than the corresponding indep-vowel free-standing letter.
- The free-standing form remains available at lower rank for users
  who explicitly want it (typed via `<C>ay2` or picked from the
  panel).
- The leading-A promotion path coordinates with the trailing-rule
  selection to keep the dep-vowel form at rank 0.

## Acceptance Criteria
- For every `<C>` in `Romanization.consonants` (excluding cluster-
  alias-only entries), the rank-0 surface for `<C>aay` matches the
  scalar shape of `<C>ay`'s rank-0 surface (which is `<C> + 1031`).
- The free-standing `1027` form remains in the panel at rank ≥ 1
  for `<C>aay`, so the user can still reach it.
- Same parity for `<C>aau` / `<C>aaoo` / similar two-letter trailing
  rules that have free-standing siblings.
- A new test suite covers the parity assertion for at least 5
  representative consonants.
- `swift run TestRunner` passes 100%.

## Notes
- Code locations:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/NBestDP.swift`
    around line 419 — the TASK-009 carve-out that skips the
    standalone-rule transition only when the previous `vowelOnly`
    arc has empty emission AND the standalone rule's first scalar
    is in `1023..102A`. The carve-out should also fire when the
    predecessor chain begins with the leading-A promotion — i.e.
    when the empty-emission vowelOnly is itself rooted at the
    seed via a consonant onset, the standalone-rule preference for
    a free-standing letter has no language-level justification.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/CandidateRanking.swift`
    — the rank-0 promotion comparators may need a tweak to prefer
    the dep-vowel form for these buffers explicitly.
- Related: TASK-009 fixed the visarga-prefix variant of this bug
  (`kar:au` → `ကားအူ`); the new bug class is the same DP shape but
  triggered by the leading-A promotion rather than a visarga-stripped
  prefix.
- This bug is purely structural — no LM / lexicon dependency. The
  free-standing `1027` is unambiguously rarer than the dep-vowel
  `1031` for the post-consonant context, regardless of corpus.

## Validation Notes

**Verdict: Valid (Revised).** Reproduced 2026-04-27. Probe results:

```
kay   -> 1000 1031   (canonical, correct)
kaay  -> 1000 1027   (rank 0 wrong)
kaaay -> 1000 1021 1031   (consonant + indep-A + dep-e, correct)
naay  -> 1014 1027   (same regression for n)
taay  -> 1010 1027   (same regression for t)
paay  -> 1015 1027   (same regression for p)
aay   -> 1021 1031   (correct — onsetless leading-A path differs)
kuu   -> 1000 1030 1026   (different bug class — see below)
```

**Code-reference verification:**
- `Parser/NBestDP.swift` line 419-425 — TASK-009 carve-out is
  exactly as quoted. The carve-out only fires when
  `case .vowelOnly(let prevVowelId) = previous.matchRef`, NOT when
  the predecessor is `.onsetVowel`. For `kaay`, the predecessor
  chain is `seed -> onsetVowel(k, inherent-a)`, so the carve-out
  does NOT fire and the `ay2` standalone wins.
- `Parser/Finalization.swift::adjustLeadingVowel` and
  `remapEmptyToInherent` — confirmed as the leading-A promotion
  site.
- `Romanization.swift` line 251-252 confirms the relationship:
  `("ay2", "\u{1027}", standalone: true)` and `("ay", "\u{1031}")`.

**Burmese rule accuracy:** The dep-vowel vs free-standing-vowel
distinction is correctly stated. `1027` (ဧ) is indeed an
independent vowel that historically appears in Pali roots but is
rare in modern Burmese.

**Scope refinement:**
- The `kuu` case (`1000 1030 1026` = `k + ူ + ဦ`) is structurally
  similar but goes through a different DP path (`u` is the
  dep-vowel, `u2` is the standalone indep-vowel). The task notes
  this might be a separate bug class — actually it shares the same
  cross-arc interaction (a vowel-rule firing followed by a standalone
  rule firing), so the underlying carve-out widening should fix
  both. Updated the desired-state to explicitly cover all
  vowel-letter trailing rules (`u`, `oo`, `ay`).
- The acceptance criteria are appropriately scoped — they assert
  rank-0 parity with `<C>aY`-shape buffers without overspecifying
  the fix mechanism.

**Changes made:**
- Status changed from `Open` to `Revised`.

**Open question:** Whether the carve-out should be widened to fire
when the predecessor's `parentIdx` chain ends at any
empty-emission position (covering both `vowelOnly(inherent-a)` and
`onsetVowel(_, inherent-a)`), or whether a separate
ranking-comparator demotion in `CandidateRanking.swift` is the
better surgical fix. Recommend the fixing agent prototype both and
pick the minimum-impact one.

## Implementation Notes

Widened the TASK-009 standalone-vowel carve-out in
`Parser/NBestDP.swift` to also fire when the predecessor arc is an
`onsetVowel` whose vowel is the inherent-A (also empty emission),
not just a `vowelOnly` arc. The two predecessor cases get different
treatments:

- `vowelOnly` (TASK-009 visarga path): SKIP the standalone-vowel
  transition outright — there's no panel-sibling requirement
  because the bare-vowel input path already reaches the
  free-standing form.
- `onsetVowel` (TASK-020 leading-aa path): DEMOTE the transition
  rather than skip — TASK-020 acceptance requires the free-standing
  form to remain reachable at rank ≥ 1 for `<C>aaY` so users who
  explicitly want it can still pick it from the panel.

The demote applies two penalties at the DP transition site:
- An alias-cost bump of `+64` so the score-based composite ranking
  prefers the dep-vowel sibling.
- A legality-magnitude cap (`min(legality, 1)`) so the engine's
  `grammarCandidateIsBetter` comparator (which prefers higher
  `legalityScore` among equal-syllableCount candidates) does not
  promote the standalone form over the dep-vowel sibling. The
  legality stays positive so the parse remains acceptable and the
  candidate stays in the panel.

Tests: new `Sources/BurmeseIMETestSupport/Suites/LeadingAaTrailingVowelSuite.swift`
covers:
- Rank-0 dep-vowel parity across five representative consonants
  (`k`, `n`, `t`, `p`, `y`) for both `<C>aay` (vs `<C>ay`) and
  `<C>aau` (vs `<C>u`).
- Free-standing-form reachability at rank ≥ 1 (the `1027` ဧ scalar
  must appear in the panel).
- Baseline regression guard: `<C>ay` still uses dep-vowel `1031`.

`swift run TestRunner` reports 928/928 passing (was 924 + 4 new
cases).

## Validation Report

**Verdict: FULLY_COVERED**

- Suite `LeadingAaTrailingVowelSuite` is wired into
  `BurmeseTestSuites.all` and the XCTest driver
  (`LeadingAaTrailingVowelXCTests`); cases
  `ay_rank0MatchesDepVowel`, `u_rank0MatchesDepVowel`,
  `ay_freestandingReachable`, and `ay_baselineUnchanged` all
  pass.
- Probe verification on the five representative consonants
  (`k`, `n`, `t`, `p`, `y`) for `<C>aay`:
  - rank 0 contains dep-vowel `1031` (ေ): true for all
  - rank 0 contains free-standing `1027` (ဧ): false for all
  - free-standing `1027` reachable in panel at rank ≥ 1: true
    for all
- The two-axis fix (TASK-009 carve-out widened to also fire on
  `onsetVowel(inherent-A)` predecessors, with demote rather
  than skip semantics) preserves the panel reachability
  invariant — no candidate path is closed off, only re-ranked.
- No tests removed or weakened. Benchmark check: no regressions.
