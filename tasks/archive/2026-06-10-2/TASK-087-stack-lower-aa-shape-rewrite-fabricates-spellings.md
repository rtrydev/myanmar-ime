# TASK-087: Structural tall/round-aa rewrite applied to virama-stack lowers fabricates unattested spellings and makes the curated MLC spellings unreachable

## Status
Completed

## Problem Description
The aa-shape auto-correction (`expandAaVariants` / `correctAaShape`)
rewrites every candidate surface — including curated lexicon hits —
so that ာ/ါ matches the descender class of the immediately preceding
consonant ({ခ ဂ င ဒ ပ ဝ} → tall ါ, others → round ာ). When the aa
sign's base is the LOWER consonant of a Pali virama stack, the shape
is lexical, not structural, and the rewrite is wrong in both
directions:

- `thi.kkhar` → rank 0 `သိက္ခါ` labeled `src=lexicon`; the curated
  surface is `သိက္ခာ` (round; the only form in the store). The
  fabricated `သိက္ခါ` does not exist in the lexicon at all. Every
  completion (`သိက္ခါပုဒ်`, `သိက္ခါကျ`, …) is rewritten the same way.
- `ri.kkhar` → `ရိက္ခါ` (store: `ရိက္ခာ`); `sar:nap*ri.kkhar` →
  `စားနပ်ရိက္ခါ` (store: `စားနပ်ရိက္ခာ`).
- `sandar` → `စန္ဒါ`, `nandar` → `နန္ဒါ`, `arnandar` → `အာနန္ဒါ`
  (store: `စန္ဒာ`, `နန္ဒာ`, `အာနန္ဒာ` — extremely common personal
  names).
- Opposite direction: `thaddhar` → `သဒ္ဓာ` (store: `သဒ္ဓါ`, the
  standard spelling of saddhā); `thaddhartarar:` → `သဒ္ဓာတရား`.
- `upaykkhar` → `ဥပေက္ခါ` (store: `ဥပေက္ခာ`); `adhi.ppary*` →
  `အဓိပ္ပါယ်` while the curated `အဓိပ္ပာယ်` row is unreachable (both
  spellings exist as separate store entries here; only the tall one
  is ever shown).

In every case the curated spelling is unreachable at any rank because
the rewrite is applied to all candidates and the rewritten duplicate
is deduped — the user cannot type the dictionary spelling, and the
panel labels a fabricated surface as a lexicon hit. Committing it also
records the fabricated spelling into user history.

## Root Cause
`BurmeseEngine.correctAaShape`
(`Engine/SurfaceSanitizers.swift:47–106`): the backward walk from the
aa sign stops at the first consonant scalar and applies
`Grammar.requiresTallAa` membership unconditionally (modulo the
medial carve-out). A stack lower (consonant immediately preceded by
U+1039) is treated like a plain onset. The in-code comment justifies
this with corpus evidence for kinzi+ဂ (`အင်္ဂါ`) and ဂ/ပ stack lowers
(`မဂ္ဂါဝပ်`, `အဓိပ္ပါယ်` 23.8k vs 17.3k) and says per-surface
exceptions are "encoded as a data table override (see task 05)" — but
no aa-shape override table exists (the only override table is
`paliStackOverrides`, which pins stack shapes for 5 readings and has
nothing to do with aa shape). The ခ-, ဒ-, ပ- and ဓ-lower evidence
points the other way: a full-store scan finds 153 stack-lower+aa
sites whose curated shape contradicts the structural rule
(63 ဒ-lower, 45 ခ-lower, 23 ပ-lower, 20 ဓ-lower, 1 ဗ, 1 ဍ), versus
845 agreeing sites.

`expandAaVariants` then dedupes by rewritten surface, so the curated
form cannot even survive as a sibling: the class is not a ranking
issue but total unreachability plus fabricated `src=lexicon` rows.

## Burmese Language Rule Reference
The tall-aa rule (ါ after the descenders ခ ဂ င ဒ ပ ဝ) applies to
plain onsets and is correctly pinned by LangAaShapeOrthographySuite.
After a virama-stack lower, the aa shape is determined by convention
per word, with round ာ dominant (the stacked pair already descends,
so the tall hook is not needed for disambiguation): MLC spellings
`သိက္ခာ`, `ရိက္ခာ`, `ဥပေက္ခာ`, `စန္ဒာ`, `နန္ဒာ`, `မေတ္တာ`, `ကမ္ဘာ` —
but `သဒ္ဓါ`, `ဗုဒ္ဓါ`, `မဂ္ဂါ…`, `အင်္ဂါ` keep the tall hook. A
structural rule keyed on the lower consonant's descender class cannot
express this; the lexicon surface is the source of truth.

## Steps to Reproduce
1. Production-equivalent engine with bundled artifacts.
2. Type `thi.kkhar`, `sandar`, `nandar`, `thaddhar`, `upaykkhar`,
   `adhi.ppary*` (canonical compose readings of the affected
   entries; the digit-less aliases behave identically).
3. Compare rank-0 surfaces against the store rows
   (`SELECT surface FROM entries WHERE …`): the panel shows shapes
   that do not exist in the store, and the store shapes appear
   nowhere in the panel.

## Current State
- 153 curated stack-lower+aa spellings are rewritten to unattested
  forms; the curated forms are unreachable at any rank.
- Fabricated surfaces are labeled `source: .lexicon` and are recorded
  into history on commit.

## Desired State
- The aa-shape rewrite must not override the attested shape when the
  aa's base consonant is a virama-stack lower. Minimal fix: skip the
  rewrite when the base consonant is a **plain** stack lower (treat
  the shape as authored); the plain-onset rule and the medial
  carve-out stay as-is.
- **Kinzi caveat (verified during validation — do not skip naively).**
  A kinzi base is also virama-preceded: in `အင်္ဂါ` the aa's base ဂ
  sits after `103A 1039` (asat+virama), while a plain Pali stack
  lower sits after `<C> 1039`. The parser's own top-1 for kinzi
  buffers is the ROUND shape (`in+gar` → `အင်္ဂာ` top-1, tall sibling
  second; `min+galar` likewise) — today's correct `အင်္ဂါ` rank-0 is
  produced by this very rewrite. A naive
  `scalars[j-1] == 0x1039 → skip` therefore regresses
  KinziTallAaSuite. The stack-lower test must exclude kinzi, e.g.
  skip only when `scalars[j-1] == 0x1039 && scalars[j-2] != 0x103A`
  (plain `C 1039 C` stack). Kinzi+ဂ stays under the structural tall
  rule, which is uniformly lexicon-attested (`အင်္ဂါ`, `ဘင်္ဂါလီ`).
- Lexicon-sourced candidates render the store surface verbatim;
  grammar candidates for the same reading may still be
  shape-corrected (the parser already materializes the typed shape).
- Where both shapes are real store entries (`အဓိပ္ပာယ်` /
  `အဓိပ္ပါယ်`), both must be panel-reachable as distinct candidates
  rather than collapsing into one.

## Acceptance Criteria
- `thi.kkhar` surfaces `သိက္ခာ` (top-3; rank 0 preferred — it is the
  only store spelling); no `သိက္ခါ` candidate labeled lexicon.
- `ri.kkhar` → `ရိက္ခာ`; `sandar` → `စန္ဒာ`; `nandar` → `နန္ဒာ`;
  `arnandar` → `အာနန္ဒာ`; `upaykkhar` → `ဥပေက္ခာ`.
- `thaddhar` → `သဒ္ဓါ` and `thaddhartarar:` → `သဒ္ဓါတရား` (tall
  preserved — the fix must be shape-preserving, not round-forcing).
- `adhi.ppary*` reaches both `အဓိပ္ပာယ်` and `အဓိပ္ပါယ်` as separate
  candidates.
- Plain-onset behavior unchanged: LangAaShapeOrthographySuite,
  KinziTallAaSuite stay green (`အင်္ဂါ` keeps tall-aa; `par` → `ပါ`;
  `kar` → `ကာ`); `kambar` keeps `ကမ္ဘာ` at rank 0.
- `BurmeseBench --check` passes (the rewrite runs on every candidate
  on the hot path).

## Notes
- Code: `Engine/SurfaceSanitizers.swift:47–106` (`correctAaShape` —
  the backward walk needs a "is this consonant a plain stack lower?"
  check, i.e. `scalars[j-1] == 0x1039` AND NOT kinzi
  (`scalars[j-2] != 0x103A`) — see the kinzi caveat in Desired
  State), 11–30 (`expandAaVariants` dedupe); `Grammar.requiresTallAa`
  (the descender set itself is correct and unchanged).
- Full-store disagreement scan (regex `္C[medial]*[ာါ]` vs the
  structural prediction): 153 disagreeing sites / 845 agreeing —
  the agreeing majority (ဂ-lowers, တ/ဘ-lowers etc.) keeps working
  under the minimal fix because the authored store shape and the
  parser-typed shape both pass through unchanged.
- Watch the interaction with `paliStackOverrides` and the windowed
  frozen-prefix renderer (`FrozenPrefixCache`) — prefixes containing
  these words must keep the curated shape across the window
  threshold.
- Distinct from archived TASK-081: that task exempted attested
  surfaces from being *dropped* by `sanitizeMalformedMyanmarMarks`;
  this is a *rewriter* mutating attested surfaces (different
  function, different failure mode — TASK-081's exemption set cannot
  protect against an in-place rewrite).
- The old-style tall-aa variant entries after plain onsets
  (`ဖေါက်ဖျက်`, `ဓါး`, `ဓါတ်…`) are intentionally normalized by the
  same function and are NOT in scope — that behavior is pinned by
  LangAaShapeOrthographySuite and matches modern MLC orthography.

## Validation Notes

**Verdict: Valid — confirmed end-to-end against the shipped artifacts
(predicate probe + production-equivalent engine probe, 2026-06-10);
revised to add the kinzi caveat to the proposed minimal fix.**

- `correctAaShape` rewrites verified directly, both directions:
  `သိက္ခာ→သိက္ခါ`, `ရိက္ခာ→ရိက္ခါ`, `စန္ဒာ→စန္ဒါ`, `နန္ဒာ→နန္ဒါ`,
  `အာနန္ဒာ→အာနန္ဒါ`, `ဥပေက္ခာ→ဥပေက္ခါ`, `အဓိပ္ပာယ်→အဓိပ္ပါယ်`, and
  tall→round `သဒ္ဓါ→သဒ္ဓာ`; `မေတ္တာ`/`ကမ္ဘာ`/`အင်္ဂါ`/`မဂ္ဂါဝပ်`
  unchanged (agreeing sites pass through).
- Production panels reproduced exactly: `thi.kkhar` rank 0 =
  fabricated `သိက္ခါ` labeled lexicon with `သိက္ခာ` absent from the
  entire panel (n=8); same pattern for `ri.kkhar`, `sandar`,
  `nandar`, `arnandar`, `upaykkhar`; `thaddhar` rank 0 = fabricated
  `သဒ္ဓာ`; `adhi.ppary*` shows only `အဓိပ္ပါယ်` (the curated
  round-aa store entry is collapsed away); `kambar` keeps `ကမ္ဘာ`
  rank 0.
- Store spellings verified by SQL: `သိက္ခာ`/`စန္ဒာ`/`ဥပေက္ခာ`/
  `ရိက္ခာ`/`နန္ဒာ` exist, their tall twins do not; `သဒ္ဓါ` exists,
  `သဒ္ဓာ` does not; both `အဓိပ္ပာယ်` and `အဓိပ္ပါယ်` exist as
  separate entries.
- Class-size claim independently reproduced: 153 disagreeing
  stack-lower+aa sites with the identical per-consonant breakdown
  (63 ဒ, 45 ခ, 23 ပ, 20 ဓ, 1 ဗ, 1 ဍ); my agree count was 871 vs the
  task's 845 (regex treatment of medial-bearing/kinzi sites differs —
  immaterial, the disagree set is what matters).
- The in-code comment's claimed "data table override (see task 05)"
  confirmed absent: `paliStackOverrides`
  (SurfaceSanitizers.swift:1683–1696) pins 5 readings' stack
  *consonant* shapes and has no aa-shape entries.
- REVISED the minimal fix: probing the raw parser shows `in+gar` /
  `min+galar` top-1 parses carry ROUND aa — today's correct kinzi
  tall-aa (`အင်္ဂါ`) is produced by `correctAaShape` itself, and a
  kinzi base is also preceded by U+1039. The originally suggested
  `scalars[j-1] == 0x1039` skip would regress KinziTallAaSuite;
  Desired State and Notes now require excluding the kinzi shape
  (`scalars[j-2] == 0x103A`) from the skip. Acceptance criteria
  already pinned KinziTallAaSuite green, so the criteria were
  adequate; the guidance now prevents the trap rather than just
  detecting it.
- Burmese rule check: correct. The tall-aa descender rule is a
  plain-onset disambiguation convention; after a stack lower the
  shape is per-word (MLC attests both `သိက္ခာ`-class round and
  `သဒ္ဓါ`/`မဂ္ဂါ`-class tall), so the lexicon surface is the only
  valid source of truth there. Kinzi+ဂ is uniformly tall in the
  corpus, consistent with keeping kinzi under the structural rule.
- Scope: correctly scoped — single rewriter root cause, examples
  cover both rewrite directions plus the dual-entry collapse case.

## Implementation Notes

**Existing-test conflict (documented before adjustment, per pipeline
hard rules).** `KinziTallAaSuite` contains two cases that pin the
exact behavior this task establishes as wrong, beyond the kinzi
cases the validation already flagged:

- `paliStack_descenderLower_aa_isTall` expects bare-engine rank 0
  tall ါ for `pap+par` / `ag+gar` / `ad+dar` — plain stack lowers.
- `correctAaShape_rewritesStackedDescender` directly pins the
  plain-stack rewrites `ပပ္ပာ→ပပ္ပါ`, `အဂ္ဂာ→အဂ္ဂါ`, `အဒ္ဒာ→အဒ္ဒါ`
  (plus the kinzi rewrite `မင်္ဂာ→မင်္ဂါ`, which stays).

These pins were written for task 01 on the strength of two ဂ-lower
examples and one ပ-lower frequency comparison, with the stated plan
that per-surface exceptions would live in "a data table override
(see task 05)" — an override table that was never built. The
full-store scan (153 disagreeing stack-lower sites: 63 ဒ, 45 ခ,
23 ပ, 20 ဓ, 1 ဗ, 1 ဍ) shows the shape is a per-word convention that
no structural rule can express; `ad+dar` → tall in particular
contradicts the curated round spellings of the most common ဒ-lower
words (`စန္ဒာ`, `နန္ဒာ`, `အာနန္ဒာ`). The acceptance criteria of this
task (`sandar` → `စန္ဒာ` etc.) are unsatisfiable while
`correctAaShape` rewrites plain stack lowers, so the two cases are
adjusted to pin the NEW contract: plain-stack-lower aa keeps the
typed/authored shape (bare engine renders the typed round `ar`;
tall after a stack lower is reachable through lexicon hits, which
now pass through verbatim), while kinzi stays under the structural
tall rule. The kinzi engine cases (`min+gar`, `ahin+gar`,
`thin+gar`, `pin+gar`) and the plain-onset cases are untouched.

**Fix.** `correctAaShape` (`Engine/SurfaceSanitizers.swift`): the
backward walk now stops without rewriting when the aa's base
consonant is a plain virama-stack lower — `scalars[j-1] == 0x1039`
AND NOT `scalars[j-2] == 0x103A` (the kinzi shape keeps the
structural rule, per the validation caveat). The misleading task-01
comment block citing the nonexistent override table is rewritten to
describe the authored-shape contract.

**Tests.** New `StackLowerAaShapeFidelitySuite`: direct
`correctAaShape` preservation checks (both directions: `သိက္ခာ`-class
round and `သဒ္ဓါ`/`မဂ္ဂါဝပ်` tall), the kinzi-stays-structural unit,
plain-onset rewrites unchanged, and production-equivalent panel
checks for `thi.kkhar`/`ri.kkhar`/`sandar`/`nandar`/`arnandar`/
`upaykkhar` (top 3, no fabricated lexicon twin), `thaddhar`/
`thaddhartarar:` (tall preserved), `adhi.ppary*` (both store
spellings reachable), and the `kambar`/`mayt+tar`/`in+gar` controls.

**Result (2026-06-10).** Implemented as described above. Full suite:
1700/1700 cases, 9286/9286 assertions; `BurmeseBench --check` passes.
Commit: "Treat aa shape after a plain virama-stack lower as authored,
not structural".

## Validation Report

**Verdict: FULLY_COVERED (independent validation, 2026-06-10).**

- **Acceptance criteria:** all met and pinned by
  `StackLowerAaShapeFidelitySuite`: round-class top-3 with no
  fabricated lexicon twin (`thi.kkhar`, `ri.kkhar`, `sandar`,
  `nandar`, `arnandar`, `upaykkhar`), tall preserved (`thaddhar`,
  `thaddhartarar:`), dual-entry case (`adhi.ppary*` reaches both
  spellings), plain-onset and kinzi controls, `kambar`/`mayt+tar`
  rank-0. Full TestRunner green at HEAD. Bench: the gate failed on
  the validation host under sustained background load, but it
  failed identically at the pre-Step-3 commit — the base-vs-HEAD
  per-scenario differential is within noise (see TASK-085's
  validation report for the full attribution).
- **Skip-condition review:** the implemented guard
  (`scalars[j-1] == 0x1039 && !(scalars[j-2] == 0x103A)`, with `j`
  at the base consonant) matches the validation caveat exactly —
  plain stack lowers skip the rewrite, kinzi bases stay structural.
  Independent probes confirm `correctAaShape` preserves both
  directions and rewrites kinzi (`အင်္ဂာ→အင်္ဂါ`).
- **KinziTallAaSuite amendment — scrutinized and justified.** The
  two amended cases (`paliStack_descenderLower_aa_isTall` →
  `paliStack_lowerAa_keepsTypedShape`,
  `correctAaShape_rewritesStackedDescender` →
  `correctAaShape_rewritesKinziKeepsStackLower`) pinned the exact
  rewrite this task establishes as wrong; the original task-01
  justification depended on an aa-shape override table that was
  never built, and `ad+dar`→tall contradicts the curated round
  spellings of the most common ဒ-lower words. The conflict was
  documented in this task file before adjustment. The amendment
  STRENGTHENS coverage: the kinzi unit pin (`မင်္ဂာ→မင်္ဂါ`) is
  retained verbatim, a new authored-tall preservation pin (`သဒ္ဓါ`
  stays tall) is added, and the four kinzi engine cases
  (`min+gar`, `ahin+gar`, `thin+gar`, `pin+gar`) plus the
  plain-onset controls are untouched. Kinzi behavior independently
  re-verified on the production engine: `in+gar` serves `အင်္ဂါ`.
- **Windowed-path spot check:** a 19-char incremental probe
  (`thi.kkharshi.tearlu`) keeps the curated `သိက္ခာ…` shape across
  the window threshold with no fabricated `သိက္ခါ` anywhere in the
  final panel.
- **Known soft consequence (accepted, not a regression):** for
  tall-attested stack-lower words typed via compose readings
  (e.g. `mag+garwap*`), the bare grammar parse now renders the
  typed round shape at rank 0 with the curated tall `မဂ္ဂါဝပ်` at
  rank 1. This is inherent to the authored-shape contract (the
  engine cannot know the per-word shape without the lexicon row)
  and sits within the durable reachability rule; the task's own
  acceptance shape for `thaddhar` (top-3) accepts the same
  trade-off.
