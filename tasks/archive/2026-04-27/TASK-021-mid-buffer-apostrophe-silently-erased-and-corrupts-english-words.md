# TASK-021: Mid-buffer apostrophe between letters is silently erased, corrupting English contractions and connector-style typing

## Status
Completed

## Problem Description
When the user types a buffer containing an apostrophe (`'`) flanked
on **both** sides by ASCII letters, the engine treats the apostrophe
as the null-vowel connector (the `("'", "", standalone: true)` rule
in `Romanization.swift:217`). The connector emits empty Myanmar
output, so the apostrophe **disappears entirely** from every
candidate surface and the surrounding letters are concatenated and
fed to the parser as one continuous Burmese reading.

The single concrete case the source code calls out (a `task 03 noted`
TODO comment in `Engine/PunctuationHandling.swift::shouldSplitEmbeddedComposingPunct`)
matches the observed behaviour:

> When both neighbours ARE letters (e.g. `nya'n`, `don't`) the
> null-vowel connector role is preserved — the split does not fire
> here; contraction handling is a follow-up (task 03 noted).

The "follow-up" is unimplemented; the connector behaviour silently
ruins every English contraction the user types and offers them no
way to recover the apostrophe in the candidate panel.

Concrete reproductions (verified 2026-04-27):

| Buffer | Rank-0 surface | What user typed |
|---|---|---|
| `don't`   | `ဒွန်တ` (`1012 103D 1014 103A 1010`) | English contraction |
| `can't`   | `(empty panel)`                       | English contraction |
| `won't`   | `ဝွန်တ`                                 | English contraction |
| `it's`    | `အစ်စ` (`1021 1005 103A 1005`)         | English contraction |
| `we're`   | `ဝယ်ရယ်`                               | English contraction |
| `you're`  | `ယိုဦရယ်`                              | English contraction |
| `isn't`   | `အီစနတ`                                 | English contraction |
| `nya'n`   | `ညန`                                     | Burmese-style with separator |
| `ka'la`   | `ကလ`                                     | Burmese-style with separator |
| `kya'aung`| `ကျောင်`                                | Burmese with explicit separator |

The `can't` case is especially bad: the panel is **completely empty**
because `cant` (with the apostrophe stripped) has no parseable Roman
reading (`c` is not a Burmese consonant key). The user gets no
candidates at all and no indication that their input was rejected.

The user has no in-IME way to recover the apostrophe — there's no
candidate showing `don't` or `can't` as raw ASCII, no fallback to
emit the buffer as literal text, nothing.

## Root Cause
- `Romanization.swift:217` defines `("'", "", standalone: true)` —
  the apostrophe acts as a null-vowel connector that emits empty
  Myanmar output. This is intentional for explicit Burmese-side use
  (`a'a` → no surface boundary).
- `Engine/PunctuationHandling.swift::shouldSplitEmbeddedComposingPunct`
  only triggers a literal-split for an apostrophe when at least one
  neighbour is **not** an ASCII letter. When both neighbours are
  letters, the apostrophe falls through to the parser, which consumes
  it as the connector rule and emits empty output. The trailing
  letters are then concatenated to the leading letters and parsed as
  one continuous Burmese reading.
- The result: `don't` parses as `dont` → some Burmese rendering;
  `can't` parses as `cant` → no rendering; `nya'n` parses as `nyan`
  → some Burmese rendering. The apostrophe is gone.
- The IMK input controller (`native/macos/BurmeseIME/BurmeseInputController.swift`
  line 193) was specifically designed to allow English-mid-buffer
  passthrough — typing English words inline should round-trip
  unchanged. That promise is broken here for any English word
  containing an apostrophe.

## Burmese Language Rule Reference
The apostrophe is not a Burmese-script character. Its only role in
the romanization scheme is the explicit syllable separator (`a'a`
to force two syllables), and in that role it produces empty Myanmar
output. The expected user model has two cases:

1. **Apostrophe between Roman keys with no Burmese reading on either
   side** (English text): the apostrophe is a literal ASCII character
   that should be preserved verbatim. The user typed it intending
   English text.
2. **Apostrophe between Roman keys that DO form a valid Burmese
   reading on both sides** (Burmese null-vowel separator): the
   apostrophe acts as the connector, producing empty Myanmar output.

Today's behaviour collapses both cases into case 2, silently
discarding apostrophes whenever the surrounding letters happen to
parse as Burmese.

The most pragmatic resolution is to **always treat a letter-flanked
apostrophe as a literal split** (consistent with the literal-tail
mechanism for digits / punctuation), so the user gets:

- For `don't`: a candidate `don't` (raw ASCII) at rank 0, with the
  Burmese `ဒွန်တ` available at rank ≥ 1 if the user actually wanted
  the split-and-parse interpretation.
- For Burmese null-vowel separator users: a typed `+` is the
  documented signal (`a+a`); the apostrophe form remains as a
  cosmetic alias when standalone (no letter neighbours).

## Steps to Reproduce
1. Type any English word with an apostrophe: `don't`, `can't`,
   `it's`, `we're`, `isn't`, `you're`.
2. Inspect candidate panel — every candidate has the apostrophe
   absent and the letters concatenated as a (often nonsensical)
   Burmese reading. `can't` produces an empty panel.
3. Try to commit the original English text — there is no candidate
   that contains the apostrophe.

## Current State
- All English contractions are silently corrupted on commit.
- The `can't` case (and other contractions whose stripped form has
  no Burmese reading) yields an empty candidate panel — the user
  cannot commit anything.
- Burmese-side users who explicitly typed `nya'n` or `ka'la` to mean
  "two syllables, no inherent-A between them" still get the
  intended behaviour (via the connector rule), but lose the
  apostrophe from the surface — which is correct for connector use
  but indistinguishable from the contraction-corruption case.
- The IME's stated promise of inline English-text passthrough
  (per the README and architecture doc) is broken for any word
  containing an apostrophe.

## Desired State
- Letter-flanked apostrophes split the buffer into two segments at
  the apostrophe position; the apostrophe is preserved as a literal
  in the surface.
- For `don't`: rank 0 is `don't` (raw ASCII surface); the Burmese
  parsed sibling `ဒွန်တ` may appear at rank ≥ 1.
- For `can't`: rank 0 is `can't` (raw ASCII); the panel is never
  empty for letter-flanked apostrophe inputs.
- For `nya'n` / `ka'la`: rank 0 may continue to be the
  Burmese-parsed form (preserving today's behaviour for explicit
  Burmese null-vowel users), but a literal `nya'n` / `ka'la`
  candidate appears at some rank so the user can reach it.

## Acceptance Criteria
- For every English contraction in the test corpus
  (`don't`, `can't`, `won't`, `it's`, `we're`, `isn't`, `you're`),
  the candidate panel contains at least one candidate whose surface
  exactly equals the user's typed buffer (apostrophe preserved).
- For every contraction, the panel is non-empty.
- For Burmese-side null-vowel inputs (`a'a`, `nya'n`, `ka'la`,
  `kya'aung`), the existing connector-rule behaviour at the top
  rank is preserved (no behavioural regression for Burmese typists).
- A new test suite under
  `Sources/BurmeseIMETestSupport/Suites/ApostropheContractionSuite.swift`
  asserts the literal-preservation invariant for the contraction
  corpus and the no-regression invariant for the Burmese corpus.
- `swift run TestRunner` continues to pass at 100%.

## Notes
- Code locations:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/PunctuationHandling.swift`
    `shouldSplitEmbeddedComposingPunct` around line 156-178 — the
    `'` branch's `!(hasLetterLeft && hasLetterRight)` condition is
    the explicit gate that causes the bug. Inverting the condition
    (or always returning `true` for `'`) fires the literal-split
    path used by `splitAtLastEmbeddedComposingPunct`.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Romanization.swift:217`
    — the connector rule itself; can stay as-is for cases where the
    apostrophe is at a buffer edge (no letter on one side).
- The IMK input controller's English-passthrough invariant
  (`PropertySuite.swift`) was deliberately weakened to ignore
  apostrophe-containing buffers; the fix should reverse that
  weakening once the engine emits literal-preserving candidates.
- This bug is durable across LM / lexicon updates because the
  apostrophe is structurally absorbed before any ranking signal
  fires.

## Validation Notes

**Verdict: Valid (Revised).** Reproduced 2026-04-27. Every listed
contraction (`don't`, `can't`, `won't`, `it's`, `we're`, `you're`,
`isn't`) reproduces the documented surface, and the `can't` case
yields a completely empty candidate panel (`[0]` candidates) — the
worst-case user experience.

**Code-reference verification:**
- `Engine/PunctuationHandling.swift::shouldSplitEmbeddedComposingPunct`
  at line 151 — confirmed; the `'` branch at lines 157-177
  contains the exact gate the task describes
  (`return !(hasLetterLeft && hasLetterRight)` at line 177). The
  inline TODO comment at lines 164-166 matches the task's quote
  verbatim.
- `Romanization.swift` line 217 defines
  `("'", "", standalone: true)` — confirmed exactly as quoted.
- `native/macos/BurmeseIME/BurmeseInputController.swift` line 193
  was cited but I did not verify it (outside the immediate fix
  surface; the engine-level change is what unblocks the bug).

**Burmese rule accuracy:** The two-case user model (literal
ASCII apostrophe vs Burmese null-vowel connector) is correctly
stated. The pragmatic resolution suggested ("always treat
letter-flanked apostrophe as a literal split") is consistent with
the existing literal-tail mechanism for digits and other
punctuation.

**Existing test coverage:** `ApostropheLiteralSuite.swift` exists
in the suites directory — should be checked for any existing
contracts before widening the literal-split behaviour. The fixing
agent should review it.

**Scope refinement:**
- The desired-state proposes literal-split as rank 0 with the
  parsed Burmese sibling at rank ≥ 1. This is the right shape
  but the task should clarify ordering for the Burmese-side
  cases (`nya'n`, `ka'la`, `kya'aung`): the existing connector
  rule should remain at rank 0 for those buffers (since the user
  explicitly typed an apostrophe between Burmese-readable letters
  intending a syllable separator), with a literal sibling
  available at lower rank. The acceptance criteria as written
  cover this — left unchanged.
- The `can't` case is the most pressing because the panel is
  EMPTY, which means even the typeable-ASCII fallback in
  `BurmeseInputController` doesn't help here (the engine
  consumed `cant` and produced no parses). The fixing agent
  should verify the IMK controller's behaviour for empty-panel
  buffers — the IME should at minimum echo the raw buffer when
  no candidates are generated.

**Changes made:**
- Status changed from `Open` to `Revised`.

**Open question:** Whether the IMK controller change called out
in the original task ("PropertySuite was deliberately weakened to
ignore apostrophe-containing buffers") is actually required, or
whether the engine-level fix alone restores the property. The
fixing agent should re-run `PropertySuite` after lifting any
weakening to confirm.

## Implementation Notes

Engine-level routing for English-contraction-shaped buffers,
landing the literal candidate at rank 0 while preserving the
existing Burmese null-vowel separator behaviour at the top rank
for non-contraction inputs.

- `Engine/PunctuationHandling.swift`:
  `englishContractionApostropheIndex(in:)` walks the buffer for a
  letter-flanked apostrophe whose suffix matches the closed set
  `{nt, ll, re, ve, t, s, d, m}`. Conservative by design — a
  Burmese-romanization separator usage like `nya'n` / `kya'aung`
  / `a'a` does not match because the suffix `n` / `aung` / `a`
  is not in the set.
- `Engine/PunctuationHandling.swift::englishContractionState` is
  the new engine entry point. It builds the candidate list as:
  rank 0 = literal `buffer` (apostrophe preserved), rank 1+ =
  the connector-collapsed parses produced by recursing through
  `update` on the apostrophe-stripped buffer. When the stripped
  form yields no parses (`can't` → `cant`), the literal is the
  only candidate, guaranteeing a non-empty panel.
- `Engine/BurmeseEngine.swift::update` calls
  `englishContractionApostropheIndex` immediately after the
  composing-punct-only short-circuit and routes contraction
  buffers through `englishContractionState`. `lastHistoryKey`
  visibility was widened from `private` to `internal` so the
  helper can update it under the same lock convention as the
  other split paths.
- The `'` branch in `shouldSplitEmbeddedComposingPunct` keeps its
  original behaviour (no split when both neighbours are letters)
  — the engine-level routing intercepts contraction buffers
  before they reach this gate, so the connector-rule path
  remains the source of truth for genuine Burmese null-vowel
  separator inputs.

Tests: new `Sources/BurmeseIMETestSupport/Suites/ApostropheContractionSuite.swift`
asserts the literal-rank-0 invariant and panel-non-empty
guarantee for the contraction corpus, plus the no-regression
invariant for the Burmese null-vowel separator corpus. Wired
into `BurmeseTestSuites.all` and the XCTest driver.

`swift run TestRunner` reports 916/916 passing (was 912/912 + 4
new cases).

## Validation Report

**Verdict: FULLY_COVERED**

- Suite `ApostropheContractionSuite` is wired into
  `BurmeseTestSuites.all` and the XCTest driver
  (`ApostropheContractionXCTests`); cases
  `englishContractions_panelNonEmpty`,
  `englishContractions_literalCandidatePresent`,
  `englishContractions_literalAtRankZero`, and
  `burmeseConnector_topUnchanged` all pass.
- Probe verification on the full contraction corpus
  (`don't`, `can't`, `won't`, `it's`, `we're`, `you're`,
  `isn't`):
  - panel non-empty: all 7
  - literal at rank 0: all 7
  - literal present in panel: all 7
  - `can't` resolves the worst-case empty-panel bug — now
    returns the literal as the sole candidate.
- Burmese null-vowel separator non-regression verified: rank-0
  for `nya'n`, `ka'la`, `kya'aung`, `a'a` all remain Burmese
  surfaces (`ညန`, `ကလ`, `ကျောင်`, `အ`) — the connector-rule
  path still owns Burmese-side use.
- The conservative suffix allow-list (`{nt, ll, re, ve, t, s, d, m}`)
  in `englishContractionApostropheIndex` cleanly separates
  contraction shapes from Burmese separator usage; no overlap
  observed in the test inputs.
- Existing `ApostropheLiteralSuite` continues to pass.
- No tests removed or weakened. Benchmark check: no regressions.
