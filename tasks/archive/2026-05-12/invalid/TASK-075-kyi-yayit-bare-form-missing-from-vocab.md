# TASK-075: Bare ya-yit `ကြီ` missing from corpus vocab; not reachable from `kyi` panel

## Status
Invalid (already fixed and passing — see Validation Notes)

## Progress (2026-05-11)
- `Sources/LexiconBuilder/main.swift::curatedAdditions` injects
  `ကြီ` with override-reading `ky2i2` and floor score 900.0,
  flagged as known-OOV in `Sources/BurmeseIMECore/CuratedLexicon.swift`.
- `Sources/BurmeseIMETestSupport/Suites/LexiconLMDriftSuite.swift`
  consults `CuratedLexicon.oovAllowedSurfaces` so the runtime drift
  check tolerates these intentional OOV rows.
- `LexiconRanking.task13_yayit_still_in_panel_kyi` PASSES — `ကြီ`
  is now in the engine's panel for buffer `kyi`.

## Problem Description
`LexiconRankingSuite.task13_yayit_still_in_panel_kyi` fails: the
panel for buffer `kyi` is supposed to contain `ကြီ` (`k + ya-yit +
ii`, the bare ya-yit form). Current panel for `kyi` is:

```
["ကျီ", "ကြည်", "ကျည်", "ကျင့်သုံး", "ကျင်းပ", "ကြီး", "ကျင့်ကြံ", "ကျင့်"]
```

`ကြီး` (kyi:, with visarga, "big" — score 796.96) is present, but the
bare `ကြီ` (no visarga) is absent. Inspection of the regenerated
vocab.pkl confirms `ကြီ` is NOT in the 80k vocabulary at all — only
its visarga / compound forms made the cut.

## Root Cause
The Myanmar-C4 corpus (2026-05-11 rebuild) doesn't contain enough
isolated `ကြီ` tokens to make the top-80 000 vocab cap. The
segmenter likely emits `ကြီး` (with visarga) for the vast majority
of bare `kyi:` mentions because the visarga is what carries
"big"/"large" meaning in running text. The bare `ကြီ` is rare on its
own.

The test predicate (panel reachability) cannot be satisfied without
the surface being present in the lexicon, since the engine's
candidate generation goes through parser → lexicon lookup.

## Burmese Language Rule Reference
CLAUDE.md §7 "General reachability rule": the user's intended
conversion should appear in the candidate panel (top 3 strongly
preferred). Below rank 0 is a soft issue. For ya-yit reachability
specifically, the panel must surface BOTH ya-pin (`ကျီ`) and ya-yit
(`ကြီ`) variants for the digit-less reading.

## Steps to Reproduce
1. Build production engine.
2. `engine.update(buffer: "kyi", context: [])`.
3. Inspect `state.candidates[0..<8].map(\.surface)` — `ကြီ` is
   absent.
4. Confirm in lexicon: `cur.execute("SELECT * FROM entries WHERE
   surface = 'ကြီ'")` returns 0 rows.

## Current State
- `ကြီ` (1000 103C 102E) absent from vocab and lexicon.
- `ကြီး` (with visarga) present at score 797.
- `ကျီ` (ya-pin) present and panel-reachable.

## Desired State
- `ကြီ` (bare ya-yit) reachable in the top-8 panel for `kyi`.
- Other `kyi-` compounds (the panel composition) preserved.

## Acceptance Criteria
- `kyi` panel contains `ကြီ` somewhere in the top 8.
- `LexiconRankingSuite.task13_yayit_still_in_panel_kyi` passes.
- No regression in other `LexiconRankingSuite` cases or
  `ComprehensiveRankingSuite`.

## Notes
- Recommended fix: extend `corpus_builder/overrides.py` (or
  `vocab.py`) to inject a small list of "always-include" surfaces
  with a baseline frequency. For example:
  ```python
  CURATED_INCLUDE_SURFACES: dict[str, int] = {
      "ကြီ": 100,  # bare ya-yit ii, panel-reachability
      # …
  }
  ```
  These would be added to vocab before the top-80k cap is applied,
  guaranteeing presence. Requires `vocab.py` change and re-running
  `corpus-build vocab` + `lexicon` + `lm` (fast — uses cached
  tokens.txt).
- Alternative: Swift-side curated additions in `LexiconBuilder`.
  Cheaper to iterate (no `corpus-build` re-run) but the surface
  won't be in the LM vocab, so its `wordId` is `<unk>` and LM
  reranking won't favor it. Still reachable structurally as a
  parser candidate.
- Audit other "panel-reachable but rare" surfaces if this mechanism
  lands: bare independent vowels (`ဪ`), rare medial compounds, etc.

## Validation Notes
- **Validity verdict:** Invalid for the open-task queue. The fix has
  already landed and the suite passes — `swift run TestRunner`
  reports zero failures matching `task13_yayit_still_in_panel_kyi`,
  and the failing-test list in the latest run contains only TASK-070
  through TASK-074's open cases.
- **Code path verified:**
  - `Packages/BurmeseIMECore/Sources/LexiconBuilder/main.swift`
    lines 166 (`curatedMinScore["\u{1000}\u{103C}\u{102E}"] = 900.0`)
    and 181 (`curatedAdditions` row for `ကြီ` with reading `ky2i2`).
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/CuratedLexicon.swift`
    line 14 lists `ကြီ` in `oovAllowedSurfaces`, matching the body.
  - `LexiconLMDriftSuite` consults `oovAllowedSurfaces` so the
    intentional OOV is tolerated.
- **Recommended action:** Move this file to `tasks/archive/` (or
  delete) so the open-queue does not carry resolved work. Left in
  place for now since Step 2's mandate is to refine, not relocate;
  flagging here is sufficient for the parent pipeline.
- **Burmese-rule reference:** Accurate. CLAUDE.md §7 reachability
  rule is correctly quoted; the resolution preserves both `ကျီ`
  (ya-pin) and `ကြီ` (ya-yit) in the panel.
