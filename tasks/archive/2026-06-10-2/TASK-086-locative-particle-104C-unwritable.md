# TASK-086: Locative particle ၌ (U+104C) has no romanization at all — unwritable, silently dropped by the reverse romanizer, and its lexicon entries are mis-indexed under particle-less readings

## Status
Completed

## Problem Description
Of the four Myanmar symbol-particles U+104C–U+104F, three are covered:
၍ (`ywe`), ၏ (`ei`) are standalone vowel-table entries, and ၎င်း is
reachable via its lexicon alias `ng*:`. The fourth, ၌ (U+104C,
locative "at/in", standard formal Burmese), has no roman key anywhere
in the romanization table, no parser rule, and no lexicon alias —
there is no way to produce it from the keyboard at all, standalone or
suffixed.

Worse, `ReverseRomanizer.romanize` silently drops the scalar: 
`romanize("၌") == ""`. As a consequence the 21 lexicon entries whose
surface contains ၌ are indexed under readings that do not represent
the particle: `ရာ၌` under `rar`, `တို့၌` under `to.`, `အတွင်း၌` under
`atwin:`, `ပေါ်၌` under `paw`, etc. Typing those common readings
offers the ၌-bearing surface as if it were a homophone of the bare
word, the candidate's displayed reading does not match its surface,
and committing one records user history under the particle-less key.
The harm is not theoretical ranking noise: verified against the
shipped artifacts, `to.` serves the mis-indexed `တို့၌` at **rank 0,
above the bare `တို့` the user actually typed**.

## Root Cause
- `Romanization.swift` standalone symbol entries cover only `ywe` →
  U+104D and `ei` → U+104F (lines ~370–375). U+104C has no entry, so
  neither the forward parser nor the TASK-080 generative
  `<word> + particle` branch (which derives `suffixingSymbolParticles`
  from "standalone entries whose Myanmar output is a single scalar in
  U+104C–U+104F", `Engine/InputNormalization.swift:20–27`) can ever
  produce it.
- `ReverseRomanizer.romanize` has no mapping for U+104C and emits
  nothing for it (verified: `ရာ၌` → `rar`), so the corpus pipeline
  indexes every ၌-bearing entry under the truncated reading. The same
  silent-drop is what produced the 21 mis-indexed rows in the shipped
  store.

## Burmese Language Rule Reference
၌ (နှိုက်, locative case marker, read "hnai'") is a standard formal
Burmese particle that attaches directly after a noun (`မြို့၌`,
`အတွင်း၌`, `ရာ၌`), exactly parallel to ၏ (genitive) and ၍
(conjunctive) which the engine already supports. An IME that supports
the U+104A–U+104F punctuation/symbol block for output must provide an
input path for it; a reverse romanizer must never silently delete a
scalar from the reading (that breaks the reading↔surface contract the
alias index relies on).

## Steps to Reproduce
1. `ReverseRomanizer.romanize("၌")` → returns the empty string;
   `romanize("ရာ၌")` → `rar`.
2. Search `Romanization.vowels` / `consonants` for a key producing
   U+104C — none exists.
3. Production-equivalent engine: there is no buffer whose panel
   contains `၌` (standalone or after a syllable) other than via the
   mis-indexed homophone rows described above.
4. Type `to.` and observe `တို့၌` offered with reading `to.`.

## Current State
- ၌ cannot be typed at all.
- 21 store entries containing ၌ are indexed under particle-less
  readings and surface as pseudo-homophones of the bare word.

## Desired State
- A roman key for ၌ exists, registered as a standalone vowel-table
  entry so the existing TASK-080 suffixing-particle machinery picks
  it up automatically (standalone typing + `<word>၌` composition +
  the truncated-reading rescue). Note the table entry alone also
  fixes the reverse direction: `ReverseRomanizer.vowelPatterns` is
  built from `Romanization.vowels` unfiltered
  (ReverseRomanizer.swift:416–429) — that is exactly how `ei`/`ywe`
  reverse-map today — so one table edit covers forward parse,
  suffix composition, and reverse romanization.
- Key choice must confront the homophone reality (see Notes): ၌ is
  read identically to the verb နှိုက်, whose canonical reading
  `hnite` is already a penalty-0 store row. Either (a) use `hnite`
  and accept that the verb and the particle are competing homophone
  candidates under one key, or (b) pick a collision-free dedicated
  key. Option (a) matches how the engine treats all other homophone
  sets and is the recommended default.
- Regenerated lexicon data indexes `ရာ၌`-class entries under their
  full readings (requires the U+104C reverse mapping plus a data
  pipeline rerun).
- Until the data pipeline is regenerated, the engine-side key must at
  minimum make ၌ producible standalone and after a completed
  syllable (parallel to `ei`/`ywe` behavior pinned by
  SuffixingParticleReachabilitySuite).

## Acceptance Criteria
- Typing the chosen key standalone surfaces `၌` in the panel, top-3
  strongly preferred. Rank 0 is required only if a collision-free
  key is chosen; with `hnite` the existing verb `နှိုက်` (canonical
  penalty-0 store row, rank-0 today) is a legitimate competitor and
  must itself stay reachable.
- Typing `<word reading><key>` (e.g. the reading of `အတွင်း` + key)
  surfaces `<word>၌` in the panel, mirroring the TASK-080 acceptance
  shape for `၏`/`၍`.
- `romanize` round-trips: `romanize("၌")` returns the new key (not
  "") and `romanize("ရာ၌")` contains it. (Scoped to U+104C: bare ၎
  U+104E also romanizes to "" today, but standalone ၎ does not occur
  in running text outside `၎င်း`, which round-trips as `ng*:` — the
  U+104E gap is documented here as out of scope, not silently
  endorsed.)
- `LexiconLMDriftSuite` is updated/regenerated coherently if the data
  pipeline is rerun; if data is not regenerated in this task, the
  mis-indexed rows keep their current behavior (documented, not
  worsened).
- Existing particle suites stay green: SuffixingParticleReachability-
  Suite, plus the `to.ei`/`phyitywe` composition controls (these live
  in SuffixingParticleReachabilitySuite and
  EmbeddedToneSplitLexiconFidelitySuite).

## Notes
- Code: `Sources/BurmeseIMECore/Romanization.swift` (~370–375,
  standalone symbols); `Sources/BurmeseIMECore/ReverseRomanizer.swift`
  (no U+104C branch); `Engine/InputNormalization.swift:20–27`
  (`suffixingSymbolParticles` derivation — picks up new table entries
  automatically).
- Key-choice caution (CORRECTED during validation): `hnite` DOES
  collide — it is the canonical reading of the verb `နှိုက်`
  (penalty-0 row in `reading_alias_index`; today `hnite` yields
  `နှိုက်` at rank 0 with store-backed completions). This is
  unavoidable for any phonetic key: the particle ၌ is named/read
  နှိုက် (hnai'), i.e. it is a true homophone of that verb. The
  collision is therefore a homophone-panel situation (durable rule
  §7), not a blocker — parallel to how `၎င်း` shares `ng*:` with its
  homophones. The standalone-symbol table (which the DP gates by
  position) remains the right place rather than a consonant entry,
  so `hn…` onsets are not shadowed mid-syllable.
- Distinct from archived TASK-080: that task fixed composition and
  truncation for particles that already had roman keys (`ei`, `ywe`)
  and added reachability for `၎င်း` via its existing `ng*:` alias.
  ၌ has no key at all — a coverage gap, not a composition bug. The
  TASK-080 machinery is the natural delivery vehicle for the fix.
- The 21 mis-indexed rows are NOT encoding-broken (they are clean
  surfaces with wrong readings), so the TASK-081 encoding-validity
  containment correctly does not touch them.

## Validation Notes

**Verdict: Valid — all factual claims verified; revised for one
factual error and two acceptance-criteria problems (2026-06-10).**

- Verified empirically: `ReverseRomanizer.romanize("၌")` → `""`,
  `romanize("ရာ၌")` → `rar`, `romanize("တို့၌")` → `to.`;
  `romanize("၏")` → `ei`, `romanize("၍")` → `ywe`,
  `romanize("၎င်း")` → `ng*:` (controls work as described). 21 store
  entries contain ၌, indexed under particle-less readings exactly as
  listed. `Romanization.swift:374–375` has only the U+104D/U+104F
  standalone entries; `suffixingSymbolParticles`
  (InputNormalization.swift:22–31) is derived from the table, so a
  new entry is picked up automatically — confirmed.
- Strengthened the harm statement: production probe shows `to.`
  ranks the mis-indexed `တို့၌` at rank 0 above bare `တို့`.
- CORRECTED a factual error: the original note claimed `hnite` "does
  not collide with any existing alias row". It collides directly —
  `hnite` is the canonical penalty-0 reading of the verb `နှိုက်`
  (homophone of the particle; verified by SQL and panel probe).
  Consequently relaxed the standalone acceptance criterion from
  unconditional rank 0 to panel presence / top-3 (rank 0 only for a
  collision-free key), per the durable reachability rule.
- Discovered during validation (simplifies the fix): the reverse
  romanizer needs no dedicated U+104C branch — `vowelPatterns`
  ingests all of `Romanization.vowels`, which is exactly how
  `ei`/`ywe` reverse-map today. Desired State updated.
- Narrowed the "no scalar in U+104C–104F romanizes to ''" criterion
  to U+104C: bare ၎ (U+104E) also romanizes to "" today, but it has
  no standalone use outside `၎င်း` (which round-trips via `ng*:`);
  requiring a roman key for bare ၎ would be scope creep with no user
  story.
- Corrected a suite reference: `ParticleSuffixCompositionSuite` does
  not exist; the `to.ei`/`phyitywe` controls live in
  `SuffixingParticleReachabilitySuite` and
  `EmbeddedToneSplitLexiconFidelitySuite`.
- Burmese rule check: ၌ = locative case marker (နှိုက်, "at/in"),
  parallel to genitive ၏ and conjunctive ၍ — correct as stated.
- Scope: correct — one coverage gap with a data-pipeline follow-up,
  properly separated from archived TASK-080.

## Implementation Notes

**Fix (2026-06-10).** One standalone vowel-table entry plus a gate
widening, exactly as the revised Desired State predicted:

- `Romanization.swift`: `.init("hnite", "\u{104C}", standalone:
  true)` next to `ywe`/`ei`, with a comment documenting the
  deliberate homophone collision with the verb နှိုက် (option (a)
  from the task — the recommended default).
- `Parser/SyllableParser.swift`: the TASK-007 mid-buffer tag widens
  from `v == 0x104D || v == 0x104F` to `0x104C...0x104F`, so the new
  standalone rule is position-gated like its siblings (paired-arc
  emission skipped, mid-buffer standalone arcs skipped). NBestDP
  comments updated to match.
- No reverse-romanizer change was needed: `vowelPatterns` ingests
  `Romanization.vowels` unfiltered, so `romanize("၌")` → `hnite` and
  `romanize("ရာ၌")` → `rarhnite` fall out of the table entry.
- `Engine/InputNormalization.swift`: comment update only —
  `suffixingSymbolParticles` derives from the table and picked the
  new entry up automatically, giving `<word reading>hnite` →
  `<word>၌` composition through the TASK-080 generative branch.
- Syntax-tab snapshots (`native/macos/.../SyntaxReferenceView.swift`,
  `native/windows/preferences/Romanization.cs`) gain the matching
  `hnite` row per the keep-in-sync rule in CLAUDE.md.

**Data pipeline.** NOT rerun in this task (generated data is one
pipeline output; regeneration is a separate pass). The 21 mis-indexed
rows keep their current behavior — documented, not worsened.
`LexiconLMDriftSuite` does not recompute readings from surfaces, so
it stays green against the shipped artifacts.

**Tests.** New `LocativeParticleReachabilitySuite`: reverse
round-trip (scoped to U+104C), bare-engine standalone reachability,
production homophone panel (`hnite` serves both `၌` and `နှိုက်`),
`atwin:hnite` → `အတွင်း၌` and `rarhnite` → `ရာ၌` compositions,
mid-buffer cleanliness (`kahnitema`, `tahnitelar`), and the
`to.ei`/`phyitywe` rank-0 controls. `StandaloneParticleMidBufferSuite`
adds U+104C to its polluting-scalar set. The suite pins panel
presence for both homophones (per the recalibrated acceptance
criteria) rather than a specific rank order.

Full suite: 1706/1706 cases, 9300/9300 assertions;
`BurmeseBench --check` passes. Commit: "Give the locative particle ၌
a roman key (hnite) and a reverse mapping".

## Validation Report

**Verdict: FULLY_COVERED (independent validation, 2026-06-10), with
the documented data-pipeline follow-up still open.**

- **Acceptance criteria:** all met. Production probe: `hnite` →
  `၌` at rank 0 with the homophone verb `နှိုက်` at rank 1 (both
  reachable, exceeding the panel-presence criterion);
  `atwin:hnite` → `အတွင်း၌` rank 1, `rarhnite` → `ရာ၌` rank 1,
  `myo.hnite` → `မြို့၌` rank 2 (TASK-080 composition shape);
  `romanize("၌")` → `hnite`, `romanize("ရာ၌")`/`romanize("တို့၌")`
  contain `hnite`, `ei`/`ywe` round-trips unchanged.
  `LocativeParticleReachabilitySuite` pins all of this plus
  mid-buffer cleanliness (`kahnitema`, `tahnitelar`) and the
  `to.ei`/`phyitywe` rank-0 controls. LexiconLMDriftSuite and the
  particle suites are green in the full run.
- **Mid-buffer gate:** the TASK-007 widening to U+104C–104F also
  covers U+104E, which has no standalone rule — harmless, and
  `StandaloneParticleMidBufferSuite`'s polluting-scalar set was
  STRENGTHENED (U+104C added), not weakened.
- **Mis-indexed rows not worsened:** `to.` still serves the
  mis-indexed `တို့၌` at rank 0 above `တို့` — byte-identical to the
  pre-fix behavior documented in this task, and the TASK-084 trust
  gate (`isExactTrustworthyRow` leg 3) verifiably keeps all 21
  pre-mapping ၌ rows out of the new exact-privilege paths.
- **Native table sync:** `SyntaxReferenceView.swift` (macOS) and
  `Romanization.cs` (Windows) both carry the matching `hnite` row.
- **Open follow-up (pre-existing, explicitly out of scope per the
  generated-data non-negotiable):** the data-pipeline rerun that
  re-indexes the 21 ၌-bearing rows under hnite-bearing readings.
  The engine-side reverse mapping is in place, so the next corpus
  regeneration fixes them automatically.
