# TASK-060: Tone-eligible LHS with doubled-dot or doubled-colon mid-buffer leaves the panel with no Burmese candidate

## Status
Completed

## Implementation Notes
Fixed in
`Engine/PunctuationHandling.swift::renderFrozenPunctSegments`:
added a `nextIsDocPunct(after:)` lookahead that gates the
`dotActsAsVowelModifier` / `colonActsAsVowelModifier` absorption.
When the very next character is also a composing-punct (`./`:`),
the renderer refuses to absorb the current `.` / `:` into the
`current` segment as a vowel-modifier — instead it flushes both
chars literally between the rendered Burmese syllables.

The asymmetry the fix addresses: pre-fix, on a buffer like
`kar..ka`, the renderer ate the first `.` into the `kar.` vowel
modifier (creaky tone), tried and failed to apply tone absorption
to the second `.`, then flushed the second `.` literally — leaving
the surface `ကာ့.က` whose `<tone> <punct> <Myanmar onset>` shape
the TASK-055 sanitiser correctly rejects. With no surviving
Burmese sibling, the panel collapsed to the literal raw buffer
only.

With the new lookahead, on `kar..ka`:
- `current="kar"` and the FIRST `.` is followed by another `.`, so
  the vowel-modifier absorption is gated off. The renderer flushes
  `current` as `ကာ` (no tone) and emits the `.` literally.
- The second `.` flushes literally too.
- Combined with the rendered active syllable, the panel carries
  `ကာ..က` (`1000 102C 002E 002E 1000`) — Burmese on both sides of
  the literal `..` punct run.

The fix preserves:
- Single-`.` / single-`:` tone absorption (`kar.kar` →
  `ကာ့ကာ`, `kar.thar.kar` → `ကာ့သာ့ကာ`) — the lookahead only
  fires when the IMMEDIATELY-following char is also `./:`, so
  single-tone sites keep their absorption.
- Tone-INELIGIBLE LHS shapes (`ka..tar` → `က..တာ`, pinned by
  `MidBufferPunctuationSuite`) — these never entered the
  vowel-modifier absorption branch in the first place.
- The TASK-055 tone-orphan-leak rejection (`kar.:kar`'s leaky
  `ကာ့:က` is still dropped) — the fix adds a non-leaky sibling
  (`ကာ.:က`) without weakening the sanitiser.

Coverage in `DoubledPunctVowelRuleSuite` (16 bug buffers spanning
the `ar`, `ay`, `o`, `u`, `i`, `aung` vowel-rule families plus
mixed-punct and trailing-tone shapes, with separate cases pinning
the single-tone-absorption and tone-ineligible-LHS controls).
Note: `kein..ka` is intentionally NOT in the bug-buffer list —
`kein` itself parses to a doubled-coda surface (`ကယ်င်`) that the
existing `sanitizeDoubledCodaChain` correctly rejects regardless
of the trailing punct shape; the TASK-060 fix has no effect on
that pre-existing parse-level issue.

## Problem Description
When the user types a buffer of shape
`<C><open-vowel-rule>..<C><any-tail>` or
`<C><open-vowel-rule>::<C><any-tail>` — i.e. an open-vowel syllable
with a tone-absorbing rule (`r` → `102C`, `ay` → `1031`, …) followed
by **doubled** identical document-punct (`..` or `::`, NOT mixed `.:`
or `:.`) and a following Burmese onset — the production engine returns
**only the literal raw buffer** at rank 0 and **no Myanmar candidate
at any rank**. The user's intended `ကာ..က` (open-vowel + literal `..`
+ next syllable) is unreachable.

This is the deliberately-uncovered tail of archived TASK-055
(tone-orphaned-punct leak). TASK-055 correctly rejects rank-0 surfaces
where the parser absorbs the first `.` / `:` as a tone scalar
(`1037` / `1038`) and strands the second between Myanmar scalars.
TASK-055's bug table only covered the **mixed-punct** shapes
(`thar.:kar`, `thar:.kar`, `kar.'kar`, `kar:'kar`, …); the suite
explicitly tested those.

The doubled-identical-punct shape is a different bug class:

| Buffer        | Rank-0 (current)               | Burmese in panel? |
|---------------|--------------------------------|-------------------|
| `kar..ka`     | literal `kar..ka` (002E twice) | NO                |
| `kar..thar`   | literal                        | NO                |
| `thar..tha`   | literal                        | NO                |
| `thar..thar`  | literal                        | NO                |
| `myar..ka`    | literal                        | NO                |
| `lar..lar`    | literal                        | NO                |
| `kar..k`      | literal                        | NO                |
| `tar..ka`     | literal                        | NO                |
| `kar.:ka`     | literal                        | NO                |
| `kar:.ka`     | literal                        | NO                |

Compare to working shapes:

| Buffer       | Rank-0                                            | Comment |
|--------------|---------------------------------------------------|---------|
| `ka..tar`    | `က..တာ` (`1000 002E 002E 1010 102C`)              | tone-INELIGIBLE LHS — pinned by `MidBufferPunctuationSuite` |
| `kar.kar`    | `ကာ့ကာ` (`1000 102C 1037 1000 102C`)              | single `.` cleanly absorbed as tone — pinned by `MidBufferPunctuation*Suite` |
| `kar.thar.kar` | `ကာ့သာ့ကာ`                                     | each `.` absorbs cleanly, no leak |

The pattern: for tone-INELIGIBLE LHS (`<C>a` shapes), `..`/`::`/`.:`/
`:.` between syllables flushes as literal at rank 0 and the parser
keeps a Burmese candidate. For tone-ELIGIBLE LHS (`<C><open-vowel>`)
with doubled punct followed by another Burmese onset, the parser
produces only tone-absorbed candidates (every one rejected by
TASK-055's sanitiser), and no "skip-tone-absorption" alternative
survives — the panel ends up with only the literal.

## Root Cause
The parser appears to NOT enumerate a "skip the optional tone
absorption" alternative when the LHS is tone-eligible AND followed by
doubled identical punct. Every parse path consumes the first `.` / `:`
as a tone (`1037` / `1038`) on the open-vowel syllable, leaving the
second `.` / `:` between the tone scalar and the next Myanmar onset.
TASK-055's `surfaceContainsInterleavedComposingPunct` (in
`Engine/SurfaceSanitizers.swift`) — specifically the new
`leftIsTone && hasRightMyanmar` branch around line 914 — correctly
rejects every such candidate. But there is no surviving alternative
parse to take its place, so all Burmese candidates get sanitised away.

The fix probably needs to live in the parser:
- Either enumerate a "literal-`..` / literal-`::` between syllables"
  alternative even when the LHS is tone-eligible (so the parser emits
  BOTH `kar.` (with tone) + `.` orphaned AND `kar` (no tone) + `..`
  literal), OR
- Detect doubled identical document-punct between Myanmar scalars in
  the parser's input normalisation pass and split the buffer at the
  doubled-punct boundary, so the LHS parses as `kar` (no tone) and
  the `..` becomes a literal-flush segment between syllables.

A pure sanitizer relaxation would re-introduce the TASK-055 leak it was
designed to prevent — the fix has to add a competing legitimate parse,
not weaken the rejection of the leaky one.

## Burmese Language Rule Reference
CLAUDE.md §2 ("Literal Fallback"): *"For non-empty typeable input, the
panel must not be empty."* The current behaviour technically satisfies
this — the panel has the literal candidate. But the spirit of the rule
is that the user's typeable Burmese-shape inputs should produce
Burmese candidates. The user typed `kar..ka` clearly expecting `ကာ..က`
(or `ကာ` + literal `..` + `က`); that surface is unreachable from any
candidate slot.

CLAUDE.md §1 ("Grammar and Sanitizers"): *"Sanitizers normally filter
only when at least one clean sibling survives. When every Myanmar
candidate is structurally bad, preserve the user's escape hatch by
promoting the raw literal fallback."* The sanitizer IS doing the
right thing (it correctly rejects the leaky surfaces); the bug is
upstream — the parser is not producing the clean sibling alternative.

CLAUDE.md §4 ("Punctuation and Tones"): *"`.` and `:` are composing
tone keys when they complete a Burmese syllable."* The first `.` in
`kar..` does complete a Burmese syllable, so absorption is allowed.
But it is not REQUIRED — the alternative interpretation (treat `..`
as a literal pair, do not absorb the first as tone) is a perfectly
valid parse and matches what `ka..tar` already does for the
tone-ineligible LHS shape.

## Steps to Reproduce
1. Build the bare engine `BurmeseEngine()` (the bug reproduces
   without lexicon / LM).
2. For each buffer in `{kar..ka, thar..thar, kar..thar, myar..ka,
   lar..lar, kar:.ka, kar.:ka}`, call
   `engine.update(buffer: input, context: [])`.
3. Inspect `state.candidates`. Confirm:
   - rank 0 == raw buffer string (literal fallback);
   - no candidate at any rank has a surface starting with a Myanmar
     scalar (every surface starts with the ASCII first byte of the
     reading).
4. Compare to `ka..tar` (tone-ineligible LHS) — that returns
   `က..တာ` at rank 0, proving the parser CAN produce the
   literal-`..`-between-Myanmar shape when the LHS doesn't tempt
   tone absorption.

## Current State
- `<C><open-vowel>..<C><...>` shapes: panel has only the literal
  raw buffer; no Burmese candidate at any rank.
- `<C><open-vowel>::<C><...>` shapes: same.
- `<C><open-vowel>.:<C><...>` and `<C><open-vowel>:.<C><...>`:
  same (covered by TASK-055 bug-shape but with NO surviving
  Burmese alternative). The TASK-055 suite asserts the leaky
  surface is rejected at all ranks but does not assert that any
  Burmese surface survives.
- Tone-INELIGIBLE LHS shapes (`ka..tar`, `ka::tar`, `ka.:tar`,
  `ka:.tar`) work correctly — `MidBufferPunctuationSuite`
  pinned.
- Single-`.` / single-`:` after tone-eligible LHS works correctly
  (`kar.kar` → `ကာ့ကာ`, `kar:kar` → `ကား` + something) — single
  punct is cleanly absorbed as tone.

## Desired State
- `kar..ka` rank 0 = `ကာ..က` (`1000 102C 002E 002E 1000`) — open
  vowel, literal `..`, next syllable.
- `thar..thar` rank 0 = `သာ..သာ` (`101E 102C 002E 002E 101E 102C`).
- `kar..thar` rank 0 = `ကာ..သာ`.
- `kar:.ka` and `kar.:ka` rank 0 = `ကာ:.က` / `ကာ.:က` (literal mixed
  punct between syllables; equivalent to TASK-055's "discard the
  leaky tone interpretation, pass punct through as literal"
  alternative). Note: TASK-055's tone-absorbed surface `ကာ့:က`
  must still be rejected; this task adds the missing alternative.
- The tone-absorbed surface (`ကာ့..` etc.) may exist as a lower-rank
  candidate or may be sanitised away — either is acceptable as long
  as the literal-`..` alternative is at rank 0.
- The literal raw buffer remains reachable in the panel as
  fallback.

## Acceptance Criteria
- For each buffer in `{kar..ka, kar..thar, thar..tha, thar..thar,
  myar..ka, lar..lar, kar..k, tar..ka, kar:.ka, kar.:ka,
  kar..ka:, kar.k.k}`, the panel contains at least one Myanmar
  candidate whose surface starts with a Myanmar scalar (U+1000..
  U+109F) AND whose surface contains the literal punct scalars
  the user typed.
- For each buffer, rank 0 may be either that Myanmar candidate
  OR the literal raw buffer; presence in the panel is the hard
  requirement.
- TASK-055's `ToneOrphanedPunctLeakSuite` stays green — no
  candidate at any rank may carry the tone-orphaned-leak shape
  (`<tone> <single-punct> <Myanmar>`).
- `MidBufferPunctuationSuite` pinned shapes (`ka..tar`, `ka::tar`,
  `ka.:tar`, `ka:.tar`, `ka'.tar`, `ka*.tar`) stay rank-0
  unchanged.
- TASK-054 `MidBufferDigitTonePunctSuite` stays green.

## Notes
- Code locations to investigate:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/SyllableParser.swift`
    — the rule-matching path that consumes `<C><open-vowel><.>` /
    `<C><open-vowel><:>` as tone absorption. Likely needs a sibling
    arc that emits the bare-vowel rule (`ar`, `ay`) and leaves the
    `.` / `:` for the literal-flush emit path, gated on the next
    char also being `.` / `:`.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/InputNormalization.swift`
    — alternatively, the input normaliser could detect the
    `<C><open-vowel><doubled-doc-punct><C>` shape and split the
    buffer at the doubled-punct boundary so each side parses
    independently and the doubled punct flushes as literal.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`
    — confirm the sanitizer doesn't need changes; the rejection is
    correct, the bug is the missing competing parse.
- Probe outputs (current `main`, commit `0f1a871`, bare engine):
  ```
  kar..ka     -> [0] kar..ka (literal)               ← BUG: no Burmese in panel
  kar..thar   -> [0] kar..thar (literal)             ← BUG
  thar..thar  -> [0] thar..thar (literal)            ← BUG
  myar..ka    -> [0] myar..ka (literal)              ← BUG
  lar..lar    -> [0] lar..lar (literal)              ← BUG

  ka..tar     -> [0] က..တာ (1000 002E 002E 1010 102C) ✓ (tone-ineligible LHS, pinned)
  kar.kar     -> [0] ကာ့ကာ (1000 102C 1037 1000 102C) ✓ (single tone absorbs)
  kar.thar.kar -> [0] ကာ့သာ့ကာ                       ✓ (each . absorbs cleanly)
  ```
- This bug class is small in absolute frequency (users rarely type
  `..` between syllables), but when they DO it's catastrophic — the
  IME shows them only the ASCII literal candidate, with no path to
  produce the Burmese surface at all. That's a worse outcome than
  the TASK-055 leak it replaced (where at least the panel had a
  Burmese candidate, even if leaky).
- The acceptance criterion "Burmese candidate exists in the panel"
  is the soft form of CLAUDE.md §7's general reachability rule.
  Promoting that Burmese candidate to rank 0 is preferred but not
  required.

## Validation Report

**Verdict:** FULLY_COVERED

- **Acceptance Criteria coverage:** All buffers from the task's
  acceptance list (`kar..ka`, `kar..thar`, `thar..tha`, `thar..thar`,
  `myar..ka`, `lar..lar`, `kar..k`, `tar..ka`, `kar:.ka`, `kar.:ka`,
  `kar..ka:`, `kar.k.k`) covered by `DoubledPunctVowelRuleSuite`'s
  `bugBuffers` array. Validation-notes-recommended coverage of all
  vowel-rule families (`ar`, `ay`, `o`, `aung`, `u`, `i`) is
  included via `kay..ka`, `ko..ka`, `kaung..ka`, `ku..ka`, `ki..ka`.
- **Fix locality:** Lives in `Engine/PunctuationHandling.swift::
  renderFrozenPunctSegments` as a 3-line lookahead gate
  (`nextIsDocPunct(after:)`). Surgical and correct — only fires when
  the immediately-following char is `./:`, preserving every other
  tone-absorption path.
- **Control case preservation:** `singleToneControls` (kar.kar,
  kar.thar.kar) and `toneIneligibleControls` (ka..tar) are both
  asserted in the suite, pinning that the fix doesn't break
  single-tone absorption or the pre-existing tone-ineligible LHS
  shape.
- **TASK-055 interaction verified:** The fix adds a non-leaky
  Burmese sibling without weakening the TASK-055 sanitiser. The
  `ToneOrphanedPunctLeakSuite` is still green in the full suite run,
  confirming the leaky `<tone> <punct> <Myanmar>` surface is still
  rejected at all ranks.
- **Out-of-scope deliberately documented:** `kein..ka` excluded
  because `kein` itself parses to a doubled-coda surface that the
  pre-existing `sanitizeDoubledCodaChain` rejects independently of
  this task.
- **Regressions:** None. Full suite 1543/1543 passes.

## Validation Notes
- **Validity:** Confirmed valid against current `main` (commit
  `fdd6541`). Reproduced on bare engine (`BurmeseEngine()`).
- **Critical scope correction (terminology fix):** The original task
  framed the bug class as "tone-eligible LHS with doubled punct".
  This is **incorrect** — bare-`<C>a` shapes ARE tone-eligible
  (`ka.tar` produces `က့တာ` with creaky tone absorbed, per
  `MidBufferPunctuationSuite` line 50/74). Yet `ka..ta` works
  correctly:
  ```
  ka..ta -> [0] က..တ (1000 002E 002E 1010)             OK
  ta..ka -> [0] တ..က (1010 002E 002E 1000)             OK
  ma..ka -> [0] မ..က (1019 002E 002E 1000)             OK
  ```
  The actual bug class is narrower: **multi-letter open-vowel rules
  that produce multi-scalar Burmese vowel surfaces** followed by
  doubled punct. Verified failures:
  ```
  kar..ka     -> literal only           ar  → 102C       FAIL
  kay..ka     -> literal only           ay  → 1031       FAIL
  ko..ka      -> literal only           o   → 102D 102F  FAIL
  kau..ka     -> ကု.က (one dot dropped) au → 102F       PARTIAL FAIL (different bug)
  ku..ka      -> ကု.က (one dot dropped) u   → 102F      PARTIAL FAIL (also surfaces only one dot!)
  ki..ka      -> ကိ.က (one dot dropped) i   → 102D      PARTIAL FAIL
  kaung..ka   -> ကောင့်.က (one dot dropped, one absorbed as tone) FAIL
  ```
  And working contrasts:
  ```
  ka..ta      -> က..တ                   OK (bare-<C>a, tone-eligible)
  k..k        -> က..က                   OK (single-letter onset, no vowel)
  ```
  So the trigger is: **a vowel rule with surface that is NOT just the
  default `<C>a` shape** (i.e., the rule absorbs more than just the
  bare `a`). This includes `ar`, `ay`, `o`, `u`, `i`, `aung`, `ein`,
  etc.
- **Secondary bug discovered:** `ku..ka`, `ki..ka`, `kau..ka` produce
  rank-0 surfaces with **only ONE dot** instead of two (e.g.
  `1000 102F 002E 1000` for `ku..ka` — input has two `.` but output
  has one). This is a separate dot-loss bug, not the literal-only
  panel bug. It is mentioned here as a related artifact but is NOT
  in scope for this task; the fixing agent should be aware that
  fixing the literal-only panel issue may also surface or interact
  with this dot-loss issue. If unsure, file a follow-up task.
- **Scope correction:** Updated the bug class description in the
  task body should be:
  - **Trigger:** `<C><multi-scalar-vowel-rule><doubled-identical-punct><C-or-EOS>`
    where the doubled punct is `..` or `::` (and the mixed-punct
    cases `:.`/`.:` from TASK-055).
  - **NOT triggered by:** bare-`<C>a` shapes (`ka..ta`, `ma..ka`),
    even though those are also tone-eligible.
  - The original framing accidentally promised over-coverage. The
    fixing agent should focus on the multi-scalar-vowel-rule class
    only.
- **Acceptance criteria:** The list of buffers
  `{kar..ka, kar..thar, thar..tha, thar..thar, myar..ka, lar..lar,
  kar..k, tar..ka, kar:.ka, kar.:ka, kar..ka:, kar.k.k}` is good but
  could be expanded to cover more vowel-rule shapes (`kay..ka`,
  `ko..ka`). The fixing agent SHOULD add at least one case from each
  of the major vowel-rule families: `ar`, `ay`, `o`, and one
  multi-letter (`aung` or `ein`).
- **Burmese rule references:** §1, §2, §4 cited correctly. §7
  (reachability) is the strongest argument here — the user's
  intended Burmese surface is unreachable from the panel at any
  rank, which is a hard reachability failure.
- **Application feature deliberation:** Could the literal-only
  outcome be deliberate, e.g. "doubled punct between syllables is
  always a sentence boundary, treat as ASCII"? No. The
  `ka..tar` → `က..တ` rank 0 (pinned by `MidBufferPunctuationSuite`)
  proves the engine DOES intentionally produce mid-buffer-punct
  Burmese candidates for doubled `..`. The bug is the asymmetric
  failure for vowel-rule LHS shapes only.
- **Changes made:** Status updated to `Revised`. Validation Notes
  add the critical scope correction (the bug class is narrower than
  "tone-eligible LHS"), document the secondary dot-loss bug for
  awareness, and recommend expanded acceptance-criteria buffers.
  The fixing agent should treat the bug-class description in this
  Validation Notes section as authoritative over the original
  Problem Description framing.
