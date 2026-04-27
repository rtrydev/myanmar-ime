# TASK-018: Mid-buffer inherent-A chain longer than the right-shrink window leaks the entire trailing buffer as raw ASCII

## Status
Completed

## Problem Description
TASK-016 fixed the `<C>aa` / `<C>aaa` "silent collapse" pathology by
rejecting chained inherent-`a` arcs in the DP and letting the
right-shrink probe drop the trailing `a`(s) into the literal tail
where `composeLetterRunsInTail` re-renders them as a visible
independent vowel.

That fix works for trailing chains of up to ~4-5 `a`s. Beyond that
threshold, **and when the buffer continues with more letters past
the chain**, the engine catastrophically dumps the entire post-`<C>`
portion of the buffer as **raw ASCII letters** at rank 0.

Concrete reproductions (verified 2026-04-27):

| Buffer | Chars | Rank-0 surface | Hex |
|---|---|---|---|
| `kaakaa`     | 6 | `ကက`            | `1000 1000` (correct: chain → 1 indep-A absorbed, then `kaa` → `က`) |
| `kaaakaa`    | 7 | `ကက`            | `1000 1000` (correct) |
| `kaaaakaa`   | 8 | `ကက`            | `1000 1000` (correct) |
| `kaaaaakaa`  | 9 | `ကaaaakaa`      | `1000 0061 0061 0061 0061 006B 0061 0061` |
| `kaaaaaakaa` | 10 | `ကaaaaakaa`    | `1000 0061 0061 0061 0061 0061 006B 0061 0061` |
| `kaaaaakaaa` | 10 | `ကaaaakaaa`    | `1000 0061 0061 0061 0061 006B 0061 0061 0061` |

The same collapse fires for any consonant: `naaaaakaa` →
`နaaaakaa`, `haaaaakaa` → `ဟaaaakaa`, `thaaaaakaa` → `သaaaakaa`.

The **9-char threshold** is the critical regression boundary. At 8
chars the engine still produces clean Myanmar; at 9+ chars the
right-shrink probe peels the entire tail past the leading
consonant into the literal tail, and `composeLetterRunsInTail` is
gated off because the tail is "too long" — see the heuristic in
`update(buffer:context:)`:

```
let shouldComposeDroppedTail = !droppedTail.isEmpty
    && droppedTailHasComposingChars
    && (droppedTail.count <= 6 || droppedTailHasComposingPunctuation)
```

So when the dropped tail exceeds 6 chars and has no composing
punctuation, the literal-tail composer is skipped and the raw ASCII
falls through unchanged.

A pathological extreme: typing 18 `a`s after `k` (`kaaaaaaaaaaaaaaaaa`)
produces `ကaaaaaaaaaaaaaaaa` — 17 raw ASCII letters at rank 0, a
total breakdown for any user with auto-repeat enabled.

## Root Cause
1. The TASK-016 chained-inherent-A guard in
   `Parser/NBestDP.swift::runDP` rejects DP transitions where the
   second `a` would chain onto an existing inherent-`a` arc. Combined
   with the right-shrink probe in
   `parseLongestAcceptablePrefix`, the parser settles on the
   **shortest** acceptable prefix — typically `k` + first `a` — and
   the rest of the buffer becomes the dropped tail.
2. `composeLetterRunsInTail` (in `Engine/MidBufferDigits.swift`) is
   the engine's fallback for re-rendering dropped letters as Myanmar.
   It is **gated off** when the dropped tail is longer than 6 chars
   and has no composing punctuation, on the assumption that long
   dropped tails are pure-ASCII garbage (English mid-buffer text).
3. The 6-char gate is a heuristic from a different feature
   (English-text passthrough). It conflicts directly with TASK-016's
   contract that "dropped chained-`a` letters re-render as visible
   Myanmar." For inputs whose chain is short enough to keep the
   dropped tail ≤ 6 chars, both fixes coexist; once the chain crosses
   the threshold, the literal-fallback path leaks raw ASCII.
4. The 9-char threshold is the buffer length at which the dropped
   tail crosses 6 chars (`kaaaaakaa` drops 8 chars: `aaaakaa`).

## Burmese Language Rule Reference
A user typing on a phone or with auto-repeat may produce a long
chain of identical letters with no Myanmar interpretation. The
expected behaviour is one of:

1. Render the chain as a single visible Myanmar character (the
   TASK-016 fix's intent for short chains).
2. Render the chain as a single Myanmar character + truncated
   trailing tail (preserve the user's right-side context).
3. Refuse to commit any candidate that surfaces raw ASCII in
   place of what the user intended as Burmese letters — the user
   typed Roman keys to produce Burmese, not English text.

A surface like `ကaaaakaa` matches none of these. The user typed `k`
+ several `a`s + `k` + `a`s, all of which are valid Roman → Myanmar
keys; emitting raw ASCII here is a complete failure of the
romanization pipeline's promise.

## Steps to Reproduce
1. Open the IME with bundled lexicon and LM (or use bare
   `BurmeseEngine()` for an isolated test).
2. Type any buffer of the form `<C>` + ≥5 `a`s + `<C>` + ≥1 `a`
   (total length ≥ 9, e.g. `kaaaaakaa`, `naaaaakaa`).
3. Inspect rank-0 candidate surface — past the leading Myanmar
   consonant, every character is raw ASCII.

The transition is incremental: `kaaaaaka` (8 chars) → `ကက` (clean).
Adding one more letter (`kaaaaakaa`, 9 chars) → `ကaaaakaa`.

## Current State
- Buffers of the form `<C>aaaaa<rest>` (5+ `a`s, total ≥ 9 chars)
  emit raw ASCII at rank 0.
- The candidate panel offers no Burmese-only alternative — every
  ranked candidate carries the same ASCII tail.
- Auto-repeat or accidental key-hold makes this trivially
  reproducible by ordinary users.
- TASK-016's intended behaviour (drop trailing `a`s, render as one
  indep-A) only fires when the dropped tail is short enough to clear
  the 6-char gate.

## Desired State
- For any buffer with a long inherent-A chain, the engine continues
  to render visible Myanmar past the leading consonant. The trailing
  letters past the chain (e.g. `kaa` in `kaaaaakaa`) parse as
  Myanmar (`<C> + indep-A + <C> + indep-A` or a similar legal
  rendering).
- No candidate at any rank exposes raw ASCII letters in the middle
  of an otherwise-Burmese surface for inputs that contain only
  Roman composing characters (no digits, no literal punctuation).
- The 6-char `composeLetterRunsInTail` gate is widened, replaced by a
  composability check (the dropped tail contains only ASCII letters
  and at least one consonant), or both — whichever preserves
  English-passthrough for clearly non-Burmese buffers while letting
  the inherent-A chain unwind cleanly.

## Acceptance Criteria
- For every buffer matching `<C>a{5,}<C>a*`, the rank-0 surface
  contains no raw ASCII letters (every U+0041..U+007A scalar is
  absent past any Myanmar scalar).
- `kaaaaakaa` and longer variants produce a Myanmar-only surface
  whose scalar shape matches the canonical TASK-016 rendering of
  shorter cases (`k` + indep-A + `k` + indep-A or similar legal
  shape).
- The benchmark `repetition_t16` scenario does not regress.
- A new test suite under
  `Sources/BurmeseIMETestSupport/Suites/InherentAChainOverflowSuite.swift`
  iterates over all bare consonants (excluding medial-bearing keys)
  and asserts no rank-0 surface carries raw ASCII for buffers
  `<C>aaaaa<C>aa` through `<C>aaaaaaaaaa<C>aa`.
- `swift run TestRunner` continues to pass at 100%.

## Notes
- Code locations:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`
    around line 537 — the `shouldComposeDroppedTail` gate
    (`droppedTail.count <= 6 || droppedTailHasComposingPunctuation`)
    is the immediate suspect.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/MidBufferDigits.swift`
    `composeLetterRunsInTail` — owns the actual re-render logic.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/NBestDP.swift`
    `inherentAVowelId` guard — the upstream cause of long dropped
    tails for `aaaaa` buffers.
- The bug is durable across LM / lexicon updates (it's a structural
  pipeline gate, not a ranking decision).
- Related: TASK-016 explicitly carved out the buffer-leading
  `aa<...>` case so the leading-A promotion still produces U+1021;
  the issue here is that the *trailing* chain (post-consonant) hits
  the dropped-tail composer gate and falls through.

## Validation Notes

**Verdict: Valid (Revised).** Reproduced 2026-04-27. Probe results
match the table exactly:

```
kaakaa     -> 1000 1000           (clean, 6 chars)
kaaakaa    -> 1000 1000           (clean, 7 chars)
kaaaakaa   -> 1000 1000           (clean, 8 chars)
kaaaaakaa  -> 1000 0061 0061 0061 0061 006B 0061 0061  (regression, 9 chars)
naaaaakaa  -> 1014 0061 0061 0061 0061 006B 0061 0061  (same shape with na onset)
kaaaaaaaaaaaaaaaaa -> 1000 + 16x raw ASCII             (catastrophic)
```

**Code-reference verification:**
- `Engine/BurmeseEngine.swift` lines 537-539 — the
  `shouldComposeDroppedTail` gate is exactly as quoted:
  `(droppedTail.count <= 6 || droppedTailHasComposingPunctuation)`.
- `Engine/MidBufferDigits.swift::composeLetterRunsInTail` — owns
  the re-render path; confirmed.
- `Parser/NBestDP.swift::inherentAVowelId` guard at lines 447-454
  is the TASK-016 chained-inherent-A reject — confirmed.

**Burmese rule accuracy:** The desired-state framing (no raw ASCII
between Myanmar scalars in a Roman-only buffer) matches the
engine's overall pipeline contract documented in `CLAUDE.md` under
*Conversion pipeline > Literal tail vs Raw passthrough.* The
"Myanmar output never has Latin characters interleaved between
Myanmar chars" invariant is asserted by `PropertySuite` and
`FuzzSuite` already (per `CLAUDE.md`), so this is a regression
of an existing structural rule, not a new one.

**Scope refinement:**
- Original task lists only `<C>aaaaa<C>aa`-shape buffers. Probe
  confirms the bug also fires for any `<C>` followed by ≥ 5 `a`s and
  any continuation that creates a dropped tail > 6 chars — the
  underlying gate is purely length-based, not pattern-specific.
  Acceptance criteria already use the correct `<C>a{5,}<C>a*`
  regex; widened note below.
- The 9-character buffer length is the threshold ONLY when the
  consonant onset is one char long. Two-char onsets (`th`, `ny`,
  `ph`) shift the threshold by their length: `thaaaaakaa` (10
  chars) is the first failing case for `th`. The acceptance suite
  should iterate onsets of varying lengths.

**Changes made:**
- Status changed from `Open` to `Revised`.
- Notes section gained the multi-char-onset clarification.

**Open question:** Whether widening the gate could regress the
English-passthrough path (TASK-021's contract). The
`droppedTailHasAsciiLetters` flag at line 534 already exists but
is unused in the gate decision — the fixing agent should consider
using it to distinguish "long ASCII-only tail (English text)"
from "long mixed letter-run tail with consonant signal (Myanmar
fallback)".

## Implementation Notes

Narrowed the long-dropped-tail gate to fire `composeLetterRunsInTail`
specifically for the inherent-A overflow shape (`a{3,}<rest>`),
without affecting arbitrary long-letter tails.

- `Engine/MidBufferDigits.swift::droppedTailHasInherentAChainPrefix`
  detects a dropped tail whose first three scalars are all ASCII
  `a` (U+0061). That shape is the unambiguous fingerprint of the
  TASK-016 chained-inherent-A guard peeling a long `<C>aaaaa...`
  buffer down to the leading consonant arc + one inherent-A vowel.
- `Engine/BurmeseEngine.swift::update` extends the
  `shouldComposeDroppedTail` gate to allow the re-render whenever
  the dropped tail matches that shape. Other long ASCII-only tails
  (random fuzz buffers like `ureqnborylahzy`) keep the existing
  literal-tail behaviour, preserving the anchor-monotonicity
  invariant exercised by `PropertySuite.property_anchorMonotonicity`.

The first attempted fix widened the gate to "any all-letter dropped
tail" but introduced a regression: re-running `composeLetterRunsInTail`
on arbitrary tails subjects them to parser-internal re-segmentation
(observed for `qnborylahzy` where adding `y` shifted the ya-yit
medial across the surface). The narrowed `a{3,}` heuristic is
the minimum scope that satisfies the TASK-018 acceptance criteria
without disturbing unrelated buffers.

Tests: new `Sources/BurmeseIMETestSupport/Suites/InherentAChainOverflowSuite.swift`
asserts the no-ASCII-leak invariant for the documented repro
buffers, the pathological auto-repeat case, a sweep across
single- and multi-char onsets with varying chain lengths, and a
short-chain counter-example to lock in the existing TASK-016
collapse behaviour. Wired into `BurmeseTestSuites.all` and the
XCTest driver.

`swift run TestRunner` reports 920/920 passing (was 916 + 4 new
cases).

## Validation Report

**Verdict: FULLY_COVERED**

- Suite `InherentAChainOverflowSuite` is wired into
  `BurmeseTestSuites.all` and the XCTest driver
  (`InherentAChainOverflowXCTests`); cases
  `repro_kaaaaakaa_isMyanmarOnly`,
  `repro_extremeChain_isMyanmarOnly`,
  `sweep_consonantsAndChainLengths_areMyanmarOnly`, and
  `counter_shortChain_unchanged` all pass.
- Probe sweep on `kaaaaakaa`, `kaaaaaakaa`, `naaaaakaa`,
  `thaaaaakaa`, and the pathological 17-`a` extreme yields
  Myanmar-only surfaces (`ကက`, `ကက`, `နက`, `သက`, `ကအ`).
  No raw-ASCII leakage past any Myanmar scalar.
- The narrow `a{3,}` heuristic in
  `droppedTailHasInherentAChainPrefix` correctly distinguishes
  the inherent-A overflow shape from arbitrary long letter-runs,
  preserving `PropertySuite` / `FuzzSuite` invariants
  (`anchorMonotonicity` etc.) which still pass within the 933-case
  suite.
- Benchmark check: no regressions across all 8 scenarios
  including `repetition_t16` (p99=2819us) which directly exercises
  long repeated buffers.
- No tests removed or weakened.
