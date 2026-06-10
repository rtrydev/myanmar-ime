# TASK-084: Exact lexicon hits reached through builder-synthesized alias rows (`ah-`/`a-` prefix convention) are never recognized as exact and get crowded out of the prefix lookup

## Status
Completed

## Problem Description
The LexiconBuilder deliberately emits synthetic alias rows so that the
legacy `ah-` typing convention (and the bare `a-` double-onset
convention) for word-initial `အ` (U+1021) keeps working: every entry
whose surface starts with `အ` gets `ah<alias>` rows (penalty +0) and
`a<alias>` rows (penalty +2) in `reading_alias_index`, with the stated
intent that "the U+1021-leading lexicon hit remains panel-reachable"
(LexiconBuilder/main.swift:448–522). That intent is defeated for a
large subset of these rows: typing the `ah`-style alias of a common
word yields a panel that does not contain the word at any rank, only
parser garbage (`a|h…` segmentations rendered as `အဟ…`) plus unrelated
completions.

Verified failures (production-equivalent engine, shipped artifacts):
- `ahain` (store row → `အိမ်` "home", penalty 1): panel = `အဟိန်`,
  `အဟိမ်`, `အိုင်`-completions, `အိန်` — `အိမ်` absent at every rank.
- `ahaya` → `အရ` absent; `ahayar` → `အရာ` absent.
- `ahakhan:ahanar:` → `အခမ်းအနား` absent; the panel is parser garbage
  `အဟခန်းအဟနား` plus fabricated `အဟခန်းအနား…` compounds.
- `ahahti.ahatway.` → `အထိအတွေ့` absent; `aharo:aho:` → `အရိုးအိုး`
  absent; `aharay:ahati:` → `အရေးအတီး` absent.

Even in the "working" cases (`ahara`, `aharar`), the curated word is
served only as an unprioritized trailing lexicon candidate below
parser garbage (`ahara` rank 0 = `အဟရ`, `အရ` at rank 2) because the
hit is never recognized as an exact match.

The natural `a`-style typings (`ain`, `ara`, `akhan:ahanar:`, …) work,
so this breaks one documented input convention rather than the words
outright — but for users of that convention the words are unwritable.

## Root Cause
Two independent mechanisms combine; both stem from the engine
discarding the matched `alias_reading` identity of store hits.

1. **Matched-alias identity loss / exact recognition by canonical
   reading.** `SQLiteCandidateStore`'s prefix and exact queries SELECT
   only `canonical_reading`, never the `alias_reading` that actually
   matched. The engine then reconstructs "is this hit exact for the
   typed buffer?" via
   `exactAliasPrefixes.contains(Romanization.aliasReading(hit.reading))`
   (Engine/BurmeseEngine.swift:1863–1884, and again at the
   `exactAliasLexicon` filter, line ~2036), where `exactAliasPrefixes`
   is `Romanization.lookupAliasReadings(for: normalized)` — the typed
   buffer plus only its y↔r rewrites. For a hit served via a
   builder-synthesized row, `aliasReading(canonical)` (e.g. `ain` for
   `ain2`) never equals the typed buffer (`ahain`), so the hit is
   excluded from `prioritizedLexicon` (the panel-presence guarantee),
   from `exactReadingLexiconSurfaces` (the TASK-081 attestation set
   and TASK-083 reachability re-injection), and from the TASK-078
   whole-buffer punct-split evidence injection.
2. **Prefix-lookup LIMIT-20 crowd-out.** The prefix query
   (`SQLiteCandidateStore.swift:255–263`) orders by
   `alias_penalty ASC, rank_score DESC LIMIT 20` with no preference
   for exact-length matches. A penalty-1 exact row loses to 20
   penalty-0 *completions of longer readings* sharing the prefix.
   For `ahain`, 20+ penalty-0 `ahaing…` rows fill the window and the
   penalty-1 exact `ahain` → `အိမ်` row (rank_score 767.5, higher
   than every crowding row) is never returned to the engine at all.
   434 alias rows share the `ahaya` prefix; the same crowd-out kills
   `ahaya` → `အရ`.

Additionally the parser's DP prefers the `a|h…` segmentation (`အဟ…`)
for these buffers and the `ah|…` parse (which would produce the
correct surface as a grammar candidate) does not survive into the
panel, so there is no grammar-side rescue either.

## Burmese Language Rule Reference
Word-initial `အ` is the single most productive morphological prefix in
Burmese (noun-deriving `အ-`). The romanization table documents `ah` as
the roman key for the letter `အ` (Romanization.swift consonant table),
and the builder ships dedicated alias rows for both the `ah`- and
`a`-prefixed conventions. A reading convention that is documented and
indexed must resolve to the indexed entries.

## Steps to Reproduce
1. Production-equivalent engine with bundled artifacts.
2. Pick any high-frequency `အ…` entry and type `ah` + its digit-less
   reading remainder — e.g. `ahain` (`အိမ်`), `ahaya` (`အရ`),
   `ahakhan:ahanar:` (`အခမ်းအနား`) — without committing.
3. Page through the full candidate list.
4. Compare with direct SQL: the typed string is present verbatim in
   `reading_alias_index` pointing at the expected entry.

## Current State
- The exact alias rows exist in the store, but the engine either never
  receives them (LIMIT-20 crowd-out) or receives and fails to
  recognize them as exact (canonical-reading reconstruction), so the
  intended words are absent or buried under `အဟ…` parser garbage.
- All `ah`-prefixed rows behave as ordinary low-priority prefix
  completions at best.

## Desired State
- A store hit whose **matched** `alias_reading` (or compose reading)
  equals the typed buffer is treated as an exact alias hit: it enters
  `prioritizedLexicon` / `exactReadingLexiconSurfaces` and is
  panel-reachable (top-3 strongly preferred for the highest-scored
  exact row of the buffer).
- An exact-match row must not be crowded out of the prefix lookup by
  same-prefix completions — e.g. surface matched-alias data from the
  store (return `alias_reading` in the SELECT), and/or always union
  the exact-equality query into the prefix lookup results.
- The `a|h` parser garbage may keep rank 0 where the LM genuinely
  prefers it; the requirement is reachability of the curated word,
  per the durable reachability rule.

## Acceptance Criteria
- `ahain` surfaces `အိမ်`; `ahaya` surfaces `အရ`; `ahayar` surfaces
  `အရာ`; `ahakhan:ahanar:` surfaces `အခမ်းအနား`;
  `ahahti.ahatway.` surfaces `အထိအတွေ့`; `aharo:aho:` surfaces
  `အရိုးအိုး` (panel presence required, top-3 preferred).
- The already-working canonical typings stay at rank 0: `ain` →
  `အိမ်`, `ara` → `အရ`, `arar` → `အရာ`, `ahti.ahatway.` →
  `အထိအတွေ့`, `aro:aho:` → `အရိုးအိုး`, `akhan:ahanar:` →
  `အခမ်းအနား` (verified working today — must not regress).
- `ah` alone keeps `အ` at rank 0 with the `အ…` completions below it
  (verified working today).
- Existing exact-alias suites stay green (LexiconRankingSuite,
  CuratedAliasRankZeroSuite, AbsorbedExactAliasReachabilitySuite,
  ComprehensiveRankingSuite).
- `BurmeseBench --check` passes (the prefix-lookup query and its LRU
  caches are on the per-keystroke hot path).

## Notes
- Code: `Sources/BurmeseIMECore/SQLiteCandidateStore.swift:255–263`
  (prefix SQL, LIMIT 20, no alias_reading in SELECT);
  `Engine/BurmeseEngine.swift:1863–1884` (exactAliasPrefixes /
  exactReadingLexiconSurfaces), ~2036 (`exactAliasLexicon` filter);
  `Sources/LexiconBuilder/main.swift:448–522` (the `ah-`/`a-` alias
  emission and its stated reachability intent).
- The same identity-loss mechanism affects every *builder-side* alias
  family that the *engine-side* `lookupAliasReadings` cannot
  regenerate from the typed buffer: loanword `Cr`-cluster rewrites
  (`kr`/`pr`/… emitted by `indexedAliasReadings`) are recognized only
  because the parser independently parses those clusters; the
  `a-`-prefix rows (penalty +2) are doubly buried. A fix at the
  matched-alias level covers all of them uniformly.
- Distinct from archived TASK-083 (absorption of exact hits into
  grammar parses with negative scores) and TASK-080 (right-shrink
  truncation losing the alias prefix): here the buffer parses fine
  and nothing is truncated — the hit is lost inside the store query /
  exact-recognition logic itself.
- Scale: every `အ…` entry in the lexicon ships these rows; the broken
  subset is any row where (penalty ≥ 1) or (≥20 same-prefix
  lower-penalty completions exist). Verified counts: 434 rows share
  the `ahaya` prefix alone.
- Penalty-0 synthetic rows are NOT safe either: `ahahti.ahatway.` /
  `aharo:aho:` / `aharay:ahati:` are penalty-0 alias rows and still
  absent from their panels — identity loss alone (mechanism 1) is
  sufficient to bury them, and for these longer buffers the windowed
  frozen-prefix path freezes `aha` as `အဟ` and composes fabricated
  `အဟ…` compounds. A fix must therefore work in both the whole-buffer
  and windowed paths; recognition by the *matched* alias covers both
  because the exact-recognition logic is shared.

## Validation Notes

**Verdict: Valid — confirmed end-to-end against the shipped artifacts
(production-equivalent engine probe, 2026-06-10).**

- Every panel claim reproduced exactly: `ahain` (n=9, no `အိမ်`),
  `ahaya` (no `အရ`), `ahayar` (no `အရာ`), `ahakhan:ahanar:`
  (fabricated `အဟခန်းအနား…` compounds, no `အခမ်းအနား`),
  `ahahti.ahatway.` / `aharo:aho:` / `aharay:ahati:` all missing
  their entries; `ahara` serves `အရ` at rank 2 below `အဟရ`/`အဟာ`.
- Every "working today" control reproduced at rank 0: `ain`, `ara`,
  `arar`, `ahti.ahatway.`, `aro:aho:`, `akhan:ahanar:`, `ah`.
- Store-side claims verified by direct SQL: `ahain` rows
  (`အိန်` p0 / `အိမ်` p1 rank 767.5 / `အိမ်၌` p1), 434 rows share the
  `ahaya` prefix, 63 penalty-0 rows fill the `[ahain, ahaio)` window
  against LIMIT 20, exact `ahakhan:ahanar:` rows exist in both
  alias and compose indexes at penalty 1.
- Code references verified: prefix SQL drops `alias_reading` and
  LIMITs 20 (`SQLiteCandidateStore.swift:255–263`); the engine
  rebuilds `aliasReading` from the canonical reading at
  `BurmeseEngine.swift:1749` and recognizes exactness via
  `exactAliasPrefixes` (1863) / `exactAliasLexicon` (2036) — the
  matched alias is unrecoverable at that point, exactly as described.
- Scope: correctly scoped. The two mechanisms are one user-visible
  failure (both must be fixed for the headline cases) and the task
  already generalizes to every builder-side alias family the engine
  cannot regenerate — do not split.
- Changes: added the penalty-0 / windowed-path note above (observed
  during validation; the original text implied penalty ≥ 1 or
  crowd-out were required, but identity loss alone breaks penalty-0
  multi-word rows too). No other edits; examples and acceptance
  criteria were already representative and testable.

## Implementation Notes

**Fix (2026-06-10).** Both mechanisms addressed; exactness is now
recognized by the MATCHED alias, with a trust gate that keeps
reading-under-covering corpus residue out of the new privilege paths.

- `SQLiteCandidateStore.lookup(prefix:)` unions the exact-equality
  rows (alias + compose, per lookup variant) ahead of each LIMIT-20
  range query, so an exact row can never be crowded out of the
  window. Union rows are gated by the new
  `Romanization.isExactTrustworthyRow`; the window rows themselves
  are returned exactly as before.
- New protocol method `CandidateStore.lookupAliasExact(aliasReading:)`
  — verbatim equality against the alias index, no compose fallback
  and no variant expansion (default implementation keeps the old
  reconstruction semantics for generic stores; SQLite overrides with
  the prepared equality statement).
- `BurmeseEngine.updateInternal` queries the whole-buffer exact hits
  once (`lookupExact`, LRU-backed), filters them through
  `isExactTrustworthyRow`, and uses them for: (a) the
  anchor-windowing suppression (`hasExactLexiconMatch`), (b) a union
  into `lexiconCandidates` in BOTH the whole-buffer and windowed
  paths (the windowed union is what makes 19-char rows like
  `ahathaing:ahawaing:` → `အသိုင်းအဝိုင်း` reachable through the
  frozen-prefix path), and (c) an `exactMatchedHitKeys` set that
  extends `exactReadingLexiconSurfaces` (sanitizer preservation +
  TASK-083 reachability reinjection) and the `exactAliasLexicon`
  prioritization filter.
- The TASK-078 punct-split evidence injector accepts matched-alias
  exactness via `lookupAliasExact` membership alongside its existing
  reconstruction gate (which keeps its `'thar`-class strictness).

**Trust gate (`Romanization.isExactTrustworthyRow`).** The shipped
store carries corpus rows whose reading silently under-covers the
surface (the reverse romanizer drops scalars it cannot map): `၁ဝ`
indexed under `wa`, `၃က` under `ka`, Zawgyi `သို႔` under `tho`, and
the 21 pre-mapping ၌ rows under particle-less readings. Those hid
behind the LIMIT-20 window for years; rescuing exact rows past the
window would have promoted them (verified:
LexiconPhantomDigitFreeRankZeroSuite and LexiconPrefixLiteralTailSuite
regressed in the first green attempt). Three structural legs: no
digit scalars (digits are literal and these paths only run on
digit-free buffers), no section-mark/extension-block scalars no
forward rule emits (U+104A/B, U+1050–109F), and symbol-particle
reading coverage (a surface containing ၌/၍/၏ must carry
hnite/ywe/ei in its reading — validated against the store: 0 false
positives on the 95 ၍ / 147 ၏ rows, all 21 mis-indexed ၌ rows
contained). Rows failing the gate keep their pre-TASK-084
window-gated behavior — documented, not worsened.

**Windowed-tail scope decision.** The fix deliberately does NOT
extend matched-alias exactness to windowed TAIL hits: composing a
synthetic-alias tail (`ahaung` → `အောင်`) across every frozen branch
and marking the result exact destabilized long-sentence anchors
(ComprehensiveRanking `careerAndFamily` locked a kinzi-fabricated
branch into every final candidate; bisected and verified). Per the
durable reachability rule, ranking stability wins; whole-buffer
synthetic-alias rows are the path the `ah-` convention's
panel-reachability guarantee runs through, and that works in both
windowed and non-windowed modes.

**Tests.** New `SynthesizedAliasExactHitSuite`: store-level
crowd-out rescue (`ahain`/`ahaya`), production top-3 for the
single-word `ah-` typings, panel presence for the multi-word and
tone-bearing typings (`ahayar`, `ahakhan:ahanar:`,
`ahahti.ahatway.`, `aharo:aho:`), the windowed 19-char case one-shot
AND incremental, and the canonical-typing rank-0 controls
(`ain`/`ara`/`arar`/`ahti.ahatway.`/`aro:aho:`/`akhan:ahanar:`/`ah`).

Full suite: 1711/1711 cases, 9320/9320 assertions;
`BurmeseBench --check`: no regressions.

## Validation Report

**Verdict: FULLY_COVERED (independent validation, 2026-06-10).**

- **Acceptance criteria:** all met and pinned by
  `SynthesizedAliasExactHitSuite`: store-level crowd-out rescue
  (`ahain`/`ahaya`), production top-3 for the single-word `ah-`
  typings, panel presence for `ahayar`/`ahakhan:ahanar:`/
  `ahahti.ahatway.`/`aharo:aho:`, the windowed 19-char
  `ahathaing:ahawaing:` case (one-shot AND incremental), and the
  seven canonical-typing rank-0 controls including `ah` → `အ`.
  Full TestRunner green at HEAD (LexiconRankingSuite,
  CuratedAliasRankZeroSuite, AbsorbedExactAliasReachabilitySuite,
  ComprehensiveRankingSuite included). Bench: the gate failed on
  the validation host under sustained background load, but it
  failed identically at the pre-Step-3 commit a340c35 — the
  base-vs-HEAD per-scenario differential is within the noise band
  in both directions (several scenarios faster at HEAD), so the
  prefix-lookup union and per-update whole-buffer exact query
  (both LRU-backed) introduce no attributable hot-path regression.
- **Class generalization verified:** the doubly-buried `a-`
  double-onset convention (penalty +2 rows) works through the same
  matched-alias mechanism — independent probes show `aain` → `အိမ်`
  rank 0 and `aaya` → `အရ` rank 1, though no suite case pins that
  family explicitly (minor, the mechanism is shared).
- **Trust gate verified:** `wa`/`ka`/`tho` panels do NOT resurface
  the reading-under-covering rows (`၁ဝ`, `၃က`, Zawgyi `သို႔`); a
  source scan confirms no forward romanization rule emits
  U+104A/B or U+1050–109F, so the structural legs of
  `isExactTrustworthyRow` are sound; the 21 pre-mapping ၌ rows are
  contained (leg 3) — `to.` behavior is byte-identical to pre-fix.
- **Windowed-tail scope decision reviewed:** scoping matched-alias
  exactness to whole-buffer rows (not windowed tails) is the
  correct call per the durable reachability rule — the
  ComprehensiveRanking `careerAndFamily` anchor stability evidence
  is documented in-code at the exact filter site, and the
  windowed whole-buffer union still delivers the 19-char headline
  case.
- **Regressions:** none. The `exactComposeLexicon` filter
  correctly excludes matched-alias hits already in
  `exactAliasLexicon` (no double prioritization); key formats
  (`surface\0reading`) are consistent across
  `exactMatchedHitKeys`, `lexiconCandidateKey`, and the
  punct-split injector.
