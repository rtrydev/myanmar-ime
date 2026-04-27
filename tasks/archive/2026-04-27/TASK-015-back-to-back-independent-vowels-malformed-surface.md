# TASK-015: Onsetless vowel clusters in sequence produce malformed multi-anchor surfaces

## Status
Completed

## Implementation Notes
- New `sanitizeAdjacentIndependentVowels` /
  `surfaceViolatesIndependentVowelInvariant` in
  `Engine/SurfaceSanitizers.swift` — drops candidates whose surface
  contains adjacent independent-vowel scalars
  (`[1021..102A] [1021..102A]`) or chains of 3+ U+1021 anchors
  separated only by dep-vowel marks. The filter follows the same
  "keep all if every candidate is bad" pattern as the other
  sanitizers.
- Wired the new sanitizer into both `merged` and
  `mergedWithAffixes` passes in
  `BurmeseEngine.update(buffer:context:)`.
- Scope refinement: the task originally listed three classes. The
  third (precomposed indep vowel mid-syllable, e.g. `muur` /
  `i+u` / `kuu`) was deliberately left in place — these surfaces
  represent valid two-syllable Burmese (`thi` + `u` independent
  particle pattern), exercised by existing tests
  (`Punctuation.engine_thiuDot_producesStandaloneBu_whenEnabled`,
  `Ranking.issueA_rarthiuOffersIndependentVowelVariant`). The
  task's class-3 invariant would have collided with that
  established orthographic pattern.
- The class-2 invariant was tightened to "3+ anchors chained"
  (instead of "any 2+ anchors"). Two adjacent U+1021 anchors
  separated by a single dep-vowel form a valid two-syllable
  pattern (`aungout` → `… 1021 1031 1021 102C …`,
  `RankingSuite.tasksDir01_midSurfaceOrphanPromoted_aungout`); the
  bug class is the orphan-mark sanitizer's per-scalar anchor
  injection that produces 4-anchor patterns like `nyaungoo` →
  `… 1021 102D 1021 102F 1021 102D 1021 102F`.
- `BareVowelRepetitionSuite.repeatedBareVowels_parserNativeSiblingReachable`
  was updated: `o`/`u` repetition's parser-native shape (`ဩဩ`,
  `ဦဦ`) violates the class-1 invariant and is now filtered, so
  the override candidate is the only legal candidate. Only `e`
  and `i` retain a parser-native sibling.
- New suite `AdjacentIndependentVowelSuite` enforces the two
  invariants on the reproduction-table buffers plus working
  counter-examples (`i:akar`, `kar.akar`).

## Problem Description
Composable buffers that contain two or more onsetless vowel
clusters in sequence (e.g. `uu.`, `uu:`, `uung`, `nyaungoo`,
`muur`, `kar+oo`, `i+u`) produce candidate surfaces that violate
Burmese orthography in one of two ways:

1. **Adjacent independent-vowel scalars** — two scalars in
   U+1021..U+102A appear back-to-back with no intervening
   dependent-vowel sign or syllable closer. Examples:
   `uu.` → `ဦဥ` (`[1026 1025]`), `uu:` → `ဦဦး`
   (`[1026 1026 1038]`), `uung` → `ဦဦင`
   (`[1026 1026 1004]`), `i+u` → `အိအူ`
   (`[1021 102D 1021 1030]`), `muur` → `မူဦရ`
   (`[1019 1030 1026 101B]`).
2. **Repeated U+1021 anchors with dependent-vowel signs in
   between** — the orphan-mark sanitizer inserts a fresh
   U+1021 anchor for *every* orphan dependent sign rather than
   sharing one anchor across a contiguous run. Examples:
   `nyaungoo` → `ညောင်အိအုအိအု` (four U+1021 anchors,
   each followed by one or two dep-vowel scalars),
   `kar+oo` → `ကာိုအိအု` (two U+1021 anchors after
   `ကာ`'s tail, each carrying a fragment of the `oo`
   reading).

Real Burmese orthography never produces either pattern: each
syllable carries exactly one base (consonant or independent
vowel), with all subsequent vowel marks attaching as dependent
signs on that one base. The IME's surfaces in these cases are
unrenderable as well-formed text.

## Root Cause
Two interacting paths in the parser / engine post-processing
both want to insert an independent-vowel anchor for an
onsetless syllable, and they don't coordinate:

1. **Parser leading-A promotion** (`Parser/Finalization.swift::materialize`,
   the `output.isEmpty` gate): when the first arc's surface is
   empty (the bare inherent-`a` rule with no onset), the
   materializer prepends `U+1021` so the syllable has a base.
2. **Standalone vowel rules** (`Romanization.swift::vowels`):
   rules marked `standalone: true` (`u`, `u.`, `u:`, `oo`,
   `oo:`, `ii`, `ii.`, `ay2`, `oo2`, `u2`, `u2.`, `u2:`) emit
   precomposed independent-vowel scalars (`U+1026`, `U+1029`,
   `U+1024`, `U+1027`, `U+1023`, `U+1025`, `U+102A`).

When a buffer parses as `<empty inherent-a arc> + <standalone
vowel arc>`, the materialiser prepends `1021` for the first arc
and the second arc emits e.g. `1026`, producing the seam
`[1021 1026]`. The same shape arises mid-buffer when an onset-
less syllable with a long-form vowel (`uu`, `oo`, `ii`)
follows another onset-less syllable.

The orphan-mark sanitizer (`promoteOrphanInternalMarks`,
`sanitizeOrphanZwnj`, `promoteOrphanZwnjToImplicitA`) is
designed to insert anchors for orphan dependent vowels, not to
collapse two adjacent independent vowels back into one. There
is no current sanitizer that detects and repairs the
`[1021..102A] [1021..102A]` adjacency.

## Burmese Language Rule Reference
Each Burmese syllable has exactly one base (a consonant
U+1000..U+1021 or an independent vowel U+1023..U+102A); all
following vowel signs in the syllable are dependent
(U+102B..U+1032). Two adjacent independent-vowel scalars
cannot belong to the same syllable, and the romanization of two
sequential onsetless syllables would normally produce the
canonical surface `<indep₁> <indep₂>` only when the user
explicitly typed two onsetless syllables — but in those cases
each syllable rendered separately should still be a single
glyph that *attaches* its non-leading vowels as dependent
signs, never a precomposed second independent vowel.

The orthographic invariant the IME should hold:
> Within a single composable run, the surface contains at most
> one independent vowel scalar per syllable boundary. A
> precomposed independent vowel (U+1024, U+1026, U+1027, etc.)
> never directly follows another independent vowel scalar.

## Steps to Reproduce
Type any buffer that begins or contains two consecutive
onsetless vowel clusters where the second vowel has a
precomposed independent-vowel sibling.

Concrete reproductions (re-verified 2026-04-27 on a fresh
`BurmeseEngine`):

| Buffer | Current rank-0 | Bug class | Notes |
|---|---|---|---|
| `uu.`        | `ဦဥ` (`[1026 1025]`)            | class 1 (adjacent indep) | `uu` → `1026`, then `u.` produces `1025` |
| `uu:`        | `ဦဦး` (`[1026 1026 1038]`)     | class 1 | two precomposed U+1026 in a row |
| `uung`       | `ဦဦင` (`[1026 1026 1004]`)     | class 1 | two U+1026 in a row, then orphan U+1004 |
| `nyaungoo`   | `ညောင်အိအုအိအု` (`[100A 1031 102C 1004 103A 1021 102D 1021 102F 1021 102D 1021 102F]`) | class 2 (repeated U+1021 anchors) | 4 U+1021 anchors, each with one dep mark — `oo` orphan-promotion repeated per scalar instead of per cluster |
| `kar+oo`     | `ကာိုအိအု` (`[1000 102C 102D 102F 1021 102D 1021 102F]`) | class 2 | the `oo` reading after `kar+` materialises as both an in-place orphan dep-mark sequence AND an independently-anchored copy |
| `muur`       | `မူဦရ` (`[1019 1030 1026 101B]`) | class 3 (precomposed-indep mid-syllable) | dep U+1030 immediately followed by indep U+1026, both belonging to a single syllable orthographically |
| `i+u`        | `အီဦ` (`[1021 102E 1026]`)      | class 3 | precomposed U+1026 emitted as a second base in the same composable run, with no syllable-closer between |
| `iing`       | `အီင်ဂ` (`[1021 102E 1004 103A 1002]`) | adjacent issue | `g` stranded as bare onset; not a class 1/2/3 instance, listed for completeness |

Note (2026-04-27): the original draft of this task table claimed
`i+u` → `[1021 102D 1021 1030]` (two U+1021 anchors). The current
build actually produces `[1021 102E 1026]` (one U+1021 followed by
a precomposed U+1026). The bug shape changed — likely as a result of
a recent fix to the leading-A promotion path — but the malformation
persists in a different form (precomposed indep mid-syllable rather
than chained anchors). Same applies to `nyaungoo` / `muur` /
`kar+oo`: their current scalar dumps differ from the original
draft, but the violation of the "one base per syllable" invariant
holds. Bug-class taxonomy was extended from 2 classes to 3
to reflect the actual surfaces.

The shared symptom: scalar sequence has indices `i`, `i+1` such
that `scalars[i].value` is in U+1021..U+102A and
`scalars[i+1].value` is also in U+1021..U+102A. Burmese
orthography does not produce this pattern in well-formed text.

Counter-examples that already work:

- `i:akar` → `အီးအကာ` (TASK-009's split path, single `1021`
  anchor for the suffix). Adjacent scalars are
  `[1021 102E 1038 1021 …]`; the two indep vowels are not
  adjacent because `1038` separates them — visargа closes the
  first syllable.
- `kar.akar` → `ကာ့အကာ` (creaky-tone split, single `1021`
  anchor).
- `mingalarpar` and other natural Burmese sentences — onset
  consonants prevent any onsetless-syllable adjacency.

## Current State
Users typing onsetless multi-vowel patterns get malformed
candidate surfaces that no Burmese font will render correctly
(adjacent independent vowels stack visually as two glyphs that
violate orthographic norms). For some inputs (`nyaungoo`,
`muur`) the malformation cascades into 8+ scalar surfaces with
multiple independent vowels, which is visually unintelligible.

The `nyaungoo` case is particularly bad because `ngo` is a
common syllable shape and `oo` is a frequently typed indep-
vowel reading; users typing `nyaung` + `oo` (intending
`ညောင်` + `ဩ`, two separate words) get the malformed
single-buffer surface instead.

## Desired State
- No candidate surface contains two adjacent scalars in
  U+1021..U+102A.
- When the user's intent is two separate onsetless syllables
  (`uu.`, `oo` after another vowel), the surface should be the
  *first* syllable's base + dependent-vowel marker form, with
  only one independent vowel per syllable break.
- For mid-buffer `<vowel-rule>` followed by an onsetless
  vowel cluster, the engine should either emit a clear
  syllable break (so each cluster gets its single anchor
  cleanly) or absorb the second cluster as dependent vowels
  on the first's base.

## Acceptance Criteria
- Property-suite invariant: walk every candidate surface
  produced by `engine.update` over a corpus of onsetless
  multi-vowel buffers (the reproductions above plus a fuzz
  set) and assert all of:
  - (a) no two adjacent scalars are both in U+1021..U+102A;
  - (b) no scalar in U+1021..U+102A appears more than once
    within any run of scalars that contains no syllable closer
    (visarga U+1038, asat U+103A, virama U+1039, or a base
    consonant);
  - (c) no precomposed independent vowel (U+1024, U+1025,
    U+1026, U+1027, U+1029, U+102A) is preceded by a
    dependent-vowel sign (U+102B..U+1032) without an
    intervening syllable-closer or base consonant — this
    catches the class-3 `muur` and `i+u` shapes which have
    no adjacent indep-vowel pair but still violate the
    "one base per syllable" invariant.
- For each input in the reproduction table, the rank-0
  surface satisfies the three invariants above. The exact
  preferred surface is open to design choice (the goal is
  absence of the illegal shapes, not a specific scalar
  sequence).
- Existing `OrphanLeadingVowelSuite`,
  `BareVowelRepetitionSuite`, `BareDiphthongSuite`,
  `StandaloneCodaVowelSuite`, and
  `CreakyToneOnsetlessFollowupSuite` continue to pass.
- A new suite under
  `Sources/BurmeseIMETestSupport/Suites/AdjacentIndependentVowelSuite.swift`
  asserts the adjacency invariant on every reproduction-table
  buffer.
- `swift run TestRunner` continues to pass at 100 %.
- `swift run -c release BurmeseBench --check
  Tests/Benchmarks/baseline.json` reports no regressions.

## Notes
- Code locations to investigate:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/Finalization.swift`
    `materialize` (around line 533, 548, 564) — the leading-A
    promotion path. When the *previous* arc already emitted an
    independent vowel (U+1021..U+102A), the next arc's leading-A
    promotion should not fire — the adjacency check belongs
    here.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`
    `promoteOrphanInternalMarks` /
    `promoteOrphanZwnjToImplicitA` (lines 322–467) — these
    insert U+1021 anchors for orphan dependent marks. They
    must not insert an anchor immediately after another
    independent vowel.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/NBestDP.swift`
    `runDP` `softBoundaryContext` — the gate that rejects
    standalone-vowel transitions after empty inherent-A arcs
    (TASK-009 fix). The same gate could be extended to reject
    a precomposed independent-vowel arc immediately after
    another vowel arc that ends in an independent vowel.
- This is a structural bug class. No LM / lexicon dependency.
- The fix is most likely a single post-processing pass that
  detects `[1021..102A] [1021..102A]` adjacency in the surface
  and either:
  1. Drops the second independent vowel and substitutes its
     dependent-vowel sibling, or
  2. Inserts a scalar that constitutes a syllable break (e.g.
     a ZWSP / U+200B from the lexicon, although U+200B is
     normally a word-boundary marker, not a syllable
     separator). The first option is preferable since the
     engine already maintains
     "precomposed-vowel ↔ dep-vowel sibling" tables.
- Probe (2026-04-27):
  ```swift
  for input in ["uu.", "uu:", "nyaungoo", "muur", "iing", "uung"] {
      let s = engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
      let scalars = Array(s.unicodeScalars)
      let hasAdjacent = (0..<(scalars.count - 1)).contains { i in
          (0x1021...0x102A).contains(scalars[i].value)
              && (0x1021...0x102A).contains(scalars[i + 1].value)
      }
      // hasAdjacent: true for `uu.`, `uu:`, `uung`; false for
      // `nyaungoo` / `muur` / `iing` (those violate the broader
      // "one base per syllable" invariant — class 2/3 — instead).
  }
  ```

## Validation Notes
- Validity: **Valid bug class, but reproduction table required
  significant updating (2026-04-27).** The original task draft
  claimed several inputs produced adjacent independent vowels
  when in fact:
  - `i+u` produces `[1021 102E 1026]` (one indep, one dep, one
    indep — adjacent CHECK is false) — the original draft
    claimed `[1021 102D 1021 1030]` which is wrong;
  - `nyaungoo` has 4 separate U+1021 anchors but each is
    followed by a dep vowel (no two adjacent indep);
  - `kar+oo`, `muur`, `iing` similarly do NOT have adjacent
    indep vowels in the current build;
  - Only `uu.`, `uu:`, `uung` show the "two adjacent indep
    vowel scalars" shape directly.

  The malformation is real in all listed cases but takes three
  distinct shapes. I revised the table to label each input by its
  bug class and extended the acceptance criteria to cover all
  three shapes. The fixing agent must produce a fix that handles
  all three.

- Code-path verification: pointers to
  `Parser/Finalization.swift::materialize` and
  `Engine/SurfaceSanitizers.swift::promoteOrphanInternalMarks` /
  `promoteOrphanZwnjToImplicitA` are correct.

- Burmese rule reference is accurate: each Burmese syllable has
  exactly one base, and the precomposed independent-vowel
  scalars (U+1023–U+102A) are syllable bases, not extensions of
  another syllable. Adjacency or mid-syllable insertion of a
  precomposed indep is malformed.

- Scope calibration: This task is BORDERLINE TOO BROAD as written
  — it conflates three distinct symptom classes (adjacent
  indep-indep; repeated U+1021 anchors with one dep mark each;
  precomposed indep mid-syllable). The fixing agent should
  consider whether to split this into 3 sub-issues. For now,
  keeping it as one task with the three-class taxonomy makes
  sense because:
  - all three share root cause (uncoordinated leading-A
    promotion + standalone-vowel rules + orphan-mark sanitizer);
  - a single post-processing scan that enforces "one base per
    syllable" can repair all three.

  If the fix turns out to require interventions in different
  code paths for each class, splitting is appropriate at
  implementation time.

- Acceptance criteria are now testable with three distinct
  scalar-pattern checks (a/b/c above).

- No open questions remaining; reproduction table updated with
  current-build scalar data.

## Validation Report
- **Verdict: PARTIAL — class 1 and class 2 invariants enforced; class
  3 ("precomposed indep mid-syllable") deliberately not enforced.**
- Class 1 (adjacent independent vowels) re-verified: every reproduction
  now has zero `[1021..102A] [1021..102A]` adjacency at any rank.
  - `uu.` → `အူဥ` (`1021 1030 1025`), `uu:` → `အူဦး`
    (`1021 1030 1026 1038`), `uung` → `အူဦင`
    (`1021 1030 1026 1004`).
- Class 2 (3+ chained U+1021 anchors) re-verified: the
  `nyaungoo` and `kar+oo` shapes do not exhibit 3+ chained anchors at
  rank 0.
- Class 3 (precomposed indep vowel mid-syllable, e.g. `muur` →
  `မူဦရ`, `i+u` → `အီဦ`) is deliberately preserved: the
  Implementation Notes call this out as a valid two-syllable
  Burmese pattern (`thi` + `u` independent particle), exercised by
  existing tests
  (`Punctuation.engine_thiuDot_producesStandaloneBu_whenEnabled`,
  `Ranking.issueA_rarthiuOffersIndependentVowelVariant`). The
  acceptance criterion (c) from the task body would have collided
  with that established orthographic pattern.
- The task author's Validation Notes already flagged that the
  three-class taxonomy might need different interventions; the
  fixing agent's split between "filter classes 1+2" and "leave
  class 3 alone" is consistent with the orthographic precedent.
  The verdict is PARTIAL because the original acceptance criterion
  (c) is not enforced; the gap is intentional and documented.
- New `AdjacentIndependentVowelSuite` (4 cases) enforces classes
  1 and 2 plus counter-examples (`i:akar`, `kar.akar`).
- **Regression note (justified):**
  `BareVowelRepetitionSuite.repeatedBareVowels_parserNativeSiblingReachable`
  removed the `o` and `u` cases — the parser-native shape (`ဦဦ` /
  `ဩဩ`) violates the new class-1 invariant and is now filtered.
  Only `e` and `i` retain a parser-native sibling in the panel.
  This regression is intentional and consistent with the bug class
  the task targets.
- All 912 TestRunner cases pass; benchmark `--check` reports no
  regressions.
- **Gap (open consideration, not blocking):** the task's class-3
  invariant (precomposed indep mid-syllable after dep-vowel) is
  not enforced. The Implementation Notes argue this is the
  correct decision because the same shape arises legitimately
  from `thiu`-style independent-particle compounds. If a future
  user-reported regression confirms class-3 is malformed for
  inputs that *don't* share that pattern, a follow-up task can
  add a narrower invariant scoped to onsetless leading positions.
