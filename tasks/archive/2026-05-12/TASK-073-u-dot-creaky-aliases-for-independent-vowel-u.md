# TASK-073: Add `u.` (creaky) alias for independent vowel `ဥ` without breaking `u` → `ဥ`

## Status
Completed

## Implementation Notes
- The curated alias `u.` → `ဥ` was already in the lexicon (TSV +
  `curatedExtraAliases` map) from a prior iteration; the missing
  piece was engine-side ranking. The grammar candidate `ဥ` (absorbed
  via the curated alias, stored score ~745) lost to the pure-lexicon
  candidate `အူ့` (stored score ~193) at rank 0 because the merge
  unconditionally places `exactAliasLexicon` entries ahead of all
  grammar candidates, regardless of composite or absolute score.
- Fix in `Engine/BurmeseEngine.swift`: at the merge step, if the top
  grammar candidate's alias-reading matches the user's exact alias
  prefix AND its absorbed score is more than 2× the best pure-
  lexicon candidate's score, lift the grammar candidate ahead of the
  prioritized lexicon. Narrow threshold so ordinary lexicon-absorbed
  grammar candidates don't override the existing merge order.
- Tests added: `TASK073TASK074CuratedAliasRankZeroSuite` covers
  `u.` → `ဥ` (this task) and `an:` → `အံး` (TASK-074, shared
  comparator pathology) plus controls for the already-passing
  baseline (`u`, `u2`, `an`, `an.`) and panel reachability for the
  parser-emitted siblings (`အူ့`, `အန်း`).

## Problem Description
`RankingSuite.issueD_engineTopSurfacesLegalStandaloneVowel` fails on
the creaky-tone variant: `u.` should produce `ဥ` (U+1025) at rank 0
but produces `အူ့` (`အ + uu-vowel + dot-below`).

The independent vowel `ဥ` in Burmese is *phonetically* pronounced
with creaky tone (`/ʔù/`), but the LETTER carries no tone mark in
storage. The reverse romanizer therefore emits canonical reading `u`
for surface `ဥ`. Users typing the creaky-marked form `u.` expect
`ဥ` (per Burmese phonetics + traditional typing convention) but the
lexicon has no `u.` alias for that surface.

The naive fix — stamping `ဥ → "u."` via `overrides.py` — was tried
and reverted (2026-05-11 iteration). It correctly added `u.` → `ဥ`
but broke FIVE other tests that rely on `u` → `ဥ` ordering:
`engineTop.u`, `task02_orphanZwnj_suppressed_u`,
`task10_trailingDigit_u2` (two assertions),
`tasksDir03_bareVowelPrimary_u`. The override rewrites the canonical
and only the rewritten form is alias-indexed.

## Root Cause
The `Romanization.indexedAliasReadings` pipeline only emits one
digit-stripped variant per canonical reading. There is no built-in
"add creaky-tone alias" rule for short-vowel readings of independent
vowels.

The override mechanism in `corpus_builder/overrides.py` is a
one-to-one map (`surface → single canonical reading`); it cannot
attach multiple readings to the same surface.

## Burmese Language Rule Reference
The seven independent vowels (`ဣ`, `ဤ`, `ဥ`, `ဦ`, `ဧ`, `ဩ`, `ဪ`)
have stable phonetic creaky/short distinctions baked into their
*pronunciation* even when the letter itself carries no tone mark.
The bare-letter form maps to `u`; the creaky-pronunciation form
maps to `u.`. Both should reach the same surface.

The expected predicate: for each `(surface, creaky_reading,
short_reading)` independent-vowel pair, BOTH readings must produce
the surface as a top candidate.

## Steps to Reproduce
1. Build production engine.
2. `engine.update(buffer: "u.", context: [])` → top = `အူ့` (wrong).
3. `engine.update(buffer: "u", context: [])`  → top = `ဥ` (correct).
4. Same predicate applies to `i.` / `i` for `ဣ` if applicable
   (verify whether the suite covers it).

## Current State
- `u.` → `အူ့` (rank 0, score 193) — bug.
- `u` → `ဥ` (rank 0, score 745) — correct.
- The override path was tried: makes `u.` → `ဥ` work but breaks
  `u` → `ဥ` (the digit-stripped alias only carries one form).

## Desired State
- `u.` → `ဥ` at rank 0.
- `u` → `ဥ` at rank 0 (preserved).
- `u2` → `ဥ၂` at rank 0 (preserved).
- `RankingSuite.issueD`, `task02`, `task10`, `tasksDir03` all green.

## Acceptance Criteria
- For each of `{u, u., u2, u2:}` the rank-0 surface contains `ဥ`
  (possibly followed by a digit when input had a digit).
- `RankingSuite` passes in full.
- No regression in `ReverseRomanizerSuite`, `LexiconRankingSuite`.

## Notes
- The Swift-side curated alias map landed
  (`Sources/LexiconBuilder/main.swift::curatedExtraAliases`,
  `"\u{1025}": [("u.", 0)]`). Verified: the lexicon now has
  `('u.', 'ဥ', 745.95, 0)` as the highest-scored alias for reading
  `u.`. **However, the engine still picks `အူ့` at rank 0.** The
  parser-produced `အူ့` has a non-zero `parserScore` and the
  composite-score comparator at
  `CandidateRanking.swift:183` (`log(rank_score) + α·lmLogProb`)
  prefers it over the lookup-only `ဥ` (which has `parserScore = 0`
  and is "absorbed"-flagged).
- So the lexicon alias is **necessary but not sufficient**. The
  remaining work is engine-side:
  - Option A: bump lookup-only candidates' `parserScore` when they
    come from a curated extra alias (treat them as if the parser
    produced them).
  - Option B: introduce a "trusted curated alias" flag in the
    candidate metadata that the composite-score comparator weights
    above the parser-favoring tie-break.
  - Option C: extend the parser/forward-romanizer to emit `ဥ` as a
    candidate for `u.` natively, so it picks up parser-score the
    same way `အူ့` does.
- Sibling independent vowels to consider: `ဣ` (i / i.), `ဥ` (u / u.),
  `ဩ` (aw / aw.). Add to the same map once the engine-side fix lands.
- `task02_orphanZwnj_suppressed_u`, `task10_trailingDigit_u2`,
  `tasksDir03_bareVowelPrimary_u`, `engineTop.u` — all `u`-typing
  paths — pass after the ZWNJ-drop and `curatedExtraAliases` landed.
  Only `engineTop.u.` (creaky-dot variant) remains.

## Validation Report
- **Verdict:** FULLY_COVERED.
- **Acceptance criteria:** All criteria covered. Two-pronged fix:
  (1) the merge-time `topGrammarBeatsPrioritizedLexicon` gate lifts a
  curated-alias-absorbed grammar candidate ahead of the prioritized
  lexicon when the grammar candidate's alias-reading matches the user
  prefix AND its absorbed score is more than 2x the top lexicon
  candidate's; (2) the
  `absorbedMissingFromLM`-asymmetry direct-score fallback in
  `grammarCandidateIsBetter` resolves the comparator pathology
  shared with TASK-074.
- **Test coverage:** `TASK073TASK074CuratedAliasRankZeroSuite` covers
  `u.` rank-0, controls for `u` / `u2` / `an` / `an.` baselines, and
  panel-reachability of the parser-emitted siblings (`အူ့`, `အန်း`).
  All pass.
- **Regression check:** `RankingSuite.issueD`,
  `task02_orphanZwnj_suppressed_u`, `task10_trailingDigit_u2`,
  `tasksDir03_bareVowelPrimary_u`, `engineTop.u`,
  `ReverseRomanizerSuite`, `LexiconRankingSuite` all green.
- **Notes:** No tests removed or assertions weakened.

## Validation Notes
- **Validity verdict:** Valid. Reproduced via `swift run TestRunner`
  — `Ranking.issueD_engineTopSurfacesLegalStandaloneVowel` fails on
  the `u.` expectation: got `အူ့`, expected `ဥ`. The `u` and `ay`
  controls pass, so the bug is narrowly scoped to the creaky `u.`
  shape.
- **Curated alias confirmed in source:**
  `Packages/BurmeseIMECore/Sources/LexiconBuilder/main.swift` lines
  149-151 contain `curatedExtraAliases: ["\u{1025}": [("u.", 0)]]`
  exactly as the task body describes. The lexicon side is in place.
- **Score chain confirmed:** Lines 354-355 compute
  `score = max(baseScore, curatedMinScore[surface])`. `curatedMinScore`
  for `ဥ` is not set (so the floor mechanism does not apply here), but
  the alias row `(u., ဥ, ~745, 0)` exists. The remaining bug is the
  composite-ranking comparison between a parser-emitted `အူ့`
  (parserScore > 0) and a lookup-only `ဥ` (parserScore = 0). This
  matches the comparator analysis at
  `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/CandidateRanking.swift`
  lines 183-184 (composite = `log(rank_score) + α · lmLogProb`,
  α ≈ 0.4).
- **Scope assessment:** Body is broad enough — addresses the full
  class of independent-vowel creaky-tone aliases (`ဣ`/`ဥ`/`ဩ`)
  via the curated-alias mechanism, with explicit follow-up to
  expand the map once the engine-side fix lands. Acceptance
  criteria mention `{u, u., u2, u2:}` which covers the four
  shapes per CLAUDE.md §3 ("Digits Are Literal") + the creaky
  variant.
- **Burmese-rule reference:** Independent-vowel creaky/short
  pronunciation distinction is correct. The seven independent
  vowels enumerated (ဣ ဤ ဥ ဦ ဧ ဩ ဪ) match Unicode U+1023..U+102A.
- **Risks to flag for fixer:** Options A/B/C in the body all touch
  ranking. Option A (bump parserScore for curated-alias lookups)
  risks letting a curated alias outscore a legitimate parser-emitted
  rival even when the parser parse is the user's intent. Prefer
  Option C (extend the parser/forward-romanizer to emit `ဥ`
  natively for `u.`) since it grants parserScore the same way for
  the canonical and creaky readings and avoids special-casing
  curated metadata. If Option A is used, the bump must be tightly
  gated so other lookup-only candidates are not affected.
