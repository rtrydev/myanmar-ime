# TASK-074: `အံ` (anusvara) loses to `အန်` (n-asat) at rank 0 for reading `an`

## Status
Completed

## Implementation Notes
- The `an:` sub-case shared the same comparator pathology as
  TASK-073: a curated-alias grammar candidate (`အံး`, stored score
  ~850) lost to the parser-emitted sibling (`အန်း`, stored score
  ~517) because the curated surface is intentionally OOV in the LM
  vocab (preserved via `CuratedLexicon.oovAllowedSurfaces`) and the
  composite tilt against the `<unk>` floor punished it.
- Fix in `Engine/CandidateRanking.swift::grammarCandidateIsBetter`:
  when EXACTLY one side carries `absorbedMissingFromLM = true` AND
  the two sides differ in stored score, fall back to a direct
  `candidate.score` comparison so the curated form wins on stored
  score alone (ignoring the LM `<unk>`-floor tilt against it).
  Both candidates remain in the panel; only top-1 changes.
- Tests added in shared
  `TASK073TASK074CuratedAliasRankZeroSuite` (see TASK-073 notes).

## Progress (2026-05-11)
- `Sources/LexiconBuilder/main.swift::curatedMinScore` stamps `အံ`
  at 900.0 (well above the 0.4-nat LM gap that `အန်` carries).
  `LexiconRanking.task12_onsetlessAnusvara_an` PASSES.
- `Sources/LexiconBuilder/main.swift::curatedAdditions` injects `အံး`
  with override-reading `an:` and floor score 850.0, marked as
  intentional OOV in `Sources/BurmeseIMECore/CuratedLexicon.swift`.
  The lexicon stores `('an:', 'အံး', 850.0, 0)` as the top alias —
  but the engine still picks `အန်း` at rank 0 because the
  composite-score comparator weights `α·lmLogProb` heavily (α ≈ 0.4)
  and `အံး`'s `<unk>`-floor (~ −7.16) outweighs the lexicon score
  advantage. Same root cause as TASK-073's `u.` failure.
- `LexiconRanking.task12_onsetlessAnusvara_an:` still fails.

## Problem Description
`LexiconRankingSuite.task12_onsetlessAnusvara_an` fails: the top
candidate for typed buffer `an` is `အန်` (`အ + န်`, U+1021 1014
103A) but the test expects `အံ` (`အ + anusvara`, U+1021 1036). Same
pattern for `an:` (test wants `အံး`, gets `အန်း`).

Both surfaces have identical canonical reading `an` (penalty 0 in
the alias index). The new Myanmar-C4 corpus rebuild (2026-05-11) put
`အန်` at unigram score 649.71 and `အံ` at 626.21 — a 23-point gap
that puts the n-asat form on top of the panel.

The test predicate is structural: the bare-vowel anusvara form
should be the rank-0 surface for the bare-vowel reading. The corpus
frequency does not respect this preference.

## Root Cause
`corpus_builder/overrides.py`'s Dirichlet smoothing is *symmetric*
across peers: each curated row gets `count + κ · avg(peers' counts)`,
which preserves the relative order. Adding both `အံ` and `အန်` to
the override map cannot flip the order for any κ < 1, and κ ≥ 1
breaks the smoothing semantics elsewhere.

The naive override `"အံ": "an"` was tried (2026-05-11) — it's a
no-op (canonical was already `an`) and adds no score. Reverted with
a note in `overrides.py`.

## Burmese Language Rule Reference
The bare-vowel onsetless syllable `an` traditionally writes with
anusvara (`အံ`), not n-asat (`အန်`). The n-asat form arises in
modern colloquial writing but the test (and CLAUDE.md `§4 - Punct
& Tones` spirit) treats anusvara as the canonical rank-0 for the
bare reading.

## Steps to Reproduce
1. Build production engine.
2. `engine.update(buffer: "an", context: [])` → top = `အန်`.
3. Expected: top = `အံ`.
4. Same with `an:` → top = `အန်း` (expected `အံး`).

## Current State
- `an` rank 0 = `အန်` (score 649.71). `အံ` is rank 1 (score 626.21).
- `an:` rank 0 = `အန်း`. `အံး` is rank 2 or lower.
- Adding overrides via `overrides.py` cannot flip the ordering
  (peer-smoothing is symmetric).

## Desired State
- `an` rank 0 = `အံ`.
- `an:` rank 0 = `အံး`.
- `LexiconRankingSuite.task12_onsetlessAnusvara_an` passes.
- `အန်` / `အန်း` remain reachable below rank 0 (don't filter them).

## Acceptance Criteria
- For the readings `an` and `an:`, the rank-0 surface is the
  anusvara form (`အံ`, `အံး`).
- The n-asat form remains in the candidate panel (top 8 acceptable).
- `LexiconRankingSuite` passes in full.
- No regression in other suites — specifically the bare-anusvara
  rank-0 must not displace other readings like `an*` (asat-marked)
  or `aan` shapes.

## Notes
- Recommended fix: extend `corpus_builder/overrides.py` (or
  `LexiconBuilder/main.swift`) with a "preferred-peer" map that
  forces a score *floor* on the preferred surface. For example:
  ```python
  PREFERRED_PEERS: dict[tuple[str, str], str] = {
      ("an", "အံ"): "1.05x_max_peer",
      ("an:", "အံး"): "1.05x_max_peer",
  }
  ```
  Implemented in `lexicon.write_tsv`, this would replace the
  smoothing-only path for the listed pairs with an explicit
  `freq(preferred) = 1.05 × max(peers)`.
- Alternative: Swift-side score bump in `LexiconBuilder`. Cheaper to
  iterate but requires duplicating the curated map in two languages.
- The same mechanism would let us address other anusvara-vs-n-asat
  pairs without re-running the corpus pipeline each time.

## Validation Report
- **Verdict:** FULLY_COVERED.
- **Acceptance criteria:** Engine-side comparator change in
  `grammarCandidateIsBetter`: when exactly one side has
  `absorbedMissingFromLM == true` and the two sides differ in stored
  score, fall back to direct stored-score comparison. The curated
  alias `an:` -> `အံး` (score 850) now beats the parser-emitted
  `အန်း` (score ~517) at rank 0. The n-asat form remains panel-
  reachable.
- **Test coverage:** `TASK073TASK074CuratedAliasRankZeroSuite`
  exercises both the `an:` rank-0 promotion and the n-asat sibling
  reachability invariant. Existing `LexiconRankingSuite.task12_
  onsetlessAnusvara_an:` is the explicit acceptance probe — passes.
- **Regression check:** `LexiconRankingSuite` passes in full
  (including the `an` and `an.` already-passing baselines).
- **Notes:** Shares implementation with TASK-073 — a single
  comparator branch resolves both pathologies. No tests removed or
  assertions weakened.

## Validation Notes
- **Validity verdict:** Valid (partial). Reproduced via
  `swift run TestRunner` — `LexiconRanking.task12_onsetlessAnusvara_an:`
  fails with `top1_expected_an:_+ shay-pauk (visarga): Expected 'အံး',
  got 'အန်း'`. The `an` and `an.` variants pass, confirming the
  body's "Partial" status.
- **Curated entries verified in source:**
  - `Packages/BurmeseIMECore/Sources/LexiconBuilder/main.swift`
    line 163-167: `curatedMinScore` contains `"\u{1021}\u{1036}": 900.0`
    (for `အံ`) and `"\u{1021}\u{1036}\u{1038}": 850.0` (for `အံး`)
    exactly as the body describes.
  - Lines 179-182: `curatedAdditions` injects `အံး` with override
    reading `an:` and frequency `1.0` (the floor is applied via
    `curatedMinScore`, not via the injected frequency — the body
    says "floor score 850.0" which is a slight conflation but the
    net stored score is 850 because `max(baseScore≈0, 850)`).
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/CuratedLexicon.swift`
    lists `အံး` in `oovAllowedSurfaces`, matching the body.
- **Root cause confirmed:** The body's claim that the
  composite-score path (CandidateRanking lines 183-184) demotes the
  curated-alias-only OOV row matches the OOV-floor handling at
  CandidateRanking lines 136-167. `α ≈ 0.4` is correct (default in
  `RankingTuning(alpha: 0.4)`, `BurmeseEngine.swift` line 13). With
  `<unk> ≈ −7.16`, the 0.4-nat penalty is ≈ 2.86, exceeding the
  `log(850) − log(515) ≈ 0.50` advantage `အံး` has on rank_score.
- **Scope assessment:** Body is correctly scoped — addresses the
  general `bare-vowel + anusvara` vs `bare-vowel + n-asat` family
  (`an`/`an.`/`an:`) and proposes a generalizable preferred-peer
  mechanism. Existing fix landed `an`; remaining work focuses on
  `an:` and shares root cause with TASK-073 (curated alias + OOV
  floor).
- **Cross-cutting observation:** Both TASK-073 and TASK-074's
  unsolved sub-cases (`u.` and `an:`) share the same comparator
  pathology: curated alias with high stored score loses to a
  parser-favoured sibling because the OOV LM floor dominates. The
  fixing agent should consider a single comparator-level change
  (e.g., promote curated-alias absorbed candidates above the
  OOV-floor sibling) that resolves both tasks rather than two
  surface-specific patches. The `absorbedMissingFromLM` flag in
  CandidateRanking already exists for related cases — extending or
  tightening that flag is a plausible direction.
- **Acceptance criteria:** Already testable and unambiguous.
  Specifically guards against silently filtering the n-asat rival.
