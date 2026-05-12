# TASK-050: Common Burmese syllable shapes `ein`/`oun`/`pein`/`koun` — phonetic typing path absent (split into a romanization-design question and a malformed-panel-candidate bug)

## Status
Partially Completed (TASK-050b implemented; TASK-050a no-op against current state; TASK-050c deferred)

## Problem Description
The original task claimed common Burmese syllables `<C>ein` (=
`<C> + ိ + န်`, e.g. `ပိန်`, `ကိန်`, `မိန်`, `တိန်`) and `<C>oun`
(= `<C> + ု + ံ` or `<C> + ု + န်`, e.g. `ပုံ`, `ကုံ`, `တုံ`) were
unreachable through the documented romanization scheme. Verification
shows this is **partially incorrect**: the syllables ARE reachable
via the existing `ain`/`own` rules:

- `pain` → `ပိန်` (`1015 102D 1014 103A`) — rank 0
- `pown` → `ပုံ` (`1015 102F 1036`) — rank 0
- `kain` → `ကိန်` — rank 0
- `kown` → `ကုန်` — rank 0 (with `ကုံ` at rank 2)

So under CLAUDE.md §7 "panel reachability rule" the syllables are
reachable through the documented romanization. What the original
task is really asking for is **adding `ein`/`oun` as alternate
phonetic aliases of `ain`/`own`** for users who think of the
sound rather than the orthographic shape.

This is a **romanization-scheme expansion question**, not a bug,
and needs an explicit product decision before code changes. The
analogous prior decision is TASK-062 (open) — narrow phonetic
alias `y` → `r` for native lemmas — which was deliberately
scoped to a small reading-alias addition and not generalized to
fuzzy phonetic matching.

However, the verification probe surfaced a **second, distinct,
and actually-bug-shaped issue**: when the user does type `oun`
or `<C>oun`, the panel currently emits structurally illegal
Burmese surfaces that violate CLAUDE.md §1 (cross-category
dependent-vowel chains).

Verified panel surfaces (production-equivalent engine):

| Buffer  | Rank-0 surface | Hex                                    | Notes |
|---------|----------------|----------------------------------------|-------|
| `pein`  | `pein`         | `0070 0065 0069 006E` (ASCII only)    | only literal in panel |
| `kein`  | `kein`         | ASCII only                             | only literal |
| `mein`  | `mein`         | ASCII only                             | only literal |
| `tein`  | `tein`         | ASCII only                             | only literal |
| `ein`   | `၏န`          | `104F 1014` (1 candidate, no literal!) | malformed: `ei` rule emits `104F` "of" particle, then bare `n` consonant |
| `oun`   | `oun`          | rank 0 ASCII; rank 1 `အိုူန` (`1021 102D 102F 1030 1014`) | malformed: `i+u+long-u` chain on `1021` anchor |
| `koun`  | `ကိုယ်ဦန` (`1000 102D 102F 101A 103A 1026 1014`) | rank 0 | malformed: phantom `1026` independent vowel mid-word |
| `poun`  | `ပိုယ်ူန` (`1015 102D 102F 101A 103A 1030 1014`) | rank 0 | malformed: orphan `1030` long-u after asat coda |
| `toun`  | `တိုယ်ူန`     | as above                               | malformed: same shape |
| `noun`  | `ဏိုဦန`      | `100F 102D 102F 1026 1014`             | malformed: phantom `1026` mid-word |
| `houn`  | `ဟိုဦန`      | `101F 102D 102F 1026 1014`             | malformed |
| `oun.`  | rank 0 literal; rank 1 `အိုူန့` | `1021 102D 102F 1030 1014 1037` | malformed |
| `oun:`  | rank 0 literal; rank 1 `အိုူနး` | `1021 102D 102F 1030 1014 1038` | malformed |

Comparison — the documented romanizations work:

| Buffer  | Rank-0 surface | Hex                       | Status |
|---------|----------------|---------------------------|--------|
| `pain`  | `ပိန်`        | `1015 102D 1014 103A`    | clean — this is the documented spelling |
| `kain`  | `ကိန်`        | `1000 102D 1014 103A`    | clean |
| `main`  | `မိန်`        | `1019 102D 1014 103A`    | clean |
| `pown`  | `ပုံ`          | `1015 102F 1036`         | clean |
| `kown`  | `ကုန်`        | `1000 102F 1014 103A`    | clean |

So the syllables ARE reachable; only the spellings `<C>ein`/`<C>oun`
are unproductive (and additionally produce illegal panel candidates
when partially matched). The `pi.n*` workaround in the original
task is unnecessary — `pain` is the clean canonical input.

## Root Cause
`Sources/BurmeseIMECore/Romanization.swift::vowels` does not
define any of the following rules:
- `ein`, `ein:`, `ein.`
- `oun`, `oun:`, `oun.`

The table covers many neighbouring families:
- `aing` family (`ိုင်`) — short-ai diphthong + nga-asat.
- `aung` family (`ောင်`) — short-au + nga-asat.
- `in` family (`င်`) — bare nga-asat coda.
- `an` family (`န်` / `မ်` / `ံ`) — bare na/ma/anusvara coda.
- `own` family (`ုံ` / `ုန်` / `ုမ်`) — short-u + nasal coda.
- `on` family (`ွန်` / `ွမ်` / `ွံ`) — wa-hswe + nasal coda.

But the `ein` (= `102D 1014 103A`) and `oun` (= `102F 1014 103A`
or `102F 1036`) shapes have no direct romanization. The parser
therefore cannot match these inputs to any vowel arc, and the
right-shrink probe shrinks back past every onset attempt until
the literal-ASCII fallback wins rank 0.

The `e` and `o` letters do match their own bare-vowel rules
(emit `101A 103A` for `e`, `102D 102F` for `o`), and `i`/`u`
match short-vowel rules. But the combinations `ei` and `ou`
followed by `n`/`n:`/`n.` are not recognised by the parser as
vowel-final compounds.

## Burmese Language Rule Reference
Burmese has a regular set of "diphthong-style" finals:

| Romanization (this scheme) | Burmese final | Example |
|----------------------------|----------------|---------|
| `aing` / `ai`              | `ိုင်` / `ိုင်` | `ပိုင်` |
| `aung` / `aw`              | `ောင်` / `ော်` | `ပေါင်` |
| `own` / `on`               | `ုံ` / `ွန်`   | `ပုံ` / `ပွန်` |
| `ote` / `out`              | `ုတ်` / `ောက်` | `ပုတ်` |
| `ate`                       | `ိုက်`        | `ပိုက်` |

The phonetic "ein" and "oun" sounds correspond to two of the most
common Burmese syllable shapes:

- **`ein` /ein/** — appears in `ပိန်` (thin), `ကိန်` (occur),
  `မိန်` (declare), `တိန်`, `ဇိမ်`, `ဆိမ်`, and hundreds of
  loanwords. The orthographic shape is `<C> + ိ + န်` (short-i +
  na-asat) or `<C> + ိ + မ်` (short-i + ma-asat).
- **`oun` /oun/** — appears in `ပုံ` (shape), `မုံ`, `ကုံ`,
  `ဖုံ`, and many particles. The orthographic shape is
  `<C> + ု + ံ` (short-u + anusvara) — already covered by `own`
  in the table — but only via the `w`-cluster spelling.

A user who reads/writes Burmese phonetically and types `pein`
expects `ပိန်` to appear at the top of the panel. With this
scheme, the user must learn the structural workaround
`pi.n*` (5 keystrokes for a 4-character phonetic word) or the
`pown` workaround for `ပုံ`.

This is a structural gap in the romanization scheme, not a
parser bug — but the user-facing impact is large: many common
Burmese words become difficult or impossible to type without
a non-obvious learned modifier.

## Steps to Reproduce
1. Construct a production-equivalent engine.
2. Evaluate the following buffers and inspect rank-0 surface:
   - `pein`, `kein`, `mein`, `tein`, `sein`, `hkein`
   - `oun`, `koun`, `poun`, `toun`, `noun`
   - `ein`, `ein:`, `ein.`, `oun:`, `oun.`
3. Observe: rank-0 is the literal ASCII for every buffer.
4. Observe: no Myanmar candidate (`<C> 102D 1014 103A` for
   `pein`, `<C> 102F 1036` for `oun`) appears in the panel.

## Current State
- Users typing `pein`, `kein`, `mein`, `tein`, `oun`, `koun`,
  `poun`, etc. see no Myanmar candidate in the panel — they
  must either page back and re-type or accept the ASCII output.
- The only workaround documented anywhere is the structural
  spelling (`pi.n*` for `ပိန်`, `pown` for `ပုံ`), which is
  non-obvious and does not match natural phonetic typing.
- Common Burmese words like `ပိန်` (thin), `ပုံ` (shape),
  `ကိန်` (occur), `မုံ`, `တုံ` are difficult to compose
  efficiently.

## Desired State
**Status: pending product decision.** The original "add missing
vowel rules" desired state below is preserved as one option for
the romanization design call (see Validation Notes for the
recommended task split). It must not be implemented without
explicit user sign-off because it would meaningfully change
the romanization scheme.

Original proposal (one of three possible outcomes — see
Validation Notes):

Add the missing vowel-rule entries to
`Sources/BurmeseIMECore/Romanization.swift::vowels` so that:

- `ein` → `102D 1014 103A` (short-i + na-asat = `ိန် `)
- `ein:` → `102D 1014 103A 1038` (heavy tone)
- `ein.` → `102D 1014 1037 103A` (creaky tone)
- `ein2` → `102D 1019 103A` (ma-asat variant, optional)
- `oun` → `102F 1036` (short-u + anusvara = `ုံ`) — note: this
  collides with the existing `own` rule which produces the same
  surface; the addition is for the digit-less natural-typing
  path. The `own` rule continues to exist as the canonical/
  alternative.
- `oun:` → `102F 1036 1038`
- `oun.` → `102F 1036 1037`
- Optionally: `oun2` → `102F 1014 103A` (na-asat variant)

With these rules in place, a user typing `pein` produces
`ပိန်` at rank 0 (or top-3); typing `pown` continues to
produce `ပုံ` at rank 0; typing `oun` standalone produces
either an independent-vowel-anchored form or the appropriate
diphthong (per the leading-A promotion).

## Acceptance Criteria
- `engine.update(buffer: "<C>ein", context: [])` for each base
  consonant produces a Myanmar candidate matching the scalar
  shape `<C> 102D 1014 103A` at rank ≤ 3.
- The clean Myanmar surface is present at rank 0 for common
  buffers (`pein`, `kein`, `mein`, `tein`, `sein`); for less
  common bases it must still appear in the panel.
- Tone variants `<C>ein:` and `<C>ein.` produce the toned
  surface (`<C> 102D 1014 103A 1038` and
  `<C> 102D 1014 1037 103A`).
- `oun`, `oun:`, `oun.` produce the anusvara-bearing surface
  via the leading-A promotion (independent-vowel anchored
  `1021 102F 1036` for the bare onsetless case).
- A new suite under
  `Sources/BurmeseIMETestSupport/Suites/EinOunReachabilitySuite.swift`
  asserts the panel-presence invariant for the consonant
  cross-product × ein/oun × tone variants.
- Existing `own` (`102F 1036`) and `in` (`1004 103A`) family
  tests continue to pass — the new rules must not displace
  them at rank 0 for their canonical inputs.
- The reverse-romanizer continues to round-trip the canonical
  spellings (`ပိန်` ↔ `pein` or the existing `pi.n*` — whichever
  the fix designates as canonical).

## Validation Notes
**Verdict: Needs Clarification + a real but smaller bug.** The
task as written conflates two distinct issues, one of which is
not actually a bug.

### What was verified

Verification probe (BurmeseBench shim, bundled lexicon + LM):

1. The original "unreachable" claim is false. `pain` →
   `ပိန်` (`1015 102D 1014 103A`) at rank 0, `pown` → `ပုံ`
   (`1015 102F 1036`) at rank 0. The "natural Burmese
   syllables" the task lists are reachable using the
   documented romanization scheme — only via the
   `ain`/`own` spellings, not the alternative `ein`/`oun`
   spellings. CLAUDE.md §7 panel-reachability rule is
   therefore satisfied for these syllables.

2. The `pi.n*` "workaround" the original task cites is also
   not the canonical input — `pain` is. The `ain` rule
   (Romanization.swift line 337: `ain` → `102D 1014 103A`)
   is the documented romanization for the /ein/-final sound.

3. The original task also implies that adding `ein`/`oun`
   would be a small change. But the existing `e` rule
   emits `1021 101A 103A` (anchor + ya-asat) and `ei`
   emits `104F` (the abbreviation `၏`). Adding a `ein`
   rule that wins the trie longest-match would interact
   with both of those plus the `eing`/`een` shapes. This
   is a multi-week design exercise, not a data addition.

### What is a real bug

The probe surfaced a separate, real, sanitizer-shaped bug:
when the user types the unrecognized phonetic spellings
`<C>oun`, `<C>oun.`, `<C>oun:`, the parser/lattice emits
**structurally illegal Burmese surfaces** in the panel:

- `oun` → `အိုူန` (`1021 102D 102F 1030 1014`) — the
  scalars `102D 102F 1030` are short-i + short-u +
  long-u all chained on a single `1021` anchor. CLAUDE.md
  §1 explicitly forbids "cross-category dependent-vowel
  chains on one base except the legal `102D 102F` and
  `1031 + 102B/102C` storage shapes". `102D 102F 1030`
  is exactly that forbidden shape.
- `koun` → `ကိုယ်ဦန` (`1000 102D 102F 101A 103A 1026
  1014`) — has a phantom `1026` (independent vowel `ဦ`)
  wedged between an asat-closed cluster and a bare
  trailing consonant.
- `poun`/`toun` etc. follow the same template with an
  orphan `1030` long-u after a ya-asat closure (e.g.
  `ပိုယ်ူန` `1015 102D 102F 101A 103A 1030 1014`).
- `ein` → `၏န` (`104F 1014`): the `ei` rule emits
  `104F` (the Burmese abbreviation `၏` "of"), and the
  trailing `n` becomes a bare `1014` consonant with no
  asat or vowel anchor. Crucially the panel has only
  this one candidate — even the literal-ASCII fallback
  (which CLAUDE.md §2 mandates) is missing. That is a
  fallback-injection bug.

These ARE bugs aligned with existing rules:
- The `oun`/`koun`/etc. surfaces fall under "cross-
  category dep-vowel chain on one anchor", already
  policed elsewhere.
- The `ein` empty-Myanmar-panel + missing literal
  fallback is a violation of CLAUDE.md §2 ("for non-
  empty typeable input, the panel must not be empty"
  — actually the panel has the `104F 1014` malformed
  Myanmar surface but no literal-ASCII backup, so the
  user has no clean way out).

### Recommendation

Split this task. Two follow-up tasks should be filed:

1. **TASK-050a (sanitize cross-category dep-vowel
   chain in `oun` family)** — extend the existing
   sanitizer that rejects illegal `102D 102F 1030`-on-
   single-anchor adjacency to cover the surfaces above.
   This is a clean bug fix in the spirit of CLAUDE.md
   §1.

2. **TASK-050b (literal fallback missing for
   `ein`/`<C>ein` family)** — investigate why `ein`
   produces a single `104F 1014` Myanmar candidate
   with no literal-ASCII echo. Likely the
   `injectLiteralFallback` path is keyed on "rank-0 is
   mostly-unconverted ASCII" but rank-0 here is
   mostly-Myanmar yet structurally garbage.

3. **TASK-050c (open design question)** — should the
   romanization scheme accept `ein`/`oun` as
   alternative phonetic aliases of `ain`/`own`? This
   is a design call analogous to TASK-062 (`y`→`r`
   alias). It needs explicit user/product input
   before code changes, including a decision on
   reverse-romanizer canonicalization (TASK-062
   chose to keep `hsayar` as a phonetic alias and
   not a canonical reading; TASK-050 needs the same
   call). Marking it Needs Clarification is the
   right state.

### Why not just leave the task open as-is

The task as written would lead a fixing agent to add
`ein`/`oun` rules to `Romanization.swift` without
addressing either:
- the panel-reachability bug for `<C>oun` malformed
  candidates (the actually-fixable bug);
- the broader CLAUDE.md §5 design constraint that
  romanization aliases are scoped narrowly and
  explicitly.

Adding `ein` as a vowel rule would also collide with
the existing `e` (`1021 101A 103A`) and `ei`
(`104F`) rules in non-trivial ways and could
regress other flows. The fixing agent needs the
user's design call before touching `Romanization.swift`.

### Open questions for the user

1. Should `ein`/`oun` be added as phonetic aliases of
   `ain`/`own`? If yes, are they panel-only siblings
   of the canonical `ain`/`own` reading or full
   first-class spellings?
2. Should `pein` resolve to `ပိန်` at rank 0 or panel-
   reachable only? (CLAUDE.md §7 favors the panel-
   reachable interpretation when ambiguity is
   structural.)
3. Should the malformed `<C>oun` panel candidates
   (cross-category dep-vowel chain) be sanitized
   independently of the alias question? (Recommended:
   yes — that part is a clean §1 bug fix.)

### Step-2 re-verification (2026-05-12)

Re-ran the production-equivalent probe against the working-
tree bundled artifacts (which are the rebuilt LM + lexicon —
`git status` shows both as `M`). Findings:

- `pain`, `kain`, `main`, `pown`, `kown` all reach the clean
  canonical Myanmar surface at rank 0 — confirms the
  "syllables ARE reachable via `ain`/`own`" claim.
- `pein`, `kein`, `mein`, `tein`, `sein`, `hkein` — panel
  contains ONLY the literal ASCII. No Myanmar candidate at
  all. CLAUDE.md §2 literal-fallback rule is satisfied
  (rank 0 = raw buffer), but §7 panel-reachability fails for
  the phonetic typing path. Behavior matches the task body.
- `pein.` / `kein.` — `ပယ်င့်` / `ကယ်င့်` at rank 0 (clean
  Myanmar, `<C> + 101A 103A 1004 1037 103A`, i.e. `y-asat +
  nga-creaky`) with the literal as rank-1 fallback. **This
  contradicts the table on lines 44-54 which lists `pein` as
  "ASCII only" without distinguishing the toneless variant
  from the toned ones.** The tone-suffix variants are
  reachable, the toneless ones are not. This is a finer-
  grained statement of the bug — the fixing agent for
  TASK-050a/b should be aware that the panel-emptiness is
  specifically toneless `<C>ein`, not the full family.
- `ein` standalone — only candidate is `၏န` (`104F 1014`).
  Confirms the §2 violation (no literal-ASCII echo). The
  `ei` standalone rule emits `104F` and the trailing `n`
  becomes an orphan bare consonant.
- `oun` — rank 0 ASCII literal IS present; rank 1 is
  `အိုူန` (`1021 102D 102F 1030 1014`). The §1 violation
  (`102D 102F 1030` cross-category chain on `1021`) is at
  rank 1, not rank 0. So `oun` does NOT violate §2 (literal
  is present and at rank 0); the only complaint is the
  malformed rank-1 candidate. Same pattern for `oun.`,
  `oun:`.
- `koun`, `poun`, `toun`, `noun`, `houn` — rank 0 IS the
  malformed Myanmar surface (`1026` phantom independent
  vowel mid-word, or `1030` orphan long-u after asat coda).
  Literal ASCII drops to rank 1+ or off-page. This IS a §2
  / §1 dual violation: the malformed Myanmar surface
  outranks the literal, and the literal-fallback rule
  ("sanitizer-retained illegal rank 0 → literal at rank 0")
  is not firing because the sanitizer is not rejecting
  these surfaces.

### Refinements for the proposed split

- **TASK-050a (sanitizer fix)** is well-founded. The
  illegal scalar adjacencies to police are:
  - `102D 102F 1030` on a single anchor (`oun` family).
  - `1026` independent-vowel anchor appearing mid-word
    after an asat-closed cluster (`koun`, `noun`,
    `houn`, `poun`/`toun` rank-1 variants).
  - `103A 1030` (asat immediately followed by long-u)
    inside one cluster (`ပိုယ်ူန` shape on `poun`/`toun`).

- **TASK-050b (literal-fallback fix)** narrows to: when
  the parser/lattice emits only structurally-illegal
  Myanmar surfaces AND no clean Myanmar sibling exists,
  the literal fallback must be promoted to rank 0 per
  CLAUDE.md §2. The current code only catches the
  "mostly-unconverted ASCII" rank-0 case (line 138 of
  CLAUDE.md) — it doesn't yet handle "mostly-Myanmar but
  structurally garbage" rank-0.

- **TASK-050c (design question)** remains as-is — purely a
  product call about romanization scheme expansion.

## Implementation Notes (2026-05-12)

Implemented the unambiguous parts of the split:

### TASK-050b (literal-fallback widening) — DONE

The bug surfaced as: for buffer `ein`, the production-equivalent
engine returns a single-candidate panel `["၏န"]` (no literal-ASCII
echo). Root cause: the rebuilt lexicon contains the
sentence-boundary-pollution row
`surface='၏န' canonical_reading='eina' unigram_score=397.97`
(a collision of `…၏` ending one corpus sentence and `န…` starting
the next). This row's `source=.lexicon` triggered the existing
`injectLiteralFallback` carve-out at `BurmeseEngine.swift:2920`
which early-returned for any lexicon-source rank-0, suppressing
the literal-fallback injection. CLAUDE.md §2 violation (panel must
not be empty for non-empty typeable input — the user has no clean
way to commit `ein` as typed).

**Fix**: narrowed the carve-out at
`BurmeseEngine.swift::injectLiteralFallback` so a lexicon-source
rank-0 surface whose first scalar is a Myanmar abbreviation mark
(U+104A..U+104F — `၊ ။ ၌ ၍ ၎ ၏`) falls through to the literal-
fallback injection path. Those scalars are standalone
punctuation/abbreviation marks that never head a multi-scalar
Burmese word; any lexicon row whose surface starts with one is
structurally suspect corpus pollution. The abbreviation-led row
stays in the panel as a lower-ranked alternative; only its
suppression of the literal was the bug.

### TASK-050a (sanitizer for `oun` cross-category chain) — NO-OP

Step-2 verification claimed `oun`/`koun` produce rank-0 surfaces
that violate the `surfaceContainsMultiClusterOnSingleAnchor`
predicate. Re-probed both the bare engine and the
production-equivalent engine after the TASK-050b fix landed: the
rank-0 surface for `oun`/`koun`/`poun`/`toun`/`noun`/`houn` is
either the literal-ASCII fallback or a structurally-legal Burmese
surface; the malformed surfaces sit at rank 1+. The existing
sanitizer's "preserve violators when no clean sibling exists"
fallback policy already handles this correctly — adding another
predicate would either over-fire (rejecting legitimate `1026`
mid-word shapes that TASK-060 explicitly expects) or be a no-op.

Specifically, the bare-engine probe shows `koun` rank-0 is the
literal `koun` (with the malformed Myanmar surfaces at rank 1+),
and the production-equivalent probe is similar. The task's Step-2
section that flagged `1026` mid-word as a bug appears to have
overstated the case — `1026` after `103A` is the canonical TASK-060
rendering shape (see `BufferFinalOrphanAnchorSuite::
cleanYaAsatU1026FormReachableInPanel`).

### TASK-050c (`ein`/`oun` as alias of `ain`/`own`) — DEFERRED

Pure product/design call about romanization scheme expansion.
Per the pipeline policy ("you may either implement the
unambiguous parts, defer, or split per the task notes"), this
part is deferred pending explicit product input.

### Regression-witness suite

Added
`Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/TASK050OunEinIllegalSurfaceSuite.swift`
with:

- `ein_literalPresentInPanel_bundled` — direct repro witness
  (was failing before the fix).
- `cOunFamily_literalPresentInPanel_bundled` — invariant guard
  for `<C>oun` buffers in production-equivalent.
- `cOunFamily_literalAtRankZero_whenStructurallyIllegal_bundled`
  — rank-0 must be either literal or structurally-legal Burmese
  (never a `multi-cluster-on-single-anchor` violator).
- `ein_literalPresentInPanel_bareEngine` — bare-engine invariant
  guard.
- `cOunFamily_rank0_isLiteralOrCleanMyanmar_bundled` — broader
  rank-0 sanity check.
- `ein_abbreviationLedLexiconRowDoesNotMonopolisePanel_bundled` —
  asserts the abbreviation-led row stays reachable in the panel
  (the fix only removes its rank-0 monopoly).
- Carve-outs: `carveOut_pain_cleanMyanmarAtRankZero_bundled` and
  `carveOut_pown_cleanMyanmarAtRankZero_bundled` — documented
  `ain`/`own` romanizations still produce clean Myanmar at rank 0.

Registered in `BurmeseTestSuites.all`.

### Verification

- `swift run TestRunner` → 1612/1612 cases, 8935/8935 assertions.
  Before the fix: 1611/1612 cases (the
  `ein_literalPresentInPanel_bundled` failure).
- `swift run -c release BurmeseBench --check` →
  `garbage_incremental p95` flickers around the 396.4us threshold
  (379-402us) both BEFORE and AFTER the fix; the noise is a
  pre-existing stale-baseline drift, not caused by this change.
  Confirmed by stashing the fix and re-running: same regression
  signal at the threshold. Engine cost of the change is
  unmeasurable above noise.

## Notes
- The fix is primarily a data addition to `Romanization.swift`
  plus the reverse-romanizer alias updates. The parser DP and
  legality scan will pick up the new rules automatically
  through the trie regeneration at parser-init.
- Care needed for `oun` because it collides with `own`. The
  decision is whether to:
  - Add `oun` as a digit-less alias of `own3` (preferred — keeps
    one canonical reverse-romanization);
  - Or add `oun` as a separate rule that emits `102F 1014 103A`
    (the na-asat variant of the `oun` sound).
  Both interpretations are real Burmese spellings; the
  romanization scheme should probably surface both as panel
  candidates with one canonical at rank 0.
- The `e` letter is currently strongly tied to the bare-vowel
  rule emitting `101A 103A` (ya-asat). Adding `ein*` as a
  multi-letter vowel rule must not regress the existing
  `<C>e` → `<C>ယ်` mapping (handled automatically by the
  longest-match trie walk: `ein` matches before `e` when the
  buffer continues with `in`).
- Lexicon coverage check before/after the rule addition is
  recommended: `pein`, `pown`, etc. should round-trip cleanly
  through the reverse-romanizer for any lexicon entry that
  uses these surfaces.

## Validation Report (Step 4, 2026-05-12)

**Verdict: PARTIAL** — the "Partially Completed" framing in
the status line is accurate.

### Component-by-component verdict

**TASK-050b (literal-fallback widening): FULLY_COVERED.**
- The narrowed lexicon-source carve-out at
  `BurmeseEngine.swift:2938-2943` correctly excludes
  abbreviation-led lexicon rows (U+104A-U+104F) from the
  early-return path. The implementation matches the design
  in the task notes.
- The class-of-issue is covered, not just the `ein` example:
  any lexicon row whose surface starts with `၊ ။ ၌ ၍ ၎ ၏` —
  these are standalone punctuation/abbreviation marks that
  never head a multi-scalar Burmese word — now falls through
  to literal-fallback injection. This is the correct
  granularity; broader (e.g. exclude all single-scalar
  lexicon rows) would risk regressing legitimate single-scalar
  Myanmar hits, narrower (e.g. only U+104F) would leave the
  other abbreviation marks producing the same bug class on
  different inputs.
- Test coverage in `TASK050OunEinIllegalSurfaceSuite` is
  thorough: direct `ein` literal-presence witness,
  abbreviation-led-row-coexists-in-panel invariant,
  carve-out assertions for `pain` and `pown` proving the
  documented `ain`/`own` paths still produce clean Myanmar
  at rank 0.

**TASK-050a (sanitizer for `oun` cross-category chain): NO-OP, justified.**
- The Step-2 verification claimed `koun`/`poun`/etc. produce
  malformed rank-0 surfaces. The Step-3 re-probe (after the
  TASK-050b fix landed) found rank-0 is now either the
  literal-ASCII fallback or a structurally-legal Myanmar
  surface — the malformed shapes sit at rank 1+.
- The "no-op" framing is justified: the
  `cOunFamily_rank0_isLiteralOrCleanMyanmar_bundled` and
  `cOunFamily_literalAtRankZero_whenStructurallyIllegal_bundled`
  cases in the new suite serve as regression witnesses,
  proving the invariant holds without an explicit
  sanitizer extension. Adding the proposed sanitizer
  predicates would, per the implementation notes, either
  over-fire (rejecting legitimate TASK-060 `1026` mid-word
  shapes) or be a no-op against the current panel.
- This is a legitimate "spec ambiguity resolved by
  re-probing" rather than dropped work. The dropped scope
  is acknowledged in writing and the regression witnesses
  remain to catch any future drift.

**TASK-050c (romanization-scheme expansion): DEFERRED, justified.**
- The deferral is per CLAUDE.md §5 and §7: romanization
  alias expansion is a product/design decision (analogous
  to open TASK-062) and requires explicit sign-off,
  including reverse-romanizer canonicalization. The Step-3
  policy explicitly permits deferring this part.

### Scope creep check
- No scope creep. The implementation is strictly narrower
  than the original task's "add ein/oun vowel rules"
  proposal: only the literal-fallback path was touched,
  no romanization rules were added, no reverse-romanizer
  aliases were introduced.

### Regressions
- No tests removed, weakened, or suppressed.
- The benchmark noise on `garbage_incremental p95` flickers
  at the threshold both before and after the fix; the
  implementation notes correctly identify this as a
  pre-existing stale-baseline drift, not a regression of
  this change. Confirmed: full bench `--check` reports
  "no regressions" against `Tests/Benchmarks/baseline.json`.

### Gaps
- TASK-050c remains a real outstanding design question.
  This is appropriate — it should not be implemented by an
  automated pipeline.
- The status line "Partially Completed" accurately reflects
  scope. The orchestrator does not need to re-run Step 3
  on this task; the remaining work is product-decision-
  blocked.
