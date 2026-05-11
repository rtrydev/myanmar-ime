# TASK-068: Mid-buffer unsupported ASCII letters (`f`, `q`, `x`, `c`-not-as-`ch`) silently dropped from rank-0 surface and replaced with phantom `1021` anchor

## Status
Completed

## Implementation Notes
- Added `class_E_unsupportedLetterMidBuffer` literal-promotion
  signal in
  `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift::injectLiteralFallback`,
  alongside the existing Class A–D promotion triggers. The new
  class fires when:
  1. The rawBuffer contains at least one ASCII letter that is not
     present in any romanization rule. `f`, `q`, `x` never appear
     in any onset/vowel/cluster-alias rule. `c` is conditionally
     unsupported: it appears only in the `ch`/`chw` cluster
     aliases, so a `c` NOT followed by `h` is treated as
     unsupported (handles the `kca` / `anaconda` / `ace` /
     `acer` lone-`c` cases).
  2. At least one unsupported letter is at offset > 0 (the
     buffer-leading case is already handled by the parser's own
     "start after the unsupported letter" path and the ASCII-
     ratio promotion).
  3. The rank-0 surface omits at least one unsupported letter
     present in the rawBuffer — i.e. the parser silently absorbed
     it into a phantom anchor or otherwise dropped it.
  When the predicate fires, the literal raw buffer is promoted to
  rank 0 via the existing literal-promotion machinery. This
  matches option (b) from the task body and aligns with TASK-043's
  unconvertible-buffer policy.
- Added regression suite
  `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/MidBufferUnsupportedLetterSuite.swift`
  covering the bug class:
  `midUnsupportedLetter_rank0HonorsLetter` (every rank-0 surface
  either contains the letter or equals the literal),
  `midUnsupportedLetter_readingMatchesSurface` (no reading-vs-
  surface mismatch — if reading carries an unsupported letter the
  surface must too), `midUnsupportedLetter_literalReachable`
  (literal always in panel), `leadingUnsupportedLetter_literalAtRank0`
  (buffer-leading case regression baseline), `clusterC_unaffected`
  (`cha` / `chai` cluster aliases must NOT be force-promoted).
- Suite registered in
  `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/BurmeseTestSuites.swift`.
- Two existing tests were adjusted because they pinned the
  pre-fix bug behavior; both adjustments are documented inline:
  - `LiteralFallbackPrefixedRepetitionSuite::carveOut_nonCollapseBuffers_unchanged`
    previously asserted that `anaconda` should NOT promote
    literal. `anaconda` contains a lone-`c` between `a` and `o`
    which the pre-fix engine silently absorbed — the exact
    TASK-068 bug class. `anaconda` removed from the carve-out
    set; `mahabodhi` (no unsupported letters) kept as the
    regression baseline.
  - `UnparseableTailFallbackSuite::composableTailRegression`
    previously asserted `ace` → `အယ်` and `acer` → `အယ်ရ` —
    pinning the silent-absorption of the lone-`c` between
    `a` and `e`/`r`. `ace` and `acer` removed from the
    composable-tail regression; the `ab` case (no unsupported
    letter) kept as the regression baseline.
- Test runner: 1556/1556 cases, 8581/8581 assertions pass
  (was 1551/1551, 8551/8551 before this task).
- `BurmeseBench --check --samples 5` shows borderline noise on the
  `long` scenario; second-run validation confirmed no real
  regression. The fix only adds a predicate check inside the
  already-cheap literal-fallback path, so no perf impact is
  expected.

## Problem Description
When the user types an ASCII letter that is not part of any
romanization rule — `f`, `q`, `x`, or a lone `c` (not part of `ch`) —
in the **middle** of an otherwise convertible buffer, the parser
silently drops the unsupported letter from the rank-0 Myanmar surface
and emits a phantom `U+1021` (independent vowel `အ`) anchor in its
place. The candidate's `reading` field still contains the user's
typed letter, but the `surface` does not — creating a reading-vs-
surface mismatch that the user cannot see in the panel.

The literal raw buffer is correctly placed at rank 1 per TASK-043's
`unconvertibleRatio < 0.5` policy (the unsupported letter is one of
several characters), so a recoverable escape hatch exists — but the
user-facing rank-0 panel entry shows a Burmese surface that does NOT
correspond to what was typed. Selecting it commits an unrelated
sequence (`ka` + `အ` instead of preserving `f`).

## Root Cause
The N-best DP in `Parser/NBestDP.swift` skips over unrecognised
single ASCII letters when threading arcs through the buffer, treating
them as zero-cost gaps rather than as boundary breakers or literal
pass-throughs. Once the DP has consumed the surrounding `<C>` +
trailing-vowel arcs, the materialise path in `Parser/Finalization.swift`
synthesises a `1021` anchor for the orphan dep-vowel arc that follows
the dropped letter, because:

1. The skipped letter (`f`, `q`, `x`, `c`) is not in the
   `Romanization.composingCharacters` consonant set, so no onset arc
   matches at that position.
2. The DP advances past the unrecognised letter and re-enters arc
   matching at the next valid character (`a`, `r`, etc.).
3. The resumed arc is a bare-vowel rule (`a` → empty output → promoted
   to `1021`; `ar` → `1021 102C`; etc.), which the orphan-anchor
   injection logic resolves by inserting `1021` to host the dep-vowel.
4. The candidate's `reading` carries the original buffer letter intact
   (the engine preserves the un-normalised input verbatim for reading
   echo), so the user reads `kfa` in the reading column but the
   surface column shows `ကအ` (the dropped `f` materialised as `1021`).

The literal-fallback wrapper measures
`unconvertibleRatio = (rawBuffer.count - parseable) / rawBuffer.count`
where `parseable` is the longest prefix the parser can accept. For
`kfa`: `parseable` is small but non-zero (the parser claims to handle
the whole buffer by skipping `f`), so the ratio falls below 0.5 and
the literal is appended at rank 1 instead of promoted to rank 0.

## Burmese Language Rule Reference
CLAUDE.md §1 ("Grammar and Sanitizers"): "Candidates should be
orthographically legal before they reach the panel." A surface whose
scalars do not correspond to any segmentation of the user's typed
buffer violates the implicit "surface reflects input" invariant —
not a Burmese orthography rule per se, but the user's mental model
of the IME.

CLAUDE.md §3 ("Digits Are Literal") establishes the principle that
unrecognised user-input characters stay at the typed position — the
same principle should extend to unrecognised ASCII letters: they
should appear in the surface verbatim (`ကfa`) or trigger literal
fallback at rank 0, not be silently dropped.

TASK-043 (archived 2026-05-03c) established the literal-fallback
policy for fully-unconvertible buffers (`comp`, `facebook`, etc.),
but the per-position drop-and-substitute behaviour for individual
unsupported letters mid-buffer was not explicitly addressed.

## Steps to Reproduce
```swift
let engine = BurmeseEngine()

// Single unsupported letter mid-buffer:
let s1 = engine.update(buffer: "kfa", context: [])
print(s1.candidates[0].surface)  // "ကအ" (1000 1021)
print(s1.candidates[0].reading)  // "kfa"
// Surface is `ka + အ` (`f` dropped, `1021` injected); literal at rank 1.

// Realistic-looking word:
let s2 = engine.update(buffer: "makfaung", context: [])
print(s2.candidates[0].surface)  // "မကအောင်" (1019 1000 1021 1031 102C 1004 103A)
// Reading: "makfaung". Surface: ma + ka + 1021 + aung. The `f` is gone,
// the user's intended position is filled by an unrelated `အ` anchor.

// Same pattern with q/x/c:
_ = engine.update(buffer: "kqa", context: []).candidates[0].surface  // "ကအ"
_ = engine.update(buffer: "kxa", context: []).candidates[0].surface  // "ကအ"
_ = engine.update(buffer: "kca", context: []).candidates[0].surface  // "ကအ"
```

## Current State
- `kfa` rank 0 = `ကအ` (1000 1021). Surface scalars: `ka + 1021`. The
  user's `f` is silently absorbed into a phantom independent-vowel
  anchor. Literal `kfa` is at rank 1.
- `kfar` rank 0 = `ကအာ` (1000 1021 102C). Surface: `ka + 1021 + ar`.
- `makfaung` rank 0 = `မကအောင်` (1019 1000 1021 1031 102C 1004 103A) —
  six-syllable Burmese with the `f` invisibly fused into a `1021`.
- `min+gar+f+kya` rank 0 = `မင်္ဂါအ္ကြ` — `f+kya` becomes `1021 1039 1000 103C`,
  i.e. an independent-vowel-`အ` subjoined to `kya`. The user's
  explicit `+` boundary around `f` is honoured but the `f` itself
  becomes `အ`.
- The `+` separator does NOT mitigate the bug; explicit `min+f+gar`
  produces `မင်အ္ဂါ` (`min + 1021_subjoined_ga`).

## Desired State
- For any buffer containing an unsupported ASCII letter
  (`f`, `q`, `x`, lone `c` not as `ch`/`ck`/etc.) mid-buffer:
  - Either the unsupported letter is preserved verbatim in the
    rank-0 surface (e.g. `ka` + literal `f` + … = `ကfa` /
    `1000 0066 0061`), OR
  - The literal raw buffer is promoted to rank 0 (the current
    above-50% behaviour, generalised to "ANY unsupported letter
    mid-buffer triggers literal at rank 0").
- The reading-vs-surface mismatch must not occur: a candidate's
  `reading` must be a faithful round-trip of the `surface`'s
  romanization, modulo the existing reverse-romanizer rules.
- Literal fallback remains reachable in the panel (CLAUDE.md §2)
  — currently satisfied at rank 1 for `kfa`, would need to remain
  so under either fix.

## Acceptance Criteria
- For every buffer in
  `{kfa, kqa, kxa, kca, kfar, makfaung, min+f+gar, min+gar+f+kya,
   kabfa, kayfa}`, the rank-0 surface either:
  (a) contains the original ASCII letter at the typed position
      (preserved verbatim, e.g. `ka` + `f` + `a` → `ကfa`), OR
  (b) equals the literal raw buffer (promoted to rank 0).
- No rank-0 Myanmar surface for any test buffer contains a `1021`
  scalar that maps back-to-back to a position the user typed an
  unsupported ASCII letter at.
- Existing `RankingSuite`, `LiteralFallbackCandidateSuite`,
  `LiteralFallbackIllegalSurfaceSuite`,
  `LiteralFallbackPrefixedRepetitionSuite` stay green.
- A new regression suite (e.g. `MidBufferUnsupportedLetterSuite`)
  asserts the predicate "if the rawBuffer contains an unsupported
  ASCII letter at position p and the rank-0 surface omits it,
  the test fails".
- `swift run TestRunner` 1543/1543 stays green; benchmark
  `--check` does not regress.

## Notes
- Code locations to investigate:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/NBestDP.swift`
    — the arc-matching loop that advances past unrecognised
    characters. Trace where the DP decides to skip a char without
    consuming it via any arc.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/Matching.swift`
    — the onset/coda matchers; check whether unknown-letter handling
    falls through to a "skip and continue" path vs. an "emit literal"
    path.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`
    — the literal-fallback wrapper. The `unconvertibleRatio`
    calculation in TASK-043's policy may need to count unsupported
    letters in the raw buffer (not just letters the parser can't
    place at all). For `kfa`, the parser claims to handle 100% of
    the buffer (it skipped the `f`); the unconvertibleRatio is
    therefore ~0%, missing the rank-0 promotion gate.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`
    — a new sanitizer could detect "rank-0 surface lacks a scalar
    corresponding to a user-typed ASCII letter at the same position"
    and reject those candidates, falling back to literal.
- The bug is **disruptive** because:
  - The user typing a typo (`makfaung` for `makaung`) sees a
    plausible-looking Burmese candidate that does not contain their
    typo — they may commit it unaware that their input was modified
    silently.
  - The reading-vs-surface mismatch is invisible in most candidate
    panels (only the surface is shown by default).
  - For longer buffers with embedded English punctuation or English
    words (loanword romanizations), the silent absorption can
    fabricate Myanmar text that the user never intended to type.
- The pattern only fires for genuinely unsupported letters; supported
  letters that LOOK unsupported (capital `H` → maps to lowercase
  `h` = ha-htoe; `J` → `j` = cluster shortcut) work correctly.
- Related: TASK-043 (archived 2026-05-03c) established the literal-
  fallback policy. This task extends it to per-position unsupported
  letters that the parser silently consumes.

## Validation Notes
- **Verdict:** Valid. Bug reproduces against `BurmeseEngine()` at HEAD
  for every probe in the example set. Confirmed reading-vs-surface
  mismatch: `kfa` rank-0 surface is `ကအ` (1000 1021) but reading is
  `kfa` (the original buffer); the dropped `f` is replaced by a
  phantom `1021` anchor. Same pattern for `kqa`, `kxa`, `kca`,
  `kfar`, `makfaung`, `kabfa`, `kayfa`, `min+f+gar`, `min+gar+f+kya`.
- **Buffer-prefix sanity check:** Standalone `f`, `fa`, `fk`, `fka`
  (where the unsupported letter is the FIRST character) correctly
  surface the literal at rank 0 with no Myanmar-side absorption
  — the bug is genuinely position-dependent and only fires when a
  parseable Myanmar arc precedes the unsupported letter.
- **Scope:** The original task focused on `f`, `q`, `x`, `c`. The
  full set of unsupported single-letter ASCII codes the parser
  treats as gaps would be worth enumerating from `Romanization`
  (the rule table) at fix time — `c` is the trickiest because it
  IS supported as part of `ch`, but lone `c` (no following `h`)
  silently drops. The fixing agent should confirm the full
  unsupported-letter set rather than hard-coding the four examples.
- **Acceptance criteria:** Already testable; left as-is. The
  predicate "rawBuffer contains an unsupported ASCII letter at p
  AND the rank-0 surface omits it" is a clean property test.
  Note that "preserve verbatim in surface" (option a) would
  produce mixed Myanmar+ASCII surfaces — a non-trivial change to
  the surface-rendering contract; option (b) "promote literal raw
  buffer to rank 0" is the cleaner fix and matches the pattern
  established by TASK-043.
- **Application-feature deliberation:** Some users genuinely type
  English words / proper nouns / English-loanword fragments mid-
  buffer, and the IME currently has no "leave English alone"
  affordance other than the literal-at-rank-1 fallback. Promoting
  the literal to rank 0 when an unsupported letter is detected may
  be more disruptive for users who expect the Burmese candidate
  even when typing imperfect romanizations. The fixing agent
  should consider the SURFACE-CONTAINS-LITERAL-LETTER option —
  preserve the unsupported letter verbatim in the Myanmar surface
  (e.g. `ကfa`) — which keeps the user's intent visible without
  collapsing the entire buffer to ASCII. The "promote literal
  rank-0" path is the safer first cut.
- **TASK-043 reference:** Confirmed archived at
  `tasks/archive/2026-05-03c/`. The `unconvertibleRatio < 0.5`
  threshold mentioned in the task is consistent with that policy.
- **Reading-vs-surface contract:** This is the critical invariant
  to add. There is currently no test asserting that rank-0
  candidate's reading is a faithful round-trip of the surface
  (per the existing reverse-romanizer rules). A new sanity test
  in the proposed `MidBufferUnsupportedLetterSuite` would close
  the gap.
- **Test runner baseline:** CLAUDE.md states 1355/1355; the task
  cites 1543. Fixing agent should sync against actual current
  baseline.

## Validation Report
- **Verdict:** FULLY_COVERED.
- **Test adjustments (anaconda / ace / acer dropped):** Both are
  genuine bug-class buffers, not weakened assertions. `anaconda` was
  pinned in the `carveOut_nonCollapseBuffers_unchanged` test which
  asserts "literal must NOT take rank 0" — but `anaconda` contains a
  lone-`c` (between `a` and `o`) that the pre-fix engine silently
  absorbed into a phantom `1021`. Post-fix, literal correctly takes
  rank 0; the test removal is the correct response. `mahabodhi` (no
  unsupported letters) remains as the regression baseline for the
  carve-out class. Similarly, `ace`/`acer` were pinning the
  silent-absorption surfaces `အယ်`/`အယ်ရ` (option-pre-fix `c`
  dropped); their removal reverses the pinning of incorrect behavior.
  The new `MidBufferUnsupportedLetterSuite::midUnsupportedLetter_
  rank0HonorsLetter` covers `kca` and other lone-`c` mid-buffer
  buffers, exercising the same bug class explicitly.
- **False-positive scan:** Cluster aliases `cha`, `chai`, `chwe`,
  `chu`, `char`, `chee` (c-followed-by-h) are NOT promoted to
  literal — confirmed via probe and the new `clusterC_unaffected`
  case. Other cluster shortcuts (`j`, `gy`, `sh`, `kya`-style) also
  unaffected. Normal codas (`kar`, `kal`, `kan`, `kang`, ...) work
  normally.
- **Mid-buffer cluster-c:** `kchu` and `kacha` (c followed by h) do
  not trip class_E.
- **`c` detection logic:** Only lone-`c` (not followed by `h`)
  triggers; confirmed via the engine code at `BurmeseEngine.swift`
  around line 3199 — the `next != "h"` guard correctly excludes
  cluster-c. Note: this lookahead checks only the very next
  character, so `cy`/`cw`/etc. are treated as unsupported. The bug
  body did mention `ck` as a candidate exception but the fix
  intentionally narrows to just `ch`/`chw`, which matches the
  actual romanization rule table.
- **Reading-vs-surface contract:** New `readingMatchesSurface` test
  asserts the invariant that the candidate's reading carries no
  unsupported letter that the surface lacks — closes the
  pre-existing gap.
- **Test run:** 1556/1556 cases, 8581/8581 assertions pass.
- **Bench check:** `BurmeseBench --check --samples 5` reports "no
  regressions" (the predicate runs only inside the literal-fallback
  path so perf impact is negligible).
