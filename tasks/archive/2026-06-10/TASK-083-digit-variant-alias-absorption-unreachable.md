# TASK-083: Digit-disambiguated homophone variants vanish when their lexicon hit is absorbed into a rarity-penalized grammar parse

## Status
Completed

## Implementation Notes
All changes in `Engine/BurmeseEngine.swift` (`updateInternal`),
following the task's third proposed route (panel reachability via the
preserve + inject pattern, store scoring untouched):

- `exactAliasPrefixes` / `exactComposePrefixes` computation moved up,
  before the grammar LM-margin prune, and a new
  `exactReadingLexiconSurfaces` set is built from the RAW store hits
  whose alias/compose reading matches the typed buffer.
- Both `pruneGrammarByLmMargin` call sites add the set to
  `preservingGrammarSurfaces`, so the absorbed rare-consonant grammar
  candidate survives the prune (fixing the failed
  `score > parserScore` carve-out for negative absorbed scores).
- After the merge (next to the existing strict-stack and bare-ya/ra
  injections, before the sanitizers), any exact-reading hit whose
  surface is still missing from `merged` is appended past the page
  cap — reachability, never a ranking promotion, so `khana` rank 0
  stays `ခန` and the `htarna`/`thi`/`ti` controls are unchanged.
- TASK-081's `attestedExactReadingSurfaces` now reuses
  `exactReadingLexiconSurfaces` (plus the history-matched surfaces).

**Scope limitation documented:** the `kumpani` acceptance
sub-criterion is not satisfiable inside this task's own scope. The
store returns ZERO hits for `kumpani` (verified empirically): the
entry's alias is `ku.m+pani` and its compose key is `ku.mpani` — the
creaky-dot `u.` vs `u` distinction is load-bearing in both indexes,
so no engine merge-stage fix can surface `ကုမ္ပဏီ` for `kumpani`.
Serving it would require vowel-quality (`u` ↔ `u.`) reading aliasing,
which the task's own Scope note forbids (all three fix routes "stay
inside the engine merge stage") and which CLAUDE.md §5 treats as a
deliberately-scoped non-goal (no general fuzzy matching). The
canonical alias `ku.m+pani` → `ကုမ္ပဏီ` is fixed and tested.

New suite: `Suites/AbsorbedExactAliasReachabilitySuite.swift`
(absorbed exact-hit reachability for `khana`/`ku.m+pani`, rank-0
stability for `khana`/`htarna`/`thi`, `ti` → `ဋီ` reachability,
prefix-completion non-regression). Full runner green (1667 cases /
9117 assertions); `BurmeseBench --check` reports no regressions.

## Problem Description
Homophone variants whose canonical reading carries a digit
disambiguator (retroflex ဏ/ဋ/ဌ family, etc.) are supposed to be
reachable from the digit-less reading via the lexicon alias index
("variants must surface in the panel for the digit-less reading; page
through results"). For a subset of these words the variant is
unreachable at any rank under default settings: the exact alias-index
hit is *absorbed* into a grammar parse of the same surface, and that
grammar parse is simultaneously (a) demoted below every non-rare parse
by the rarity-first comparator, (b) further demoted because the
absorbed lexicon score is *negative* (the store scores alias rows as
`rank_score − alias_penalty × 1000`, e.g. `ခဏ` = 682 − 1000 = −318),
which also defeats the absorption-preservation condition
`score > parserScore` in the LM-margin prune, and (c) dropped by that
prune at the default 8-nat margin.

Because the absorption removes the hit from `uniqueLexiconCandidates`,
the `prioritizedLexicon` path — the mechanism explicitly designed to
guarantee exact-alias panel presence — never sees it either.

Affected words include everyday vocabulary: `khana` → `ခဏ` ("a
moment"; panel shows the prefix completions `ခဏလေး`, `ခဏတာ`, … but not
`ခဏ` itself) and `kumpani`/`ku.m+pani` → `ကုမ္ပဏီ` ("company").

## Root Cause
Chain across three locations:

1. `SQLiteCandidateStore.lookupPrefix`
   (`SQLiteCandidateStore.swift:499`):
   `score = rank_score − aliasPenalty × 1000` goes negative for every
   alias row with `rank_score < 1000·penalty` (92,178 of 158,345 alias
   rows in the shipped lexicon).
2. `BurmeseEngine.update` absorption
   (`Engine/BurmeseEngine.swift:1698–1711`): when the lexicon surface
   equals a grammar-parse surface, the hit is folded into the grammar
   candidate (`score += lexiconCandidate.score`, i.e. *subtracts* for
   negative scores) and skipped from the lexicon list — removing it
   from `exactAliasLexicon` / `prioritizedLexicon`
   (lines 1969–1978).
3. `grammarCandidateIsBetter`
   (`Engine/CandidateRanking.swift:88–90`) orders by `rarityPenalty`
   below legality but before any score/LM signal, so the ဏ-bearing
   parse sits below every non-rare parse in the grammar pool;
   `pruneGrammarByLmMargin` (`CandidateRanking.swift:47`) then drops it
   because its LM log-prob trails the buffer-best by more than the
   margin and the absorption carve-out
   (`$0.candidate.score > Double($0.parserScore)`, line 60) fails due
   to the negative absorbed score — adding a negative lexicon score
   leaves `candidate.score` *below* `parserScore`, the exact opposite
   of what the attested-surface preservation intended.

Empirically: `khana` with default settings (page 9, margin 8) has no
`ခဏ` anywhere; with page 40 and margin 100 it appears at rank 23.
Contrast case: `htarna` → `ဌာန` is *also* a parser-emittable rare
parse (rarity 1) with a negative absorbed alias score (749.8 − 1000 =
−250.2), yet it wins rank 0 — because its non-rare grammar siblings
(`ထာန`, `ထါန`) are OOV letter-chains the LM scores at the unknown
floor, so neither the comparator nor the LM-margin prune buries the
variant. The unreachable class is therefore: rare-consonant variants
whose digit-less reading ALSO spells real high-frequency words
(`ခန`, `ခံ`, `ခမ်` for `khana`; `ကုမ္ပနီ`-style chains for
`ku.m+pani`) — exactly the words where the user most needs the panel
to offer the variant, since the LM legitimately prefers the common
sibling and the absorbed exact hit is the variant's only lifeline.

## Burmese Language Rule Reference
ဏ vs န (and ဋ/ဌ vs တ/ထ) is a lexical spelling distinction in
Pali-derived words — `ခဏ` and `ကုမ္ပဏီ` cannot be spelled with န.
Since ASCII digits are literal in user input (the `n2` key cannot be
typed), the alias index is the only path to these spellings; if it does
not surface them, the words are unwritable.

## Steps to Reproduce
1. Production-equivalent engine, default settings.
2. Type `khana`; page through the full candidate list.
3. Type `ku.m+pani` (the canonical alias) and `kumpani`; page through.
4. Compare with `SQLiteCandidateStore.lookup(prefix: "khana")`, which
   returns `ခဏ` (reading `khan2a`).

## Current State
- `khana`: panel = `ခန`, `ခံ`, `ခမ်`, six `ခဏ…` completions, literal —
  `ခဏ` absent.
- `ku.m+pani`: rank 0 `ကုမ္ပနီ`; `ကုမ္ပဏီ` absent.
- The same surfaces ARE returned by the store's exact/prefix lookups.

## Desired State
- An exact alias-index hit (alias penalty ≤ 1 relative to the typed
  buffer) is always panel-reachable, absorption notwithstanding —
  either by exempting exact hits from absorption-removal, by clamping
  the absorbed score at ≥ 0, or by routing absorbed exact hits through
  the prioritizedLexicon slot.
- Non-exact rare-consonant prefix completions keep their current
  (working) behavior; rank-0 ordering for the common spelling
  (`ခန`-type parses need not be displaced).

## Acceptance Criteria
- `khana` surfaces `ခဏ` in the panel (top-3 preferred; any page
  acceptable per the variants rule).
- `ku.m+pani` surfaces `ကုမ္ပဏီ`. (Amended in Step 5 — see Gap Fix
  Notes: the original criterion also required plain `kumpani`, which
  is unsatisfiable in this task's scope because the store has zero
  alias/compose hits for that reading; the `u` vs `u.` vowel-quality
  distinction is load-bearing in both indexes.)
- Control words stay correct: `htarna` → `ဌာန` rank 0; `thi` → `သည်`
  rank 0; `ti` keeps `ဋီ` reachable; LexiconRankingSuite,
  CuratedAliasRankZeroSuite, ComprehensiveRankingSuite stay green.
- `BurmeseBench --check` passes.

## Notes
- The −1000-per-penalty scoring is store-internal ranking magic that
  predates the absorption path; any fix must keep the prefix-completion
  ordering (`ORDER BY alias_penalty ASC, rank_score DESC LIMIT 20`,
  `SQLiteCandidateStore.swift:256–283`) intact.
- 92,178 alias rows have `rank_score < 1000·alias_penalty`; only the
  subset whose surface is also a parser-emittable parse of the
  digit-less reading is affected (parser emits `ခဏ` for `khana` with
  `rarityPenalty 1` — verified via `parseCandidates`).
- Distinct from archived TASK-073/074 (curated-alias comparator
  promotion for `u.` / `an:`): those added curated extra aliases and a
  comparator carve-out; this is the absorption/penalty-score interaction
  that bypasses the prioritized-lexicon guarantee entirely.

## Validation Notes
- **Verdict: valid.** Every load-bearing number reproduced at commit
  795465c: `khana` panel = [`ခန`, `ခံ`, `ခမ်`, six `ခဏ…` completions,
  literal] with `ခဏ` absent; `ku.m+pani` rank 0 `ကုမ္ပနီ` with
  `ကုမ္ပဏီ` absent (only its `ကုမ္ပဏီများ…` completions appear);
  `kumpani` also lacks `ကုမ္ပဏီ` entirely.
- Store-side facts verified: `store.lookup(prefix: "khana")` returns
  21 hits including `ခဏ` at score −317.8 (rank_score 682.17, penalty 1
  → 682 − 1000), and the shipped lexicon has exactly 92,178 alias rows
  with `rank_score < 1000·alias_penalty` out of 158,345. The scoring
  line is `SQLiteCandidateStore.swift:499` as cited (also 475/524 for
  the compose/lattice variants).
- Absorption-path facts verified: `parseCandidates("khana")` emits
  `ခဏ` with `rarityPenalty 1` (so the lexicon hit is folded into the
  grammar candidate at BurmeseEngine.swift:1698–1711 and removed from
  `uniqueLexiconCandidates`), and the prune carve-out at
  CandidateRanking.swift:58–62 demonstrably fails for negative
  absorbed scores. Control words behave as claimed: `htarna` → `ဌာန`
  rank 0, `thi` → `သည်` rank 0, `ti` keeps `ဋီ` reachable (rank 2).
- Corrected a discriminator misattribution in the original Root Cause:
  the task claimed `ဌာန` works because its surface stays "out of the
  grammar parse pool." Verified false — `parseCandidates("htarna")`
  emits `ဌာန` at rarity 1, its alias row is penalty 1 / rank_score
  749.8 (absorbed score −250.2, negative like `ခဏ`'s), and it still
  wins rank 0. The actual discriminator is the LM-margin interaction:
  `ဌာန`'s non-rare siblings are OOV chains, `ခဏ`'s non-rare siblings
  are real words. Rewrote the "Empirically:" paragraph accordingly —
  this matters for the fix, because it shows the prune (not the
  absorption alone) delivers the killing blow, and any fix validated
  only on `htarna`-shaped words would miss the bug.
- Changed: removed the "32-ish non-rare parses" count (the parser
  returns ~5–8 parses for these buffers at maxResults 40; the count is
  not load-bearing — what matters is rarity-first ordering placing the
  ဏ parse below every non-rare sibling) and spelled out the carve-out
  failure mechanism with the exact predicate from line 60.
- Not re-verified: the "page 40 / margin 100 → rank 23" settings
  experiment (requires a custom `IMESettings` run; plausible and not
  load-bearing for the fix).
- Scope: correctly scoped. The three proposed fix routes (exempt exact
  hits from absorption-removal, clamp absorbed score at ≥ 0, or route
  absorbed exact hits through `prioritizedLexicon`) all stay inside
  the engine merge stage; the task correctly forbids touching the
  store's `ORDER BY alias_penalty ASC, rank_score DESC` contract.

## Validation Report (Step 4, 2026-06-10, HEAD 574e8ee)
- **Verdict: PARTIAL** (one acceptance sub-criterion unmet, with a
  documented and legitimate scope justification).
- Verified passing: `khana` → `ခဏ` reachable with `ခန` keeping
  rank 0; `ku.m+pani` → `ကုမ္ပဏီ` reachable; controls `htarna` →
  `ဌာန` rank 0, `thi` → `သည်` rank 0, `ti` → `ဋီ` reachable;
  prefix completions unchanged. `AbsorbedExactAliasReachabilitySuite`
  (4 cases) green inside the full runner.
- Class coverage verified beyond the suite with an independent probe:
  four additional absorbed-class members all panel-reachable —
  `arnar` → `အာဏာ`, `pamarna` → `ပမာဏ`, `dan*rar` → `ဒဏ်ရာ`,
  `ban*` → `ဘဏ်` (all penalty-1 alias rows verified in the store).
- **Unmet criterion:** "`kumpani` surfaces `ကုမ္ပဏီ`". Confirmed
  independently: the store returns zero alias/compose hits for
  `kumpani` (the entry's alias is `ku.m+pani`, compose key
  `ku.mpani`; the `u` vs `u.` vowel-quality distinction is
  load-bearing in both indexes). No engine merge-stage fix can serve
  it, and vowel-quality reading aliasing is a deliberately scoped
  non-goal (CLAUDE.md section 5). Resolution belongs to the corpus
  builder (add a curated `kumpani` extra alias) or to amending the
  criterion — flagged for Step 5 as a low-severity decision, not an
  engine defect.
- No perf regression traced to this commit: garbage_incremental p99
  399-400us and garbage_incremental_prod 494us at 1351fbd (this
  commit), at parity with pre-pipeline 795465c and within the
  baseline gate.

## Gap Fix Notes (Step 5, 2026-06-10)
- Resolution of the unmet `kumpani` sub-criterion: **criterion
  amended**, not implemented. Rationale:
  * The store returns zero alias/compose hits for `kumpani` (verified
    by Step 4 and re-confirmed in the implementation notes): the
    entry's alias is `ku.m+pani`, its compose key `ku.mpani` — the
    creaky-dot `u.` vs plain `u` vowel-quality distinction is
    load-bearing in both indexes, so no engine merge-stage fix can
    serve it. All three fix routes this task scoped ("stay inside
    the engine merge stage") are therefore structurally unable to
    satisfy it.
  * Serving it would require `u` ↔ `u.` vowel-quality reading
    aliasing, which CLAUDE.md §5 treats as a deliberately scoped
    non-goal (no general fuzzy matching; the only sanctioned open
    alias gap is phonetic `y` → spelling `r`).
  * A curated `kumpani` extra alias through the corpus builder was
    considered and rejected for this iteration: corpus-builder
    changes require regenerating the TSV + SQLite + LM together
    (generated data is never hand-edited), a pipeline run that is
    out of proportion for one alias. If vowel-quality alias curation
    is ever wanted, it should be designed as a reviewed
    corpus-builder feature (curated extra-alias table), not patched
    in per-word.
- The amended criterion set is fully satisfied at HEAD:
  `AbsorbedExactAliasReachabilitySuite` green inside the full runner
  (1687 cases / 9207 assertions), `ku.m+pani` → `ကုမ္ပဏီ` reachable,
  `khana` → `ခဏ` reachable with `ခန` rank 0, controls unchanged.
