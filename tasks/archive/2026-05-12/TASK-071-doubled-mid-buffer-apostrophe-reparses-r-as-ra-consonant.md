# TASK-071: Mid-buffer apostrophe re-parses `r` after a consonant as `ra`-consonant instead of `aa`-vowel

## Status
Completed

## Implementation Notes
- Added an engine-side ranking carve-out
  (`preferredAaOverBareBaseSubstitution` +
  `grammarCandidateIsBetter` gate) for the narrow pattern where two
  candidate surfaces differ by exactly one scalar substitution at the
  same index, one carrying an aa-family dependent vowel
  (U+102B / U+102C) and the other carrying a bare consonant base
  (U+1000..U+1021) standing as its own single-letter syllable (no
  follow-on dep-vowel / medial / asat / virama). When the parser score
  agrees, the aa-family form is selected directly without falling into
  the lattice composite. This prevents the 3-syllable
  `<C> + <particle> + <X>` re-segmentation from displacing the
  user-respecting `<C>aa + <X>` parse when the user typed `<C>ar'<X>`.
- The bare-base sibling remains in the panel at lower rank; no
  candidates are filtered out. No corpus rebuild required.
- Tests added: `TASK071ApostropheRaConsonantSuite` covers the
  regression (`thar'mar` → `သာမာ`) and the broader class (`kar'mar`,
  `nar'mar`, `phar'mar`), plus regression controls for the
  no-apostrophe baseline and panel reachability of the legitimate
  `Cra` cluster reading.

## Problem Description
`DoubledMidBufferApostropheSuite.singleApostrophe_topSurfaceUnchanged`
fails on input `thar'mar`. Expected top surface is `သာမာ` (101E 102C
1019 102C — "thaa-maa"). Got `သရမာ` (101E 101B 1019 102C — "tha-ra-
maa"): the `r` in `thar` is read as `ya/ra` consonant (U+101B) instead
of the `aa`-vowel marker (U+102C).

The bug is specific to the apostrophe-mid-buffer combination —
`thar` alone reaches `သာ` at rank 0, and `thar'` (one apostrophe at
the end) was historically stable. The doubled-apostrophe case has its
own suite because it's a known fragile shape; this is a regression of
the "single apostrophe should leave the top surface unchanged"
invariant.

## Root Cause
Investigation (2026-05-11) confirmed this is a **lattice-composite
scoring issue**, not a parser-segmentation bug. Lexicon scores:

| Reading | Surface | Score |
|---|---|---|
| `tha`  | `သ`  | 873.07 |
| `thar` | `သာ` | 832.61 |
| `ra`   | `ရ`  | **934.91** ← unusually high |
| `mar`  | `မာ` | 742.45 |

3-syllable parse `tha + ra + mar` = `သရမာ` totals 873+934+742 (log
sum 20.22). 2-syllable parse `thar + mar` = `သာမာ` totals 832+742
(log sum 13.33). The lattice composite picks the 3-syllable parse
because `ရ` (Pali genitive particle) is the most common single-letter
in the corpus.

Why this only affects `thar'mar`: the sibling cases `kar'par`,
`mingalar'par` ALSO have a viable 3-syllable parse (`ka+ra+par`,
`ka+ra+...+par`) with similar composite math. They pass because the
LM trigram for `ကာ ပါ` (and the longer bigram for `မင်္ဂလာ ပါ`) is
strong enough to override the per-syllable lattice. The LM does NOT
have a comparably strong bigram for `သာ မာ` (it's a less frequent
collocation in modern Burmese).

## Burmese Language Rule Reference
The romanization convention for `r` after a consonant: it is the
typing shorthand for the `aa`-vowel marker (U+102C). The CLAUDE.md
§5 ("Romanization Conventions") covers ya-pin/ya-yit but not the
`r`-as-vowel convention explicitly — it's an implicit property of
the syllable rule table.

## Steps to Reproduce
1. Build production engine.
2. `engine.update(buffer: "thar'mar", context: [])`.
3. Inspect `state.candidates[0].surface` — observe `သရမာ`.
4. Compare against `engine.update(buffer: "tharmar", context: [])`
   (no apostrophe) — should still produce `သာမာ` at rank 0.

## Current State
- `thar'mar` rank 0 = `သရမာ` (broken).
- `tharmar` (no apostrophe) rank 0 = `သာမာ` (correct).
- `thar` (alone) rank 0 = `သာ` (correct).
- `thar'` (trailing apostrophe) rank 0 = `သာ'` or `သာ` (historically
  correct).

## Desired State
- `thar'mar` rank 0 = `သာမာ` (single apostrophe mid-buffer leaves the
  base reading parse stable).
- `DoubledMidBufferApostropheSuite.singleApostrophe_topSurfaceUnchanged`
  passes.

## Acceptance Criteria
- For any input of the form `<C>ar'<X>` where `<C>` is a consonant
  and `<X>` is a Burmese-mappable suffix, the leading `Car` portion
  must parse as `<C> + aa-vowel` (102C), not `<C> + ra-consonant`
  (101B).
- `DoubledMidBufferApostropheSuite` passes in full.
- No regression in `MidBufferPunctuationSuite`,
  `ReverseRomanizerSuite`, `SyllableParserSuite`.

## Notes
- This was masked by the prior LM ranking. The data rebuild
  (2026-05-11) shifted scores enough to make the wrong parse win at
  rank 0. Probe the parser's N-best output to confirm the
  `r`-as-aa-vowel parse is still IN the candidate list but ranked
  below the `r`-as-consonant parse.
- Possible fixes:
  - Parser side: demote the bare `ra`-consonant arc when the
    preceding consonant is followed by an `r` in the buffer (so
    `Car` always prefers `aa`-vowel over `C + ra`). Risk: breaks
    legitimate `Cra` clusters where the user genuinely wants
    `<C>+<ra>` (e.g. `kraa`).
  - Engine side: a composite-score modifier that, for syllables
    whose surface is a single high-frequency particle-class scalar
    (`ရ`, `င်`, `သ`, …), discounts the lattice score so the
    particle-as-coda parse doesn't trump a same-buffer
    Car-as-`Cā` parse.
  - Corpus side: filter the `ra → ရ` particle entries' contribution
    to the unigram score (currently 934 — well above any
    legitimate consonant-onset reading). Likely won't pass the
    `LexiconLMDriftSuite` without retraining.
- Curated score floors on `သာ` are NOT a clean fix: bumping `သာ`
  high enough to win the lattice composite (`log(သာ) > log(သရ ·
  ရ)`-ish) would require score 5000+, which has cross-test side
  effects.

## Validation Report
- **Verdict:** FULLY_COVERED.
- **Acceptance criteria:** Engine-side `grammarCandidateIsBetter`
  carve-out (`preferredAaOverBareBaseSubstitution`) handles the broader
  `<C>ar'<X>` class — when two grammar candidates differ by exactly
  one aa-vowel-vs-bare-consonant substitution and the parser score
  agrees, the aa-vowel side wins directly. The bare-base sibling stays
  reachable.
- **Test coverage:** `TASK071ApostropheRaConsonantSuite` adds 7 cases:
  regression for `thar'mar`, 4 class probes (`thar'mar`, `kar'mar`,
  `nar'mar`, `phar'mar`), no-apostrophe baseline control, `thar`
  buffer-leading control, panel-reachability for legitimate `Cra`
  clusters (`kra`). All pass.
- **Regression check:** `DoubledMidBufferApostropheSuite`,
  `MidBufferPunctuationSuite`, `ReverseRomanizerSuite`,
  `SyllableParserSuite` all green. The new comparator branch is
  narrowly gated (single-scalar substitution, aa-vowel vs bare
  consonant base, base not followed by attachable mark, prev scalar
  is a consonant base), so it cannot trigger on broader sites.
- **Notes:** No tests removed or assertions weakened.

## Validation Notes
- **Validity verdict:** Valid. Reproduced via `swift run TestRunner`
  — `DoubledMidBufferApostrophe.singleApostrophe_topSurfaceUnchanged`
  fails with `thar'mar` -> `သရမာ` (101E 101B 1019 102C); expected
  `သာမာ`. The bug is narrowly scoped to apostrophe-mid-buffer + a
  re-segmentation that prefers `<C>+ra-consonant+<rest>` over
  `<C>+aa-vowel+<rest>`.
- **Confirmed romanization mappings:** In `Romanization.swift`,
  `r → ရ` (consonant, line 53) and `ar → ာ` (aa-vowel, line 226) are
  both valid arcs the lattice can pick. The failing case shows the
  lattice picking `tha+ra+mar` even though `thar+mar` is a legal
  2-syllable parse of the same buffer. The score profile cited in
  the task body (ra=934, thar=832, tha=873, mar=742) is plausible
  given log-frequency scaling.
- **Scope assessment:** Correctly scoped to the class `<C>ar'<X>`
  where the buffer offers both a 2-syllable `<C>aa + <X>` parse
  and a 3-syllable `<C> + ra + <X>` parse. The single-apostrophe-vs-
  double-apostrophe distinction is incidental — the apostrophe is
  what disrupts the lattice's lookup-side bonus that previously
  picked the 2-syllable parse. Acceptance criteria are framed in
  terms of the general pattern, which is appropriate.
- **Why other tests pass:** Sibling cases (`kar'par`,
  `mingalar'par`) survive because trigram LM has stronger bigrams
  for `ကာ ပါ` / `မင်္ဂလာ ပါ`. `သာ မာ` is rarer so the LM tilt does
  not save the lattice composite. This is a known fragile interaction
  exposed by the 2026-05-11 data rebuild and matches the test
  suite's documented purpose (single-apostrophe stability invariant).
- **Risk of curated-floor fix:** Even-handed; the task body already
  rejects a naive surface-score bump. Engine-side composite-score
  guard for high-frequency particle-class single-scalar surfaces
  (`ရ`, `င်`, `သ`) is the cleanest path and is consistent with how
  TASK-073/074 worked around `<unk>`-floor LM signals.
- **Open question (left unresolved for fixer):** Is there a
  systematic way to detect "this lattice's composite is driven by a
  particle-class single-scalar mid-syllable that wouldn't appear
  in real prose at this position"? A direct N-best probe before
  composite ranking might surface this without surface-specific
  curation.
