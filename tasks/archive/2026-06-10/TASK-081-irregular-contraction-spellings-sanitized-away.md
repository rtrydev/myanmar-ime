# TASK-081: Lexicon-attested irregular spellings (ယောက်ျား, ကျွန်ုပ်) are stripped by structural sanitizers even on exact-reading input

## Status
Completed

## Implementation Notes
- `Engine/SurfaceSanitizers.swift`: `sanitizeMalformedMyanmarMarks`
  gained a `preservedSurfaces: Set<String> = []` parameter (same
  pattern as `sanitizeAdjacentIndependentVowels`'s TASK-052 set).
  Preserved surfaces are exempt from dropping but do NOT count toward
  `hasClean`, so the all-illegal escape hatch is unchanged.
- `Engine/BurmeseEngine.swift` (`updateInternal`): new
  `attestedExactReadingSurfaces` set computed from the RAW store hits
  (`lexiconCandidates`) whose alias/compose reading matches the typed
  buffer (`exactAliasPrefixes` / `exactComposePrefixes`), plus history
  candidates whose recorded reading alias-matches `aliasPrefix`.
  Building from the raw hits (not `uniqueLexiconCandidates`) matters:
  for `kwyanote` the exact hit is absorbed into a *lattice-injected*
  grammar candidate (buffer length 8 reaches `latticeMinReadingLen`)
  and never appears in the post-absorption list. The set is passed to
  both `sanitizeMalformedMyanmarMarks` call sites (the main merge and
  the affix path).
- New suite `Suites/LexiconAttestedIrregularSpellingSuite.swift`:
  exact-alias reachability for `ယောက်ျား` / `ကျွန်ုပ်` (top-3),
  clean-sibling survival (`ကျွနုပ်` row stays reachable), bare-engine
  guard that the structural filter still applies without attestation,
  and a record-then-retype history-survival case using an isolated
  temp `SQLiteUserHistoryStore`.
- Full runner green (1658 cases / 9045 assertions);
  `BurmeseBench --check` reports no regressions.

## Problem Description
A small but high-frequency class of Burmese words is written with
lexicalized irregular orthography that violates the engine's structural
syllable model:

- `ယောက်ျား` ("man/husband") — ya-pin medial U+103B *after* the asat
  coda (`…1000 103A 103B 102C 1038`), the standard modern spelling.
- `ကျွန်ုပ်` ("I", formal) — vowel sign U+102F after the asat of `န်`
  (`…1014 103A 102F 1015 103A`), the standard contraction spelling.

These words exist in the shipped lexicon with penalty-0 alias rows
(`youtar:` → `ယောက်ျား`, `kwyanote` → `ကျွန်ုပ်`), but when the user
types the exact alias the surfaces are removed from the panel because
`scanOutputLegality` rejects them and `sanitizeMalformedMyanmarMarks`
filters them out whenever any "clean" sibling exists. The clean siblings
are wrong words (`ယောက်အား`, `ကျွနုပ်`), so the intended word is
unreachable at any rank — the user cannot type it at all.

The general issue: sanitizers treat the structural legality scan as
ground truth for *curated lexicon surfaces*, but Burmese has a closed
set of lexicalized contractions that are deliberately "illegal" under
the syllable grammar. Structural filters must not outvote the lexicon
when the user typed the entry's exact reading.

## Root Cause
`BurmeseEngine.update` merge pipeline
(`Engine/BurmeseEngine.swift:2100–2115`): every merged candidate,
including exact alias-index lexicon hits, passes through
`sanitizeMalformedMyanmarMarks` (`Engine/SurfaceSanitizers.swift:155`),
which drops all candidates failing
`SyllableParser.scanOutputLegality` once one passing sibling exists.
There is no exemption for surfaces that came from the curated lexicon
via an exact alias/compose match. Verified:

```
scanOutputLegality("ယောက်ျား") = false   // medial after asat
scanOutputLegality("ကျွန်ုပ်")  = false   // dep-vowel after asat
type "youtar:"   → [ယောက်အား, ရောက်အား, literal]  (ယောက်ျား absent)
type "kwyanote"  → [ကျွနုတ်, ကျွနုပ်, …]            (ကျွန်ုပ် absent)
```

The scan itself is correct as a *generative* filter (medials/vowels
after asat are parser bugs in any non-lexicalized context); the bug is
applying it as a *destructive* filter to attested store surfaces.

## Burmese Language Rule Reference
Burmese orthography contains lexicalized contractions that break the
canonical syllable template; the two canonical examples are
`ယောက်ျား` (ya-pin medial written after the asat coda) and
`ကျွန်ုပ်` (u-vowel sign written after the asat — a lexicalized
contraction). Both are the standard MLC dictionary spellings — a
correct IME must produce them verbatim. The historical-contraction
etymologies are incidental; what matters is that these are attested,
curated spellings that no structural syllable grammar will generate.

## Steps to Reproduce
1. Production-equivalent engine with bundled artifacts.
2. Type `youtar:` (exact digit-stripped alias of `ယောက်ျား`).
3. Type `kwyanote` (digit-stripped alias of `kwy2anote2` /
   `ကျွန်ုပ်`).
4. Inspect the full candidate list (page through).

## Current State
Both words are absent from the panel at every rank; only structurally
"clean" wrong words and the raw literal are offered. The store lookup
itself returns the correct surfaces (verified directly), so the loss is
entirely in the engine's sanitizer stage.

## Desired State
- An exact alias/compose lexicon hit (penalty ≤ 1) is exempt from
  legality-scan-based dropping: the curated surface is attested
  orthography by definition.
- The exemption is scoped to lexicon-/history-sourced candidates whose
  reading matches the user's buffer (exact alias or compose key), so
  parser-fabricated illegal surfaces keep being filtered.
- `ယောက်ျား` and `ကျွန်ုပ်` become reachable (top-3 strongly preferred
  on their exact aliases).

## Acceptance Criteria
- `youtar:` surfaces `ယောက်ျား`; `kwyanote` surfaces `ကျွန်ုပ်`.
- Parser-generated surfaces failing the scan are still dropped when
  clean siblings exist (existing sanitizer suites stay green, e.g.
  LiteralFallbackIllegalSurfaceSuite, MedialPositionInvariantSuite,
  AsatAfterDepVowelSuite).
- User history entries recorded for these surfaces survive re-typing.

## Notes
- Code: `Engine/SurfaceSanitizers.swift:155`
  (`sanitizeMalformedMyanmarMarks`), `Engine/BurmeseEngine.swift`
  merge/sanitize stage (~2100), `Parser/Finalization.swift:248`
  (`scanOutputLegality`).
- Related but different root cause from TASK-079: there the scan is
  wrong about a *regular* shape (`ော့်`) and should be fixed in the
  predicate; here the shapes are genuinely irregular and need a
  lexicon-attestation exemption rather than a predicate change. If
  TASK-079's fix lands first, re-verify this task's cases still fail
  before implementing.
- Other potentially affected entries: any future lexicon imports with
  Pali/Sanskrit ligature irregularities; the fix should be data-driven
  (source = lexicon + exact reading match), not a hardcoded surface
  list.
- Sharpening the "clean siblings are wrong words" point: `ကျွနုပ်` is
  itself a real lexicon row (alias `kwyanote`, penalty 0, rank_score
  417.1 vs `ကျွန်ုပ်`'s 667.6) — a corpus-frequency artifact of the
  asat-less misspelling. The sanitizer therefore keeps a *lower-scored
  lexicon-sourced misspelling* while dropping the higher-scored
  standard spelling of the same reading, which is the clearest
  demonstration that structural legality must not outvote curated
  lexicon data on exact-reading input.

## Validation Notes
- **Verdict: valid.** Reproduced at commit 795465c:
  `scanOutputLegality("ယောက်ျား") == false`,
  `scanOutputLegality("ကျွန်ုပ်") == false`; engine panels for
  `youtar:` = [`ယောက်အား`, `ရောက်အား`, literal] and `kwyanote` =
  [`ကျွနုတ်`, `ကျွနုပ်`, literal] — the intended words absent at every
  rank in both.
- Lexicon claims verified against the shipped store: `youtar:` →
  `ယောက်ျား` (679.7, penalty 0) and `kwyanote` → `ကျွန်ုပ်` (667.6,
  penalty 0) exist as alias rows; the sanitizer call site is
  `BurmeseEngine.swift:2102` (`merged =
  Self.sanitizeMalformedMyanmarMarks(merged)`), with a second site at
  line 2789 the fix should also consider.
- Scope: correctly scoped. The exemption-for-attested-surfaces design
  matches the repo's sanitizer policy ("filter only when at least one
  clean sibling survives" exists to protect users from parser bugs,
  not to censor curated entries) and correctly defers the *regular*
  `ော့်` shape to TASK-079's predicate fix. The two examples are the
  canonical members of the class, not narrow word-specific picks.
- Changed: tightened the linguistic reference (dropped the specific
  historical-contraction etymologies, which were asserted with more
  confidence than warranted and are not load-bearing) and added the
  verified `ကျွနုပ်`-is-also-a-lexicon-row fact, which strengthens the
  acceptance criteria's "exemption must be scoped to reading-matched
  attested surfaces" requirement: a fix that simply trusts any
  lexicon-sourced sibling would still rank the misspelling above
  nothing — both rows must survive, with the standard spelling
  reachable.
- Sequencing note kept as-is: if TASK-079 lands first, re-verify these
  two cases still fail (they should — neither shape involves the
  aw-family creaky-asat cluster).

## Validation Report (Step 4, 2026-06-10, HEAD 574e8ee)
- **Verdict: PARTIAL.**
- All written acceptance criteria pass:
  `LexiconAttestedIrregularSpellingSuite` (4 cases) verifies
  `youtar:` → `ယောက်ျား` and `kwyanote` → `ကျွန်ုပ်` in top 3,
  clean-sibling survival, bare-engine structural filtering, and the
  history round trip. Full runner green. The exemption is correctly
  data-driven (no hardcoded surface list) and the `hasClean` escape
  hatch is untouched.
- **Gap (new Burmese-incorrect behavior introduced elsewhere):** the
  shipped lexicon contains 238 distinct surfaces that fail
  `scanOutputLegality` (full-store scan). Only a subset are
  legitimate lexicalized irregulars (`ယောက်ျား` family, `ကျွန်ုပ်`
  family, `ရှ်`-coda loanwords, plus genuinely legal words the scan
  over-rejects such as `မြေဧက`, `တည်ဆဲဥပဒေ`). The rest are corpus
  encoding artifacts, and the unconditional exemption now resurfaces
  them on exact-reading input — four at **rank 0**, displacing the
  clean pre-pipeline rank 0 (verified by side-by-side probes at
  795465c vs HEAD):
  * `.ka` → `့က` (U+1037 with no base) rank 0; was `.က`.
  * `tang+` → `တင္` (dangling virama) rank 0; was `တံဂ`.
  * `vu.d+` → `ဗုဒ္` (dangling virama) rank 0; was `ဗုဒ`.
  * `myi.u:` → `မျိူး` (102D+1030 typo cluster) rank 0; was `မြိဦး`.
  * `aykya:` → `ေကြး` (e-vowel before base) rank 8; was absent.
  * `yayarkyar*:` → `ယောကျာ်း` rank 16; was absent.
- Fix direction for the gap: either (a) a narrow structural sub-class
  filter inside the exemption that still rejects encoding-invalid
  shapes (orphan leading combining mark, dangling U+1039 virama,
  U+1031 before any base consonant, 102D+1030 vowel collision) while
  keeping the lexicalized-irregular and over-rejected-legal classes,
  or (b) corpus_builder-side filtering of malformed surfaces plus
  regeneration (the durable rule: fix the pipeline, not the data).
  Option (a + b) together is the robust answer; (a) alone unblocks
  the engine regression without touching generated data.
- Test-coverage note: no suite pins any of the leakage readings, which
  is why the runner stayed green. A regression suite for the
  encoding-invalid class should accompany the follow-up fix.

## Gap Fix Notes (Step 5, 2026-06-10)
- Implemented option (a): a narrow encoding-validity sub-filter,
  `BurmeseEngine.isEncodingInvalidSurface`
  (`Engine/SurfaceSanitizers.swift`), flagging exactly the four hard
  Unicode-storage-order violation classes from the validation report:
  surface-initial dependent/combining mark, dangling U+1039 virama,
  U+1031 not preceded by a base/independent-vowel/medial, and the
  `102D 1030` typo cluster. Surfaces failing only the structural
  legality scan (the lexicalized-irregular class the exemption
  protects) are deliberately NOT flagged — the scan must never grow
  into a second grammar.
- Wired into every attested-surface path:
  * `exactReadingLexiconSurfaces` (BurmeseEngine.swift) filters
    encoding-invalid store hits at construction, so they are neither
    preserved through `sanitizeMalformedMyanmarMarks` nor re-injected
    by the TASK-083 reachability append;
  * the history half of `attestedExactReadingSurfaces` applies the
    same filter (a surface committed while a malformed row was
    reachable must not keep resurrecting it);
  * the TASK-080 truncated-reading exact-hit rescue and the TASK-078
    `injectWholeBufferPunctSplitEvidence` injector (both run after or
    outside the sanitizer stage) skip encoding-invalid hits.
- New suite `Suites/EncodingInvalidLexiconRowContainmentSuite.swift`:
  predicate unit coverage for the four broken shapes plus the
  must-not-flag set (`ယောက်ျား`, `ကျွန်ုပ်`, `ရှ်`, `ကို`, kinzi,
  `၎င်း`, …), production containment for all five leaked readings
  (`.ka`, `tang+`, `vu.d+`, `myi.u:`, `aykya:` — malformed surface
  absent at every rank, rank 0 encoding-clean; scalar sequences
  verified against the shipped store rows), top-3 reachability for
  the lexicalized irregulars (no over-filtering), and a
  history-containment round trip with a malformed recorded surface.
- `yayarkyar*:` → `ယောကျာ်း` (rank 16) is intentionally NOT flagged:
  the shifted-asat shape is a recognized variant rendering of
  `ယောက်ျား`, not a storage-order violation, and it sits deep in the
  panel tail — outside both the encoding-invalid class and the
  rank-0-displacement severity that motivated this fix.
- Durable follow-up (documented, not done here): corpus_builder-side
  filtering of encoding-invalid surfaces plus full regeneration of
  TSV + SQLite + LM (238 store surfaces fail the legality scan; the
  encoding-invalid subset should be dropped at build time). Per the
  repo rule, generated data was not hand-edited; the engine gate
  keeps the malformed residue out of the panel until the pipeline
  regeneration happens.
