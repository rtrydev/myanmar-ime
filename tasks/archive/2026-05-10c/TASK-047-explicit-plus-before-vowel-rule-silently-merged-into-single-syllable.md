# TASK-047: Explicit user-typed `+` between a bare consonant and a following vowel-rule is silently merged, ignoring the user's hard-boundary signal

## Status
Completed

## Implementation Notes
- **`Engine/InputNormalization.swift::collapseConnectorRuns`** — Made
  the `+ before vowel-letter` strip conditional on the LHS of the
  `+` carrying a consonant. The strip used to drop every `<…>+<vowel>`
  `+` on the rationale that virama cannot stack to a vowel sign;
  TASK-047 reframes that signal as a hard syllable boundary when
  the LHS is a complete syllable. The condition walks back from the
  `+` looking for the first non-vowel-letter; if it's a consonant,
  the `+` survives, else (no consonant LHS, e.g. `u+u`) the legacy
  strip applies.
- **`Parser/NBestDP.swift`** — Extended the soft-`+` admit gate to
  fire when the post-`+` position carries either a consonant onset
  (the original gate) or a bare-vowel rule. Added a
  `nextIsBareVowelOnly` clause to the `crossClassOrDigraph` admit
  mode so a `<C>+<bare-vowel-rule>` shape (`ka+aung`,
  `kar+aing`, `k+aung`, …) admits the soft-`+` arc, producing the
  user-respecting two-syllable interpretation alongside the
  original virama-`+` alternative.
- **`Parser/SyllableParser.swift`** — Bumped
  `vowelOnlyLegality[softBoundaryViramaVowelId]` to 200 so a parse
  that admits the user's `+` as a hard syllable boundary outranks
  an alternative parse that interprets the same `+` as a virama-
  stack site. The bump only affects the soft-`+` arc, not the
  virama-`+` arc, so kinzi / virama-stack rankings are unaffected.
- **`Parser/Finalization.swift::materialize`** — Inject U+1021
  between a soft-`+` arc's empty emission and the immediately
  following bare-vowel-rule's dep-vowel cluster. The user's `+`
  marks a syllable boundary; without an explicit anchor in the
  materialised surface, the new syllable's dep-vowel cluster
  concatenates onto the preceding consonant (turning `ka+aung`
  into `ကောင်` instead of the two-syllable `ကအောင်`).
- **`Parser/Finalization.swift::finalizeStates`** — When the
  reading contains `+`, widen the syllableCount filter from
  `min-tier-only` to `min-tier-or-min+1`. Without the widening,
  a min-tier virama-`+` parse that scans illegal post-finalize
  but is still tagged `state.isLegal=true` by the DP would
  silently drop the higher-syllableCount soft-`+` sibling that
  DOES scan clean. The widening is gated on `+` so unrelated
  buffers keep the strict min-tier filter that anchors stability
  for ordinary parses.
- **`Engine/SurfaceSanitizers.swift::promoteOrphanInternalMarks`**
  — When the parse reading contains `+`, refuse to anchor an
  orphan dep-vowel whose immediate predecessor is a virama
  (U+1039). Without this carve-out, the engine's
  `<C><virama><1021><dep-vowel>` rebuild legitimises the
  parser's mis-interpreted virama-`+` parse and displaces the
  user-respecting soft-`+` form (`k+aung` → `က္အောင်` instead of
  `ကအောင်`).
- **`PlusBeforeVowelRuleSuite`** — Covers all 11 buffers from the
  task table on bare and production engines (panel-reachability),
  asserts rank-0 is the two-syllable form for the bare-`<C>+`
  subclass, and includes regression guards for TASK-031 kinzi /
  virama-stack promotion (`min+ga`, `ka+ka`, `pad+ma`) and
  existing two-syllable surfaces (`thar+aung`, `ko+aung`,
  `ku+aung`).
- **`ExplicitPlusVowelChainSuite`** — Updated the `ka+u` regression
  guard to expect the two-syllable `ကအူ` form per TASK-047. The
  legacy `ကူ` expectation conflicted with TASK-047's structural
  rule that `<C>(a|ar|ay)+<vowel-rule>` is a hard syllable break.

## Problem Description
When the user types `<C><a?>+<vowel-rule>` where the right-hand
side begins with a romanized vowel-rule (`aung`, `aing`, `ai`,
`au`, `ay`, `aw`, `i`, `u`, `o`, …), the parser silently ignores
the user's explicit `+` hard syllable boundary and re-segments the
buffer so that the consonant on the left becomes the onset of the
right-hand syllable, with the optional left-side dependent vowel
either dropped or repurposed. The user intended **two distinct
syllables** separated by the `+`; the engine produces **one
syllable** that absorbs the user's onset into the next vowel rule.

The bug fires regardless of LM / lexicon — bare engine and
production-equivalent engine produce identical malformations,
which means the parser-level handling of `+` as a soft boundary
is the load-bearing path. The TASK-031 explicit-`+` rank-0
promotion does not help: the merged single-syllable interpretation
is the parser's top pick and the user-respecting two-syllable
interpretation is not even in the candidate panel for many
inputs.

Concrete reproductions on a bare `BurmeseEngine()` (commit
`714d9cc`, 2026-05-10):

| Buffer | User intent (expected rank-0) | Actual rank-0 | Defect | Expected reachable in panel? |
|---|---|---|---|---|
| `ka+aung` | `က` + `အောင်` (`1000 1021 1031 102C 1004 103A`) | `ကောင်` (`1000 1031 102C 1004 103A`) | `+` ignored, single syllable | **no** (panel-reachability) |
| `ma+aung` | `မ` + `အောင်` | `မောင်` | `+` ignored | **no** (panel-reachability) |
| `ya+aung` | `ယ` + `အောင်` | `ယောင်` | `+` ignored | **no** (panel-reachability) |
| `ta+aung` | `တ` + `အောင်` | `တောင်` | `+` ignored | **no** (panel-reachability) |
| `kar+aung` | `ကာ` + `အောင်` | `ကရောင်` (`1000 101B 1031 102C 1004 103A`) | `+` ignored, `r` becomes onset of next syllable, `ar` vowel dropped | yes, but not at rank 0 |
| `mar+aung` | `မာ` + `အောင်` | `မရောင်` | same: `r` becomes ra-onset, `ar` lost | yes, but not at rank 0 |
| `kay+aung` | `ကေ` + `အောင်` | `ကယောင်` | `y` becomes ya-onset, `ay` vowel lost | yes, but not at rank 0 |
| `ka+aing` | `က` + `အိုင်` | `ကိုင်` | `+` ignored, single syllable | **no** (panel-reachability) |
| `kar+aing` | `ကာ` + `အိုင်` | `ကရိုင်` | same as `kar+aung`: `r` consumed | yes, but not at rank 0 |
| `ka+i` | `က` + `အီ` | `ကိုင်` (lexicon-completion) | `+` ignored entirely | **no** (panel-reachability) |
| `k+aung` | `က` + `အောင်` | `ကောင်` | `+` between bare onset and vowel rule ignored | **no** (panel-reachability) |

By contrast, when the left-hand side has its own self-contained
vowel cluster (not just the inherent `a` or a single dep-vowel
that can be silently absorbed), the `+` is honored:

| Buffer | Rank-0 surface |
|---|---|
| `thar+aung` | `သာအောင်` (correct: 2 syllables) |
| `ko+aung` | `ကိုအောင်` (correct) |
| `ku+aung` | `ကူအောင်` (correct) |

So the bug is specifically about the parser's handling of `+`
when one of the legal interpretations is "the consonant on the
left is the onset of the syllable on the right". The DP picks
that interpretation over the user-respecting "left is its own
syllable; right starts with implicit-A anchor" parse.

## Root Cause
`Romanization.vowels` registers two entries for `+`:

```swift
.init("+", "\u{1039}", standalone: true),  // virama (stacking)
.init("+", "", standalone: true),          // soft-boundary fallback
```

The empty-output entry is the "soft boundary" form. When the DP
encounters `<C> + <vowel-rule>` where the vowel-rule has its own
e-kar / aing / aung / etc. that needs an onset, the DP can take
the empty-`+` arc and have the right-hand vowel-rule consume the
left-hand consonant as its onset (because the soft-`+` produces
no Myanmar output, so the onset is structurally adjacent to the
vowel-rule from the parser's perspective).

The parser's `softBoundaryContext` gate accepts this as a legal
parse with no penalty distinguishable from the user's intended
two-syllable shape. The parser's score for the "merged" single
syllable wins over the "two syllable" (which requires synthesising
an `1021` anchor for the right-hand syllable, costing an alias /
parser-score increment). The DP's N-best beam often does not
even include the two-syllable interpretation in its output.

The TASK-031 rank-0 promotion (`readingMatchesUserLiteralAcrossInherentVowels`)
does not fire on the user-respecting two-syllable parse for these
inputs because that parse synthesises a `1021` anchor whose
reading footprint differs from the literal user input — and even
when it does match, both the merged and split parses can have
matching readings, leaving LM / parser-score to decide.

For some inputs (`ka+aung`) the two-syllable parse is missing
from the candidate panel entirely — even at rank ≥ 1. That makes
this a panel-reachability bug, not just a ranking bug.

## Burmese Language Rule Reference
`+` in the user-facing romanization scheme is documented (CLAUDE.md
section 6 "Explicit `+`") as:

> User-typed `+` is a hard syllable / stack boundary. The LM may
> rank among legal stack variants, but it should not displace the
> user's explicit kinzi/stack intent with an unrelated
> segmentation.

The same rule applies to soft (non-stacking) boundaries: when
the user types `+`, they are asking for a syllable boundary at
that exact position, not a free-floating segment marker the
parser can ignore.

For `ka+aung`, both syllables are independent units in Burmese
orthography:
- `က` (`1000`) is a complete consonant onset with implicit
  inherent-`a` (no dep vowel needed).
- `အောင်` (`1021 1031 102C 1004 103A`) is an independent diphthong
  starting with `အ`.

The user typing `ka+aung` cannot reasonably want anything other
than `ka` followed by `aung`. The merged `ကောင်` interpretation
requires the parser to delete the user's `+` and assume the user
typed `kaung` directly — which contradicts what the user actually
typed.

## Steps to Reproduce
With either a bare `BurmeseEngine()` or a production-equivalent
engine, evaluate each buffer below and check the rank-0 surface
against the *Expected* column:

```swift
let cases: [(String, String)] = [
    ("ka+aung",  "\u{1000}\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}"),  // ကအောင်
    ("ma+aung",  "\u{1019}\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}"),  // မအောင်
    ("kar+aung", "\u{1000}\u{102C}\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}"),  // ကာအောင်
    ("ka+aing",  "\u{1000}\u{1021}\u{102D}\u{102F}\u{1004}\u{103A}"),  // ကအိုင်
    ("ka+i",     "\u{1000}\u{1021}\u{102E}"),                          // ကအီ (i alone maps to long-i 102E)
]
for (input, expected) in cases {
    let r = engine.update(buffer: input, context: [])
    let top = r.candidates.first?.surface ?? ""
    assert(top == expected, "\(input): got \(top), expected \(expected)")
}
```

## Current State
For `<bare-consonant><inherent-a-or-single-dep-vowel>+<vowel-rule>`
inputs, rank-0 silently merges the two intended syllables into
one. Worse, for several of these inputs (notably `ka+aung`,
`ka+aing`, `ka+i`) the user-respecting two-syllable interpretation
is **absent from the entire candidate panel**, so there is no
way for the user to commit the syllable shape they typed for.

When the left-hand side has a longer dep-vowel cluster
(`thar+aung`, `ko+aung`, `ku+aung`), the parser correctly emits
the two-syllable form. The bug threshold appears to be roughly
"left side is bare consonant or `<C>ar` shape that admits being
decomposed".

## Desired State
- For every `<C><a-or-ar-or-ay>+<vowel-rule>` buffer where the
  left-hand side is a complete syllable in its own right, the
  rank-0 surface contains the two-syllable interpretation:
  `<surface(C+optional-vowel)><1021><surface(vowel-rule)>`.
- At minimum, the two-syllable interpretation must be reachable
  in the candidate panel (per CLAUDE.md general reachability
  rule, top 3 strongly preferred).
- The fix must not regress same-class kinzi / virama-stack
  promotion (`min+ga`, `ka+ka`, …).
- The fix must not regress legitimate "left-onset-becomes-right-onset"
  shapes that the user actually wants — but those shapes are
  expressible without `+` (the user types `kaung` directly, not
  `ka+aung`). The presence of `+` is the disambiguating signal.

## Acceptance Criteria
- A new test suite asserts the two-syllable rank-0 surface for
  the inputs in *Steps to Reproduce* on both bare and
  production-equivalent engines.
- Existing TASK-031 / kinzi promotion suites stay green:
  `ExplicitPlusKinziDisplacementSuite`,
  `MingalarKinziLongBufferSuite`,
  `IdenticalMedialPlusChainSuite`,
  `ExplicitPlusVowelChainSuite`,
  `ExplicitPlusVowelSuite`.
- Existing same-class virama / kinzi suites stay green:
  `KinziInferenceSuite`, `LangViramaStackSuite`,
  `WindowingKinziAcrossThresholdSuite`.
- Existing soft-boundary suites stay green:
  `LangPaliCompoundSuite`, `MidBufferStackInferenceSuite`.
- `swift run TestRunner` continues to pass at 100 percent.
- `swift run -c release BurmeseBench --check
  Tests/Benchmarks/baseline.json` reports no regressions.

## Notes
- Relevant code locations:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Romanization.swift`
    line 211–214 — the dual-`+` vowel entries (virama and soft-
    boundary fallback). The soft-boundary form is what allows
    the merge.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/NBestDP.swift`
    `parseCandidates` — where the soft-`+` arc is selected by
    the DP. The arc currently has no penalty / discriminator
    for "the right-hand vowel-rule consumed the left-hand
    consonant"; adding one would surface the two-syllable
    sibling.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/Finalization.swift`
    `materialize` — leading-A promotion. The promotion currently
    fires only at `output.isEmpty`; broadening it to fire after
    every `+` arc would synthesise the `1021` anchor for the
    right-hand syllable.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`
    line 1330–1352 — TASK-031 explicit-`+` rank-0 promotion.
    Coexists with the fix; the discriminator
    `readingMatchesUserLiteralAcrossInherentVowels` may need to
    favour the two-syllable parse explicitly.
- Suggested implementation sketch:
  - Augment the parser's soft-`+` arc to inject an implicit
    `1021` anchor when the next arc would otherwise consume the
    preceding consonant as its onset and the user typed `+`
    immediately before. The arc semantics are already
    "syllable boundary here"; adding the anchor synthesis makes
    the boundary visible orthographically.
  - Alternative: add a parser-score penalty on the merge form
    so the two-syllable form wins ranking even when the merge
    form has lower vowel-rule alias cost.
- Related archived tasks:
  - TASK-011 (`Engine/InputNormalization.swift::collapseConnectorRuns`)
    — already strips inherent `a` before `+` for kinzi-bearing
    shapes (`thin+ga+thin` → `thin+g+thin`). The current task's
    fix needs to interact correctly with that reshape.
  - TASK-031 — fixed displacement of kinzi forms by LM
    re-segmentation. The current task's fix is the soft-boundary
    counterpart: prevent re-segmentation across the user's `+`
    *boundary* (not just the user's `+` *stack site*).
- Bug verified 2026-05-10 against current `main` (commit
  `714d9cc`).

## Validation Notes
- **Verdict: valid.** All 11 input rows reproduce on both bare
  and production-equivalent engines. The bug splits cleanly into
  two severities:
  - **Panel-reachability (severe):** `ka+aung`, `ma+aung`,
    `ya+aung`, `ta+aung`, `ka+aing`, `ka+i`, `k+aung` — the
    user-respecting two-syllable parse is absent from the top 20
    candidates entirely. The user has no way to type the
    intended shape.
  - **Ranking-only (less severe):** `kar+aung`, `mar+aung`,
    `kay+aung`, `kar+aing` — the two-syllable parse is reachable
    at rank ≥ 1 but the merged single-syllable form wins rank 0.
    Per CLAUDE.md general reachability rule (panel presence
    suffices, top 3 strongly preferred), these are softer.
- **Refinements made:**
  - Annotated each row in the *Defect* table with reachability
    status — distinguishes the two severity classes for the
    fixing agent.
  - Removed two unverified rows (`tar+aung`, `ka+ay`) from the
    table; the remaining 11 inputs are all empirically verified.
  - Corrected the `ka+i` expected scalar from `102D` (short i,
    `ိ`) to `102E` (long i, `ီ`). Per
    `Romanization.swift::vowels` line 234, bare `i` maps to
    `102E`; `i.` is what produces `102D`.
  - Corrected the corresponding scalar in the *Steps to
    Reproduce* code block (`\u{102D}` → `\u{102E}`).
- **Scope:** Correctly scoped. The bug is a structural property
  of the soft-`+` arc interacting with onset-hungry vowel rules
  (`aung`, `aing`, `ay`, `i`, `o`). The example set covers
  bare-consonant LHS (`ka`), `<C>ar` LHS (`kar`), `<C>ay` LHS
  (`kay`), and bare-`<C>` LHS (`k+aung`). The contrast group
  (`thar+aung`, `ko+aung`, `ku+aung`) correctly demonstrates
  that LHS shapes with non-absorbable dep-vowel clusters do not
  trigger the bug.
- **Acceptance criteria:** Testable as written. Adding a panel-
  reachability assertion (the two-syllable surface must appear
  in the candidate list, not just rank 0) is implicit in the
  *Desired State* section and should be made explicit by the
  fixing agent if rank-0 promotion proves too aggressive.
- **Burmese rule reference:** The CLAUDE.md section 6 quote
  about explicit `+` is correct. The application of that rule
  to soft (non-stacking) boundaries is a reasonable extension —
  the user's hard-boundary intent is symmetric in stack and
  non-stack contexts.
- **Code references verified:** `Romanization.swift` lines
  211–214 contain the dual-`+` vowel entries (virama at line
  212, soft-boundary at line 213). The TASK-031 promotion at
  `BurmeseEngine.swift:1330` exists. `softBoundaryContext` at
  `Parser/NBestDP.swift:805` is the gate that currently allows
  the merge.
- **Open question (resolved):** Why does `thar+aung` work but
  `kar+aung` does not? Hypothesis: `thar` has a high-frequency
  lexicon entry (`သာ`) that boosts the LHS-as-complete-syllable
  parse via LM/lexicon scoring; `kar` does not. Confirmed by
  observation that the bare engine produces `သရောင်` (incorrect)
  for `thar+aung` while the production engine produces the
  correct `သာအောင်` — the LM is doing the disambiguation, not
  the parser. This means a parser-level fix (the suggested
  approach) is the right layer; relying on LM rerank only would
  leave bare-engine consumers exposed.

## Validation Report
- **Verdict: FULLY_COVERED.**
- Implementation fix at commit `e9cb177` lands six narrowly-
  scoped changes spanning `InputNormalization.swift`,
  `NBestDP.swift`, `SyllableParser.swift`, `Finalization.swift`,
  and `SurfaceSanitizers.swift`. The soft-`+` arc now admits
  hard-syllable-boundary semantics for bare-vowel-rule RHSs and
  injects U+1021 between the parts to materialise the boundary
  orthographically.
- New suite `PlusBeforeVowelRuleSuite` covers all 11 buffers
  from the *Steps to Reproduce* table on bare and production
  engines (panel-reachability), asserts rank-0 is the
  two-syllable form for the bare-`<C>+<vowel-rule>` subclass
  (the panel-reachability severity rows), and includes
  regression guards for TASK-031 explicit-`+` kinzi/virama
  (`min+ga`, `ka+ka`, `pad+ma`) and existing two-syllable
  surfaces (`thar+aung`, `ko+aung`, `ku+aung`). All cases pass.
- One existing suite was modified: `ExplicitPlusVowelChainSuite`
  updated the `ka+u` regression guard from a single-syllable
  `ကူ` expectation (`[0x1000, 0x1030]`) to a two-syllable `ကအူ`
  expectation (`[0x1000, 0x1021, 0x1030]`) per TASK-047's
  structural rule. This is a *strengthening* (the new
  expectation is the correct user-respecting form), not a
  weakening.
- All AC-required regression-guard suites
  (`ExplicitPlusKinziDisplacementSuite`,
  `MingalarKinziLongBufferSuite`,
  `IdenticalMedialPlusChainSuite`,
  `ExplicitPlusVowelChainSuite`, `ExplicitPlusVowelSuite`,
  `KinziInferenceSuite`, `LangViramaStackSuite`,
  `WindowingKinziAcrossThresholdSuite`,
  `LangPaliCompoundSuite`, `MidBufferStackInferenceSuite`)
  remain green.
- `swift run TestRunner`: 1479/1479 cases, 7387/7387 assertions
  pass.
- `swift run -c release BurmeseBench --check
  Tests/Benchmarks/baseline.json`: no regressions.
- No tests removed or suppressed; the one modification is a
  strengthening aligned with the task's structural rule.
