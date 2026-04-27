# TASK-014: Bare consonant + `:` produces literal colon instead of visarga heavy tone

## Status
Completed

## Implementation Notes
- New helper `applyBareConsonantToneFromTail` in
  `Engine/PunctuationHandling.swift`: when the right-shrink probe
  drops a `:` or `.` into the literal tail and the candidate's
  surface ends in a bare base consonant
  (U+1000..U+1021 / U+103F), emit a sibling whose tail's leading
  `:`/`.` is replaced by the visarga (U+1038) or creaky-tone
  (U+1037) scalar. The remainder of the tail is preserved.
- Wired the helper into `BurmeseEngine.update(buffer:context:)`'s
  affix-attach loop so the toned sibling lands at rank 0 and the
  literal-`:`/`.` form remains at rank 1 for users typing English
  mid-buffer.
- The helper deliberately rejects when the next character of the
  tail is an ASCII letter (mid-buffer `:` between English words)
  so `khun:akar`-style splits keep their literal colon and no
  spurious visarga is emitted between two letter syllables.
- Mid-buffer digit + tone (`12.`, `1.2`, `100:`) is unaffected
  because the trailing `:`/`.` lands in `effectiveTail` *after*
  the digit cluster — the candidate surface ends in a Myanmar
  digit (U+1041..U+1049), not a base consonant, so the helper
  returns nil and the literal punctuation passes through.
- The previously-asserted literal-`.` behaviour for `ka.` in
  `EngineSuite.task03_literalTailsStayLiteral` was an acceptable
  regression — the test was updated to remove the `ka.` case (the
  literal-`.` form remains in the panel, asserted by the new
  `BareConsonantToneSuite.bareConsonantTone_literalFallbackReachable`
  case).
- New suite `BareConsonantToneSuite` covers the reproduction-table
  consonants (`k`/`kh`/`t`/`th`/`p`/`m`/`n`/`l`/`y`/`w`),
  panel-reachability of the literal fallback, and existing-vowel-rule
  unchanged behaviour (`kar:`/`ki:`/`ku:`/`kar.`).

## Problem Description
A bare consonant followed by `:` (i.e. `<consonant>:` with no
intervening vowel suffix) produces a candidate surface where the
`:` remains as a literal ASCII colon `U+003A` rather than mapping
to visarga `U+1038` on the consonant's inherent-`a` reading.

For example, typing `ka:` produces `က:` (`[1000 003A]`) instead
of `ကား` (`[1000 102C 1038]`) or even just `ကး` (`[1000 1038]`,
visarga directly on inherent-`a`). The same shape repeats across
every bare consonant: `kha:`, `tha:`, `ma:`, `pa:`, `na:`,
`la:`, `wa:`, etc. all leak the literal `:`.

Compare to the working forms:
- `kar:` → `ကား` ✓ (vowel suffix `ar` already includes the
  visarga via the `ar:` rule).
- `ki:` → `ကီး` ✓ (`i:` rule).
- `ku:` → `ကူး` ✓ (`u:` rule).

So when the user picks a vowel romanization that has a `:`
sibling rule, visarga works. When the user picks the bare
inherent-`a` form (no explicit vowel suffix typed), the `:`
falls through as a literal ASCII character.

## Root Cause
`Romanization.swift::vowels` defines visarga-bearing entries only
for explicit vowel suffixes: `ar:`, `i:`, `u:`, `ay:`, `aw:`,
`o:`, `an:`, `own:`, `aung:`, `aing:`, `ai:`, `ain:`, `on:`,
`u2:`, `ar2:`, `aw2:`, `aung2:`, `ay2:`, `an2:`, `an3:`, `own2:`,
`own3:`, `on2:`, `on3:`, `ain2:`. There is no rule for the bare
inherent-`a` + visarga case (which would be a key like `:` with
output `U+1038`, or a vowel rule entry with empty roman key and
visarga output).

Consequently, when the parser sees `ka:`, it consumes `ka` as the
onset (with empty inherent-`a` arc), reaches the `:` at end of
buffer, finds no vowel rule that matches, and falls into the
right-shrink path. Right-shrink drops the `:` from the parser
input and the engine reattaches it as a literal tail —
`splitComposablePrefix` keeps `:` in the composable prefix
(`:` is in `composingCharacters`), so the literal-tail re-append
mechanism doesn't fire. The `:` gets emitted as part of the
parser's output via the unparseable-tail fallback path, which
preserves it as ASCII `U+003A`.

## Burmese Language Rule Reference
Visarga `U+1038` is the heavy-tone mark in Burmese. It can attach
to any vowel reading, including the inherent `a` of a bare
consonant. The surface `<C>း` (consonant + visarga directly,
representing inherent-`a` heavy tone) is grammatical Burmese and
appears in real text — it's the equivalent of writing the heavy-
tone form of a consonant without explicitly spelling out an `a`
vowel sign. Common examples: `ပြီး` (`pyi:`), `ကြီး` (`kyi:`),
and a wide class of two-syllable words where the second
syllable's heavy tone would otherwise need to be typed as `kar:`
when the user means just `<consonant>:`.

The IME's romanization scheme has explicit `:` siblings for every
*other* vowel reading, so consistency demands that the bare
inherent-`a` case also accept `:` as a visarga modifier.

## Steps to Reproduce
For any bare consonant `<C>`, type `<C>:`. The rank-0 surface
contains a literal ASCII colon (`U+003A`) instead of visarga
(`U+1038`).

Concrete reproductions (verified 2026-04-27 on a fresh
`BurmeseEngine`):

| Buffer | Current rank-0 | Desired rank-0 |
|---|---|---|
| `ka:`  | `က:`   (`[1000 003A]`) | `ကး` (`[1000 1038]`) or `ကား` |
| `kha:` | `ခ:`   | `ခး`  |
| `tha:` | `သ:`   | `သး`  |
| `ma:`  | `မ:`   | `မး`  |
| `pa:`  | `ပ:`   | `ပး`  |
| `na:`  | `န:`   | `နး`  |
| `la:`  | `လ:`   | `လး`  |
| `ya:`  | `ယ:`   | `ယး`  |
| `wa:`  | `ဝ:`   | `ဝး`  |

Counter-examples that work today and must continue to work:

- `kar:` → `ကား` (`ar:` vowel rule).
- `ki:` → `ကီး` (`i:` vowel rule).
- `ku:` → `ကူး` (`u:` vowel rule).
- Mid-buffer literals (`car:` followed by another syllable)
  must keep working as documented.

## Current State
Users typing the natural shorthand `<C>:` for a heavy-tone
inherent-`a` syllable get a literal colon in their committed
output. The workaround is to type `<C>ar:` (with explicit `ar`),
but that maps to a different vowel sign (`ား` long-aa visarga
vs. just `း` visarga). Users who want the bare-`<C>း` shape
have no clean keypath to it.

The same bug affects the dot variant inconsistently — `ka.`
produces `က.` (literal dot) under the same path, although the
`.` ↔ creaky-tone analogue is also missing from `vowels`.

## Desired State
- `<C>:` produces a candidate surface ending in `<C> U+1038`
  (visarga directly on the consonant's inherent-`a`).
- `<C>.` similarly produces `<C> U+1037` (creaky tone) at
  rank ≥ 0 (panel access, even if rank-0 should be the bare
  consonant for ranking).
- The visarga sibling appears in the candidate panel alongside
  the literal-colon fallback, so users who genuinely meant a
  literal `:` (e.g. typing English text mid-buffer) can still
  pick that surface.
- Existing vowel-rule visarga (`kar:`, `ki:`, `kaung:`, etc.)
  is unchanged.

## Acceptance Criteria
- For every bare consonant + `:` reproduction in the table, the
  rank-0 candidate surface scalar sequence ends with
  `<consonant> U+1038`. The literal-colon fallback (`<C> 003A`)
  remains accessible at rank ≥ 1.
- For every bare consonant + `.` analogous case (`ka.`, `tha.`,
  …), the rank-0 candidate surface ends with
  `<consonant> U+1037`.
- A new suite under
  `Sources/BurmeseIMETestSupport/Suites/BareConsonantToneSuite.swift`
  covers the bug-class inputs and counter-examples
  (`kar:`/`kar.`, `ki:`/`ki.`, …).
- Existing `EngineSuite`, `PunctuationSuite`,
  `MidBufferPunctuationSuite`, and `OrphanLeadingVowelSuite`
  continue to pass.
- `swift run TestRunner` continues to pass at 100 %.
- `swift run -c release BurmeseBench --check
  Tests/Benchmarks/baseline.json` reports no regressions.

## Notes
- Code locations:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Romanization.swift`
    lines 210–376 (`vowels` table). The fix is to add bare-
    inherent-`a` entries `:` → `U+1038` and `.` → `U+1037` as
    `standalone: true` (legal without onset) but without the
    `+`/`*` standalone semantics those connector entries have.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/NBestDP.swift`
    — verify the new entry interacts correctly with
    `softBoundaryContext` so it doesn't fire mid-buffer where
    it would over-match (a mid-buffer `:` after a consonant
    that has no closing vowel should remain a literal break).
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/PunctuationHandling.swift`
    `mapPunctuation` / `splitAtLastEmbeddedComposingPunct`
    — the new vowel rule must not regress the mid-buffer
    `:` literal split (e.g. `khun:akar` should stay as a
    literal-`:` split because there is no preceding vowel
    rule that absorbs the `:`, and TASK-009's open-colon-
    vowel-modifier logic specifically uses
    `colonActsAsVowelModifier` to gate when `:` is part of a
    vowel suffix).
- This bug is structural (independent of LM / lexicon).
  Verified empirically on a fresh `BurmeseEngine()`.
- Probe (2026-04-27):
  ```swift
  for c in ["k", "kh", "t", "th", "p", "ph", "m", "n", "l", "y", "w"] {
      let s = engine.update(buffer: "\(c)a:", context: []).candidates.first?.surface ?? ""
      // s contains 0x003A (literal colon) instead of 0x1038 — bug.
  }
  ```

## Validation Notes
- Validity: **Valid bug, confirmed via probe (2026-04-27).**
  | Input | Surface | Hex | Has visarga? |
  |---|---|---|---|
  | `ka:`  | `က:`     | `1000 003A` | NO (literal colon) |
  | `kha:` | `ခ:`     | `1001 003A` | NO |
  | `tha:` | `သ:`     | `101E 003A` | NO |
  | `ma:`  | `မ:`     | `1019 003A` | NO |
  | `pa:`  | `ပ:`     | `1015 003A` | NO |
  | `na:`  | `န:`     | `1014 003A` | NO |
  | `la:`  | `လ:`     | `101C 003A` | NO |
  | `ya:`  | `ယ:`     | `101A 003A` | NO |
  | `wa:`  | `ဝ:`     | `101D 003A` | NO |
  | `kar:` | `ကား`    | `1000 102C 1038` | YES (control) |
  | `ki:`  | `ကီး`    | `1000 102E 1038` | YES (control) |
  | `ku:`  | `ကူး`    | `1000 1030 1038` | YES (control) |

- Code-path verification: confirmed there is no bare-`:`
  vowel rule in `Romanization.swift`. Visarga-bearing entries
  exist only as siblings of explicit vowels (`ar:`, `i:`, `u:`,
  `ay:`, …). The diagnosis in the task body is correct.

- Burmese rule reference is accurate: `<C>း` (consonant + visarga
  on inherent-`a`) is grammatical Burmese. Real-text examples
  exist (e.g. `ပြီး`, `ကြီး`).

- Scope calibration: Correctly scoped. Task covers the entire
  bare-consonant class, plus the analogous `.` (creaky tone) issue
  is identified and within scope. The `.` case is verified
  (e.g. `ka.` → `က.` literal dot, by the same path).

- Refinement on rank-0 expectation for `.`: the task says
  "rank ≥ 0" because creaky tone on bare inherent-`a` is rare —
  the literal-dot fallback may be more common in mixed-script
  use. The fixing agent should preserve panel access to both
  forms; absolute rank-0 default is open to design.

- Acceptance criteria are testable: scalar-sequence assertion
  on rank-0 surface is unambiguous.

- Note for fixing agent: the Notes section flags TASK-009's
  `colonActsAsVowelModifier` gate. The fixing agent must
  carefully sequence the new bare-`:` rule through the
  `softBoundaryContext` / `colonActsAsVowelModifier` checks so
  that mid-buffer `:` retains its literal-split behaviour
  (e.g. `khun:akar` should not now over-absorb the `:` as
  visarga on the previous syllable's inherent-`a`).

- No open questions.

## Validation Report
- **Verdict: FULLY_COVERED.**
- Acceptance criteria re-verified via probe (debug build, 2026-04-27).
  Every bare-consonant + tone reproduction now produces a rank-0
  surface with the expected tone marker, and the literal-tail
  fallback is reachable at rank ≥ 1:
  - `ka:` → `ကး` (`1000 1038`), literal `က:` reachable at rank 1.
  - `kha:` → `ခး` (`1001 1038`), literal `ခ:` reachable.
  - `tha:` → `သး` (`101E 1038`), `ma:` → `မး`, `pa:` → `ပး`,
    `na:` → `နး`, `la:` → `လး`, `ya:` → `ယး`, `wa:` → `ဝး`.
  - `ka.` → `က့` (`1000 1037`), `kha.` → `ခ့`, `tha.` → `သ့`,
    `ma.` → `မ့`, `pa.` → `ပ့` (all with creaky tone at rank 0).
- Counter-examples preserved: `kar:` → `ကား`, `ki:` → `ကီး`,
  `ku:` → `ကူး`, `kar.` → `ကာ့`, `kaung:` → `ကောင်း`.
- Mid-buffer literal `:` retains literal behaviour: `khun:akar` →
  `ခူန:အကာ` (literal U+003A intact between the two letter-syllables),
  `ka:apa` → `က:အပ` (literal U+003A intact). The helper correctly
  rejects when the tail's next character is an ASCII letter.
- Mid-buffer digit + tone unaffected: `ka1:` → `က၁:`, `ka12:` →
  `က၁၂:`, `100:` → `၁၀၀:` (literal U+003A retained because the
  surface ends in Myanmar digits, not a base consonant).
- New `BareConsonantToneSuite` (4 cases) covers the bug-class
  consonants, panel-reachability of the literal fallback, and
  vowel-suffix unchanged behaviour. All green.
- **Regression note (justified):**
  `EngineSuite.task03_literalTailsStayLiteral` was updated to remove
  the `ka.` literal-dot expectation. The new behaviour promotes
  `ka.` → `က့` to rank 0 with the literal-dot form retained at rank
  ≥ 1 (asserted by
  `BareConsonantToneSuite.bareConsonantTone_literalFallbackReachable`).
  The regression is intentional and the literal-fallback assertion
  was migrated, not weakened.
- All 912 TestRunner cases pass; benchmark `--check` reports no
  regressions.
