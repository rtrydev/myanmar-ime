# TASK-051: Mid-buffer digit immediately followed by dep-vowel / medial / e-kar produces illegal Unicode storage order at rank 0

## Status
Completed

## Problem Description
When the user types an ASCII or Myanmar digit (`0-9`) in the middle of
a buffer between a Myanmar consonant onset (or medial) and a following
vowel rule whose materialised surface begins with a dep-vowel scalar,
medial scalar, or e-kar scalar (U+102B..U+1032, U+1036, U+103B..U+103E),
the engine emits a rank-0 candidate where the digit scalar (U+0030..U+0039
or U+1040..U+1049) sits **between** the consonant and the dep-vowel /
medial / e-kar that should attach to it. The dep-vowel marks are
therefore visually attached to the digit, not to the consonant — a
Unicode-storage-order violation per CLAUDE.md §3 ("a digit never
anchors asat or dependent marks").

Examples from a production-equivalent engine:

| Buffer        | Rank-0 surface (hex)                                  | Why illegal |
|---------------|-------------------------------------------------------|-------------|
| `ka2aung`     | `1000 1042 1031 102C 1004 103A`                       | `1042` digit followed by `1031` e-kar, then aa + kinzi-asat — the e-kar / aa / asat cluster anchors on the digit, not on `1000` |
| `ka2ar`       | `1000 1042 102C`                                      | digit followed by `102C` aa |
| `ka2i`        | `1000 1042 102E`                                      | digit followed by `102E` long-i |
| `ka2u`        | `1000 1042 1030`                                      | digit followed by `1030` long-u |
| `ka2y` (=`ka` + `2` + `y`/`e`) | `1000 1042 1031`                     | digit followed by `1031` e-kar |
| `kya2aung`    | `1000 103B 1042 1031 102C 1004 103A`                  | `1042` between medial `103B` and `1031` e-kar |
| `kya2y`       | `1000 103B 1042 1031`                                 | medial + digit + e-kar |
| `ky2aung`     | `1000 103B 1042 1031 102C 1004 103A`                  | same shape via reading-internal `ky2` digit |
| `khy2et`      | `1001 103B 1042 1000 103A`                            | digit between medial and coda-consonant + asat |
| `ka2yar`      | `1000 1042 1031 102C`                                 | digit + e-kar + aa (no consonant base for the dep-vowel cluster) |
| `t2ote` (rank 2) | `1010 1042 102F 1010 103A`                         | digit + short-u + coda — short-u anchors on digit |
| `kar2na` (rank 0) | `1000 102C 1042 1014`                             | clean — digit is followed by a fresh consonant `1014`; this is a non-violator counter-example |
| `kar2aung` (rank 0) | `1000 102C 1042 1021 1031 102C 1004 103A`        | clean — `1021` anchor is correctly injected after the digit so the `aung` cluster has its own base |

The general class is `<Myanmar-base-or-medial><digit><dep-vowel-or-medial>`,
where the dep-vowel / medial scalar's nearest base on its left is a
digit rather than a consonant base. The legitimate rank-0 shape for
each of these buffers is `<consonant>(<medial>?)<digit><U+1021 anchor>
<dep-vowel cluster>...`, i.e. the same `1021` injection the engine
already performs for `kar2aung` and `tar2aing`. The bug is that the
injection only fires when the digit's predecessor is a fully-formed
dep-vowel cluster (`ar`, `aing`, `aung` already finished); when the
digit lands immediately after a bare onset (consonant + optional
medial) and the next syllable's first scalar is a dep-vowel / e-kar,
the injection is skipped.

## Root Cause
Two issues feed the bug:

1. `Engine/SurfaceSanitizers.swift::surfaceContainsDigitOrphanAsat`
   (TASK-052) covers only `<digit>103A` and `<digit>1021 103A`
   adjacencies. It does not cover `<digit><dep-vowel>` (102B..1032),
   `<digit>1036` (anusvara), or `<digit><medial>` (103B..103E)
   adjacencies. The illegal storage-order shape therefore passes the
   sanitizer pipeline unchallenged.

2. The orphan-mark anchor injector (`promoteOrphanInternalMarks` in
   `Engine/SurfaceSanitizers.swift`) injects `U+1021` between the
   prior syllable's closure and an unanchored dep-vowel cluster. The
   injector's "this mark already has an anchor" check
   (`attachableMarkHasAnchor`) treats a digit-bearing scalar's
   leftward walk as not-yet-terminated and finds the consonant base
   further back, so it concludes the dep-vowel IS anchored — but the
   anchor it finds is across a digit, which is structurally illegal.

The parser/DP path materialises `<C>(<medial>?)` for the prefix and
`<digit><dep-vowel-rule>` for the tail because the vowel rule lookup
in the parser is per-syllable and does not see the digit as a
syllable boundary. The digit lands at its typed position (per
CLAUDE.md §3 "Digits Are Literal") and the trailing vowel-rule's
materialised scalars are concatenated directly after the digit.

## Burmese Language Rule Reference
Per Unicode TUS storage order for Myanmar (U+1000..U+109F), dependent
vowel marks (U+102B..U+1032), the anusvara `U+1036`, and medials
(U+103B..U+103E) must immediately follow their consonant base (with
the optional kinzi `1004 103A 1039` upper or virama-stack upper
between). A digit (U+1040..U+1049 or U+0030..U+0039) is never a
consonant base — it does not anchor dependent marks. CLAUDE.md §3
codifies this as "a digit never anchors asat or dependent marks."

The bug class extends the existing TASK-052 / TASK-014 family from
"digit + asat" to "digit + any combining mark in the U+102B..U+103E
range that requires a consonant base on its left".

## Steps to Reproduce
1. Construct a production-equivalent engine.
2. Evaluate each of the following buffers:
   - `ka2aung`, `ka2ar`, `ka2i`, `ka2u`, `ka2y`, `ka2aing`
   - `kya2aung`, `kya2y`, `ky2aung`, `khy2et`, `khy2it`, `khy2at`,
     `khy2ot`, `khy2up`
   - `t2ote`, `ny2an`, `ny2an*`
3. Inspect the rank-0 surface and confirm the scalar adjacency
   `<digit>(<dep-vowel> | <medial> | 1036 | 1031)` appears.

## Current State
- Rank-0 candidates for these buffers carry illegal Unicode storage
  order where dep-vowel / medial / anusvara / e-kar scalars are
  anchored to a digit rather than a consonant base.
- The candidates render in unpredictable ways across rendering
  engines: some show the dep-vowel as a floating mark, some
  attach it to the wrong glyph, some show a tofu / replacement
  character.
- The user has no clean two-syllable form in the panel:
  `ka2aung` should produce `က၂အောင်` (`1000 1042 1021 1031 102C
  1004 103A`) but no candidate carries the `1021` anchor for the
  second syllable.

## Desired State
- The rank-0 candidate for `<C>(<medial>?)<digit><dep-vowel-rule>`
  buffers carries a `U+1021` anchor between the digit and the
  following dep-vowel / medial / e-kar cluster, so the dep-vowels
  attach to the injected `1021` independent vowel rather than the
  digit. Examples:
  - `ka2aung` → `က၂အောင်` (`1000 1042 1021 1031 102C 1004 103A`)
  - `kya2aung` → `ကျ၂အောင်` (`1000 103B 1042 1021 1031 102C 1004
    103A`)
  - `ky2aung` → same as `kya2aung` (the `ky2` digit collides with
    the CLAUDE.md §3 "digit-is-data" rule, so the canonical
    rank-0 should preserve the `2` at its typed position with a
    `1021` anchor for the following `aung` cluster)
  - `t2ote` → `တ၂အုတ်` (or simply suppress the malformed sibling
    so the literal-digit form `တ` + `2` is rank 0)
- The sanitizer rejects any candidate whose surface contains
  `<digit>(102B..1032 | 1036 | 103B..103E)` adjacency unless the
  digit is followed by a `1021` anchor.

## Acceptance Criteria
- `engine.update(buffer: "ka2aung", context: [])` rank 0 has scalar
  sequence `1000 1042 1021 1031 102C 1004 103A` (or equivalent
  `1000 0032 1021 1031 102C 1004 103A` with ASCII digit).
- For every buffer in the reproduction set, no rank-0 candidate
  carries the `<digit><dep-vowel-or-medial>` adjacency.
- `kar2aung` → `1000 102C 1042 1021 1031 102C 1004 103A` continues
  to work (the regression guard).
- A new suite `Sources/BurmeseIMETestSupport/Suites/DigitDepVowelAnchorSuite.swift`
  asserts the panel-presence invariant for the cross-product of
  base consonants × digits × vowel-rules-starting-with-dep-vowel.
- `surfaceContainsDigitOrphanAsat` is extended (or a sibling
  predicate `surfaceContainsDigitOrphanDepVowel` is added) to
  flag the new adjacency class.

## Notes
- Related sanitizer code lives at
  `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`
  around `sanitizeDigitOrphanAsat` (line ~592) and the
  orphan-mark anchor injector `promoteOrphanInternalMarks`
  (line ~1487).
- The `ky2aung` reading variant raises a secondary question: per
  CLAUDE.md §3 the digit `2` in `ky2` is data, not a disambiguator,
  in the user-facing path. But the romanization reading table
  uses `ky2` as the canonical key for ya-pin. The fix must decide
  whether to produce `1000 103B 1042 1021 1031 102C 1004 103A`
  (digit-as-data interpretation, with `1021` anchor) or
  `1000 103B 1031 102C 1004 103A` (digit-as-disambiguator
  interpretation, dropping the digit). The former is consistent
  with the rest of the CLAUDE.md §3 rules; the latter would
  require user-facing romanization changes outside this task's
  scope.
- Counter-examples that must keep working:
  - `kar2aung` → `1000 102C 1042 1021 1031 102C 1004 103A`
  - `tar2aing` → `1010 102C 1042 1021 102D 102F 1004 103A`
  - `pyate2` → `1015 103B 102D 1010 103A 1042` (digit at the
    end, no following dep-vowel — current behavior is correct
    and must remain).
  - `kar2na` → `1000 102C 1042 1014` (digit followed by a fresh
    consonant — no violation, must remain).

## Validation Notes
- **Verdict: Valid.** Reproduced every listed buffer under the
  production-equivalent engine
  (`SQLiteCandidateStore(.../BurmeseLexicon.sqlite)` +
  `TrigramLanguageModel(.../BurmeseLM.bin)`). Probe transcript:
  - `ka2aung` rank 0 = `1000 1042 1031 102C 1004 103A` (digit
    `1042` directly followed by e-kar `1031`; no `1021` anchor)
  - `ka2ar`   rank 0 = `1000 1042 102C` (digit + aa)
  - `ka2i`    rank 0 = `1000 1042 102E` (digit + long-i)
  - `ka2u`    rank 0 = `1000 1042 1030` (digit + long-u)
  - `ka2y`    rank 0 = `1000 1042 1031` (digit + e-kar)
  - `ka2aing` rank 0 = `1000 1042 102D 102F 1004 103A`
  - `kya2aung` rank 0 = `1000 103B 1042 1031 102C 1004 103A`
    (medial `103B` + digit + e-kar)
  - `ky2aung`  rank 0 = `1000 103B 1042 1031 102C 1004 103A`
  - `khy2et`   rank 0 = `1001 103B 1042 1000 103A` (medial +
    digit + coda + asat — the asat anchors via the new coda
    consonant `1000`, so this case is actually a *medial after
    digit* violation, not an asat-after-digit violation; the
    existing `surfaceContainsDigitOrphanAsat` predicate does
    not fire because `1042` is followed by `1000`, not `103A`)
  - `t2ote`    rank 0 = `1010 1042 102D 102F 1010 101A 103A`
    (digit + o-cluster on digit), rank 2 = `1010 1042 102F
    1010 103A` (digit + short-u on digit)
  - `kar2aung` rank 0 = `1000 102C 1042 1021 1031 102C 1004
    103A` (clean — `1021` injected, must remain)
  - `tar2aing` rank 0 = `1010 102C 1042 1021 102D 102F 1004
    103A` (clean)
  - `kar2na`   rank 0 = `1000 102C 1042 1014` (clean — digit
    followed by consonant base, no violation)
  - `pyate2`   rank 0 = `1015 103B 102D 1010 103A 1042` (clean
    — digit trailing, no following dep-vowel)
- **Changes during review:**
  - Status flipped from `Open` to `Revised` to flag that the
    task has been audited.
  - Added `kar2na` to the explicit counter-example list at the
    bottom (it was in the body table but not in the regression
    guard list).
  - Confirmed the root-cause analysis line-numbers map to the
    current tree: `surfaceContainsDigitOrphanAsat` lives at
    `Engine/SurfaceSanitizers.swift:602` (predicate) and
    `sanitizeDigitOrphanAsat` at line 592;
    `promoteOrphanInternalMarks` at line 1487;
    `attachableMarkHasAnchor` at line 1630. The existing
    predicate only covers `<digit>103A` and `<digit>1021 103A`
    adjacency. Extending it to cover `<digit>(102B..1032 |
    1036 | 103B..103E)` adjacency, AND teaching
    `promoteOrphanInternalMarks` to inject a `1021` anchor on
    the right of a digit before a dep-vowel cluster, are both
    necessary for the fix.
  - Confirmed `attachableMarkHasAnchor` (line 1630) walks the
    surface backward and falls through to `return false` when
    it crosses a digit scalar (digits don't match any of the
    return-true branches and don't satisfy
    `isAttachableMarkValue`, so the loop reaches `return
    false` at line 1705). The bug is therefore NOT that the
    anchor check accepts the digit-bearing prefix as a valid
    anchor for a dep-vowel — it correctly rejects it. The
    actual failure path is upstream: the candidate is emitted
    by the parser with `<digit><dep-vowel>` adjacency and
    `promoteOrphanInternalMarks` is either not run on this
    parse or its injection sites don't include the post-digit
    position. Fixing agent should verify which path emits the
    candidate before broadening the sanitizer.
- **Open question (resolved):** the task's "Root Cause"
  section conjectured that `attachableMarkHasAnchor` "treats a
  digit-bearing scalar's leftward walk as not-yet-terminated
  and finds the consonant base further back". A direct read
  of the function disproves that — it returns `false` when it
  crosses a digit. The true cause is more likely that
  `promoteOrphanInternalMarks` does not run on parses
  emitted with a mid-buffer digit segment (see also
  `MidBufferDigits.swift` for the digit-extraction path which
  may bypass orphan-mark promotion). Updated the Root Cause
  description below in spirit; left the original text in
  place so the fixing agent can re-evaluate.
- **Scope:** the task is correctly scoped as a general class
  (`<digit><any dep-vowel/medial/e-kar>`). The examples cover
  the orthographic cross-product (e-kar, aa, long-i, long-u,
  short-u + coda, o-cluster, medial-after-digit) and the
  counter-examples (clean digit-trailing and digit-followed-
  by-consonant cases). No splitting required.
- **Burmese rule reference:** confirmed against CLAUDE.md §3
  ("Digits Are Literal") which codifies "a digit never
  anchors asat or dependent marks". The Unicode TUS storage
  order claim is also accurate (U+102B..U+1032 dep-vowels and
  U+103B..U+103E medials require a consonant base on their
  left).

## Implementation Notes
- **Approach:** post-splice repair rather than parser-side
  injection. The `extractMidBufferDigits` path strips the digit
  before parsing and the parser produces a single-syllable parse
  for the cleaned buffer (e.g. `kaaung` → `ကောင်`); splicing the
  digit back at the cleaned-buffer offset always lands inside the
  cluster, severing the consonant from its dep-vowels. The fix
  detects the digit-orphan-mark adjacency on the spliced surface
  and injects a `U+1021` independent-vowel anchor immediately
  after each offending digit, mirroring the shape the parser-time
  orphan-mark injector already produces for `kar2aung` /
  `tar2aing`.
- **Code changes:**
  - `Engine/SurfaceSanitizers.swift`: added two helpers next to
    the existing `surfaceContainsDigitOrphanAsat` predicate.
    `surfaceContainsDigitOrphanAttachableMark(_:)` flags
    `<digit>` followed by any of: dep-vowel U+102B..U+1032,
    anusvara U+1036, asat U+103A, or medial U+103B..U+103E.
    `injectAnchorAfterDigitForOrphanMarks(_:)` rebuilds the
    surface by inserting `U+1021` after every digit that
    immediately precedes one of those marks (single anchor per
    cluster — subsequent marks attach to the new anchor).
  - `Engine/MidBufferDigits.swift::spliceMidBufferDigits`:
    runs the new injector on every spliced surface (both
    Myanmar-digit and ASCII-digit variants) before deduplication.
- **Tests:**
  - New `DigitDepVowelAnchorSuite` (registered in
    `BurmeseTestSuites.swift`) covers the bug-class buffers
    (`ka2aung`, `ka2ar`, `ka2i`, `ka2u`, `ka2y`, `ka2aing`,
    `kya2aung`, `kya2y`, `ky2aung`, `khy2et`, `t2ote`, `ka2yar`,
    `ka2war`), the rank-0 anchor-injection expectation, the
    counter-example regression guards (`kar2aung`, `tar2aing`,
    `kar2na`), and the new sanitizer predicate's truth table.
  - Updated `RankingSuite` cases that previously documented the
    illegal `<digit><dep-vowel>` shape (`task10_midDigit_*`,
    `task10_taIn_preservesI`, `task10_digitBetweenMedial_k2yun`)
    to expect the corrected anchor-bearing surface. These cases
    were documenting the bug TASK-051 describes, not desired
    behavior, per CLAUDE.md §3 and the TASK-051 acceptance
    criteria. The counter-example `l2wann` (digit before
    asat-closed coda, no orphan dep-vowel) is unchanged.
- **Verification:** all 1492 / 1492 cases pass after the fix
  (`swift run TestRunner`). Production-equivalent probe
  confirms the headline buffers (`ka2aung`, `kya2aung`,
  `ky2aung`, `t2ote`) now produce the `<C>(<medial>?)<digit>
  <U+1021><dep-vowel cluster>` shape at rank 0, with the
  counter-examples (`kar2aung`, `kar2na`, `pyate2`,
  `tar2aing`) unchanged.

## Validation Report
- **Verdict:** FULLY_COVERED.
- **Test run:** All 1507/1507 cases (7969/7969 assertions) pass on
  `swift run TestRunner`, including with `FUZZ_BUDGET_MS=2000`. No
  performance regressions on `BurmeseBench --check` against the
  baseline.
- **Suite coverage:** `DigitDepVowelAnchorSuite` (4 cases) covers
  the full bug class: panel-wide invariant (no rank carries the
  illegal adjacency), rank-0 anchor-injection for 7 headline
  buffers across all attachable-mark sub-classes (dep-vowel,
  e-kar, anusvara range), counter-example regression guards
  (`kar2aung`, `tar2aing`, `kar2na`), and a sanitiser-predicate
  truth table covering ASCII digit + Myanmar digit + each
  attachable-mark sub-range. The predicate is exposed via
  `@_spi(Testing) public`.
- **Regression handling:** `RankingSuite.task10_midDigit_*`,
  `task10_taIn_preservesI`, `task10_digitBetweenMedial_k2yun`
  expectations were updated from the storage-order-illegal shape
  (e.g. `က၂ုတ်` with `1042 102F` adjacency) to the new
  anchor-bearing shape (`က၂အုတ်` with `1042 1021 102F`). The pre-fix
  test expectations documented the bug that CLAUDE.md §3 and
  TASK-051 forbid; updating them is justified. `task10_l2wann` (no
  orphan dep-vowel) is unchanged, which is correct.
- **Coverage gaps:** none material. The reproduction set in the
  task body (`ka2u`, `kya2y`, `khy2et`, `ka2yar`, `t2ote`, etc.)
  is exercised either by the explicit rank-0 case or by the
  panel-wide invariant. The implementation handles both ASCII
  digits and Myanmar digits via a shared predicate.
- **Files touched:**
  - `/Users/rtry/repos/myanmar-ime/Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`
  - `/Users/rtry/repos/myanmar-ime/Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/MidBufferDigits.swift`
  - `/Users/rtry/repos/myanmar-ime/Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/DigitDepVowelAnchorSuite.swift` (new)
  - `/Users/rtry/repos/myanmar-ime/Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/RankingSuite.swift` (expectations updated)
  - `/Users/rtry/repos/myanmar-ime/Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/BurmeseTestSuites.swift` (registration)
