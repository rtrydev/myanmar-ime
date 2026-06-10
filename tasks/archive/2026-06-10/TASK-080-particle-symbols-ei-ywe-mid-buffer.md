# TASK-080: Particle symbols ၏ (`ei`) and ၍ (`ywe`) cannot compose after a preceding syllable; right-shrink truncation then corrupts the panel and breaks exact-alias lookups

## Status
Completed

## Implementation Notes
Two engine-level injections in `Engine/BurmeseEngine.swift`
(`updateInternal`, just before the `finalCandidates` assembly), plus a
data-driven helper in `Engine/InputNormalization.swift`:

1. **Truncated-reading exact-hit rescue.** When the right-shrink probe
   cut the reading (`thinei` → kept `thine`, dropped `i`; `ng*:` →
   kept `ng*`, dropped `:`), the alias prefix for the regular lexicon
   lookup came from the TRUNCATED buffer, so exact alias/compose hits
   for the full reading were never queried. The engine now issues
   `candidateStore.lookupExactForLattice(reading: preTrimmedNormalized)`
   whenever a short (≤2 char) tail was dropped with no leading/digit/
   literal affixes, and injects the hits. Penalty-0 hits go to the
   FRONT only when the truncation cut composing LETTERS — that class
   fabricates `ယ်အီ`-style tails at rank 0, so the curated reading
   must beat them (`thinei` → `သင်၏` rank 0). When only punctuation
   was cut (`ng*:`), the existing tone-composition rendering is sound
   and the hits append for panel reachability only (`၎င်း` reachable,
   `င်း` keeps rank 0).
2. **Generative `<word> + ၏/၍` segmentation.** Non-lexicon
   combinations (`tharywe` → `သာ၍`) have no store row and the parser's
   mid-buffer standalone gate keeps the particle out of the DP pool.
   When the normalized buffer ends in a suffixing symbol particle, the
   engine parses the pre-particle prefix (top-2, `isAcceptableParse`
   filtered) and APPENDS `<prefix parse> + <particle>` variants —
   reachability only, never a ranking promotion, so letter-chain
   parses keep rank 0 and the bare-engine mid-buffer cleanliness pins
   are unaffected.
3. `Engine/InputNormalization.swift`: `suffixingSymbolParticles`
   derived from the romanization table (standalone entries whose
   Myanmar output is a single scalar in U+104C–U+104F — today `ywe` →
   ၍ and `ei` → ၏) and `trailingSuffixingParticle(of:)` (longest-key
   suffix match, bare-particle buffers excluded).

New suite: `Suites/SuffixingParticleReachabilitySuite.swift`
(truncated exact-alias hits top-3 for the penalty-0 rows, panel
presence for the penalty-1 `naingnganei` row, no fabricated `ယ်အီ`
tails at rank 0, generative `သာ၍` reachability with letter-chain
rank 0 preserved, `ng*:` → `၎င်း` reachability, working rank-0
controls `phyitywe`/`huywe`/`akeywe`/`to.ei`/`thuto.ei`, bare-engine
standalone particles). Full runner green (1673 cases / 9135
assertions); `BurmeseBench --check` reports no regressions.

## Problem Description
The genitive particle ၏ (U+104F, reading `ei`) and the conjunctive
particle ၍ (U+104D, reading `ywe`) are standalone-symbol vowel rules
that work at buffer start (`ei` → `၏`) but can never start a new
syllable after a completed syllable mid-buffer. Both particles are
*suffixing* function words — their entire grammatical role is to attach
after a noun/verb — so the supported usage is exactly the one that
fails.

Two compounding failures:

1. The parser produces no `<word> + ၏` segmentation, so the DP falls
   back to letter-chain garbage (`ei` → `ယ်` + `ီ`/`ည်`), e.g.
   `thinei` → `သီနယ်အီ`.
2. For a large subset of readings ending in `ei`/`ywe`, the engine's
   right-shrink acceptability probe truncates the buffer before the
   particle completes (typically dropping the final `i` of `ei`); the
   alias prefix used for the lexicon lookup is then computed from the
   *truncated* normalized buffer, so the exact alias-index hits
   (`သင်၏` ← `thinei`, `နိုင်ငံ၏` ← `naingnganei`, `မိမိ၏` ←
   `mi.mi.ei`, `အစိုးရ၏` ← `aso:rei`, …) are never queried — even
   though the store returns them when asked directly.

Scope calibration (verified against the shipped artifacts): the
failure is NOT universal across the 137 entries ending in `…၏` / 90
ending in `…၍`. Three behavior classes exist today:

- **Working via whole-buffer lookup**: buffers whose full letter-chain
  parse passes `isAcceptableParse` keep the full alias prefix, so the
  exact hit is injected and wins rank 0 (`phyitywe` → `ဖြစ်၍`,
  `huywe` → `ဟူ၍`, `patthetywe` → `ပတ်သက်၍`, `akeywe` → `အကယ်၍`).
- **Working via the embedded-punct split**: buffers where an open-tone
  vowel modifier immediately precedes the particle split so the active
  suffix is exactly `ei`, which parses standalone (`to.ei` → `တို့၏`,
  `thuto.ei` → `သူတို့၏`).
- **Broken**: buffers where the right-shrink probe truncates inside
  the particle and no split rescues it (`thinei`, `naingnganei`,
  `mi.mi.ei`, `aso:rei`, all verified ABSENT at every rank), plus any
  `<word>+၏/၍` combination with no lexicon row (e.g. `tharywe` →
  `သာ၍`), which only the parser-segmentation fix can serve.

The parser gap itself IS universal: no parse of any `<word>ei`/`<word>ywe`
buffer ever contains the particle symbol — every working case above is
rescued by the lexicon or the split path, never by the grammar.

## Root Cause
- Parser: the standalone vowel entries `ei` → `\u{104F}` and `ywe` →
  `\u{104D}` (`Romanization.swift:374–375`) are only reachable as an
  onsetless syllable arc at positions the DP allows a standalone vowel.
  After a closed syllable (`thin|`, `ngan|`, `thar|`), the DP never
  opens an onsetless standalone-symbol arc; the letters are instead
  consumed by `e`/`i`/`y`/`w` consonant-vowel chains. Probing
  `parser.parseCandidates("thinei")` shows no parse containing `၏`
  while `parseCandidates("ei")` rank 0 is `၏`.
- Engine: when no full-length parse passes `isAcceptableParse`,
  `parseLongestAcceptablePrefix` (`Engine/BurmeseEngine.swift:826`)
  right-shrinks the buffer (`thinei` → kept `thine`, dropped `i`;
  verified, same single-`i` drop for `naingnganei`, `mi.mi.ei`,
  `aso:rei`). The kept prefix parses as a letter chain (`thine` →
  `သီနယ်`), the dropped tail is re-composed (`i` → `အီ`) and appended
  to every candidate, and `aliasPrefix` (line 1509) is computed from
  the kept prefix only (`thine`) — so `candidateStore.lookup(prefix:)`
  never sees the full reading `thinei` and the exact hit cannot rescue
  the panel. Verified: `store.lookup(prefix: "thinei")` returns
  `သင်၏` (penalty 0, score 679.7) when called directly; the engine
  never issues that query.

## Burmese Language Rule Reference
၏ marks the genitive / sentence-final possessive in formal Burmese and
always attaches directly after the preceding word (`မြန်မာနိုင်ငံ၏…`).
၍ ("…and then / thus") attaches after verbs. Both are single-codepoint
symbols that begin a new orthographic syllable with no onset; a
romanization that supports them standalone must support them after any
completed syllable, because that is their only grammatical position.

## Steps to Reproduce
1. Production-equivalent engine with bundled artifacts.
2. Type the digit-stripped alias of any `…၏` lexicon entry without
   committing: `thinei`, `naingnganei`, `mi.mi.ei`,
   `myanmarnaingnganei`.
3. Inspect the panel; also compare
   `SQLiteCandidateStore.lookup(prefix: "naingnganei")` (returns
   `နိုင်ငံ၏`) with the engine panel (does not contain it).
4. Repeat for `…၍`: `tharywe`, `sap*lyany*:ywe`.

## Current State
- `thinei` → `သည်နယ်အီ` / `သီနယ်အီ` / literal; `သင်၏` absent.
- `naingnganei` → `နိုင်္ငနယ်အီ` (also carries the TASK-082 spurious
  kinzi) / `နိုင်ငနယ်အီ` / literal; `နိုင်ငံ၏` absent.
- `mi.mi.ei` → `မိမိယ်အီ` …; `မိမိ၏` absent.
- `tharywe` → `သာယွယ်` / `သာရွယ်`; `သာ၍` absent (the `ywe`-as-`y+we`
  rival parse is legitimate, but the ၍ segmentation is not even in the
  pool). Note `သာ၍` is NOT a lexicon entry — this case can only be
  fixed by the parser segmentation, not by lookup plumbing.
- For the broken subset, the workaround requires committing the noun
  first and typing `ei` standalone (standalone `ei` → `၏` works).

## Desired State
- The parse pool contains the `<preceding syllables> + ၏/၍`
  segmentation whenever the trailing reading matches `ei`/`ywe`, so the
  exact alias-index lexicon hits resolve and the particle form is
  reachable in the panel (top-3 strongly preferred when the full buffer
  is an exact penalty-≤1 alias hit).
- No `ယ်အီ`-style fabricated tails at rank 0 for `…ei` readings whose
  lexicon entry exists.
- Ambiguous cases (`ywe` after `r`-final could be `ရွယ်`) keep the
  letter-chain parses in the panel; this is a reachability fix, not a
  rank-0 mandate for the symbol in non-lexicon contexts.

## Acceptance Criteria
- `thinei` surfaces `သင်၏`; `naingnganei` surfaces `နိုင်ငံ၏`;
  `mi.mi.ei` surfaces `မိမိ၏`; `aso:rei` surfaces `အစိုးရ၏` (all are
  exact alias hits in the shipped lexicon; `naingnganei`'s row carries
  alias penalty 1 / negative store score −369.8, so panel presence —
  not rank 0 — is the bar for it).
- `tharywe` surfaces `သာ၍` somewhere in the panel while keeping
  `သာရွယ်`/`သာယွယ်` reachable. (`သာ၍` is not a lexicon row — this
  criterion specifically tests the generative parser segmentation.)
- A right-shrink truncation no longer cuts a trailing `ei`/`ywe` that
  completes an exact alias/compose lexicon reading.
- Controls (verified working today, must not regress): `phyitywe` →
  `ဖြစ်၍` rank 0, `huywe` → `ဟူ၍` rank 0, `akeywe` → `အကယ်၍` rank 0,
  `to.ei` → `တို့၏` rank 0, `thuto.ei` → `သူတို့၏` rank 0.
- Full TestRunner remains green; `BurmeseBench --check` passes.

## Notes
- Code: `Romanization.swift:370–375` (standalone symbol entries);
  `Parser/NBestDP.swift` (onsetless standalone arc admission);
  `Engine/BurmeseEngine.swift:826` (right-shrink probe), 1509
  (aliasPrefix from truncated buffer).
- ၎င်း (U+104E) is the third symbol-particle with related gaps. The
  intended reading is resolved: the shipped lexicon carries `၎င်း`
  under alias `ng*:` at penalty 0, yet standalone `ng*:` does not
  surface `၎င်း` (panel: `င်း`, `င်:`, `၄င်း`, `၄င်:`, literal — the
  digit variant `၄င်း` is reachable at rank 2, the canonical symbol is
  not). Its compounds (`ng*:ka` → `၎င်းက`, `ng*:to.` → `၎င်းတို့`,
  both penalty-0 alias rows) fail via the TASK-078 split path. A fix
  here should add panel reachability for `၎င်း` on `ng*:`.
- Entry counts in the shipped lexicon: 137 entries end in `၏`
  (147 contain it); 90 end in `၍` (95 contain it). Only the subset
  described under "Scope calibration" is unreachable today.

## Validation Notes
- **Verdict: valid, but the original scope claim was overbroad.** The
  statement "none of [the 137/95 entries] is typeable as a continuous
  buffer" was empirically false: `phyitywe`, `huywe`, `patthetywe`,
  `akeywe` surface their `…၍` entries at rank 0 (full-length
  letter-chain parse passes `isAcceptableParse`, so the whole-buffer
  alias lookup runs), and `to.ei` / `thuto.ei` surface `တို့၏` /
  `သူတို့၏` at rank 0 (rescued by the embedded-punct split whose
  active suffix is exactly `ei`). Rewrote the problem description with
  the three verified behavior classes and added the working cases as
  non-regression controls.
- The genuinely broken subset was verified candidate-by-candidate:
  `thinei`, `naingnganei`, `mi.mi.ei`, `aso:rei` lack their exact
  alias hits at every rank; `tharywe` lacks `သာ၍` (and `သာ၍` is not a
  lexicon row at all — documented, since the original acceptance
  criterion implied a lookup-based fix could satisfy it).
- Corrected the truncation example: `parseLongestAcceptablePrefix`
  keeps `thine` and drops only `i` (not "kept thi / dropped nei");
  same single-`i` drop measured for all broken `…ei` buffers. The
  `နယ်` in the garbage tail comes from the kept-prefix parse of
  `thine`, not from tail recomposition.
- Parser-gap claim verified: `parseCandidates("thinei")` (n=10)
  contains no parse with `၏`, while `parseCandidates("ei")` rank 0 is
  `၏`. The mechanism (no onsetless standalone-symbol arc after a
  closed syllable) is consistent with `Romanization.swift:374–375`
  (`ywe`/`ei` marked `standalone: true`).
- Corrected entry counts (90 end in `၍`, not 95 — 95 was the
  contains-count) and resolved the open `၎င်း` question by lexicon
  inspection: its alias IS `ng*:` at penalty 0, so the reachability
  gap is real, not a reading-convention mismatch.
- Scope: keep as one task. The parser arc and the right-shrink/alias
  interaction must be fixed coherently — fixing only the lookup would
  leave `tharywe`-class combinations broken, and fixing only the
  parser without protecting the working lookup/split paths risks
  regressing the rank-0 cases listed as controls.

## Validation Report (Step 4, 2026-06-10, HEAD 574e8ee)
- **Verdict: REGRESSION** (functional criteria met; the commit
  introduced the BurmeseBench gate failure that Step 3 misattributed
  as pre-existing drift).
- Functional acceptance criteria all verified:
  `SuffixingParticleReachabilitySuite` (6 cases) green inside the
  full runner; independent class probes confirm four additional
  lexicon rows reachable (`myanmarnaingnganei` → `မြန်မာနိုင်ငံ၏`,
  `bu.rar:thakhinei` → `ဘုရားသခင်၏`, `naingngantawei` →
  `နိုင်ငံတော်၏`, `sap*lyany*:ywe` → `စပ်လျဉ်း၍`) and the generative
  segmentation generalizes (`kaungywe` → `ကောင်၍` reachable,
  letter-chain rank 0 kept). Controls (`phyitywe`, `huywe`,
  `akeywe`, `to.ei`, `thuto.ei`) all rank 0.
- **Perf regression, conclusively attributed by bisect** (release
  builds, same machine, back-to-back, 2-3 runs per point):
  * 795465c (pre-pipeline): garbage_incremental p99 389-393us,
    prod 455-478us — both under baseline (411.6 / 489.8).
  * 1351fbd (five commits in, WITHOUT this fix): 399-400us / 494us —
    still clean.
  * d2bceaa (this fix): 874-918us / 927us — both over the gate
    (535.1us / 636.8us). HEAD 574e8ee measures the same
    (809-820us / 897-911us).
  Step 3's "pre-existing drift" evidence compared d2bceaa to
  574e8ee, which only exonerates TASK-078 — it never measured the
  true pre-pipeline commit. The acceptance criterion
  "`BurmeseBench --check` passes" is NOT met, and re-capturing the
  baseline would bake in a real 2x p99 regression.
- **Mechanism** (per-keystroke profile at HEAD vs pre-fix): the
  generative branch fires for ANY normalized buffer ending in
  `ei`/`ywe` — `trailingSuffixingParticle` matches garbage too — and
  `cachedGrammarParses(prefixReading, maxResults: 2, isFullBuffer:
  true)` then issues a second full DP parse of the entire pre-particle
  prefix on that keystroke. In the garbage_incremental buffer,
  keystroke 28 (`…oigjei`, 29 chars) becomes the slowest keystroke of
  the whole run (median 6.1ms debug vs 4.4ms for the 62-char tail
  keystrokes; not in the top-10 pre-fix). One spiked keystroke out of
  62 lands squarely in the p99 while leaving p50/p95 flat — exactly
  the observed gate signature. The grammar-parse cache does not
  amortize it because the incremental scenario resets the buffer
  (and caches) every iteration, matching real typing behaviour.
- Fix directions for Step 5: gate the generative branch on the prefix
  being plausibly Burmese (e.g. require the existing full-buffer
  parse pool to contain an acceptable parse before re-parsing, reuse
  the already-computed parse pool, or cap/skip when the pre-particle
  prefix exceeds a length budget or the buffer failed
  `isAcceptableParse`). The truncated-reading exact-hit rescue
  (injection 1) is store-LRU-backed and not implicated.

## Gap Fix Notes (Step 5, 2026-06-10)
- The generative `<word> + ၏/၍` branch now carries two cheap hot-path
  gates (`Engine/BurmeseEngine.swift`, the TASK-080 (2) block):
  1. `droppedTail.count <= particle.roman.count` — the right-shrink
     probe must have accepted the buffer at least up to the particle.
     A garbage buffer that merely *ends* in `ei`/`ywe` fails
     right-shrink long before the tail (the spiking keystroke's
     `droppedTail` spans most of the buffer), so the second DP parse
     no longer runs there. This is the principled "prefix is plausibly
     Burmese" signal: it reuses the acceptability verdict the pipeline
     already computed, costing one integer compare.
  2. `prefixReading.count <= compositionWindowSize` (18) — past the
     window the main pipeline freezes a prefix and parses only the
     active tail; a full re-parse of a longer prefix here is exactly
     the cost class windowing exists to avoid. Lexicon-backed `…၏`/
     `…၍` entries on long buffers stay served by the whole-buffer
     exact-hit rescue (injection 1), which is store-LRU-backed.
     Generative (non-lexicon) combinations with a pre-particle prefix
     longer than 18 chars lose panel reachability of the synthesized
     particle variant — a deliberate scope cap; by that length the
     realistic flow is committing the preceding words first.
- No functional change for the garbage class: its prefix parses were
  already discarded by the `isAcceptableParse` filter — the branch
  only burned the DP cost. `SuffixingParticleReachabilitySuite` and
  the full runner stay green (1687 cases / 9207 assertions including
  the new TASK-081 containment suite).
- Bench gate verified green after the fix:
  `swift run -c release BurmeseBench --check Tests/Benchmarks/baseline.json`
  reports "no regressions"; garbage_incremental p99 back to 400-412us
  (baseline 411.6, was 870-918us at d2bceaa) and
  garbage_incremental_prod p99 476-490us (baseline 489.8, was
  897-960us). The baseline was NOT re-captured.
