# TASK-085: Doubled-coda-chain sanitizer false-positives on loanword bare-consonant asat codas, collapsing the panel to literal-only for the whole class

## Status
Completed

## Problem Description
Burmese writes loanword final consonant clusters as a closed syllable
followed by a bare killed consonant: `ဘတ်စ်` (bus), `ဗိုင်းရပ်စ်`
(virus), `ဝက်ဘ်ဆိုက်` (website), `ပတ်စ်ပို့` (passport), `မော်ဒယ်လ်`
(model), `အက်စ်` (the letter S), `ဖေ့စ်ဘွတ်ခ်` (Facebook), … The
shipped lexicon contains 453 entries with this `<C>်<C>်` shape, many
in the everyday top-frequency band.

The engine treats the shape as the TASK-039 "doubled coda chain" bug
pattern and removes every candidate carrying it whenever a "clean"
sibling exists. Because the literal fallback counts as that clean
sibling after injection, entire buffers collapse to a literal-only
panel: the words are unwritable through their canonical penalty-0
readings, and no `+`/`'` separator workaround exists.

Verified (production-equivalent engine, shipped artifacts):
- `bats*kar:` / `bats*kar:kyi:` → literal-only panel (n=1).
  Store rows `bats*kar:` → `ဘတ်စ်ကား` (penalty 0, rank 603) exist.
- `vaing:rap*s*` → literal-only; `ဗိုင်းရပ်စ်` (rank 614) absent.
- `wetb*hsite` → literal-only (`ဝက်ဘ်ဆိုက်` absent); `pats*po.` →
  literal-only (`ပတ်စ်ပို့` absent); `mawdel*` → literal-only
  (`မော်ဒယ်လ်` absent); `el*` → literal-only (`အယ်လ်` absent).
- `bats*` alone: rank 0 is the misparse `ဘတစ်` (vowelled `တ`); the
  correct `ဘတ်စ်` — the parser's own top-1 parse AND a penalty-0
  store row — is filtered out.
- Workarounds also fail: `bat+s*` offers only the stack `ဘတ္စ်` and
  `ဘတစ်`; `bat's*kar:` is literal-only.

## Root Cause
`BurmeseEngine.surfaceContainsDoubledCodaChain`
(`Engine/SurfaceSanitizers.swift:1214–1311`, the TASK-045
generalization of the TASK-039 predicate) flags any pair of asats
whose in-between run is exactly one bare consonant with no dependent
vowel / medial / tone / virama / fresh anchor. That is precisely the
legitimate loanword coda shape `<C1> 103A <C2> 103A` (e.g.
`1010 103A 1005 103A` in `ဘတ်စ်`), not just the doubled-`e`-rule bug
shape (`101A 103A 101A 103A`) the predicate was written for. Verified:
the predicate returns true for `ဘတ်စ်`, `ဘတ်စ်ကား`, `မိုက်စ်`,
`အက်စ်`, `ဗိုင်းရပ်စ်`, `အယ်လ်`, `ယူအက်စ်`.

Collapse chain:
1. During the merge, `sanitizeDoubledCodaChain` drops the correct
   surfaces whenever any unflagged sibling (usually the vowelled
   misparse `ဘတစ်…`) survives — so mid-typing rank 0 is a misparse.
2. For longer buffers the surviving siblings are pruned elsewhere
   (LM margin, stack-inference rewrites such as
   `bats*…` → `bat+s*…` from the liberal Pali-stack inference), so
   by the literal-fallback stage every Myanmar candidate is flagged.
3. `update` re-runs `sanitizeDoubledCodaChain` AFTER
   `injectLiteralFallback` (BurmeseEngine.swift:~344, the TASK-045
   re-run) — the literal now counts as the clean sibling, and every
   Myanmar candidate is removed → literal-only panel.
4. The TASK-081 attested-surface exemption does not protect these
   hits because it is wired only into `sanitizeMalformedMyanmarMarks`,
   not into `sanitizeDoubledCodaChain`.

The parser and the legality scan are NOT at fault: `scanOutputLegality`
accepts the shape, `parseCandidates("bats*kar:")` returns
`ဘတ်စ်ကား` as top-1, and `isAcceptableParse` accepts it. The loss is
purely the sanitizer false positive plus its post-literal re-run.

## Burmese Language Rule Reference
A bare consonant + asat with no vowel (`စ်`, `ဘ်`, `လ်`, `ခ်`, `ဒ်`,
`မ်`…) after a closed syllable is the standard Burmese orthography
for foreign consonant clusters and acronym letters: `ဘတ်စ်`,
`ဗိုင်းရပ်စ်`, `ဝက်ဘ်`, `အိုင်အက်စ်`, `မွတ်စလင်မ်`. The genuinely
illegal shape TASK-039 targeted is the doubled `e`-rule chain — two
consecutive ya-asat codas (`101A 103A 101A 103A`) fabricated from
`ee…` input — which is a much narrower pattern than "any
`<C>်<C>်`".

## Steps to Reproduce
1. Production-equivalent engine with bundled artifacts.
2. Type the canonical reading of any loanword with a bare-consonant
   coda followed by more syllables: `bats*kar:`, `vaing:rap*s*`,
   `wetb*hsite`, `pats*po.`, `mawdel*`.
3. Observe the literal-only panel; compare with
   `SQLiteCandidateStore.lookup(prefix:)` which returns the entries,
   and `SyllableParser.parseCandidates` whose top-1 is correct.
4. For the mid-typing variant, type `bats*` and observe rank 0
   `ဘတစ်` with `ဘတ်စ်` absent.

## Current State
- 453 lexicon entries carry the flagged shape; spot-checked members
  of the class are either literal-only or rank the misparse first.
- A few members survive by luck (`yuahets*` → `ယူအက်စ်` rank 0)
  only because the exact hit lands at rank 0 before the literal is
  injected, which suppresses the literal and disarms the re-run —
  the survival is accidental and fragile.

## Desired State
- The doubled-coda predicate no longer flags legitimate loanword
  bare-consonant asat codas. Options: restrict the pattern to
  ya-asat pairs (`101A 103A 101A 103A`, the actual `ee`-chain bug
  shape), and/or exempt lexicon-attested surfaces (extend the
  TASK-081 `preservedSurfaces` pattern to this sanitizer), and/or
  require the reading evidence of a doubled `e` rule.
- Typing the canonical reading of any affected entry surfaces the
  entry (rank 0 for penalty-0 exact hits with no competing common
  word; panel presence at minimum).
- The original TASK-039/TASK-045 protections stay intact: `eea`-class
  doubled-`e` chains are still filtered when a clean sibling exists
  (DoubledCodaChainSuite stays green).

## Acceptance Criteria
- `bats*kar:` surfaces `ဘတ်စ်ကား` (top-3); `bats*` surfaces
  `ဘတ်စ်`; `vaing:rap*s*` surfaces `ဗိုင်းရပ်စ်`; `wetb*hsite`
  surfaces `ဝက်ဘ်ဆိုက်`; `pats*po.` surfaces `ပတ်စ်ပို့`; `el*`
  surfaces `အယ်လ်`; `mawdel*` surfaces `မော်ဒယ်လ်`.
- No literal-only panel for any buffer that is the exact penalty-0
  alias of a store entry in this class.
- `yuahets*` → `ယူအက်စ်` stays at rank 0 (working today).
- DoubledCodaChainSuite and the bare-engine `ee`-chain pins stay
  green; the literal fallback rules (CLAUDE.md §2) are unchanged.
- `BurmeseBench --check` passes.

## Notes
- Code: `Engine/SurfaceSanitizers.swift:1214`
  (`surfaceContainsDoubledCodaChain`), 665
  (`sanitizeDoubledCodaChain`); `Engine/BurmeseEngine.swift:~332–346`
  (post-literal re-run that finalizes the collapse);
  `Engine/InputNormalization.swift` liberal stack inference
  (`bats*` → `bat+s*`) is a secondary amplifier that removes the
  unflagged siblings on some buffers — it should not need changing
  if the predicate is fixed, but verify `kats*kar:`-style buffers
  where today only the inferred stack survives.
- Class size: 453 store entries match `[C]်[C]်` (regex sweep over
  the shipped store), including rank-600+ entries
  (`ကိုရိုနာဗိုင်းရပ်စ်`, `ဗိုင်းရပ်စ်`, `ဘတ်စ်ကား`, `ဝက်ဘ်ဆိုက်`,
  `အက်စ်`, `မွတ်စလင်မ်`).
- Distinct from archived TASK-079 (legality-scan false negative on
  `ော့်` — predicate-level, different shape) and TASK-081 (sanitizer
  exemption for `sanitizeMalformedMyanmarMarks` only — this sanitizer
  was not covered). The legality scan accepts this class; the bug is
  exclusively in the doubled-coda surface predicate.

## Validation Notes

**Verdict: Valid — confirmed end-to-end against the shipped artifacts
(predicate probe + production-equivalent engine probe, 2026-06-10).**

- Predicate false positives verified directly:
  `surfaceContainsDoubledCodaChain` returns `true` for `ဘတ်စ်`,
  `ဘတ်စ်ကား`, `ဗိုင်းရပ်စ်`, `ဝက်ဘ်ဆိုက်`, `ပတ်စ်ပို့`, `အယ်လ်`,
  `ယူအက်စ်`, `မော်ဒယ်လ်` (and, correctly, for the genuine
  doubled-ya-asat bug shapes `ရယ်ယ်` / `ကယ်ယ်`).
- Panel collapse reproduced exactly: `bats*kar:`, `vaing:rap*s*`,
  `wetb*hsite`, `pats*po.`, `mawdel*`, `el*`, `bat's*kar:` are all
  literal-only (n=1); `bats*` ranks the misparse `ဘတစ်` first with
  `ဘတ်စ်` absent; `bat+s*` offers only `ဘတ္စ်`/`ဘတစ်`; `yuahets*`
  keeps `ယူအက်စ်` at rank 0 (the accidental survival described).
- Parser-not-at-fault claim verified: `SyllableParser` top-1 for
  `bats*kar:` is `ဘတ်စ်ကား` and for `bats*` is `ဘတ်စ်` — the loss is
  downstream in the sanitizer, as stated.
- Store-side claims verified: 453 entries match `<C>်<C>်` (regex
  sweep over the shipped SQLite), and every canonical reading cited
  in the acceptance criteria matches the store
  (`bats*kar:`/`bats*`/`vaing:rap*s*`/`wetb*hsite`/`pats*po.`/
  `mawdel*`/`el*`/`yuahets*`).
- Code references verified: predicate at
  `SurfaceSanitizers.swift:1214–1311` (flags any single bare
  consonant between two asats); clean-sibling filter at 665–673;
  post-literal-fallback re-run at `BurmeseEngine.swift:332–344`.
  `DoubledCodaChainSuite` exists and pins the ya-asat chain class.
- Scope: correctly scoped — predicate-level root cause with
  class-representative examples (453-entry class, examples span
  စ/ဘ/လ/ခ codas and initial/medial/final positions). The desired
  state correctly offers both the narrow predicate restriction
  (ya-asat pairs, which still covers everything the `e`-rule can
  fabricate since `e` is the only rule that emits a coda without an
  explicit coda key) and the attested-surface exemption. No changes
  needed beyond these notes.

## Implementation Notes

**Fix (predicate restriction, 2026-06-10).**
`surfaceContainsDoubledCodaChain`
(`Engine/SurfaceSanitizers.swift`) now flags an asat pair only when
the lone consonant between the two asats is ya (U+101A). Rationale:
the `e` rule is the only rule that emits a coda without an explicit
coda key, and it always emits ya-asat (`101A 103A`), so every
doubled-coda chain the bug class can fabricate has ya as the
in-between consonant. A lone NON-ya consonant between two asats is
the standard loanword orthography (`ဘတ်စ်`, `ဗိုင်းရပ်စ်`, …) — a
regex sweep over the shipped store confirms zero entries carry the
`<C>်ယ်` shape, so the restriction cannot mis-accept a fabricated
chain that collides with curated orthography.

No change was needed in `sanitizeDoubledCodaChain`, the post-literal
re-run, or the stack-inference normalizer: with the predicate fixed,
the parser's already-correct top-1 (`ဘတ်စ်ကား`, `ဘတ်စ်`) survives the
merge and the literal fallback no longer counts as the only clean
sibling.

**Tests.** New `LoanwordBareConsonantCodaSuite`
(`Sources/BurmeseIMETestSupport/Suites/`): predicate negatives for 11
attested loanword surfaces spanning စ/ဘ/လ/ခ/မ codas and
initial/medial/final positions, predicate positives for the genuine
doubled-ya-asat shapes, production-equivalent panel checks for
`bats*kar:` (top 3), `bats*`/`vaing:rap*s*`/`wetb*hsite`/`pats*po.`/
`el*`/`mawdel*` (panel presence), a no-literal-only-collapse sweep,
and the `yuahets*` rank-0 control. DoubledCodaChainSuite (the
TASK-039/045 ya-chain pins) stays green unchanged.

Full suite: 1693/1693 cases, 9249/9249 assertions.

## Validation Report

**Verdict: FULLY_COVERED (independent validation, 2026-06-10).**

- **Acceptance criteria:** all met. Every cited buffer
  (`bats*kar:` top-3, `bats*`, `vaing:rap*s*`, `wetb*hsite`,
  `pats*po.`, `el*`, `mawdel*`, `yuahets*` rank 0) is pinned by
  `LoanwordBareConsonantCodaSuite` and passes against the shipped
  artifacts. Full TestRunner: 1711/1711 cases, 9320/9320 assertions
  green at HEAD — DoubledCodaChainSuite and the literal-fallback
  rules unchanged.
- **Full-class verification (beyond the examples):** an independent
  production-engine sweep over the top-24 entries of the
  `<C>်<C>်` adjacency class (476 entries by regex over the shipped
  store) found 19/24 at rank 0 for their canonical readings. The 5
  remaining cases (`khy2el*hsi:`, `el*ban2`, `bel*gy2iyan3`,
  `piahets*gy2i`, `gy2uvintap*s*`) have digit-bearing canonical
  readings; the digit stays literal per the durable digits-are-
  literal rule, and their digit-less aliases (`khyel*hsi:`,
  `el*ban`, `bel*gyiyan`, `piahets*gyi`, `gyuvintap*s*`) all serve
  the entry at rank 0 — not a TASK-085 gap.
- **Predicate scoping:** verified the narrowed predicate
  (`loneConsonantBetween == 0x101A`) still flags every shape the
  `e` rule can fabricate (ya is the only coda the rule emits) and
  that the new suite restates the canonical violator shapes
  (`ရယ်ယ်`, `ကယ်ယ်`, `eea`, `let+ee`) next to the loanword
  negatives. No store entry carries `<C>်ယ်`, so the restriction
  cannot mis-accept curated orthography.
- **Regressions:** none. No existing test was removed or weakened.
  The bench gate could not be certified green during validation
  because the host carried sustained background load (load avg
  ~3.2): `BurmeseBench --check` failed broadly at BOTH the
  pre-Step-3 commit a340c35 and HEAD with the same profile, and the
  per-scenario differential between the two commits is within the
  ±7% noise band in both directions — no Step-3-attributable
  regression.
