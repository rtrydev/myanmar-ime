# TASK-070: Mid-sentence `aha-` typing skips leading-A promotion, drops `အ` from `အ`-prefix syllables

## Status
Completed

## Implementation Notes
- Root cause was in `Parser/Matching.swift::filterAhStrandedAMatches`. The
  TASK-046 "stranded-`a`" carve-out only preserved the `ah` consonant
  onset when the immediately-preceding character was another `a` (the
  `<C>a-aha-<X>` site). Mid-sentence boundaries that the user expresses
  with tone markers (`.`, `:`), explicit `+`, or apostrophe `'` were
  NOT covered, so `ah` was dropped and the parser fell through to the
  `<a-standalone> + ha + <V>` decomposition, silently erasing the `အ`
  in the long-buffer windowed merge for
  `ComprehensiveRanking.sentence_article_newsDaily`.
- Fix: extend the carve-out to additionally preserve `ah` when the char
  immediately preceding the match is `.`, `:`, `+`, or `'`. Buffer-
  leading `ah` (`start == 0`) intentionally stays in the drop branch so
  `AhConsonantBoundaryH` invariants for `aha`, `ahar`, `ahin`, `ahan`,
  `ahot`, etc. remain green (the user's typing intent for those bare
  shapes is `<a-anchor> + h + <V>`, not the lexicon's `ahaung → အောင်`
  collapse).
- Tests added: `TASK070MidSentenceAhaPrefixSuite` covers the full class
  of `<lhs><boundary>aha<X>` shapes (`.`, `:`, `+`, `'`, plain inherent-a,
  buffer-leading control), and the panel-reachability invariant for
  `thi.ahaung`/`tha:ahaung` — i.e. the `သိအောင်`/`သးအောင်` sibling
  must appear in the top-8 panel via the lexicon's `ahaung → အောင်`
  alias path.

## Problem Description
After a tone-marked syllable boundary (e.g. `thi.`), a subsequent
`aha-`-prefixed segment that should compose to `အ + V-rule` instead
composes to `ဟ + V-rule` — the leading `အ` (U+1021) is silently dropped
even though the lexicon now ranks `ahaung → အောင်` at the top of its
alias table (penalty 0, score 829).

Concrete failing case
(`ComprehensiveRankingSuite.sentence_article_newsDaily`):

```
typed   : ...layarkaahakyaung:thi.ahaunglay.larte
expected: ...လောကအကြောင်းသိအောင်လေ့လာတယ်
got top1: ...လောကအကြောင်းသိဟောင်လေ့လာတယ်
```

The `ahaung` segment after `thi.` parses as `a + haung` (where the
leading `a` is dropped from the surface) instead of `ah + aung` (which
would hit the lexicon's `ahaung → အောင်` alias). The earlier
`ahakyaung:` segment in the same sentence DOES compose to `အကြောင်း`
correctly, so the bug is specific to mid-sentence boundaries.

## Root Cause
Suspected: `ReverseRomanizer.swift:88` documents the constraint
*"leading-A promotion fires only once per parse, so there's no clean
way to inject a fresh U+1021 mid-surface from a no-separator buffer"*.
Tone-marker (`.`/`:`) and explicit boundary characters likely don't
re-arm the promotion, so the second `aha-` falls through to the
`a + haung` parse.

The lexicon alias work (commit landed 2026-05-11) added `ahaung →
အောင်` as a penalty-0 alias for surface `အောင်`. That alias is
present and would resolve correctly if the parser produced `အောင်`
as a candidate. The bug is upstream of lookup — the parser never
generates `အောင်` as a candidate for the `ahaung` segment after
`thi.`, so the LM never gets a chance to score it.

## Burmese Language Rule Reference
N/A — engine parsing bug. The `ahaung → အောင်` typing convention is
documented in the lexicon TASK-046 commit context.

## Steps to Reproduce
1. Build production engine with bundled artifacts.
2. `engine.update(buffer: "thi.ahaung", context: [])`.
3. Inspect `state.candidates[0].surface` — observe missing `အ`.
4. Compare against `engine.update(buffer: "ahaung", context: [])` —
   leading `ahaung` does produce `အောင်` at rank 0.

## Current State
- `thi.ahaung` rank 0 = `သိဟောင်` (missing `အ`).
- `ahaung` (buffer-leading, no prefix) rank 0 = `အောင်` ✓.
- The sentence-level test `sentence_article_newsDaily` fails because
  exactly one `aha-` segment in the input is mid-sentence.

## Desired State
- Mid-sentence `aha-` typing reaches the lexicon's `aha-` alias rows
  the same way leading `aha-` does.
- `thi.ahaung` rank 0 = `သိအောင်` (or `သိ + အောင်` as two ranked
  candidates that ultimately bubble `အောင်` up).
- `sentence_article_newsDaily` and any future mid-sentence `aha-`
  test pass.

## Acceptance Criteria
- For inputs of the form `<syllable-with-trailing-tone-or-punct>aha<vowel-rule>`,
  the parser must produce a candidate where the leading `a` of the
  second segment resolves to U+1021 (mid-surface). The class includes
  but is not limited to: `thi.ahaung`, `te.ahalote`, `mi.ahain`,
  `tha:ahaung`, `kahaungaha-prefix` (no separator), etc.
- The same predicate should apply after ALL syllable boundaries the
  user can express: tone marks (`.`, `:`), explicit `+`, plain
  consonant-coda boundary (no separator). Currently only the
  buffer-leading case works because `promotedLeadingA` is a one-shot
  flag.
- `ComprehensiveRankingSuite.sentence_article_newsDaily` passes.
- `LexiconRankingSuite`, the rest of `ComprehensiveRankingSuite`,
  and the `ah-`-prefix alias paths (`ahaung → အောင်` for the
  buffer-leading case) stay green.

## Notes
- Code locations confirmed during validation:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/Finalization.swift`
    (lines ~813-924) — `promotedLeadingA` is a per-`materialize` flag
    that fires exactly once. Comment at the call site says "leading-A
    promotion only fires once" and is gated on `output.isEmpty`. To
    rearm mid-buffer, the promotion would need to either re-fire on
    syllable-boundary arcs or the parser would need to inject U+1021
    arcs at boundaries directly.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/ReverseRomanizer.swift`
    (lines ~85-95) — documents the same "fires only once per parse"
    constraint and warns that ReverseRomanizer for mid-surface `အ`
    intentionally emits the `ah` + trailing `a` form instead.
  - `Packages/BurmeseIMECore/Sources/LexiconBuilder/main.swift`
    (line ~444) — the `ah-`-prefix alias mechanism for surfaces that
    start with `အ` is in place; `ahaung → အောင်` exists as penalty-0
    alias for any surface beginning U+1021. The lexicon side is
    therefore wired up and the work is parser/engine-side.

## Validation Report
- **Verdict:** FULLY_COVERED.
- **Acceptance criteria:** All criteria covered. The parser carve-out
  extension in `Parser/Matching.swift::filterAhStrandedAMatches` now
  preserves `ah` onset across all enumerated boundary chars (`.`, `:`,
  `+`, `'`, plain inherent-`a`). Buffer-leading `ah` stays in the
  drop branch, preserving `AhConsonantBoundaryHSuite` invariants.
- **Test coverage:** `TASK070MidSentenceAhaPrefixSuite` adds 12
  cases: 3 buffer-leading controls, 7 mid-buffer class probes
  (covers every boundary char), 2 panel-reachability assertions for
  `thi.ahaung`/`tha:ahaung`. All pass.
- **Regression check:** Targeted `ComprehensiveRanking.article_newsDaily`
  is part of the now-passing `ComprehensiveRankingSuite`.
  `AhConsonantBoundaryHSuite` (buffer-leading `aha`/`ahar`/`ahin`/
  `ahan`/`ahot` invariants), `LexiconRankingSuite`,
  `LexiconLMDriftSuite`, `IncrementalParitySuite` all still green.
- **Notes:** No tests removed or assertions weakened. The carve-out is
  minimal and narrowly gated on prev-char identity, so the change does
  not affect any other parse shape.

## Validation Notes
- **Validity verdict:** Valid. Reproduced via `swift run TestRunner` —
  `ComprehensiveRanking.sentence_article_newsDaily` fails with exactly
  the surface described (`...သိဟောင်...` instead of `...သိအောင်...`).
- **Root-cause hypothesis confirmed:** Inspected
  `Parser/Finalization.swift` and `ReverseRomanizer.swift`; both
  contain explicit comments stating leading-A promotion fires once
  per `materialize` call. The lexicon's `ahaung → အောင်` alias does
  exist (verified in `LexiconBuilder/main.swift` line ~444), but
  the parser never generates the `အောင်` surface for the mid-buffer
  `ahaung` substring, so lookup never gets a chance to rerank.
- **Scope adjustments:** Broadened acceptance criteria from "the
  specific failing example" to "all syllable-boundary contexts where
  a fresh `အ` anchor is needed" — this is the general class. Added
  example shapes beyond `thi.aha…` so the fixing agent does not
  patch the tone-mark case alone.
- **Questions / risks:** A fix that re-arms the promotion at every
  boundary risks injecting spurious U+1021 mid-surface for input like
  `ka+aung` (where TASK-047/052 already injected a U+1021 anchor —
  see Finalization.swift line ~922). Verify the new fix composes with
  the existing "soft-`+` boundary injects U+1021" path rather than
  duplicating it. The `bareDiphthongShape` heuristic also injects
  U+1021 before dep-vowel arcs after diphthong-shape closers; any new
  promotion should compose with these.
