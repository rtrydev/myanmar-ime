# TASK-055: Tone-orphaned-punct leak — when one of two adjacent composing-punct chars consumes as a tone (`1037`/`1038`), the OTHER survives between Myanmar scalars

## Status
Completed

## Problem Description
When a buffer contains the shape
`<C><open-vowel-rule><punct1><punct2><C><V>` and `<punct1>` is
absorbable as a tone (`.` → creaky `1037`, `:` → visarga `1038`)
on the open-vowel syllable, the tone consumption fires correctly
but `<punct2>` is left orphaned as an ASCII scalar (`002E`,
`003A`, or `0027`) directly between two Myanmar scalars — the
final-tone scalar (`1037`/`1038`) and the next syllable's onset.
This violates the script-purity invariant from CLAUDE.md §1.

For comparison the simpler `<C><a><punct><punct><C><V>` shape
(no tone-eligible LHS) is **deliberately handled as a literal
flush** by `MidBufferPunctuationSuite` — `ka'.tar` → `က'.တာ`,
`ka..tar` → `က..တာ`, `ka.:tar` → `က.:တာ` are pinned as
expected and represent intentional product behavior. **Those
shapes are NOT in scope for this task.**

The bug fires when the open-vowel syllable IS tone-eligible (`thar`,
`kar`, `myar`, `lar`, …) so the FIRST punct consumes correctly but
the SECOND is left between Myanmar scalars:

| Buffer       | Rank-0 surface (hex)                                 | Defect |
|--------------|------------------------------------------------------|--------|
| `thar.:kar`  | `သာ့:ကာ` (`101E 102C 1037 003A 1000 102C`)          | `.` consumes as creaky, `:` leaks between `1037` and `1000` |
| `thar.'kar`  | `သာ့'ကာ` (`101E 102C 1037 0027 1000 102C`)          | `.` consumes as creaky, `'` leaks |
| `thar:.kar`  | `သား.ကာ` (`101E 102C 1038 002E 1000 102C`)          | `:` consumes as visarga, `.` leaks |
| `thar:'kar`  | `သား'ကာ` (`101E 102C 1038 0027 1000 102C`)          | `:` consumes as visarga, `'` leaks |
| `kar.:kar`   | `ကာ့:ကာ` (`1000 102C 1037 003A 1000 102C`)          | `.` consumes, `:` leaks |
| `kar:.kar`   | `ကား.ကာ` (`1000 102C 1038 002E 1000 102C`)          | `:` consumes, `.` leaks |
| `kar.'kar`   | `ကာ့'ကာ` (`1000 102C 1037 0027 1000 102C`)          | `.` consumes, `'` leaks |
| `kar:'kar`   | `ကား'ကာ` (`1000 102C 1038 0027 1000 102C`)          | `:` consumes, `'` leaks |
| `myar.:kar`  | `မြာ့:ကာ` (`1019 103C 102C 1037 003A 1000 102C`)    | medial onset, same leak |
| `lar.:lar`   | `လာ့:လာ` (`101C 102C 1037 003A 101C 102C`)          | same leak with `lar` onset |

Each rank-0 surface contains an ASCII composing-punct scalar (`0027`,
`002E`, `003A`) immediately between two Myanmar scalars (U+1000–U+109F),
which is exactly the script-purity violation that the existing
`sanitizeInterleavedComposingPunct` sanitizer was meant to catch.

This is the deliberately-uncovered tail of archived TASK-056
(doubled-asterisk-apostrophe leak). TASK-056's notes explicitly
flagged: *"Single-`*` mid-buffer with leading `.` like `kar:.*ar` →
`ကား.*အာ` … still has interleaved `.*` between Myanmar segments
because the run has only ONE strict-consume char."* The
sanitizer's strict-consume threshold doesn't fire when only ONE
ASCII punct survives the tone-consumption pass.

## Root Cause
The `sanitizeInterleavedComposingPunct` predicate
(`Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`,
introduced in archived TASK-056) requires the punct-run between two
Myanmar scalars to contain *at least one `*` (asterisk) OR ≥2 strict-
consume chars (`*` or `'`)*. After tone-consumption fires (the FIRST
of the two punct chars is absorbed into a `1037`/`1038` scalar
attached to the prior syllable), only a SINGLE punct survives in the
surface — and that single survivor falls below the predicate's
threshold even though it now sits between Myanmar scalars (the tone
scalar U+1037/U+1038 IS in the Myanmar range, and so is the next
syllable's onset).

The predicate's rationale was to preserve the legitimate document-
punctuation passthroughs from `MidBufferPunctuationSuite`. Those
passthroughs are intact and must remain — they fire in the shape
`<C>(a or short bare onset)<punct><punct><C><V>` where NO tone
absorption happens (the LHS is a bare consonant + inherent-a, which
is not tone-eligible). The bug shape is different: the LHS IS tone-
eligible (carries an open vowel like `ar`/`ay`), so one punct gets
absorbed and the other is left orphaned BETWEEN Myanmar scalars in
the rendered surface — exactly the script-purity violation pattern.

Distinguishing the two shapes:
- `ka'.tar` → `က'.တာ` (legitimate, `MidBufferPunctuationSuite`
  pinned). LHS `ka` did not absorb a tone; the `'.` flushes as
  literal between `1000` and `1010`.
- `kar.:kar` → `ကာ့:ကာ` (bug). LHS `kar.` absorbed `.` as creaky
  tone (`1037`); the surviving `:` sits between `1037` and `1000`.

## Burmese Language Rule Reference
CLAUDE.md §1 ("Grammar and Sanitizers"): the rejected-shapes list
includes *"composing punctuation (`*`, `'`, `:`, `.`) wedged between
Myanmar scalars"*. The current sanitizer enforces this for the
`*`-bearing subset and the doubled-`'` subset; mixed runs with
just `.`+`'`, `:`+`'`, `.`+`:`, or `:`+`.` are not covered and
violate the invariant.

## Steps to Reproduce
1. Build any engine (`BurmeseEngine()` is sufficient — the bug
   reproduces on the bare engine).
2. Call `engine.update(buffer: "thar.:kar", context: [])`.
3. Inspect `state.candidates[0].surface`. Observe that the
   rank-0 surface contains `1037` (creaky tone, absorbed from `.`)
   followed by `003A` (orphaned `:`) between two Myanmar
   scalars.
4. Repeat for the buffers in the table above; each rank-0 surface
   contains exactly ONE ASCII composing-punct between Myanmar
   following a `1037` or `1038` tone scalar.

## Current State
- After tone-absorption fires on the FIRST punct of an open-vowel
  LHS, the SECOND punct survives as ASCII between Myanmar scalars
  in the rank-0 surface.
- The literal-fallback (containing the user's exact buffer) is
  in the panel but at a lower rank than the leaky Myanmar
  candidate.
- TASK-056 sanitizer correctly catches `tha**kar` (doubled `*`)
  and other shapes with ≥2 strict-consume chars; the gap is
  specifically in surfaces where tone absorption has reduced the
  punct run to a single survivor sitting between Myanmar scalars.

## Desired State
- Rank-0 candidate either:
  (a) Sanitises the leaky Myanmar surface and promotes the
      literal-fallback (preserving the user's exact buffer), or
  (b) Composes both punct chars meaningfully where possible: the
      first as tone (already works), the second as a separate
      tone or absorbed silently. E.g. `thar.:kar` could produce
      `သာ့ကာ` (`.` as creaky on `thar`, `:` silently dropped) or
      `သာ:ကာ` after the literal-fallback is promoted.
- The result must NOT contain a raw ASCII `'` / `.` / `:` scalar
  directly between two Myanmar scalars (per CLAUDE.md §1).
- `MidBufferPunctuationSuite`'s legitimate passthroughs
  (`ka'.tar`, `ka..tar`, `ka::tar`, `ka.:tar`) must remain
  unchanged — those are tone-INELIGIBLE LHS shapes and are
  pinned as deliberate behavior.

## Acceptance Criteria
- For each buffer in the table, the rank-0 surface contains no
  scalar in {`0027`, `002E`, `003A`} immediately between two
  scalars in U+1000–U+109F (the tone scalars `1037`/`1038`
  count as Myanmar for this check).
- The literal-fallback (raw buffer) is reachable in the panel
  for every test buffer.
- Existing `DoubledLiteralPunctSuite`, `MidBufferPunctuationSuite`,
  `ApostropheLiteralSuite` cases remain green.
  - **Specifically**: `ka'.tar` → `က'.တာ`, `ka..tar` → `က..တာ`,
    `ka::tar` → `က::တာ`, `ka.:tar` → `က.:တာ` MUST remain rank-0
    unchanged (they are tone-ineligible-LHS passthroughs).
- Add a regression suite that scans every rank for the bug
  predicate (extended to detect a single composing-punct between
  Myanmar scalars where the predecessor is `1037`/`1038`) and
  asserts no candidate at any rank carries the bug shape for the
  buffers in the table.

## Notes
- Code locations:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`
    — extend `surfaceContainsInterleavedComposingPunct` to flag
    a single composing-punct (`'`/`.`/`:`) sitting between a
    tone scalar (`1037`/`1038`) and a Myanmar onset, OR more
    generally between any two Myanmar-range scalars when the
    predecessor scalar is a tone scalar.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/PunctuationHandling.swift`
    — alternatively, the punctuation handler that absorbs the
    first `.`/`:` as tone could ALSO consume the trailing punct
    (drop or fold) so the leak never enters the surface.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/DoubledLiteralPunctSuite.swift`
    — add the new bug-input rows.
- The fix MUST preserve the deliberate carve-out from `MidBuffer
  PunctuationSuite` (lines 49-59 of the suite): doubled / mixed
  punct runs in the `<C>(a)<punct><punct><C><V>` shape (tone-
  INELIGIBLE LHS) flush as literal. The bug here is specifically
  the `<C>(open-vowel)<punct><punct><C><V>` shape where tone
  absorption fires and the surviving punct ends up between
  Myanmar in the surface.
- Discrimination criteria for the new predicate:
  - LHS is tone-eligible AND first punct is `.`/`:` AND second
    punct survives between Myanmar in surface → bug, sanitize.
  - LHS is tone-INELIGIBLE (bare `<C>a` or just `<C>`) → flush
    as literal, do not flag (existing behavior).
- Probe outputs reproducible against current `main`
  (commit `fdd6541`):
  ```
  thar.:kar -> [0] သာ့:ကာ (101E 102C 1037 003A 1000 102C)  reading=thar.:kar  ← BUG
  thar:.kar -> [0] သား.ကာ (101E 102C 1038 002E 1000 102C)  reading=thar:.kar  ← BUG
  thar.'kar -> [0] သာ့'ကာ (101E 102C 1037 0027 1000 102C)  reading=thar.'kar  ← BUG
  thar:'kar -> [0] သား'ကာ (101E 102C 1038 0027 1000 102C)  reading=thar:'kar  ← BUG

  ka'.tar  -> [0] က'.တာ  (1000 0027 002E 1010 102C)  ← LEGITIMATE (pinned)
  ka.:tar  -> [0] က.:တာ  (1000 002E 003A 1010 102C)  ← LEGITIMATE (pinned)
  ka..tar  -> [0] က..တာ  (1000 002E 002E 1010 102C)  ← LEGITIMATE (pinned)
  ```

## Validation Notes

### Validity verdict
**Revised — partially valid.** Original task scope was too broad. It
conflated two distinct shapes:

1. `<C>a + mixed-punct + <C><V>` (e.g. `tha'.kar`, `ka.:tar`) →
   **NOT a bug.** This is explicitly pinned as desired behavior in
   `MidBufferPunctuationSuite` (lines 49-59 of the suite),
   `MidBufferPunctuationSuite.swift:53` `("ka'.tar", "က'.တာ")`. The
   suite comment states: *"Doubled / mixed punct runs (`..`, `::`,
   `.:`) and runs that include `*` / `'` continue to flush as
   literal because they cannot all act as a single tone marker."*
   Rows for `tha'.kar`, `tha.'kar`, `tha:.kar`, `tha.:kar`,
   `ka'.thar`, `ka.'thar` were REMOVED from the bug table.

2. `<C>(open-vowel) + punct1 + punct2 + <C><V>` (e.g. `thar.:kar`,
   `kar.'kar`) → **VALID bug.** Tone absorption fires on the first
   punct (producing `1037`/`1038`), but the second punct is left
   as ASCII between two Myanmar scalars. This violates CLAUDE.md §1
   script-purity. New rows for `kar.:kar`, `kar:.kar`, `kar.'kar`,
   `kar:'kar`, `myar.:kar`, `lar.:lar` were added; the original
   `thar.:kar`, `thar.'kar`, `thar:.kar`, `thar:'kar` are kept.

### What changed
- Title and Problem Description rewritten to specifically describe
  the tone-orphaned-punct shape, not the general "mixed punct"
  class.
- Bug table reduced to only the tone-eligible-LHS shapes.
- Acceptance criteria added explicit guard: `MidBufferPunctuation
  Suite`'s `ka'.tar` / `ka.:tar` / `ka..tar` / `ka::tar` shapes
  must remain rank-0 unchanged.
- Notes section discriminates the legitimate vs buggy shapes by
  LHS tone-eligibility.

### Code reference confirmed
`MidBufferPunctuationSuite.swift:38-59` pins `ka'.tar` → `က'.တာ`,
`ka..tar` → `က..တာ`, `ka::tar` → `က::တာ`, `ka.:tar` → `က.:တာ`. The
suite comment explicitly documents that doubled/mixed punct runs
flush as literal because they cannot all act as tone markers — that
IS the deliberate decision, and the new task respects it.

`SurfaceSanitizers.swift::surfaceContainsInterleavedComposingPunct`
(introduced in archived TASK-056) requires ≥2 strict-consume chars
or `*` in the run; the bug here has exactly ONE punct after tone
absorption, so the predicate doesn't fire.

### Burmese rule references
CLAUDE.md §1 reference is correct — script-purity invariant. CLAUDE.md
§4 ("Punctuation and Tones") is also correct: `.` and `:` are
composing tone keys when they complete a Burmese syllable. The first
punct correctly composes; the second has no defensible composition
target and should NOT survive as ASCII between Myanmar.

### Open questions resolved
- Q: Why does `tha.kar` (single `.`) work correctly (`သ့ကာ`)? A:
  Single `.` after `tha` (bare-`<C>a`) consumes as creaky tone per
  TASK-032; the surface has `1037` between `101E` and `1000`. No
  ASCII leaks.
- Q: Why does `thar.kar` (single `.`, open-vowel LHS) work? A: Same
  as above but with `ar` already consumed as `102C`; `.` consumes
  as creaky. `thar.kar` → `သာ့ကာ` (`101E 102C 1037 1000 102C`),
  no ASCII leak.
- Q: Why does the second punct leak when the first consumes? A: The
  punctuation handler peels one `./:` for tone-absorption and emits
  the tone scalar; the trailing punct is then re-routed through the
  literal-flush path (which is why `ka..tar` works correctly when
  NEITHER consumes), but the literal-flush path doesn't realise that
  the prior scalar in the surface has just become tone-emitted
  Myanmar `1037`/`1038`. So the trailing punct ends up between two
  Myanmar scalars instead of between a Latin `a` and the next
  consonant (the case the literal-flush was designed for).

## Implementation Notes

The bug lived in
`surfaceContainsInterleavedComposingPunct`
(`Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`).
The pre-fix predicate flagged a leak only when:

- the punct run contained `*` (any count), OR
- the run had ≥2 strict-consume chars (`''`), OR
- a pure doc-punct run trailed a Myanmar tone scalar with NO right-side
  Myanmar (TASK-040).

After tone absorption peels one `.`/`:` onto the prior syllable as
`1037`/`1038`, the surviving punct in the bug shape is exactly ONE
char. None of the three thresholds fired, so the leaky surface
(`<tone-scalar><002E|003A|0027><Myanmar onset>`) survived as the
rank-0 candidate.

The fix adds two new branches keyed on the tone-scalar predecessor:

1. In the doc-punct branch: when the run contains doc-punct AND the
   left side is a tone scalar AND there IS right-side Myanmar, that
   is the TASK-055 leak — return true.
2. In the pure strict-consume branch: when the left side is a tone
   scalar and there IS right-side Myanmar, even a single-char run
   (`'` or doubled-strict) is a leak — return true.

The discriminator (left-side tone scalar) keeps the
`MidBufferPunctuationSuite` carve-outs intact: those cases have
tone-INELIGIBLE bare-`<C>a` LHS, so no tone absorption fires and
the predecessor is a bare consonant, not a tone scalar — the new
branches don't trigger and the existing literal-flush path runs.

Files changed:
- `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`
  (`surfaceContainsInterleavedComposingPunct`)
- `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/ToneOrphanedPunctLeakSuite.swift`
  (new test suite)
- `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/BurmeseTestSuites.swift`
  (suite registration)

## Validation Report

**Verdict: FULLY_COVERED**

- Acceptance criteria: every bug-class buffer in the revised table
  (`thar.:kar`, `thar.'kar`, `thar:.kar`, `thar:'kar`, `kar.:kar`,
  `kar:.kar`, `kar.'kar`, `kar:'kar`, `myar.:kar`, `lar.:lar`) is
  asserted via `hasToneOrphanedPunctLeak` in
  `ToneOrphanedPunctLeakSuite`. The all-rank scan asserts NO candidate
  at any rank carries the leak shape (stronger than the original
  rank-0-only criterion).
- Tone-INELIGIBLE LHS pinned shapes from `MidBufferPunctuationSuite`
  (`ka'.tar`, `ka..tar`, `ka::tar`, `ka.:tar`, `ka*.tar`) are
  explicitly asserted with scalar-hex equality, ensuring the
  deliberate carve-out is preserved.
- Predicate sanity test is included to validate the suite's own
  `hasToneOrphanedPunctLeak` detector against both true and false
  cases.
- Discriminator design is sound: the `leftIsTone && hasRightMyanmar`
  branch fires only when the predecessor scalar is a Myanmar tone
  (`1037`/`1038`), which structurally cannot occur for tone-ineligible
  bare-`<C>a` LHS shapes. This matches the task's stated
  discrimination rule.
- No regressions: full test run is 1529/1529 cases / 8258/8258
  assertions. `MidBufferPunctuationSuite`, `DoubledLiteralPunctSuite`,
  `ApostropheLiteralSuite` are all green.
- Coverage: 5 test cases including the all-rank scan (multiplied across
  10 buffers) and the predicate-self-test guarantees both new branches
  in `surfaceContainsInterleavedComposingPunct` are exercised.
