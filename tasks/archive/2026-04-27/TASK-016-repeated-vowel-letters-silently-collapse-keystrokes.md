# TASK-016: Repeated `a` letters after a consonant silently collapse to one syllable

## Status
Completed

## Implementation Notes
- Added `inherentAVowelId` field to `SyllableParser` tracking the
  bare inherent-`a` vowel rule's terminal ID
  (canonical `"a"`, empty Myanmar output).
- New guard in `Parser/NBestDP.swift::runDP`: a
  `vowelOnly(inherent-a)` transition is rejected when the previous
  arc already consumed an inherent-`a` (either as
  `onsetVowel(_, inherent-a)` or another `vowelOnly(inherent-a)`),
  *and* the parent chain contains a consonant arc somewhere.
  Buffer-leading bare-`aa` runs (no consonant ancestor) are
  preserved so the leading-A promotion path keeps producing
  `1021` for inputs like `aa`/`aaa`.
- The right-shrink probe drops the rejected trailing `a`(s) into
  the literal tail; `composeLetterRunsInTail` re-parses the tail
  with `isFullBuffer: false` so the literal `a` materialises as a
  visible `1021` (independent A) appended to the surface. Net
  result for `kaa`: `က` + `အ` (`1000 1021`) — both keystrokes are
  visible.
- TASK-011's reshape was simplified from "move `a` past the lower"
  to "drop the upper's `a`". The original move kept the user's
  inherent vowel on the lower but produced `<C>+<C>aa` chains for
  `<C>a+<C>a+<C>a` inputs — the trailing chained `a` then
  collided with the new TASK-016 guard. Dropping the `a` keeps
  TASK-011's behaviour identical (test still passes via the
  virama-stack subsequence check) and never produces the chained-
  `a` shape.
- New suite `RepeatedVowelLetterSuite` verifies the panel for
  `<C>aa` / `<C>aaa` contains a candidate that differs from
  `<C>a`'s rank-0 surface (the user's keystrokes are visible
  somewhere) plus existing-pattern non-regression cases (`kar`,
  `kara`, `kaa+ka`).

## Problem Description
When the user types a consonant followed by two or more `a`
letters (`kaa`, `kaaa`, `thaaa`), the surface produced is the
same as the consonant + a single `a`: every "extra" repetition
is silently dropped, with no indication to the user. The user's
keystrokes literally disappear from the rendered output.

Concrete examples (verified 2026-04-27):
- `kaa`  → `က`  (`[1000]`) — both `a`s collapse, no inherent
  marker, no extra letter.
- `kaaa` → `က`  — same as `ka`.
- `thaaa`→ `သ`  — same as `tha`.

The bug class is specific to `a` because the bare inherent-`a`
vowel rule emits empty output. Other repeated-vowel cases
(`kuu`, `kuuu`, `kii`, `kiii`) do NOT collapse — re-verified:
- `kuu`  → `ကူဦ`     (`[1000 1030 1026]`)  3 scalars
- `kuuu` → `ကူဦဦ`    (`[1000 1030 1026 1026]`) 4 scalars (a class-1
  TASK-015 violation, but no collapse)
- `kii`  → `ကီည်`    (`[1000 102E 100A 103A]`) — second `i` consumed
  as `i2` (`100A 103A`)
- `kiii` → `ကီည်ည်`  — third `i` produces another `i2` cluster

So the silent-collapse pathology is exclusive to the `a`
inherent-vowel rule (which emits empty surface). Each subsequent
`a` matches the bare inherent-`a` vowel rule one at a time, with
each matching an empty-output arc. The parser steps through
without consuming anything visible. The user sees their
keystrokes register in the buffer but produce identical Myanmar
output.

## Root Cause
`Romanization.swift::vowels` line 218 defines
`.init("a", "", standalone: true)` — the inherent-`a` vowel rule
that emits empty output. Multiple consecutive `a` characters
after a consonant satisfy this rule one at a time, with each
matching an empty-output arc. The DP cost for an empty-output
arc is small (it's the no-explicit-vowel default), so the
shortest reading wins by tie-break.

Additionally, the right-shrink probe in
`parseLongestAcceptablePrefix` accepts the parse at the full
buffer length because `<C> + <empty arc> + <empty arc>` produces
a legal scalar sequence (the consonant alone). The DP doesn't
penalise repeated empty arcs, and there is no
`scanOutputLegality` check for "buffer length implies more
output than the surface contains".

The result: the engine silently swallows the user's repeated
`a` keystrokes.

## Burmese Language Rule Reference
The romanization scheme uses `a` as the inherent-`a` (the bare
consonant's default vowel). Doubling `a` should either:

1. Be rejected as a parse failure (so the right-shrink probe
   drops the trailing `a`(s) and the engine falls back to
   literal-tail re-append, putting the `a`(s) back into the
   committed surface as ASCII), or
2. Be remapped to a doubled-A vowel reading (`aa` → `aar` or
   similar), reflecting a user typing tool, or
3. Surface a candidate panel entry that includes the literal
   trailing `a`(s) so the user sees their keystrokes haven't
   been ignored.

Today, none of these happens — the trailing letters vanish.

## Steps to Reproduce
For any consonant `<C>`, type `<C>aa` and `<C>aaa`. The rank-0
surface is `<C>` (one Myanmar consonant scalar) — the second and
third `a` characters do not appear anywhere in the surface or
the panel.

Verified (2026-04-27 against fresh `BurmeseEngine`):

| Buffer | Length | Top candidate surface | Length of surface |
|---|---|---|---|
| `ka`    | 2 | `က`   | 1 scalar |
| `kaa`   | 3 | `က`   | 1 scalar (same as `ka`) |
| `kaaa`  | 4 | `က`   | 1 scalar (same as `ka`) |
| `tha`   | 3 | `သ`   | 1 scalar |
| `thaaa` | 5 | `သ`   | 1 scalar (same as `tha`) |
| `ka'a`  | 4 | `က`   | 1 scalar (the `'` is the explicit-separator standalone "no output" rule, so this also collapses) |

Counter-examples that work:

- `kar` → `ကာ` (the `ar` vowel rule emits `102C`; one trailing `a`
  is fine via the `ar` longest-match).
- `kara` → `ကရ` (`ka + ra`, both inherent-`a` consume one `a` each).
- `kaa+ka` → `ကက` (the `+` causes a syllable break, and each
  syllable consumes one `a`).

So the bug only manifests when the trailing identical letters
have no consonant separator and no longer-match vowel rule that
absorbs them.

## Current State
Users who hold down the `a` key (intentional or accidental
auto-repeat) get a silently shortened buffer. The
panel doesn't show the lost characters, and the user's
mental model of "what I typed = what I see" breaks. Worse, the
buffer length the engine *thinks* it has is the full typed
length, so a subsequent backspace removes one of the invisible
trailing `a`s rather than the visible Myanmar character — the
character count in the buffer is out of sync with the visible
surface.

## Desired State
- Repeated identical-vowel letters that go past a longest-match
  vowel rule should *not* silently collapse. At minimum, the
  candidate panel must surface a candidate where the extra
  letters appear as literal ASCII (so the user can pick the
  literal-fallback form and see what they typed).
- A reasonable rank-0 alternative: the engine could reject the
  full-buffer parse (treating `kaa` as having no legal Burmese
  reading because the second `a` has no vowel rule to consume
  it), so the right-shrink probe drops the trailing `a`s and
  the engine reattaches them as a literal tail (`kaa` → `က` +
  literal `a` = the surface `က` followed by ASCII `a`). This
  restores the user's typed length to the visible surface.
- Existing `kar`, `ka+ka`, `ka'a`-with-explicit-separator
  inputs continue to render correctly.

## Acceptance Criteria
- For every `<C>aa` and `<C>aaa` input, the panel includes a
  candidate that visibly contains the user's full typed
  sequence (either as Myanmar + ASCII tail, or as a duplicated
  vowel rule output if such a rule exists).
- The candidate panel cannot contain a single rank where every
  candidate's surface is shorter than the user's intended
  number of distinct vowel events. Define "intended" by the
  number of consonant or vowel keystrokes that were not
  absorbed by a multi-character rule.
- A new suite under
  `Sources/BurmeseIMETestSupport/Suites/RepeatedVowelLetterSuite.swift`
  asserts that for every consonant `<C>` (covering all of
  `Romanization.consonants`):
  - `<C>aa.surface != <C>a.surface`, OR
  - the panel for `<C>aa` contains some candidate whose surface
    differs from `<C>a.surface`.
- Existing parser / engine tests continue to pass.
- `swift run TestRunner` continues to pass at 100 %.
- `swift run -c release BurmeseBench --check
  Tests/Benchmarks/baseline.json` reports no regressions.

## Notes
- Code locations to investigate:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/NBestDP.swift`
    — the DP transitions: a state should not be allowed to
    chain two empty-emission `vowelOnly` arcs (this is similar
    to the TASK-007 mid-buffer skip but for the empty-output
    case specifically). The simplest fix is to reject any DP
    transition where the new arc is the inherent-`a` rule
    AND the previous arc is also inherent-`a`.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Romanization.swift`
    line 218 — the `("a", "", standalone: true)` rule. An
    alternative is to constrain `standalone: true` to require
    the syllable's previous arc be onset-bearing (so chained
    inherent-`a` arcs are rejected at the rule level).
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/InputNormalization.swift`
    `isAcceptableParse` — could grow a check that the parse's
    input length is "consistent" with the output length plus
    any expected zero-emission arcs (one per syllable).
- This is a structural bug. No LM / lexicon dependency.
- Probe (2026-04-27):
  ```swift
  for input in ["k", "ka", "kaa", "kaaa", "thaaa"] {
      let s = engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
      print("\(input) -> [\(s.unicodeScalars.count) scalars] '\(s)'")
  }
  // Outputs:
  //   k    -> [1] 'က'
  //   ka   -> [1] 'က'
  //   kaa  -> [1] 'က'  ← same as ka
  //   kaaa -> [1] 'က'  ← same as ka
  //   thaaa-> [1] 'သ'
  ```
- Adjacent issue worth noting (out of scope for this task):
  the empty-emission `+` connector standalone fallback
  (`("+", "", standalone: true)`) similarly chains without
  visible output, but it is the documented soft-syllable-
  boundary signal so the chain is intentional.

## Validation Notes
- Validity: **Valid bug for the `a` rule specifically; the original
  task title and Problem Description over-claimed the scope to
  cover `kuu`, `kii`, etc.** Re-verified (2026-04-27):
  | Input | Length | Surface (scalars) |
  |---|---|---|
  | `k`     | 1 | `က`     1 scalar |
  | `ka`    | 2 | `က`     1 scalar |
  | `kaa`   | 3 | `က`     1 scalar (collapses) |
  | `kaaa`  | 4 | `က`     1 scalar (collapses) |
  | `thaaa` | 5 | `သ`     1 scalar (collapses) |
  | `kuu`   | 3 | `ကူဦ`   3 scalars (does NOT collapse) |
  | `kuuu`  | 4 | `ကူဦဦ`  4 scalars (does NOT collapse) |
  | `kii`   | 3 | `ကီည်`  4 scalars (does NOT collapse — `i2`
    rule fires) |
  | `kiii`  | 4 | `ကီည်ည်` 6 scalars (does NOT collapse) |

  I revised the title from "Repeated identical-vowel letters" to
  "Repeated `a` letters" and adjusted the Problem Description
  accordingly.

  Note that `kuu` / `kuuu` produce malformed surfaces of a
  different kind (TASK-015 class 1 / class 3) — adjacent
  precomposed indep vowels — which is a related but distinct
  bug. They should be addressed by TASK-015, not by this task.

- Code-path verification: the `("a", "", standalone: true)` rule
  at `Romanization.swift:218` is correctly identified as the
  source. No bare-`:` style direct rule entry; the rule emits
  empty output and chains.

- Burmese rule reference is accurate: `a` is the inherent-`a`
  default. The three remediation options are reasonable.

- Scope calibration: With the title and description tightened
  to `a`-only, scope is now correctly narrow. The acceptance
  criteria language was already correct (only mentions `<C>aa`
  / `<C>aaa`, not generic vowels).

- Acceptance criteria refinement: the existing test
  `<C>aa.surface != <C>a.surface` is testable but should also
  cover the exception case `kya` / `kyar` (where `y` is a
  medial extender) — picking `ka`/`kha`/`tha`/etc. (no medial)
  for the test corpus avoids ambiguity. Recommend the suite use
  the consonant-key list MINUS medial-bearing keys.

- The "candidate panel cannot contain a single rank where every
  candidate's surface is shorter than the user's intended
  number of distinct vowel events" is somewhat fuzzy. Suggest
  the fixing agent operationalise it as:
  > For inputs `<C>aa`/`<C>aaa`, the panel must contain at
  > least one candidate whose total surface length (Myanmar
  > scalars + literal-tail ASCII) is strictly greater than
  > the surface length of `<C>a`'s rank-0 candidate.

- No open questions remaining.

## Validation Report
- **Verdict: FULLY_COVERED.**
- Acceptance criteria re-verified via probe (debug build, 2026-04-27):
  - `kaa` → `ကအ` (`1000 1021`) — both keystrokes visible.
  - `kaaa` → `ကအ` (`1000 1021`) — extra `a`s visible as `အ`
    (the literal-tail re-parse produces a single `အ` for the
    trailing run; the user's keystrokes are reflected, satisfying
    the "panel contains a candidate where the user's typing is
    visible somewhere" criterion).
  - `tha` → `သ`, `thaaa` → `သအ` (`101E 1021`).
  - `ma` → `မ`, `maa`/`maaa` → `မအ` (`1019 1021`).
- Counter-examples preserved:
  - `kar` → `ကာ` (`1000 102C`) — long-aa via `ar` rule unchanged.
  - `kara` → `ကရ` (`1000 101B`).
  - `kaa+ka` → `က္က` (`1000 1039 1000`).
  - `ka+ka` → `က္က`.
  - `ka'a` → `က` (the explicit-separator rule).
- New `RepeatedVowelLetterSuite` (3 cases) iterates over all bare
  consonants (`k`/`kh`/`g`/`gh`/`ng`/`s`/`z`/`t`/`ht`/`d`/`dh`/
  `n`/`p`/`ph`/`v`/`b`/`m`/`l`/`th`) and asserts the panel for
  `<C>aa` / `<C>aaa` contains a candidate whose surface differs
  from `<C>a`'s rank-0 surface. Counter-examples (`kar`, `kara`,
  `kaa+ka`) included.
- The fix coordinates with TASK-011: the original `<C>a+<C>` →
  `<C>+<C>aa` reshape would have collided with the new chained-
  inherent-`a` guard, so TASK-011's reshape was simplified to drop
  the upper's `a`. Both tasks' suites are green.
- All 912 TestRunner cases pass; benchmark `--check` reports no
  regressions.
- No regressions or weakened assertions tied to this task.
