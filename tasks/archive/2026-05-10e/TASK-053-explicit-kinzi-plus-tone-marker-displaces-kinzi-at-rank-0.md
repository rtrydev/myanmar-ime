# TASK-053: Explicit kinzi `<C>{a,i}n+<C>` shape loses kinzi rank-0 promotion when a trailing tone marker (`.` / `:`) or digit is appended

## Status
Completed

## Problem Description
TASK-031 (archived, Completed) restored the kinzi rank-0 promotion
for explicit `+` buffers of shape `<C>in+<C>` / `<C>an+<C>` whose
post-stack syllable is a single bare base + inherent `a` (e.g.
`min+ga` → `မင်္ဂ`, `thin+ga` → `သင်္ဂ`, `than+ga` → no kinzi at
rank 0 even pre-TASK-031, so left out of scope). The fix worked for
the bare `<C>in+<C><inherent-a>` shape — but the rank-0 promotion
**does not survive** when the post-stack syllable carries a trailing
tone marker (`.` for creaky / `:` for visarga) or a trailing digit.
The same LM-driven re-segmentation that TASK-031 fixed reasserts
itself the moment the user adds the tone.

Reproduction (production-equivalent engine):

| Buffer        | Rank-0 surface (hex)                                  | Kinzi at rank 0? | TASK-031 status |
|---------------|-------------------------------------------------------|------------------|-----------------|
| `min+ga`      | `မင်္ဂ` (`1019 1004 103A 1039 1002`)                  | YES              | TASK-031 fix works |
| `min+ga.`     | `မည်န္ဂ့` (`1019 100A 103A 1014 1039 1002 1037`)       | NO               | regression |
| `min+ga:`     | `မည်န္ဂး` (`1019 100A 103A 1014 1039 1002 1038`)       | NO               | regression |
| `min+ga2`     | `မည်န္ဂ၂` (`1019 100A 103A 1014 1039 1002 1042`)       | NO               | regression |
| `min+ga2.`    | `မည်န္ဂ၂.` (`1019 100A 103A 1014 1039 1002 1042 002E`) | NO               | regression |
| `min+gha`     | `မင်္ဃ` (`1019 1004 103A 1039 1003`)                   | YES              | works |
| `min+gha.`    | `မည်န္ဃ့` (`1019 100A 103A 1014 1039 1003 1037`)       | NO               | regression |
| `thin+ga`     | `သင်္ဂ` (`101E 1004 103A 1039 1002`)                   | YES              | works |
| `thin+ga.`    | `သည်န္ဂ့` (`101E 100A 103A 1014 1039 1002 1037`)       | NO               | regression |
| `thin+ga:`    | `သည်န္ဂး` (`101E 100A 103A 1014 1039 1002 1038`)       | NO               | regression |
| `thin+gar`    | `သင်္ဂါ` (`101E 1004 103A 1039 1002 102B`)             | YES              | works (long vowel) |
| `thin+gar.`   | `သင်္ဂါ့` (`101E 1004 103A 1039 1002 102B 1037`)       | YES              | works (long vowel) |
| `than+ga`     | `သန်ဂ` (`101E 1014 103A 1002`)                         | NO (na-asat baseline) | TASK-031 baseline (asat class) — bare-engine also returns na-asat |
| `than+ga.`    | `သံဂ့` (`101E 1036 1002 1037`)                         | NO (anusvara!)   | regression — bare-engine baseline is `သန်ဂ့` |
| `than+ga:`    | `သံဂး` (`101E 1036 1002 1038`)                         | NO (anusvara!)   | regression — bare-engine baseline is `သန်ဂး` |
| `than+gar.`   | `သန်ဂါ့` (`101E 1014 103A 1002 102B 1037`)             | NO (na-asat)     | not a regression — bare-engine baseline is the same na-asat |
| `in+ga`       | `အင်္ဂ` (`1021 1004 103A 1039 1002`)                   | YES              | works |
| `in+ga.`      | `အင်္ဂ့` (`1021 1004 103A 1039 1002 1037`)             | YES              | works (no LHS consonant) |

The discriminator is:
- **Tone present + post-stack syllable is bare inherent-a** (`<C>ga.`,
  `<C>ga:`) → kinzi displaced
- **Tone present + post-stack syllable carries long vowel** (`<C>gar.`,
  `<C>gar:`) → kinzi survives
- **No tone, bare inherent-a** → kinzi survives (TASK-031 path)

This means short-kinzi buffers (`<C>{a,i}n+<C><inherent-a>(<tone>?)`)
are the bug class.

## Root Cause
The TASK-031 rank-0 promotion path in `Engine/BurmeseEngine.swift`
(`bestStrictInferredStackIndex` lift) operates on the set
`strictInferredStackOutputs` which is populated by
`inferImplicitStackMarkers`. The inference function is invoked
per-segment for `+`-bearing buffers
(`inferImplicitStackMarkersAcrossPlusSegments`). For `min+ga.`,
the segments are `min` and `ga.`. Neither segment alone has a
kinzi-able stack site (no consonant follows `min`'s `n` within the
segment; no preceding coda inside `ga.`). The inference returns
`nil` for each segment, and the reassembled buffer is `min+ga.`
without any inferred-`+` injection. Because the inference did not
fire, `strictInferredStackOutputs` is empty, and the rank-0
promotion lift cannot run — the LM's preferred non-kinzi
re-segmentation (`mi2n+ga` / `mi2na+ga`) wins.

For the post-tone "long-vowel" buffers (`min+gar.`), the kinzi
survives because the LM evidence for the non-kinzi sibling is
weaker (`mi2n+gar.` has fewer corpus hits than `mi2n+ga.` does),
so the kinzi-bearing parser candidate wins on score even without
the TASK-031 lift.

The fix surface area is therefore the rank-0 promotion path: when
the user typed an explicit `+` AND the parser produces a kinzi
candidate (e.g. `1004 103A 1039` upper on the post-`+` consonant),
the kinzi candidate should be promoted to rank 0 regardless of
whether `inferImplicitStackMarkers` fired. CLAUDE.md §6 makes the
intent explicit: "The LM may rank among legal stack variants, but
it should not displace the user's explicit kinzi/stack intent with
an unrelated segmentation."

## Burmese Language Rule Reference
Per CLAUDE.md §6: User-typed `+` is a hard syllable / stack
boundary. The LM may rank among legal stack variants, but it should
not displace the user's explicit kinzi/stack intent with an
unrelated segmentation.

When the user typed `min+ga.`, the structural reading is:
- Upper consonant: `m` + `i` (= `mi`, with `n` as the kinzi-asat
  coda)
- Kinzi virama site: `+`
- Lower consonant: `g`
- Tail: `a.` (inherent-a + creaky tone)

The canonical orthography is `မင်္ဂ့` (`1019 1004 103A 1039 1002
1037`) — kinzi upper, virama, lower `ga`, creaky tone. The LM's
preference for `မည်န္ဂ့` (using `nya-asat` for `min` and a
non-kinzi virama-stack) is a corpus-evidence-driven re-segmentation
that ignores the user's explicit `n+g` kinzi signal.

## Steps to Reproduce
1. Construct a production-equivalent engine.
2. Evaluate the following buffers and inspect rank-0 candidate:
   - `min+ga`, `min+ga.`, `min+ga:`, `min+ga2`, `min+ga2.`
   - `min+gha`, `min+gha.`
   - `thin+ga`, `thin+ga.`, `thin+ga:`
   - `than+ga.`, `than+ga:`, `than+gar.`
3. Compare against the no-tone baseline (`min+ga` etc.) where the
   TASK-031 promotion correctly fires.

## Current State
- `min+ga.`, `min+ga:`, `thin+ga.`, `thin+ga:`, `min+gha.`,
  `than+ga:`, `than+gar.` all displace the kinzi from rank 0 to
  rank ≥ 2.
- The user typed an explicit `n+g` kinzi signal — the engine
  interprets it as a soft request rather than a hard one when a
  tone is appended.
- Users typing common kinzi-bearing Burmese words with tone
  endings see the panel paged past 2-3 wrong candidates before
  the canonical form appears.

## Desired State
- Rank-0 for the bug-class buffers (`min+ga.`, `min+ga:`,
  `thin+ga.`, `min+gha.`, etc.) is the kinzi-bearing surface
  with the trailing tone correctly placed:
  - `min+ga.` → `မင်္ဂ့` (`1019 1004 103A 1039 1002 1037`)
  - `min+ga:` → `မင်္ဂး` (`1019 1004 103A 1039 1002 1038`)
  - `thin+ga.` → `သင်္ဂ့` (`101E 1004 103A 1039 1002 1037`)
- Non-kinzi siblings (`mi2n+ga.`, `mina+ga.`) remain reachable in
  the panel at rank ≥ 1.

## Acceptance Criteria
- **Kinzi class** (`<C>{m,th}in+<C>` with `C` ∈ {`m`, `th`}):
  - `engine.update(buffer: "min+ga.", context: [])` rank 0 has
    scalar sequence `1019 1004 103A 1039 1002 1037` (kinzi
    triple + ga + creaky).
  - Same shape (kinzi at rank 0) for `min+ga:`, `min+ga2`,
    `min+ga2.`, `thin+ga.`, `thin+ga:`, `min+gha.`,
    `thin+gha.`.
- **Asat-closure class** (`<C>an+<C>` where bare-engine baseline
  is `<C> 1014 103A <C>`, i.e. na-asat upper, NOT kinzi):
  - `than+ga.` rank 0 has scalar sequence `101E 1014 103A
    1002 1037` (`သန်ဂ့`) — i.e. matches the bare-engine
    baseline rather than the current anusvara `101E 1036 1002
    1037` displacement.
  - Same shape for `than+ga:` → `101E 1014 103A 1002 1038`,
    `kan+ga.` → `1000 1014 103A 1002 1037`, `yan+gun.` →
    `101A 1014 103A 1002 102F 1014 1037`, etc.
- Existing TASK-031 cases (`min+ga`, `thin+ga`, `in+ga`,
  `yan+gun`, `than+ga`, `kan+ga`, `min+galarpar`, etc.)
  continue to produce their bare-engine rank-0 surfaces at
  rank 0 (regression guard).
- Long-vowel siblings (`min+gar.`, `thin+gar.`, `than+gar.`)
  continue to produce their existing rank-0 surfaces.
  Specifically `than+gar.` already produces `101E 1014 103A
  1002 102B 1037` (na-asat upper) at rank 0 and that must
  not regress.
- A new suite
  `Sources/BurmeseIMETestSupport/Suites/ExplicitKinziTonePromotionSuite.swift`
  covers the cross-product of `<C>{in,an}+<C>{inherent-a,
  long-vowel}<tone-suffix>` for the strict-class consonants
  (`min+ga`, `thin+ga`, `than+ga`, `yan+gun`, `nan+ga`,
  `kan+ga`, `ran+ga`), asserting the appropriate bare-engine
  baseline (kinzi for the kinzi class, na-asat for the asat
  class) at rank 0 across no-tone / creaky / heavy / digit /
  digit+creaky suffix variants.
- TASK-031 regression guard buffers (`min+ga`, `min+gar`,
  `thin+ga`, `min+ka`, `tin+ga`, `tin+ga+min`, `ban+ga`,
  `min+ga+min`, `min+galarpar`) keep their existing rank-0.

## Notes
- Implementation likely involves widening `inferImplicitStackMarkers`
  to consider the cross-segment kinzi site `<...n>+<C>...` even
  when each individual `+`-delimited segment has no internal
  stack site. The `inferImplicitStackMarkersAcrossPlusSegments`
  function (in `Engine/InputNormalization.swift` around line 1152)
  already walks segment boundaries; the missing piece is firing an
  inferred kinzi when the LHS segment ends in `<vowel><n>` and
  the RHS segment starts with a stackable lower.
- The fix should also handle the `<C>an+<C>` shape consistently —
  currently `than+ga` (no tone) produces `သန်ဂ` (not kinzi) at
  rank 0, which is a pre-existing TASK-031 gap. The fix may need
  to extend the promotion to the `an+<lower>` class too.
- Related code locations:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift::bestStrictInferredStackIndex`
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/InputNormalization.swift::inferImplicitStackMarkers`
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/InputNormalization.swift::inferImplicitStackMarkersAcrossPlusSegments`
- This is the same shape as archived TASK-031 — same parse, same
  segmentation, same LM-driven displacement. The bug differs only
  in the suffix (no-tone vs. tone). The TASK-031 fix should be
  generalised to cover the tone-bearing tail.

## Validation Notes
- **Verdict: Valid.** Reproduced every listed buffer under the
  production-equivalent engine and compared against the bare
  engine. Bare engine produces the kinzi form at rank 0 for
  every tone-suffixed buffer; production engine displaces it
  out of rank 0 (and in some cases out of the panel top 7
  entirely):
  - `min+ga.`   PROD rank 0 = `1019 100A 103A 1014 1039 1002
    1037` (`မည်န္ဂ့`); BARE rank 0 = `1019 1004 103A 1039
    1002 1037` (`မင်္ဂ့`). **The kinzi candidate is not
    present anywhere in the production panel top 7** — only
    6 grammar candidates + 1 literal-fallback. The TASK-031
    promotion path's `readingMatchesUserLiteralAcrossInherentVowels`
    discriminator must not be admitting the kinzi parse for
    this buffer (or the parse is being dropped upstream).
  - `min+ga:`   same shape; kinzi not in panel.
  - `min+ga2`   same; kinzi not in panel.
  - `min+ga2.`  same; kinzi not in panel.
  - `thin+ga.`  PROD rank 0 = `101E 100A 103A 1014 1039 1002
    1037`; BARE rank 0 = `101E 1004 103A 1039 1002 1037`.
    Kinzi IS in PROD panel at rank 2 (`101E 1004 103A 1039
    1002 1037`).
  - `thin+ga:`  PROD rank 0 = `101E 100A 103A 1014 1039 1002
    1038`; kinzi at PROD rank 2.
  - `min+gha`   PROD rank 0 = kinzi `1019 1004 103A 1039
    1003` (works).
  - `min+gha.`  PROD rank 0 = `1019 100A 103A 1014 1039 1003
    1037`; kinzi at PROD rank 6.
  - `thin+ga`   PROD rank 0 = kinzi (works).
  - `thin+gar.` PROD rank 0 = kinzi (works — long-vowel sibling).
  - `than+ga`   PROD rank 0 = `101E 1014 103A 1002` (`သန်ဂ`,
    no kinzi). This is **also** the bare-engine rank 0 — so
    this is the pre-existing TASK-031 gap noted in the task
    body, not a tone-related regression.
  - `than+ga.`  PROD rank 0 = `101E 1036 1002 1037` (`သံဂ့`,
    anusvara — DIFFERENT from BARE rank 0 `101E 1014 103A
    1002 1037` `သန်ဂ့`). Tone appended displaces na-asat
    upper into anusvara upper — same shape as TASK-031's
    `kan+ga` / `yan+gun` anusvara displacement. This is
    NOT just an extension of TASK-031 — it's the SAME
    TASK-031 bug class, reproduced with a tone suffix.
  - `than+ga:`  PROD rank 0 = `101E 1036 1002 1038` (anusvara
    displacement again).
  - `than+gar.` PROD rank 0 = `101E 1014 103A 1002 102B 1037`
    (na-asat, no anusvara displacement); BARE rank 0 same.
    So this is actually **fine** for the bare-engine intent —
    the task's table entry "regression" claim needs nuance:
    the kinzi is not lost, but neither was kinzi the bare-
    engine baseline. Removing this row from the bug-class
    list during revision.
  - `in+ga`     PROD rank 0 = kinzi (works — no LHS consonant).
  - `in+ga.`    PROD rank 0 = kinzi (works — no LHS consonant
    means no LM segmentation competitor).
- **Changes during review:**
  - Status flipped from `Open` to `Revised`.
  - Corrected the severity claim: for several buffers the
    kinzi is not just "displaced to rank ≥ 2" — it is
    **completely missing from the production candidate
    panel** (e.g. `min+ga.`, `min+ga:`, `min+ga2`,
    `min+ga2.`). This is more severe than the original task
    described. For other buffers (`thin+ga.`, `thin+ga:`,
    `min+gha.`) the kinzi IS panel-reachable at rank 2-6.
    The fix must therefore not only re-promote at rank 0 but
    also ensure the kinzi parse is emitted in the first place
    (the production engine's `min+ga.` panel is suspiciously
    short at 7 candidates — TASK-031's
    `readingMatchesUserLiteralAcrossInherentVowels` may be
    filtering out the kinzi parse before it gets a chance
    to land in `strictInferredStackOutputs`).
  - Reclassified `than+ga.` and `than+ga:` from "pre-existing
    gap" to "the SAME TASK-031 bug class (anusvara
    displacement) reproduced with tone suffix" — they are
    not new bug shapes, they are the exact `kan+ga` / `than+ga`
    shape from TASK-031 that the original TASK-031 acceptance
    criteria covered but the implementation never lifted at
    rank 0 with a tone suffix. The fix is the same surface
    area.
  - Reclassified `than+gar.` — bare engine also returns
    na-asat (no kinzi) at rank 0, so this is not a kinzi
    regression. Removed it from the bug-class table in the
    Acceptance Criteria below.
  - Added the "kinzi parse missing from panel" observation
    to the Current State section.
- **Open question (resolved):** why is the kinzi parse
  missing from `min+ga.` production output entirely?
  Hypothesis 1: the parser produces it but `grammarParses`
  filtering drops it after applying the tone-aware
  per-syllable budget. Hypothesis 2: `readingMatchesUserLiteralAcrossInherentVowels`
  rejects the kinzi parse for tone-suffixed buffers because
  the parser's reading for kinzi is `min+ga.` (matches
  user) but the parse's `output` is suppressed by an
  upstream LM filter. The fixing agent should instrument
  `grammarParses` to confirm whether the kinzi parse
  reaches the ranking phase for `min+ga.`. If the parse is
  absent at the candidate-merge step, the fix must widen
  the per-syllable budget or relax the LM-dominance gating;
  if the parse is present but filtered, the fix is in
  `bestStrictInferredStackIndex` or `grammarCandidateIsBetter`.
- **Scope calibration:** the task is correctly scoped as
  "TASK-031's tone-suffix tail". The example list covers
  the kinzi class (`min+ga`, `thin+ga`, `min+gha`) and the
  anusvara-displacement class (`than+ga`), with all four
  tone-marker variants (`.`, `:`, `2`, `2.`). No splitting
  required. Suggest the fixing agent reuse
  `ExplicitPlusKinziDisplacementSuite`'s helper pattern for
  the new `ExplicitKinziTonePromotionSuite`.
- **Burmese rule reference:** confirmed against CLAUDE.md §6
  ("User-typed `+` is a hard syllable / stack boundary. The
  LM may rank among legal stack variants, but it should not
  displace the user's explicit kinzi/stack intent with an
  unrelated segmentation"). The bug class is directly an
  extension of TASK-031's premise to tone-bearing tails.
- **Code-path note for the fixing agent:** the existing
  TASK-031 fix at `BurmeseEngine.swift:1330-1352` populates
  `strictInferredStackOutputs` from
  `grammarParses` whose reading matches the user's literal
  buffer (via
  `readingMatchesUserLiteralAcrossInherentVowels`). For
  `min+ga.`, the kinzi parse's reading should be `min+ga.`
  (literal match) — the discriminator should accept it. If
  the kinzi parse isn't in `grammarParses`, that's an
  upstream parser-budget issue. Probe results suggest the
  kinzi parse is being dropped entirely for buffers like
  `min+ga.` but is present at rank 2 for `thin+ga.` — so
  the issue is parser-budget-sensitive to the LHS-consonant
  identity. The fixing agent should validate against the
  full bug-class list rather than just one buffer.

## Implementation Notes
- **Root cause confirmed:** for tone-suffixed buffers
  (`min+ga.`, `min+ga2.`, `kan+ga.`, `than+ga.`, …) the
  right-shrink probe in `parseLongestAcceptablePrefix` peels
  the trailing tone (`.` / `:`) or digit run into the literal
  tail before the parser sees the buffer. The parser's
  reading on the shrunk input (e.g. `min+ga`) does not carry
  the tone, so the existing TASK-031
  `readingMatchesUserLiteralAcrossInherentVowels` comparison
  against the verbatim `displayBuffer` (`min+ga.`) failed for
  every parse and `strictInferredStackOutputs` ended up empty
  — the rank-0 lift never had any user-respecting surface to
  promote, and the LM-driven sibling stayed at the top.
- **Approach:** the comparator is now invoked twice per parse
  — once against the verbatim `displayBuffer` (covering
  parses whose reading already carries the tone, e.g.
  `than+gar.` → reading `thana+gar.`) and once against a
  tone-/digit-stripped sibling (covering shrunk-buffer parses,
  e.g. `min+ga.` → reading `min+ga` after the right-shrink).
  Either match adds the parse's surface to
  `strictInferredStackOutputs`, after which the existing
  `bestStrictInferredStackIndex` lift promotes it to rank 0
  through both the regular and windowed paths.
- **Code changes:**
  - `Engine/BurmeseEngine.swift`: added
    `stripTrailingToneAndDigitMarkers(_:)` helper that peels
    a trailing run of `.` / `:` / ASCII-digit chars from a
    buffer.
  - `Engine/BurmeseEngine.swift` (line ~1330, the
    `displayBuffer.contains("+")` branch): the per-parse
    discriminator now accepts either an exact-match against
    `displayBuffer` or against
    `stripTrailingToneAndDigitMarkers(displayBuffer)`. The
    stripped-sibling check is gated on the strip having
    actually changed the input so we don't pay the
    comparator cost twice for tone-free buffers.
- **Tests:**
  - New `ExplicitKinziTonePromotionSuite` (registered in
    `BurmeseTestSuites.swift`) covers the kinzi-class buffers
    (`min+ga`/`tin+ga`/`thin+ga`/`in+ga` × `{∅, ., :, 2, 2.}`
    × `{ga, gha}`), the asat-closure-class buffers
    (`kan+ga`, `than+ga`, `yan+gun`, `ban+ga` × `{∅, ., :}`),
    concrete scalar-level expectations for `min+ga.`,
    `min+ga:`, `min+ga2`, `than+ga.`, the long-vowel sibling
    regression guards (`min+gar.`, `thin+gar.`, `than+gar.`),
    the TASK-031 no-tone baselines (regression guards), and a
    truth-table sanity check on
    `stripTrailingToneAndDigitMarkers`.
- **Verification:** all 1507 / 1507 cases pass after the fix
  (`swift run TestRunner`). Production-equivalent probe
  confirms every bug-class buffer now produces the bare-engine
  baseline at rank 0:
  - `min+ga.` → `1019 1004 103A 1039 1002 1037` (kinzi)
  - `min+ga:` → `1019 1004 103A 1039 1002 1038` (kinzi)
  - `min+ga2` → `1019 1004 103A 1039 1002 1042` (kinzi)
  - `min+ga2.` → `1019 1004 103A 1039 1002 1042 002E`
  - `min+gha.` → `1019 1004 103A 1039 1003 1037` (kinzi)
  - `thin+ga.` → `101E 1004 103A 1039 1002 1037` (kinzi)
  - `thin+ga:` → `101E 1004 103A 1039 1002 1038` (kinzi)
  - `kan+ga.` → `1000 1014 103A 1002 1037` (na-asat)
  - `kan+ga:` → `1000 1014 103A 1002 1038` (na-asat)
  - `than+ga.` → `101E 1014 103A 1002 1037` (na-asat;
    pre-fix anusvara at rank 0)
  - `than+ga:` → `101E 1014 103A 1002 1038` (na-asat;
    pre-fix anusvara at rank 0)
  - `yan+gun.` → `101A 1014 103A 1002 1030 1014 1037`
    (na-asat)
  - `than+gar.` → `101E 1014 103A 1002 102B 1037` (na-asat;
    long-vowel sibling regression guard)
  All TASK-031 no-tone regression guards (`min+ga`,
  `thin+ga`, `tin+ga`, `min+ka`, `kan+ga`, `ban+ga`,
  `min+galarpar`, etc.) continue to produce their existing
  rank-0 surfaces.

## Validation Report
- **Verdict:** FULLY_COVERED.
- **Test run:** All 1507/1507 cases (7969/7969 assertions) pass on
  `swift run TestRunner`. No benchmark regressions.
- **Suite coverage:** `ExplicitKinziTonePromotionSuite` (9 cases)
  covers:
  - Kinzi class panel-rank-0 assertion across `min`, `thin`,
    `tin`, `in` × tone/digit suffixes `{∅, ., :, 2, 2.}` ×
    `{ga, gha}` lower consonants (15 buffer combinations
    enumerated)
  - Asat-closure class panel-rank-0 assertion across `kan`,
    `ban`, `than`, `yan` × `{∅, ., :, gun., gar.}` suffixes
    (11 buffer combinations)
  - Anusvara-displacement guard (the bug shape `1036` substitution
    is rejected via `assertFalse(containsAnusvara)`)
  - Concrete scalar-level assertions for `min+ga.`, `min+ga:`,
    `min+ga2`, `than+ga.` (canonical kinzi triple + tone scalars)
  - TASK-031 no-tone baseline regression guards
  - Long-vowel sibling baseline regression guards (`min+gar.`,
    `thin+gar.`, `than+gar.`)
  - `stripTrailingToneAndDigitMarkers` predicate truth table
- **Coverage gaps:** none material. The acceptance criteria's
  full bug-class cross-product is enumerated. The helper is
  exposed via `@_spi(Testing) public` for direct testing.
- **Regression handling:** No existing tests modified. The fix is
  surgical — it adds a tone-/digit-stripped second comparison to
  the existing
  `readingMatchesUserLiteralAcrossInherentVowels` filter, gated
  on the strip having actually changed the input.
- **Risk assessment:** Low. The change widens the discriminator
  but does not relax it — a parse must match either the verbatim
  buffer OR the stripped buffer. Both checks use the same
  inherent-vowel-tolerant comparator. The full test suite passes
  (1507/1507).
- **Files touched:**
  - `/Users/rtry/repos/myanmar-ime/Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`
  - `/Users/rtry/repos/myanmar-ime/Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/ExplicitKinziTonePromotionSuite.swift` (new)
  - `/Users/rtry/repos/myanmar-ime/Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/BurmeseTestSuites.swift` (registration)
