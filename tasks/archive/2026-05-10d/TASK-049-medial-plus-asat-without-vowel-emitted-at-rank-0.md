# TASK-049: Medial + asat without intervening vowel (`<medial> 103A`) emitted at rank 0 for `<C><medial>*` patterns

## Status
Completed

## Implementation Notes
Tightened the asat backward-walk in
`Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/Finalization.swift::scanOutputLegality`
so a medial scalar (`U+103B..U+103E`) is only treated as skippable
between an asat and its consonant base when a vowel-bearing
cluster (the `aw`-cluster `1031 (102B|102C)`) was peeled first.
The pre-fix walk treated medials as unconditionally skippable,
letting bare `<C><medial>103A` slip through. The same change
addresses TASK-048 for the anusvara case.

The legitimate medial-bearing closure shapes remain legal because
they either (a) place a coda consonant between the medial and
the asat (`kyan*` → `1000 103B 1014 103A`; the walk starts on the
coda base, never enters the skippable loop), or (b) carry the
aw-cluster (`kyaw*` → `1000 103B 1031 102C 103A`; the aw-cluster
peel sets `sawVowelCluster = true` so the medial is admitted in
the loop).

Added regression suite
`Sources/BurmeseIMETestSupport/Suites/MedialPlusAsatRejectionSuite.swift`
covering: (a) panel-presence invariant for every medial family
(ya-pin `103B`, ya-yit `103C`, wa-hswe `103D`, ha-htoe `103E`)
across representative consonant onsets; (b) double- and
triple-medial onsets (`kyw*`, `hkyw*`); (c) direct legality-scan
rejection of the `<C><medial>103A` shape; (d) regression guard
that legitimate medial-bearing surfaces (`kyan*`, `kyar*`,
`kyaw*`, `kyaung*`, `kywan`, `hman`) remain reachable.

Updated dependent tests:
- `Suites/AsatAfterDepVowelSuite.swift` removed `kya*`
  (`1000 103B 103A`) and `kw*` (`1000 103D 103A`) from the
  "scanOutputLegality_acceptsLegalAsatShapes" counter-example
  list and the `regressionGuards` rank-0 list. These shapes were
  asserted as legal pre-TASK-049 (the suite only guarded against
  the `<dep-vowel> 103A` family); per TASK-049 they are
  malformed. The replacements use the legitimate
  `<C><medial><coda>103A` form (`kyan*`, `kwan*`).
- `Suites/RedundantExplicitAsatSuite.swift` updated the
  `kya*kar` counter-example: pre-fix the engine emitted
  `ကျ်ကာ` = `1000 103B 103A 1000 102C` (medial + asat + ka +
  aa); post-fix the malformed `*` is dropped and the parser
  produces the two-syllable `ကျကာ` = `1000 103B 1000 102C`.

## Problem Description
When the user types `<C><medial>*` — a base consonant followed by a
medial keystroke (ya-pin, ya-yit, wa-hswe, or ha-htoe) and the
explicit asat marker `*`, with **no vowel between the medial and
the asat** — the rank-0 candidate surface emits the scalar pair
`<medial> 103A` (medial directly followed by asat). The pattern
spans every medial scalar family (`103B`, `103C`, `103D`, `103E`)
and every base consonant.

These shapes are not legitimate Burmese orthography. A medial is
part of the onset cluster and modifies the onset's articulation;
the syllable still requires either an inherent vowel or a closing
consonant + asat. Placing `103A` directly after a medial drops
the inherent vowel without providing a closure consonant — a
structurally meaningless syllable.

Verified rank-0 surfaces (production-equivalent engine):

| Buffer    | Rank-0 surface | Hex                            |
|-----------|----------------|--------------------------------|
| `kya*`    | `ကျ်`         | `1000 103B 103A`              |
| `khya*`   | `ချ်`         | `1001 103B 103A`              |
| `gya*`    | `ဂျ်`         | `1002 103B 103A`              |
| `mya*`    | `မြ်`         | `1019 103C 103A`              |
| `pya*`    | `ပြ်`         | `1015 103C 103A`              |
| `bya*`    | `ဘြ်`         | `1018 103C 103A`              |
| `kw*`     | `ကွ်`         | `1000 103D 103A`              |
| `pw*`     | `ပွ်`         | `1015 103D 103A`              |
| `hma*`    | `မှ်`         | `1019 103E 103A`              |
| `hna*`    | `နှ်`         | `1014 103E 103A`              |
| `kyw*`    | `ကျွ်`        | `1000 103B 103D 103A`         |
| `hkyw*`   | `ဟကြွ်`       | `101F 1000 103C 103D 103A`    |

The bug fires for every `<medial>*` shape regardless of which
medial(s) is in the onset cluster.

Compare to the working cases:

| Buffer    | Rank-0 surface | Notes |
|-----------|----------------|-------|
| `kya`     | `ကျ`           | medial + inherent vowel — clean |
| `kyar*`   | `ကျရ်`         | medial + ar (ra consonant) + asat — `r` consumes as ra |
| `kyan*`   | `ကျန်`         | medial + an + asat — `n` consumes as na-asat |
| `kyaa*`   | `ကျအ်`         | medial + standalone-A + asat — also malformed but separate |

## Root Cause
The parser's vowel matcher accepts the explicit asat marker
(`*` → `103A`) as a standalone "vowel-arc" terminal that does
not require an intervening vowel. When the onset has already
been consumed including medial(s), the next arc matches `*`
directly and produces `<C><medial(s)>103A` as a "legal"
single-syllable parse.

The legality scan in `Parser/Finalization.swift` treats this as
acceptable because:
- The onset (consonant + medials) is a valid onset cluster.
- Asat after a consonant is normally legal (closes the inherent
  vowel of a coda consonant).

But the legality check fails to enforce that the asat-closed
consonant must be a *coda* consonant, not a medial. A medial
scalar (`103B`–`103E`) is not a coda; it is an onset modifier.
The sanitizer pipeline in `Engine/SurfaceSanitizers.swift`
already rejects "asat after dependent vowel" combinations but
does not include the "asat after medial without intervening
coda consonant" case.

The candidate-ranking layer then promotes the malformed surface
to rank 0 because it consumes every input keystroke literally
(highest "completeness") and matches the user-typed asterisk
keystroke directly.

## Burmese Language Rule Reference
Burmese syllable structure: `<C><medial(s)><V><coda?>` where:
- `<C>` is the base consonant onset (U+1000..U+1021 or U+103F).
- `<medial(s)>` are optional onset modifiers (U+103B..U+103E),
  with a defined legal ordering.
- `<V>` is a dependent vowel mark (single or compound), the
  inherent `a` if none is written, or a sequence forming a
  diphthong final.
- `<coda?>` is an optional coda consonant in stack or asat
  form (e.g. `<consonant> 103A` for a closing asat, or
  `<consonant> 1039 <consonant>` for a virama stack).

A medial is structurally part of the onset, never part of the
coda. Placing asat directly after a medial (with no vowel and
no coda consonant) violates the syllable template — the
inherent vowel is dropped but nothing closes the syllable. Native
Burmese does not produce this shape; the cluster needs either
a vowel (e.g. `ကျ` "kya" with inherent `a`) or a coda
consonant + asat (`ကျန်` "kyan").

The exceptions (medial + asat in real Burmese text) are
**stack abbreviations** — but those use a *different* scalar
order (consonant + virama + medial-bearing-consonant), not the
`<medial> 103A` adjacency emitted here.

## Steps to Reproduce
1. Construct a production-equivalent engine.
2. For each medial-bearing onset cluster (`kya`, `khya`, `gya`,
   `pya`, `bya`, `mya`, `kw`, `pw`, `hma`, `hna`, `kyw`,
   `hkyw`, …), evaluate
   `engine.update(buffer: "\(onset)*", context: [])`.
3. Inspect rank-0 `surface` for the scalar pair `<medial> 103A`
   adjacent (medial scalar in U+103B..U+103E followed by U+103A).

Observed: every probed medial-bearing onset produces the
illegal adjacency at rank 0.

## Current State
- Rank-0 surface for `<C><medial>*` contains the adjacent
  `<medial> 103A` pair.
- No clean Burmese sibling appears in the panel because the
  parser believes the malformed shape is a complete syllable.
- The literal-ASCII fallback is the only "clean" alternative
  but sits at rank 2+.

## Desired State
- The parser legality scan or surface sanitizer rejects any
  candidate whose surface contains the adjacency
  `<medial> 103A` (medial scalar U+103B..U+103E immediately
  followed by asat U+103A) with no intervening coda consonant.
- For `<C><medial>*` inputs the rank-0 candidate is one of:
  - The literal raw-buffer fallback (per CLAUDE.md §2 — when
    every Myanmar candidate is malformed, the user's typed
    asterisk is preserved as an ASCII keystroke in the
    committed surface so the user can edit it manually);
  - A legal Burmese surface that interprets the `*` as
    triggering a different segmentation (e.g. `kya*ka` could
    surface as `ကျ * ka` with the literal-fallback head and
    Myanmar tail).
- Existing legal medial-bearing surfaces (`kya`, `kyar`,
  `kyan*`, `kyaung`, etc.) are not affected.

## Acceptance Criteria
- For every medial-bearing onset cluster in the test matrix
  (covering each medial family: ya-pin `103B`, ya-yit `103C`,
  wa-hswe `103D`, ha-htoe `103E`), and for every triple-medial
  combination already present in the parser's onset trie,
  `engine.update(buffer: "<onset>*", context: []).candidates.
  first.surface` contains no scalar window where U+103B..U+103E
  is immediately followed by U+103A.
- The clean medial-bearing surface (with inherent vowel or with
  a coda consonant) remains reachable for shapes like
  `kya` → `ကျ`, `kyan*` → `ကျန်`, etc.
- A new suite under
  `Sources/BurmeseIMETestSupport/Suites/MedialPlusAsatRejectionSuite.swift`
  enumerates the medial cross-product (per CLAUDE.md
  "scalar-predicate" pattern) and asserts the invariant.
- Existing suites (`MedialStabilitySuite`,
  `ClusterMedialPreferenceSuite`, `CwyClusterPromotionSuite`,
  `MedialHaForbiddenBasesSuite`, etc.) continue to pass.

## Notes
- Suspect fix sites:
  - `Engine/SurfaceSanitizers.swift` — add the
    `<medial> + 103A` adjacency to the existing "asat after
    incompatible dep-vowel" sanitizer.
  - `Parser/Finalization.swift` — extend the legality scan to
    score this adjacency below the acceptance threshold.
- The bug shape is `<medial> 103A` adjacency only; medial +
  coda-consonant + asat (e.g. `ကျန်` = `1000 103B 1014 103A`)
  is the legitimate form and must continue to be ranked
  cleanly.
- Triple-medial onsets (`hkyw`, `hkywa`) compound the problem:
  the rank-0 surface `ဟကြွ်` chains all four medials before
  the bare asat — even more clearly malformed than the
  single-medial case.
- Related but distinct from TASK-024 (medial-bearing onset +
  tone marker `kya.`, `kya:` — fixed) and TASK-041 (explicit
  asat after vowel rule absorbed — fixed). Those tasks address
  the medial-bearing path for tone or post-vowel asat; this
  task is specifically about asat immediately after a medial
  with no intervening vowel or coda consonant.

## Validation Notes
**Verdict: Valid (revised).** The bug class is real, fires for
every tested medial-bearing onset, and reproduces exactly the
table given.

Verification probe (BurmeseBench shim, bundled lexicon + LM):

| Buffer    | Rank-0 surface | Hex                        | Match |
|-----------|----------------|----------------------------|-------|
| `kya*`    | `ကျ်`         | `1000 103B 103A`          | yes |
| `khya*`   | `ချ်`         | `1001 103B 103A`          | yes |
| `gya*`    | `ဂျ်`         | `1002 103B 103A`          | yes |
| `mya*`    | `မြ်`         | `1019 103C 103A`          | yes |
| `pya*`    | `ပြ်`         | `1015 103C 103A`          | yes |
| `bya*`    | `ဘြ်`         | `1018 103C 103A`          | yes |
| `kw*`     | `ကွ်`         | `1000 103D 103A`          | yes |
| `pw*`     | `ပွ်`         | `1015 103D 103A`          | yes |
| `hma*`    | `မှ်`         | `1019 103E 103A`          | yes |
| `hna*`    | `နှ်`         | `1014 103E 103A`          | yes |
| `kyw*`    | `ကျွ်`        | `1000 103B 103D 103A`     | yes |
| `hkyw*`   | `ဟကြွ်`       | `101F 1000 103C 103D 103A`| yes |

In every case the panel contains only:
1. The medial+asat illegal shape (rank 0, sometimes 1).
2. A medial-variant of the same illegal shape (e.g. `ya-pin`
   vs `ya-yit` flip).
3. The literal ASCII fallback.

No clean Burmese surface (with vowel or coda) appears in the
panel — the parser wholly accepts the malformed shape and treats
the buffer as completely consumed. This makes the user-facing
hit larger than TASK-048: not only is rank 0 illegal, every
non-literal candidate is illegal.

Changes made:
- Tightened the "Steps to Reproduce" matrix already covers all
  four medial families and at least one triple-medial onset.
- Acceptance criteria already match the "no candidate carries
  the adjacency" pattern (criterion 1) — left as-is.
- Added a small clarification: the working `kyar*`/`kyan*`
  cases in the original task already correctly capture the
  desired post-fix behavior — keep those as positive controls
  in the new suite.

Suspect-fix sites:
- `Engine/SurfaceSanitizers.swift` is the natural home; the
  fix predicate is "asat at position `i` where `scalars[i-1]`
  is in `0x103B...0x103E`". The sanitizer should reject this
  adjacency; per CLAUDE.md §1 this falls under "asat after
  incompatible dependent vowel" (medials are part of the onset
  cluster, asat needs a coda consonant).
- A parser-level fix in `Parser/Finalization.swift` would also
  work but would need to score the malformed parse below the
  literal-fallback threshold so the literal becomes rank 0.

Burmese rule reference confirmed. The "stack abbreviation"
exception (medial-bearing in stack form) uses scalar order
`<C> 1039 <medial-bearing-C>`, not `<medial> 103A` adjacency,
so it is not affected by the proposed sanitizer.

Note for fix author: the existing single-syllable parse for
`<C><medial>` (without asat) emits `<C> <medial>` with the
inherent vowel, and that legal form must remain reachable.
Only the `<medial> 103A` pair with no intervening
coda-consonant scalar is forbidden.

No outstanding clarification questions.

## Validation Report
**Verdict: FULLY_COVERED.**

Build / suite status:
- `swift build` — clean (no warnings or errors).
- `swift run TestRunner` — 1488/1488 cases, 7757/7757 assertions pass.
- `swift run -c release BurmeseBench --check Tests/Benchmarks/baseline.json`
  — "no regressions".

Acceptance criteria coverage:
- AC1 (no candidate carries `<medial> 103A` for `<C><medial>*` across
  every medial family) — covered by
  `MedialPlusAsatRejectionSuite.noCandidateSurface_carriesMedialPlusAsat`
  with 41 input buffers spanning ya-pin (`103B`), ya-yit (`103C`),
  wa-hswe (`103D`), ha-htoe (`103E`), double-medial (`kyw*` family),
  and triple-medial (`hkyw*`, `hkrw*`) onsets.
- AC2 (legitimate medial-bearing surfaces remain reachable) — covered
  by `legitimateMedialSurfaces_remainReachable` over 7 positive
  controls (`kya`, `kyan*`, `kyar*`, `kyaw*`, `kyaung*`, `kywan`,
  `hman`).
- AC3 (suite at documented path) — present and registered in
  `BurmeseTestSuites.all`. Direct legality-scan predicate covered by
  `scanOutputLegality_rejectsMedialPlusAsat` (12 cases) and the
  positive control `scanOutputLegality_acceptsLegalMedialCodaShapes`
  (6 cases).
- AC4 (no regression in `MedialStabilitySuite`,
  `ClusterMedialPreferenceSuite`, `CwyClusterPromotionSuite`,
  `MedialHaForbiddenBasesSuite`) — full-suite pass confirms.

Production-equivalent validation:
- Probed via temporary BurmeseBench shim with `SQLiteCandidateStore` +
  `TrigramLanguageModel`. 0 leaks across all 12 buffers from the
  task's reproduction table including the triple-medial `hkyw*`
  (which previously emitted `ဟကြွ်` `101F 1000 103C 103D 103A`).
- Legitimate medial-bearing surfaces all reach rank 0 in
  production-equivalent: `kya` → `ကျ`, `kyan*` → `ကျန်`, `kyar*` →
  `ကျရ်`, `kyaw*` → `ကျော်`, `kyaung*` → `ကျောင်`, `kywan` → `ကျွန်`,
  `hman` → `မှန်`.

Regression analysis (same commit as TASK-048):
- See TASK-048 Validation Report for the shared regression-guard
  changes in `AsatAfterDepVowelSuite` and `RedundantExplicitAsatSuite`.
  Both updates are direct consequences of the legality-scan fix
  rejecting `<C><medial>103A`; the modified expectations match the
  post-fix correct behavior.
- The single root-cause fix (the `sawVowelCluster` gate in
  `Parser/Finalization.swift::scanOutputLegality`) covers both
  TASK-048 and TASK-049 cleanly because anusvara (`1036`) and medials
  (`103B..103E`) sit in the same backward-walk loop.

Repo cleanliness:
- `git status` — clean.
- No probe / scratch files inside the repo.
- No SourceKit-only false positives observed.

Gaps: none.
