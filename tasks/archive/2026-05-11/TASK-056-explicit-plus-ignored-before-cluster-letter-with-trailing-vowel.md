# TASK-056: Explicit `+` between consonant and a following ya-pin / ya-yit / wa-hswe cluster-letter is silently merged into the medial cluster when the cluster letter carries a trailing vowel

## Status
Completed

## Problem Description
When the user types `<C>+<cluster-letter><inherent-a-or-vowel-rule>`
where `<cluster-letter>` is one of the medial-forming letters
(`y`, `w`), the production engine's rank-0 candidate is the
single-syllable medial-cluster form (`kya`, `kwa`, …) instead of
the two-syllable `<C> + <C>V` (`ka + ya`, `ka + wa`, …) that the
explicit `+` requested. The bug is in the LM-driven ranking layer,
NOT in the parser — see Root Cause below; the bare engine produces
the correct two-syllable rank-0 surface for every listed buffer.

The bug is conditional on the trailing letter after the cluster
letter:
- `k+y`, `ka+y` (no trailing vowel) → rank-0 = `ကယ` (1000 101A,
  two syllables, `+` honored ✓)
- `k+w`, `ka+w` (no trailing vowel) → rank-0 = `ကဝ` (1000 101D,
  two syllables, `+` honored ✓)
- `k+ya`, `ka+ya` (trailing inherent-`a`) → rank-0 = `ကြ` (1000 103C,
  ya-yit medial cluster, `+` discarded ✗)
- `k+wa`, `ka+wa` (trailing inherent-`a`) → rank-0 = `ကွ` (1000 103D,
  wa-hswe medial cluster, `+` discarded ✗)
- `k+yu`, `ka+yu` → rank-0 = `ကျူ` (1000 103B 1030, ya-pin medial
  + uu, `+` discarded ✗)
- `k+yar` → rank-0 = `ကြာ` (1000 103C 102C, `+` discarded ✗)
- `k+wi` → rank-0 = `ကွီ` (1000 103D 102E, `+` discarded ✗)
- `k+war` → rank-0 = `ကွာ` (1000 103D 102C, `+` discarded ✗)

The `+`-honored two-syllable form (`ကယ` / `ကဝ`) is at rank 1 in the
panel — reachable, but the user's explicit boundary signal does not
win at rank 0 the moment a trailing vowel appears.

This is a counter-example to archived TASK-047 (which fixed
`<C>+<vowel-rule>` shapes) and TASK-058 (which fixed `Cwy` / `Cyw`
medial-typing-order asymmetry). TASK-047 explicitly addressed the
`<C>+<vowel-rule>` case but did not extend the soft-`+` admit gate
to the `<C>+<cluster-letter><a/V>` case.

For comparison, the `r`-cluster case works correctly:
- `k+ra` → rank-0 = `ကရ` (1000 101B, two syllables, `+` honored ✓)
- `p+ra` → rank-0 = `ပရ` (1015 101B, two syllables, `+` honored ✓)

The `r`-cluster letter forms ya-yit (103C, same medial slot as
`y`-after-`p/b` etc.), but the parser's cluster-promotion gate
treats `r` differently from `y`/`w` — likely because `Cra` is a
less-canonical cluster shape and the LM downweights it, while
`Cya`/`Cwa` are canonical and aggressively promoted.

## Root Cause
**Important**: re-probing the bare engine shows that **the parser
ALREADY honors the `+` correctly**. Bare engine output:
- `k+ya` → `[0] ကယ` (1000 101A) — `+` honored, two syllables
- `k+wa` → `[0] ကဝ` (1000 101D) — `+` honored
- `k+yar` → `[0] ကယာ` (1000 101A 102C) — `+` honored
- `k+wi` → `[0] ကဝီ` (1000 101D 102E) — `+` honored
- `ka+ya`, `ka+wa`, `ka+yar`, `ka+wi`, `p+ya`, `p+wa` — all `+`-
  honored on the bare engine.

The bug is **LM/lexicon-driven** and only fires in the production-
equivalent engine (`BurmeseEngine(candidateStore:languageModel:)`):
the trigram LM has strong evidence for high-frequency cluster forms
(e.g. `ကြ` `kya` is a productive prefix in many lexicon entries
like `ကြောင့်`, `ကြောင်း`, `ကြား`), so `grammarCandidateIsBetter` in
`Engine/CandidateRanking.swift` prefers the cluster-medial parse
above the user-respecting two-syllable parse.

This is structurally identical to archived TASK-031 (LM-favored
cross-class segmentation displaces explicit kinzi `<C>in+<C>`).
TASK-031 was fixed by introducing an explicit-`+` rank-0 promotion
mirror to the existing `bestStrictInferredStackIndex` lift. The
present task is the medial-cluster analogue: the user-typed `+`
between `<C>` and a cluster-letter `y/w` is the strongest possible
signal that the user does NOT want a medial; the LM should not be
allowed to displace it.

The fix likely requires:
1. `Engine/CandidateRanking.swift` — extend the user-explicit-`+`
   rank-0 promotion (analogous to TASK-031's `strictInferredStack
   Outputs`) to cover the two-syllable form `<C><cluster-letter>`
   when the input contains `+` at the right boundary, so the LM
   bonus for cluster-medial forms cannot displace it.
2. NO parser-level fix is needed (and applying one would be
   counter-productive): the bare engine already produces the right
   result. Touching `NBestDP` / `SyllableParser` would risk
   regressing the no-`+` cluster-promotion behavior tested by
   `CwyClusterPromotionSuite`.

## Burmese Language Rule Reference
CLAUDE.md §6 ("Explicit `+`"): *"User-typed `+` is a hard syllable /
stack boundary. The LM may rank among legal stack variants, but it
should not displace the user's explicit kinzi/stack intent with an
unrelated segmentation."* Promoting `<C>+<C>` into a single-syllable
medial cluster (`kya`, `kwa`) IS displacing the user's explicit
boundary intent with the LM-preferred segmentation.

CLAUDE.md §5 ("Romanization Conventions"): *"`y` after a consonant
is structural ya-yit."* This is the default (no-`+`) behaviour.
The user's `+` is the explicit override that says "no, treat as
fresh syllable, not as ya-yit".

## Steps to Reproduce
1. Build the production-equivalent engine with bundled artifacts:
   ```swift
   let store = try! SQLiteCandidateStore(path: BundledArtifacts.lexiconPath!)
   let lm = try! TrigramLanguageModel(path: BundledArtifacts.trigramLMPath!)
   let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
   ```
   **Note**: the bug does NOT reproduce on a bare `BurmeseEngine()`.
   The bare engine produces the correct two-syllable rank-0 surface
   for all listed buffers. Use the production stack to reproduce.
2. For each buffer in `{k+ya, k+wa, k+yu, k+yar, k+wi, k+war,
   ka+ya, ka+wa, ka+yu, p+ya, p+wa}`, call
   `engine.update(buffer: input, context: [])`.
3. Inspect `state.candidates[0].surface`. Observe that rank-0
   contains a medial scalar (`103B`, `103C`, or `103D`) on the
   first consonant — the cluster interpretation that ignores the `+`.
4. Inspect `state.candidates[1].surface`. Observe that the
   two-syllable form (the `+`-honoring interpretation) is reachable
   at rank 1.

## Current State
- `<C>+<cluster-letter><a/V>` rank-0 is the cluster-medial form
  (`+` discarded).
- The two-syllable form is in the panel at rank 1+ — soft issue
  per CLAUDE.md "general reachability rule" (the user's intended
  conversion is reachable below rank 0).
- The companion shape `<C>+<cluster-letter>` (no trailing vowel)
  IS rank-0 the two-syllable form — confirming the parser does
  understand the `+`-as-boundary intent in the simpler shape.

## Desired State
- `k+ya`, `ka+ya` rank-0 = `ကယ` (`1000 101A`, two syllables).
- `k+wa`, `ka+wa` rank-0 = `ကဝ` (`1000 101D`, two syllables).
- `k+yar` rank-0 = `ကယာ` (`1000 101A 102C`, two syllables).
- `k+war` rank-0 = `ကဝါ` (`1000 101D 102B`, two syllables).
- `k+yu` rank-0 = `ကယူ` (`1000 101A 1030`, two syllables).
- `k+wi` rank-0 = `ကဝီ` (`1000 101D 102E`, two syllables).
- The cluster-medial form (`ကြ`, `ကွ`, `ကြာ`, `ကွာ`, `ကျူ`, `ကွီ`)
  remains reachable in the panel for users who want it via
  history selection or paging.
- TASK-047's `<C>+<vowel-rule>` cases stay rank-0 unchanged.
- TASK-058's `CwyClusterPromotionSuite` cases (which test
  `<C><cluster-letter>` without `+`) stay rank-0 unchanged.

## Acceptance Criteria
- For each buffer in the table above, rank-0 surface lacks the
  cluster medial scalar (`103B`, `103C`, `103D`) on the first
  consonant.
- For each buffer, rank-0 surface contains TWO consonant
  anchors with the cluster letter rendered as an independent
  consonant (`101A` for `y`, `101D` for `w`) attached to a
  fresh syllable.
- The cluster-medial form remains reachable in the panel
  (rank ≤ 5) so legacy user expectations are preserved.
- Regression coverage:
  - `Sources/BurmeseIMETestSupport/Suites/PlusBeforeVowelRuleSuite.swift` —
    add bug rows for the `<C>+<cluster-letter><a/V>` shapes.
  - `CwyClusterPromotionSuite`, `ClusterMedialPreferenceSuite`,
    `LangYaPinYaYitAlternationSuite` — assert no regression on
    no-`+` cluster shapes.
  - `ExplicitPlusKinziDisplacementSuite` — confirm kinzi
    promotion is not weakened.

## Notes
- Probe outputs (PRODUCTION-EQUIVALENT engine with bundled
  lexicon + trigram LM, current `main` commit `fdd6541`):
  ```
  k+ya     -> [0] ကြ    (1000 103C)        reading=kya       ← BUG (LM-driven)
              [1] ကယ    (1000 101A)        reading=ka+ya     ← desired rank 0
  k+y      -> [0] ကယ    (1000 101A)        reading=ka+ya     ← correct (no trailing vowel)
  k+yar    -> [0] ကြာ   (1000 103C 102C)   reading=kyar      ← BUG
  k+wa     -> [0] ကွ    (1000 103D)        reading=kwa       ← BUG
  k+wi     -> [0] ကွီ    (1000 103D 102E)  reading=kwi       ← BUG
  k+ra     -> [0] ကရ    (1000 101B)        reading=ka+ra     ← correct (r-cluster)
  ka+ra    -> [0] ကရ    (1000 101B)        reading=ka+ra     ← correct
  ka+ya    -> [0] ကြ    (1000 103C)        reading=kya       ← BUG (same as k+ya)
  ```
- BARE-engine probe outputs (`BurmeseEngine()`, no LM/lexicon)
  for the SAME buffers — confirms the bug is LM-driven:
  ```
  k+ya     -> [0] ကယ    (1000 101A)        reading=ka+ya     ← correct
  k+wa     -> [0] ကဝ    (1000 101D)        reading=ka+wa     ← correct
  k+yar    -> [0] ကယာ   (1000 101A 102C)   reading=ka+yar    ← correct
  k+wi     -> [0] ကဝီ   (1000 101D 102E)   reading=ka+wi     ← correct
  ka+ya    -> [0] ကယ    (1000 101A)        reading=ka+ya     ← correct
  p+ya     -> [0] ပယ    (1015 101A)        reading=pa+ya     ← correct
  ```
- The asymmetry between `r`-cluster (honored even with LM) and
  `y`/`w`-cluster (not honored) is because the LM has stronger
  evidence for `ya-yit` / `wa-hswe` cluster prefixes (productive
  in `ကြောင်း`, `ကြား`, `ကွန်`, …) than for `ya-pin` and
  `r`-cluster prefixes. The fix should add an explicit-`+`
  rank-0 promotion that protects the user's segmentation from
  LM displacement uniformly across all three cluster letters.
- This is both a **soft issue** by CLAUDE.md §7 ("General
  reachability rule") — the user's intended form IS reachable at
  rank 1 — and a **clear violation** of CLAUDE.md §6 ("User-typed
  `+` is a hard syllable / stack boundary") because the explicit
  `+` should not be displaceable by LM ranking. TASK-031 set the
  precedent: the kinzi explicit-`+` was promoted at rank 0 to
  prevent the same class of LM displacement.

## Validation Notes

### Validity verdict
**Valid (with corrections)** — the bug is real but the original
task incorrectly attributed it to the parser. Re-probing shows the
bug is **LM-driven only**: the bare engine produces the correct
two-syllable rank-0 form for every listed buffer; only the
production-equivalent engine (with bundled lexicon + trigram LM)
exhibits the bug.

### What changed
- **Status**: `Open` → `Revised`.
- **Steps to Reproduce**: corrected — must use production-equivalent
  engine, not bare engine. Original task text said "the bug
  reproduces on the bare engine" which is FALSE.
- **Root Cause**: rewritten. Original proposed a parser-level fix
  (`NBestDP.swift`, `SyllableParser.swift`,
  `InputNormalization.swift::collapseConnectorRuns`) which would
  break the existing `CwyClusterPromotionSuite` and the bare-engine
  parser invariants. Revised root cause attributes the bug to the
  LM ranking layer (analogous to TASK-031's kinzi displacement) and
  proposes a `Engine/CandidateRanking.swift` fix.
- **Notes**: added bare-engine probe output to make the
  LM-vs-parser distinction unambiguous for the fixing agent.

### Scope assessment
Original scope is correct in WHICH buffers exhibit the bug. The
example coverage (`y`, `w` cluster-letters with various trailing
vowels) is appropriately broad. `r`-cluster correctly works
because the LM doesn't have strong cluster-prefix evidence for
`r`-onset.

### Examples augmented
Added bare-engine output rows for every buffer in the table, to
clearly show the parser already does the right thing. The fix is
isolated to ranking, not parsing. This avoids the fixing agent
spending time on the wrong layer.

### Acceptance criteria refinement
Added (implicit) constraint: the fix MUST NOT touch
`SyllableParser`, `NBestDP`, or `InputNormalization::collapseConnector
Runs`. Those layers are correct. The fix is in the
`Engine/CandidateRanking.swift` ranking comparator OR a sibling
explicit-`+` promotion path mirroring `bestStrictInferredStackIndex`
(TASK-031 precedent).

### Code reference verification
- `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/LangViramaStackSuite.swift:80-105`
  has tests for `k+ya` and `k+wa` that pin "rank-0 must NOT be the
  literal cross-class virama stack `1000 1039 101A`/`1000 1039 101D`".
  Both the current cluster-medial form AND the desired two-syllable
  form satisfy this constraint, so the suite stays green either way.
- `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/GrammarSuite.swift:315-327`
  asserts `SyllableParser().parse("k+ya").first` does not contain
  virama `1039`. Bare-parser tests, not affected by LM-layer fix.
- `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/CwyClusterPromotionSuite.swift`
  pins no-`+` cluster behavior. The fix MUST keep no-`+` cases
  rank-0 unchanged; only `+`-bearing inputs promote two-syllable.

### Open questions resolved
- Q: Is this a parser bug or a ranking bug? A: Ranking. Bare engine
  is correct.
- Q: Is the cluster-medial form an undecidable sibling of the
  user-respecting form, à la archived TASK-039 / TASK-042
  (CLAUDE.md §7)? A: No. The user's `+` is an unambiguous segment-
  boundary signal. Per CLAUDE.md §6 it must not be displaced by
  LM ranking among "legal alternatives" because the cluster-medial
  parse contradicts the `+` boundary.
- Q: Will the fix risk regressing `ka+ka` (kinzi-stack) or
  `min+ga` cases? A: No, those are kinzi-stack shapes already
  protected by TASK-031's `bestStrictInferredStackIndex`. The new
  promotion would be a sibling specifically for `<C>+<cluster-
  letter><V>` shapes.

## Implementation Notes

The bug lived in the lexicon-rank-0 carve-out introduced by TASK-031
in `BurmeseEngine.update`
(`Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`,
around line 1977 in the explicit-`+` strict-stack promotion block).

TASK-031 added a guard to skip the strict-stack rank-0 promotion when
a lexicon-source candidate already occupied rank 0. The reasoning was
that lexicon hits are the strongest signal — a curated dictionary
match should not be displaced by a grammar-side strict-stack
candidate.

That guard was too permissive for the `<C>+<cluster-letter><V>` shape.
For `k+ya`, the LM-favoured rank-0 was the lexicon hit `ကြ` with
reading `kya` — a match that IGNORED the user's explicit `+`. The
strict-inferred-stack candidate `ကယ` (reading `ka+ya`, the user-
respecting two-syllable form) sat at rank 1 and never got promoted
because the lexicon-rank-0 protection fired.

The fix narrows the guard: protect the lexicon rank-0 only when its
reading also contains the user's `+`. When the lexicon hit's reading
lacks `+`, it represents a *different* segmentation than the user
typed, so the user's explicit `+` (per CLAUDE.md §6) must win.

```swift
let lexiconAtSlotZero = displayBuffer.contains("+")
    && !merged.isEmpty
    && merged[0].source == .lexicon
    && merged[0].reading.contains("+")  // <-- new
```

This preserves the original TASK-031 protection: when the user's
typed `+` matches a lexicon entry that also carries `+` in its
reading (e.g. compound entries with explicit boundary readings), the
lexicon hit still wins. It only rebalances when the lexicon match
ignores the user's boundary signal, which is exactly the TASK-056
bug shape.

The fix is purely in the LM/lexicon ranking layer; the parser is
unchanged. `CwyClusterPromotionSuite`, `ClusterMedialPreferenceSuite`,
and the no-`+` cluster shapes (`kya`, `kwa`, `kyar`, `kwi`, `pya`,
`pwa`) all stay rank-0 unchanged because their displayBuffer does
not contain `+`. TASK-031's `min+ga` / `kan+ga` family stays
unchanged because the strict-inferred-stack promotion still applies
(the lexicon at slot 0, when present, has a reading carrying `+`,
which the new condition allows; otherwise the promotion fires
unconditionally as before).

Files changed:
- `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`
  (`lexiconAtSlotZero` discriminator)
- `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/PlusBeforeClusterLetterSuite.swift`
  (new test suite)
- `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/BurmeseTestSuites.swift`
  (suite registration)

## Validation Report

**Verdict: FULLY_COVERED**

- Acceptance criteria: bug buffers (`k+ya`, `k+yar`, `k+yu`, `k+wa`,
  `k+wi`, `k+war`, `ka+ya`, `ka+wa`, `ka+yu`, `p+ya`, `p+wa`) are
  covered in `PlusBeforeClusterLetterSuite`. Both predicate tests
  (`firstConsonantHasMedial` must be false at rank 0) AND scalar-hex
  equality assertions for the canonical two-syllable surfaces are
  present.
- Cluster-medial reachability is asserted (top-5) so the demoted form
  remains in the panel for legacy users — satisfies CLAUDE.md §7
  general reachability rule.
- Regression guards: explicit suite cases assert
  - no-`+` cluster shapes (`kya`, `kwa`, `kyar`, `kwi`, `pya`, `pwa`)
    keep their medial rank-0 (TASK-058 invariant);
  - TASK-031 kinzi (`min+ga` → `1019 1004 103A 1039 1002`) and asat
    closure (`kan+ga` → `1000 1014 103A 1002`) stay rank-0 unchanged;
  - TASK-047 `<C>+<vowel-rule>` shapes (`ka+aung`, `k+aung`, `ka+i`)
    stay rank-0 unchanged;
  - `r`-cluster shapes (`k+ra`, `ka+ra`, `p+ra`) stay correct.
- Fix design is targeted: tightening the lexicon-rank-0 carve-out to
  require `merged[0].reading.contains("+")` only changes ranking when
  the user typed `+` AND the rank-0 lexicon hit doesn't carry `+` in
  its reading — exactly the TASK-056 bug shape. All other branches
  (no-`+` input, lexicon hits whose reading carries `+`) are
  unaffected, which is consistent with TASK-031's design intent.
- Suite uses `BundledArtifacts` and skips cleanly if artifacts are
  absent, matching the project convention for production-equivalent
  ranking claims.
- No regressions: full test run is 1529/1529 cases / 8258/8258
  assertions. `LexiconRankingSuite`, `ExplicitPlusKinziDisplacement
  Suite`, `CwyClusterPromotionSuite`, `LangViramaStackSuite` all
  remain green.
- Coverage: 6 test cases exercising headline rank-0 shape, scalar-hex
  equality, panel reachability, and four regression guards; both
  branches of the updated `lexiconAtSlotZero` condition are
  exercised.
