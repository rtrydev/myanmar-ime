# TASK-054: Mid-buffer tone marker (`.` / `:`) is silently dropped between a digit-bearing syllable and a following Burmese syllable

## Status
Completed

## Problem Description
When the user types a tone marker (`.` for creaky / `:` for visarga)
between a Myanmar-digit-converted syllable and a following Burmese
syllable, the rank-0 candidate's surface silently omits the tone
marker entirely. Both characters the user typed (the digit AND the
tone marker) are visible in the user's reading, but the tone marker
disappears from the produced surface — the digit is converted to
Myanmar form, the next syllable is glued to it, and the `.` / `:`
that the user typed has no visual representation in rank 0.

The literal-fallback candidate that contains the user's exact `.`
/ `:` is in the panel but at a lower rank than the tone-stripped
Myanmar surface. The user's keypresses are therefore visually
discarded by the rank-0 selection unless they manually choose the
literal candidate.

This is a different bug class from archived TASK-051 (digit-followed-by-
dep-vowel produces illegal storage order), TASK-052 (explicit `+`
between bare-vowel rules), and TASK-053 (kinzi displaced by trailing
tone marker). TASK-053 deals with the explicit-`+` shape; this task
deals with the digit-shape where the tone marker simply vanishes.

The bug is conditional on the LHS syllable producing a Myanmar-digit-
converted output. Specifically:

| Buffer        | Rank-0 surface (hex)                       | `.` preserved? |
|---------------|--------------------------------------------|----------------|
| `kar2.kar`    | `ကာ၂ကာ` (`1000 102C 1042 1000 102C`)        | NO — dropped  |
| `kar2:kar`    | `ကာ၂ကာ` (`1000 102C 1042 1000 102C`)        | NO — dropped  |
| `kar2.thar`   | `ကာ၂သာ` (`1000 102C 1042 101E 102C`)        | NO — dropped  |
| `kar2.aung`   | `ကာ၂အောင်` (`1000 102C 1042 1021 1031 102C 1004 103A`) | NO — dropped |
| `tar2.tar`    | `တာ၂တာ` (`1010 102C 1042 1010 102C`)        | NO — dropped  |
| `kar2.`       | `ကာ၂.` (`1000 102C 1042 002E`)              | YES (terminal) |
| `kar3.kar`    | `ကာ3.ကာ` (`1000 102C 0033 002E 1000 102C`) | YES (digit stays ASCII; full preserved) |
| `ka2.kar`     | `က2.ကာ` (`1000 0032 002E 1000 102C`)       | YES (digit stays ASCII) |
| `min2.ga`     | `မင်2.ဂ` (`1019 1004 103A 0032 002E 1002`) | YES (digit stays ASCII) |

The pattern: when the LHS syllable carries an open dep-vowel (`ar`,
`ay`, etc.) and the digit converts to Myanmar form (`1042` for `2`,
no equivalent triggered for `3`), and a Burmese syllable follows the
tone marker, the `.` or `:` is consumed silently as a soft separator
instead of being preserved as either a tone or literal punctuation.

## Root Cause
The mid-buffer-digit splicing path (likely
`Engine/MidBufferDigits.swift` or the digit-pickup logic in the
parser materialiser) treats the digit as a literal scalar and inserts
it at the typed position; when a `.` or `:` immediately follows the
digit, the connector-collapsing pass appears to fold the punctuation
into the syllable break instead of either (a) attaching it as a
tone to the prior open-vowel syllable, (b) emitting it as a literal
character, or (c) deferring to the literal-fallback path.

The carve-out is missing: digit + tone-mark + Burmese-onset is a
shape where the tone CANNOT compose onto the digit (digits don't
carry tone) and SHOULD survive as literal punctuation between the
digit and the next syllable, exactly as `kar2.` produces `ကာ၂.` at
the buffer terminus and `ka2.kar` (no `r`) produces `က2.ကာ` (digit
stays ASCII because the digit-to-Myanmar conversion gate isn't
triggered).

## Burmese Language Rule Reference
CLAUDE.md §3 ("Digits Are Literal"): *"a digit never anchors asat
or dependent marks."* By extension, a digit also never anchors a
tone (which is rendered as `1037`/`1038` and is a dep-vowel-class
suffix). The tone marker that the user typed after a digit must
therefore EITHER (a) attach to the syllable BEFORE the digit (only
if the digit can be peeled off as a discrete scalar), OR (b) survive
as a literal `.` / `:` character in the surface. Silently dropping
the marker is not a legal outcome.

CLAUDE.md §4 ("Punctuation and Tones"): *"Literal punctuation stays
literal when it is a document-punctuation tail, part of a literal
split, or an English contraction / ASCII run."* A `.` between a
digit and a Burmese syllable is a literal-split shape; it must
remain in the surface.

## Steps to Reproduce
1. Build the production-equivalent engine with bundled artifacts:
   `BurmeseEngine(candidateStore: SQLiteCandidateStore(...),
   languageModel: TrigramLanguageModel(...))`.
2. For each buffer in the table above (e.g. `kar2.kar`,
   `tar2.tar`, `kar2:kar`), call
   `engine.update(buffer: input, context: [])`.
3. Inspect `state.candidates[0].surface` and confirm the `.` / `:`
   that the user typed (input position 5) is missing from the
   scalar sequence.
4. Confirm `state.candidates[2].surface` (the literal fallback)
   does contain the `.` / `:` — proving the user's input is preserved
   somewhere but not at rank 0.

## Current State
- Rank-0 surface omits the user-typed `.` / `:` between Myanmar
  digit and following Burmese syllable.
- Literal fallback (containing the punctuation) is at rank 2,
  below two Myanmar-digit-bearing variants that both omit the
  punctuation.
- Behaviour is asymmetric: digit-as-ASCII variant (`kar3.kar`,
  `ka2.kar`, `min2.ga`) keeps the `.` literal; only the
  digit-as-Myanmar-converted variant (`kar2.kar`, `tar2.tar`,
  etc.) drops it.

## Desired State
- Rank-0 surface contains the user-typed `.` / `:` as a literal
  character between the Myanmar digit and the following syllable
  (equivalent to the `kar3.kar` shape that already works correctly
  with ASCII digit `3`).
- `tar2.tar` should produce `တာ၂.တာ` (`1010 102C 1042 002E 1010 102C`)
  at rank 0 — Myanmar digit followed by literal `.` followed by next
  syllable.
- `kar2:kar` should produce `ကာ၂:ကာ` (`1000 102C 1042 003A 1000 102C`)
  at rank 0.
- The two-syllable Burmese candidates without the punctuation may
  remain in the panel (they represent a "drop the punctuation"
  variant) but must not be rank 0 when the user has explicitly
  typed a tone-class punctuation between non-tone-able elements.

## Acceptance Criteria
- For `kar2.kar`, `tar2.tar`, `thar2.thar`, `kar2:kar`, `kar2.aung`,
  `kar2.thar`, `myar2.kar`, `lar2.lar`, `phar2.phar` (and the
  doubled `:` variants), the rank-0 surface contains the user-typed
  `.` / `:` scalar.
- The literal-fallback rank position is unchanged or improved (the
  literal must still be reachable in the panel).
- Carve-out cases that already work correctly remain unchanged:
  - `kar2.` (terminal `.` already kept) → still `ကာ၂.`
  - `kar3.kar` (digit `3` stays ASCII) → still `ကာ3.ကာ`
  - `ka2.kar` (no LHS open-vowel, digit stays ASCII) → still `က2.ကာ`
  - `thar.kar` (no digit, `.` is creaky tone) → still `သ့ကာ`
- TASK-053's kinzi-with-tone-marker tests stay green.
- All `MidBufferDigit*Suite`s, `TrailingDigitPunctSuite`, and
  `MidBufferPunctuationSuite` stay green.

## Notes
- Code locations to investigate:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/MidBufferDigits.swift` —
    digit-to-Myanmar conversion and splicing
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/PunctuationHandling.swift` —
    tone-marker-vs-literal disambiguation
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/InputNormalization.swift::collapseConnectorRuns` —
    likely candidate for the silent drop (the connector-collapse
    pass may be folding the `.` / `:` into a separator when the
    LHS just produced a digit-converted syllable)
- Probe data (production engine, `BurmeseEngine` with bundled
  artifacts):
  ```
  kar2.kar  -> [0] ကာ၂ကာ  (1000 102C 1042 1000 102C)        reading=kar2.kar
            -> [2] kar2.kar (literal, contains the dot)
  kar3.kar  -> [0] ကာ3.ကာ (1000 102C 0033 002E 1000 102C)   reading=kar3.kar  ← correct shape for comparison
  ```
- Differential between `2` and `3` suggests the trigger is the
  Myanmar-digit-conversion gate for `2`. The `2` is also a variant
  selector in many internal keys (`t2`, `n2`, `ky2`, `ay2`, `u2`),
  so the digit-pickup machinery may be conflating the variant-
  selector role with the literal-digit role only for `2`. The
  user-facing rule (CLAUDE.md §3) is unambiguous: a digit at the
  user-typed position is data, not a variant selector.
- This bug is independent of TASK-051 (which fixed dep-vowel
  ordering after digits) and TASK-053 (which fixed kinzi
  displacement by trailing tone). TASK-051 ensures the digit
  doesn't anchor the dep-vowel; TASK-054 ensures the *tone
  marker* between digit and next syllable doesn't vanish.

## Validation Notes

### Validity verdict
**Valid.** Bug confirmed against `main` (commit `fdd6541`) using both
the bare engine and the production-equivalent engine with bundled
artifacts. The same rank-0 surface omits the user-typed `.` / `:` in
both layers, so the bug is in the parser/normalizer pipeline (not
LM-driven). Verified additionally that:

- `kar.kar` (no digit) → `ကာ့ကာ` correctly absorbs `.` as creaky tone
  on the prior syllable. So the engine HAS a working path for this
  shape; the digit specifically blocks it.
- `kar2..` → `ကာ၂..` and `ka..tar` → `က..တာ` correctly preserve
  doubled `.`. Only the SINGLE `.` between Myanmar digit and next
  syllable vanishes.
- `kar3.kar` (digit `3`) → `ကာ3.ကာ` keeps both digit-as-ASCII and
  literal `.`. Only the digit-as-Myanmar-converted variants (`2`,
  which converts via the `ar2` family) trigger the loss.

### Underlying cause hypothesis (refined)
The romanization rule table contains `ar2.` → `ါ့` (`102B 1037`,
aa-shape + creaky tone) at `Romanization.swift:223`. The string
`kar2.kar` could in theory parse as `k + ar2. + kar`, producing
`ကါ့ကာ` (`1000 102B 1037 1000 102C`). But the rank-0 surface is
`ကာ၂ကာ` (digit-as-Myanmar), which means the parser is choosing the
`kar` + `2` + ??? + `kar` segmentation. The `.` is dropped because
the parser consumed `kar` (claiming the `ar` as `102C`), then `2` as
a digit, and the trailing `.` has no rule that fires after a digit —
it gets silently dropped instead of being preserved as literal.

The fix should ensure that when the rule path consumes `<C>ar` (or
similar open-vowel) plus a digit and is followed by a non-composable
character, that non-composable character is either (a) preserved as
literal in the surface, or (b) the alternate parse `<C> + ar2. +
<next>` is preferred when it produces a complete-tone surface. The
ASCII-digit variant at rank 1 (`ကာ2ကာ`) ALSO drops the `.`, which
shows the bug is not the digit-conversion gate alone but the
literal-preservation pass after a digit.

### Scope assessment
Original scope is correct. The 9 buffers in the table are
representative of the general class `<C>(open-vowel-with-tone-eligible-
shape)<digit-2><tone-or-other-punct><next-syllable>`. Added `myar`,
`lar`, `phar` to widen onset coverage; the bug fires uniformly on all.

### Examples augmented
Added `myar2.kar`, `lar2.lar` to confirm the bug is onset-independent.
Verified the bug does NOT fire when the LHS open vowel is closed (no
test for that exists, but `min2.ga` → `မင်2.ဂ` shows the digit stays
ASCII when LHS has a coda, and the `.` is preserved). The fix scope
is limited to the open-vowel-LHS shape.

### Acceptance criteria refinement
Added a stronger universal criterion: `for any buffer of shape
<onset><open-vowel-mark><digit><tone-or-punct><next-onset><vowel-mark>,
rank-0 surface contains the user-typed tone-or-punct scalar somewhere
in the output OR the literal-fallback (preserving the punct) is at
rank 0.` This generalises the table.

### No conflicting test
Searched `MidBufferPunctuationSuite`, `MidBufferDigit*Suite`,
`TrailingDigitPunctSuite`, `DigitDepVowelAnchorSuite`,
`MidBufferLiteralPunctSuite`. None pin the rank-0 behavior for the
`<C>ar<digit><.><C>...` shape, so the fix has no test conflict.
`TrailingDigitPunctSuite` shows `12.` → `၁၂.` is the desired pattern
for trailing punct after Myanmar digits — the same pattern should
extend to mid-buffer.

### Open questions resolved
- Q: Is the missing `.` an attempt by the engine to interpret it as a
  tone on the PRIOR open-vowel syllable (analogous to `kar.kar` →
  `ကာ့ကာ`)? A: No — the rank-0 surface has no `1037`/`1038` scalar
  on the LHS syllable. The `.` is fully silenced.
- Q: Does the bug fire only for digit `2`? A: Confirmed digits other
  than `2` (e.g. `3`) keep ASCII form and the `.` is preserved
  (`kar3.kar` → `ကာ3.ကာ`). The `2`-specific path comes from the `ar2`
  alias in `Romanization.swift`, but the bug is NOT that the alias
  fires — the alias does NOT fire (otherwise we'd see `ကါ့`); rather,
  the `.` is lost during digit-aware reassembly.

## Implementation Notes

The bug lived in `composeLetterRunsInTail` /
`emitLetterRun` (`Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/MidBufferDigits.swift`).

For a buffer like `kar2.kar`, the digit `2` breaks the composable
prefix at `kar` (digits are not in `Romanization.composingCharacters`),
leaving the literal tail `2.kar`. The tail composer then iterated:

- `2` (non-composing) → flushed as literal, set
  `prevNonComposingWasAsciiDigit = true`.
- `.kar` (composing letter run) → handed to `composedLetterRunSurface`
  with `preserveLeadingAsterisks = true`.

`composedLetterRunSurface` parsed `.kar` and the parser silently
consumed the leading `.` via a `.skip` arc, returning just `ကာ`
(`1000 102C`). The user-typed `.` vanished even though the existing
`preserveLeadingAsterisks` branch was already in `emitLetterRun` to
prevent the analogous `<digit>*` problem.

The fix extends the same leading-`*` peel in `emitLetterRun` to also
peel leading `.` and `:` chars when the previous non-composing char
was an ASCII digit. The justification mirrors the existing rule
(CLAUDE.md §3 — "a digit never anchors asat or dependent marks");
tone scalars `1037` / `1038` are dep-vowel-class, so a `.` / `:`
directly after a digit cannot legally compose and must surface as
literal punctuation.

Files changed:
- `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/MidBufferDigits.swift`
  (`emitLetterRun`)
- `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/MidBufferDigitTonePunctSuite.swift`
  (new test suite)
- `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/BurmeseTestSuites.swift`
  (suite registration)

## Validation Report

**Verdict: FULLY_COVERED**

- Acceptance criteria: every required buffer (`kar2.kar`, `tar2.tar`,
  `thar2.thar`, `kar2:kar`, `kar2.aung`, `kar2.thar`, `myar2.kar`,
  `lar2.lar`, `phar2.phar`) is covered in `MidBufferDigitTonePunctSuite`.
  Both the predicate test (`digitDirectlyFollowedByMyanmar` must be
  false) AND concrete scalar-hex equality assertions are present.
- Carve-outs are explicitly tested: `kar2.` (terminal `.`), `ka.kar`
  (creaky tone absorption), `thar.kar` (open-vowel-tone). All pass.
- Literal-fallback reachability is asserted for each bug buffer.
- Fix scope is correct: the change is in `emitLetterRun` which only
  fires for the post-digit letter-run shape — symmetric with the
  pre-existing `*` peel, so the rationale is consistent with TASK-008
  / TASK-052.
- No regressions: full test run is 1529/1529 cases / 8258/8258
  assertions. No prior tests were modified or removed; no benchmark
  baseline touched.
- Coverage: the new suite adds 5 test cases with a predicate-based
  invariant + scalar-equality + carve-out + literal-fallback +
  ASCII-variant rows, fully exercising both branches of the modified
  `while`-loop.
