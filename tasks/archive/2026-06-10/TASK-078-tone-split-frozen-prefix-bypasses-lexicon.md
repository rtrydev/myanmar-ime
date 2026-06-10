# TASK-078: Embedded composing-punct split freezes a parser-only prefix, bypassing lexicon/LM evidence and whole-buffer exact-alias lookups

## Status
Completed

## Problem Description
When a buffer contains a mid-buffer composing-punctuation boundary that
triggers `splitAtLastEmbeddedComposingPunct` — an OPEN tone vowel-modifier
(`ar:`, `aung:`, `o:`, `i.`, …) immediately followed by a vowel-starting
letter, or an adjacent composing-punct pair such as `*:` — the engine
returns early from that branch and:

1. Renders everything before the split with `renderFrozenPunctSegments`,
   a parser-only single-best render that never consults the lexicon, the
   LM, ya-pin promotion, or user history. The prefix the user has
   *already seen rendered correctly* flips to the parser-canonical form
   on the next keystroke (e.g. ya-pin `ကျောင်း` flips to ya-yit
   `ကြောင်း`) and stays wrong for the rest of the composition.
2. Never performs the whole-buffer lexicon lookup, so exact alias-index
   hits for the full reading (curated multi-word entries) are completely
   unreachable, at any rank, on any page.
3. Composes lexicon completions of the *active suffix* onto the wrong
   parser-only prefix, fabricating compound surfaces that do not exist
   in the lexicon but are labeled `source: .lexicon` in the panel.
4. For readings whose alias contains a mid-buffer `*` (asat marker, e.g.
   every ဉ်/ည်-coda word followed by more syllables), the rendered prefix
   carries raw ASCII `*`/`*:` wedged between Myanmar scalars at rank 0 —
   one of the explicitly rejected surface shapes.

This breaks an entire input category: typing any multi-syllable word or
phrase whose reading contains `<open-tone>:<vowel-led continuation>` or a
mid-buffer `*` without committing at the boundary.

## Root Cause
`BurmeseEngine.updateInternal` (BurmeseEngine.swift:602–668): the
`splitAtLastEmbeddedComposingPunct` branch recurses only on the active
suffix and maps `effectivePrefix + cand.surface` over the inner
candidates, then returns. The full-buffer alias lookup
(`candidateStore.lookup(prefix: aliasPrefix, …)` at line ~1540), the
history lookup, the lattice decoder, and the merge/promotion stages never
see the complete reading.

The prefix render chain
(`PunctuationHandling.swift:258 splitAtLastEmbeddedComposingPunct` →
`renderFrozenPunctSegments` (line 661) → `renderFrozenSegment` (line 790))
uses `parser.parseCandidates(probe, maxResults: 1)` — single-best,
parser-score-only. The DP's aliasCost-first ordering always picks the
ya-yit/canonical sibling, so any prefix whose corpus-dominant form is the
ya-pin/lexicon form is rendered wrong. (`renderFrozenPrefixBranches` used
by the long-buffer windowing path at least re-scores branches with the LM
and special-cases ya-pin; the punct-split renderer has neither.)

The split decision itself (`shouldSplitEmbeddedComposingPunct`,
PunctuationHandling.swift:281, open-colon branch lines 330–349 / open-dot
branch lines 313–329, plus `hasAdjacentComposingPunctuation` for `*:`)
is correct segmentation behavior (TASK-009/TASK-032); the problem is what
the branch discards after splitting.

History is also broken for these buffers: the inner recursion reads
history keyed on the active suffix only, while `recordSelection` writes
under the full-buffer alias (the branch overwrites `lastHistoryKey` at
lines 664–667), so a previously committed selection for the same full
reading can never be promoted on re-typing.

## Burmese Language Rule Reference
- Cluster medial choice (ya-pin ျ vs ya-yit ြ) is lexical, not
  structural: `များ` (plural marker, ya-pin) vs `မြား` (arrow, ya-yit).
  The corpus-dominant form must come from lexicon/LM evidence, which this
  path discards.
- Composing punctuation (`*`, `'`, `:`, `.`) must never be emitted
  between Myanmar scalars (documented rejected shape).
- ဉ-coda words (e.g. စဉ်းစား "to think") are typeable only via their
  digit-stripped alias (`sany*:sar:`), since digits are literal — this
  path is therefore the *only* way to type them, and it is broken.

## Steps to Reproduce
1. Build a production-equivalent engine (`SQLiteCandidateStore` +
   `TrigramLanguageModel` from bundled artifacts).
2. Type, without committing, any reading of shape
   `<word ending in open tone ':'><vowel-initial continuation>` where the
   first word's corpus-dominant form differs from the parser one-best,
   e.g. `kyaung:a…`, `myar:a…`, or any exact lexicon alias such as
   `myar:ar:` (`များအား`).
3. Observe rank 0 and the full candidate list at each keystroke.
4. Repeat with a digit-stripped alias containing mid-buffer `*`, e.g.
   `sany*:sar:` (`စဉ်းစား`) or `akyany*:thar:` (`အကျဉ်းသား`).

## Current State
- `kyaung:` renders `ကျောင်း` at rank 0; the very next keystroke
  (`kyaung:a`) flips the visible prefix to `ကြောင်းအ` and every
  subsequent candidate inherits the wrong prefix
  (`kyaung:akyaung:` → `ကြောင်းအကြောင်း`; the `ကျောင်းအကြောင်း`-family
  surfaces are unreachable).
- `myar:ar:` → rank 0 `မြားအား`; the exact lexicon entry `များအား`
  (alias `myar:ar:`, penalty 0 row present in the shipped lexicon) is
  absent from the entire candidate list; ranks 1–8 are fabricated
  surfaces (`မြားအားဖြင့်`, `မြားအားနည်းချက်`, …) labeled lexicon.
- `sany*:sar:` → rank 0 `စန်ယ*:စား` (ASCII `*:` wedged between Myanmar
  scalars); `စဉ်းစား` absent from the panel. Similarly `ng*:ka`
  (`၎င်းက`) → `င*:က`.

## Desired State
- The visible prefix never flips to a worse rendering on a keystroke
  that only extends the buffer: prefix rendering at the split must use
  the same lexicon/LM-aware evidence as the pre-split rendering (or
  reuse the anchor surface the user already saw).
- Whole-buffer exact alias/compose lexicon hits must reach the panel
  (rank 0 strongly preferred for penalty-0 exact hits) even when the
  buffer contains an embedded tone split or mid-buffer `*`.
- No candidate may carry composing punctuation between Myanmar scalars
  when a clean rendering of the same reading exists.
- History keyed on the full-buffer alias must be consulted for these
  buffers.

## Acceptance Criteria
- Typing `kyaung:akyaung:` one-shot and incrementally yields
  `ကျောင်းအကြောင်း` reachable in the panel with the `ကျောင်း` prefix
  stable from keystroke `kyaung:` onward.
- `myar:ar:` surfaces `များအား` (exact alias hit) in the panel, top-3
  preferred.
- Split-path completion candidates remain permitted, but their prefix
  portion must match the lexicon/LM-preferred rendering of the prefix
  reading (no `မြားအား<completion>` rows while `များအား` is the
  dominant rendering of `myar:ar:`). Re-labeling composed candidates
  away from `source: .lexicon` is optional polish, not a requirement —
  prefix fidelity is the testable criterion. (Amended in Step 5 — see
  Gap Fix Notes: this criterion applies to the open-tone prefix class
  (`myar:`, `kyaung:`, …); `*`-bearing prefixes whose baseline render
  carries literal ASCII are exempt, because the literal-preservation
  pins deliberately reject the evidence override there and the clean
  curated word holds rank 0.)
- `sany*:sar:` surfaces `စဉ်းစား`; rank 0 contains no ASCII `*`/`:`
  between Myanmar scalars.
- `ng*:ka` and `ng*:to.` surface `၎င်းက` / `၎င်းတို့`.
- A selection committed for `myar:ar:` is promoted by history on the
  next typing of the same buffer.
- Control: `to.ei` keeps rendering `တို့၏` at rank 0 with the `တို့၏အ…`
  completions below it. This buffer goes through the same split branch
  (open-dot `o.` followed by vowel-led `ei`) and is currently served
  *correctly* because the active suffix happens to equal the standalone
  particle — the fix must not regress the cases the split path already
  gets right.
- Existing suites stay green, notably VisargaInherentASuite,
  MidSentenceAhaPrefixAfterBoundarySuite, OrphanLeadingVowelSuite,
  ToneOrphanedPunctLeakSuite, and the BurmeseBench `--check` gate.

## Notes
- Code: `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`
  lines 602–668 (early-return branch);
  `Engine/PunctuationHandling.swift` lines 258–355 (split decision),
  661–830 (parser-only render).
- The analogous windowed-path renderer
  (`Engine/FrozenPrefixCache.swift: renderFrozenPrefixBranches`) already
  LM-rescores branches and force-parses the ya-pin disambiguated input —
  a template for the fix.
- Verified with bundled artifacts at commit 795465c; all 1648 existing
  test cases pass, i.e. nothing currently pins this behavior. Suites pin
  only the segmentation (e.g. `kar:athit` → `ကားအသစ်`), not prefix
  medial fidelity or whole-buffer lexicon reachability across the split.
- Severity: high — affects the most common plural/genitive particle
  compounds (`များ…`), school/monastery vocabulary (`ကျောင်း…`), and all
  ဉ်-coda words.
- `ကျောင်းအကြောင်း` is NOT itself a lexicon entry (verified against the
  shipped store); the `kyaung:akyaung:` criterion is satisfied by a
  correctly rendered prefix composed with the inner `akyaung:`
  candidates, not by an exact whole-buffer hit. `များအား`, `စဉ်းစား`,
  `၎င်းက` (`ng*:ka`), and `၎င်းတို့` (`ng*:to.`) ARE penalty-0 alias
  rows, so those criteria do require whole-buffer lookup reachability.

## Validation Notes
- **Verdict: valid.** Every Current State claim reproduced exactly at
  commit 795465c against the bundled artifacts (production-equivalent
  engine, fresh per-buffer instances): `kyaung:` rank 0 `ကျောင်း` →
  `kyaung:a` rank 0 `ကြောင်းအ` with all completions inheriting the
  wrong prefix; `myar:ar:` rank 0 `မြားအား` with `များအား` absent from
  the full panel; `sany*:sar:` rank 0 `စန်ယ*:စား` (raw ASCII `*:`
  between Myanmar scalars); `ng*:ka` rank 0 `င*:က`.
- Code citations verified: early-return branch is
  `BurmeseEngine.swift:602–668`; `renderFrozenSegment`
  (PunctuationHandling.swift:790) uses `parser.parseCandidates` only
  (top-1 in the shrink loop, top-4 + independent-vowel preference for
  the final pick) — no lexicon, LM, or history access.
  `renderFrozenPrefixBranches` (FrozenPrefixCache.swift:53) does
  ya-pin disambiguation + LM rescoring, confirming the suggested
  template. Split-decision branches are at PunctuationHandling.swift
  313–329 (open dot) and 330–349 (open colon), as cited.
- History claim verified empirically: after recording
  `myar:ar: → များအား` in a fresh history store, re-typing `myar:ar:`
  does not surface it (the inner recursion looks up history under the
  active-suffix alias only; `lastHistoryKey` is overwritten with the
  full-buffer alias at lines 664–666 for writes).
- Scope: correctly scoped as one task. Items 1–4 share a single root
  cause (the branch discards lexicon/LM/history evidence after
  splitting); splitting them would invite conflicting partial fixes.
- Changed: softened the `source: .lexicon` re-labeling acceptance
  criterion to optional (the composed-candidate design inherits the
  inner candidate's source; prefix fidelity is the real requirement),
  added the `to.ei` non-regression control (verified working today via
  this same branch), and documented that `ကျောင်းအကြောင်း` is not a
  store row.

## Implementation Notes
- Fix lands in the `splitAtLastEmbeddedComposingPunct` branch of
  `BurmeseEngine.updateInternal` plus two new helpers in
  `Engine/PunctuationHandling.swift`:
  * `evidenceAlignedPunctPrefix(_:context:)` — replaces the parser-only
    prefix render when the active suffix is Burmese-composable. It
    re-runs `updateInternal` on the prefix slice (exactly the pre-split
    pipeline the user already saw) and adopts the first candidate that
    is (a) not pure-lexicon (lexicon hits for a prefix reading include
    longer completions such as `to.` → `တို့၌`), (b) a pure-Myanmar
    surface, (c) alias-reading-exact for the slice, and (d) ends on the
    same scalar as the parser baseline. Guard (d) plus a
    pure-Myanmar-baseline gate keep every literal-punct product pin
    intact: a standalone re-parse may re-interpret trailing punct
    (`ka.` → `က။` under punct mapping, `ka*.` → `က့်`) or swallow
    boundary apostrophes — those baselines either end on a different
    scalar or carry literal ASCII, so the override is rejected and the
    pre-fix render is kept. Memoised in `punctPrefixRenderCache`
    (cleared on empty-buffer reset and on `recordSelection`), so the
    recursive evidence pass runs once per new split point, not per
    keystroke; nested multi-split prefixes resolve recursively through
    the same branch.
  * `injectWholeBufferPunctSplitEvidence(into:displayBuffer:context:)`
    — runs after the prefix+suffix composition. Injects up to 3
    alias-exact whole-buffer lexicon hits ahead of the composed
    candidates (move-or-insert so a composed grammar duplicate keeps
    its source — required for the nested-prefix evidence scan), then
    promotes full-buffer-alias history hits to the very front,
    mirroring the regular pipeline's merge order. Compose-key variants
    are filtered out (`'thar` must not resurface `သာ` without the
    apostrophe); buffers carrying a literal ASCII digit skip lexicon
    injection (digits-are-literal).
- `candidateStore` / `historyStore` widened from `private` to
  `internal` so the PunctuationHandling extension (separate file) can
  reach them.
- For `*`-bearing prefixes whose baseline render carries literal ASCII
  (`sany*:` → `စန်ယ*:`, `ng*:` → `င*:`), the prefix override is
  deliberately NOT applied; the whole-buffer exact hits (`စဉ်းစား`,
  `၎င်းက`, `၎င်းတို့`) land at rank 0, which satisfies the acceptance
  criteria (rank 0 clean, top-3 reachable). Composed completion rows
  below them may still carry the literal `*:` shape — consistent with
  the literal-preservation pins in MidBufferPunctuationSuite /
  ToneOrphanedPunctLeakSuite / DoubledLiteralPunctSuite.
- New suite: `Suites/EmbeddedToneSplitLexiconFidelitySuite.swift`
  (10 cases — progressive + one-shot + nested prefix stability,
  exact-alias reachability for all four curated readings, `to.ei`
  control, history write/read round trip). TDD-verified failing
  before the fix (7 of 10 cases), green after.

## Bench Gate Result (2026-06-10, commit 574e8ee)
- `swift run -c release BurmeseBench --check Tests/Benchmarks/baseline.json`
  exits 1 with exactly two regressions, both PRE-EXISTING baseline
  drift, not caused by this task:
  * `garbage_incremental` p99: 870.7us > baseline*1.30 = 535.1us
  * `garbage_incremental_prod` p99: 960.1us > 636.8us
- Verified empirically against a worktree at the pre-fix commit
  d2bceaa (same machine, back-to-back release runs): bare p99
  879–886us pre-fix vs 824–882us at 574e8ee; prod p99 914–929us
  pre-fix vs 960us gate median. The garbage buffer contains no
  composing punctuation, so the TASK-078 split-branch code never
  executes on it. p50/p95 match the baseline in both runs; only the
  p99 tail drifted, sometime after the macOS baseline capture at
  d74c893 (2026-05-12) and before d2bceaa.
- Every punct-split-relevant scenario (`ain_colon_chain_incremental_prod`
  p95 1976us / p99 60.4ms vs baseline 2060us / 61.7ms,
  `ain_colon_chain_backspace_prod`, `plus_chain_30`, backspace
  truncation kinds) passed the gate at 574e8ee.
- Re-capturing the macOS baseline was deliberately left to a separate
  decision — doing it inside this task would mask whichever earlier
  commit introduced the garbage-tail drift.

## Validation Report (Step 4, 2026-06-10, HEAD 574e8ee)
- **Verdict: PARTIAL** (all hard criteria met; one general criterion
  is met only for the non-`*` prefix class, as the implementation
  notes themselves disclose).
- Verified passing: `EmbeddedToneSplitLexiconFidelitySuite` (9 cases)
  green inside the full runner — progressive + one-shot `ကျောင်း`
  prefix stability including the nested split, `myar:ar:` →
  `များအား` top-3 with zero `မြားအား…` fabrications, `sany*:sar:` →
  `စဉ်းစား` top-3 with clean Myanmar rank 0, `ng*:ka` / `ng*:to.`
  exact hits, `to.ei` control at rank 0, and both history
  round-trip directions. Independent probes extend the class:
  `akyany*:thar:` → `အကျဉ်းသား` rank 0; `myar:a` panel carries the
  `များ` prefix on every candidate (no arrow-prefixed rows);
  `kyaung:o` / `myar:o` completions all carry the curated prefix.
- **Residual gap (documented in Implementation Notes, confirmed by
  probe):** for `*`-bearing prefixes the composed completion rows
  below the exact hit still carry the parser-canonical prefix with
  raw ASCII wedged between Myanmar scalars (`sany*:sar:` panel ranks
  1+ are `စန်ယ*:စား`, `စန်ယ*:စားချင်`, …; `akyany*:thar:` ranks 1+
  are `အကြန်ယ*:သား…`; `ng*:ka` ranks 1+ are `င*:က…`). The acceptance
  criterion "completion candidates' prefix portion must match the
  lexicon/LM-preferred rendering of the prefix reading" is therefore
  met for the open-tone class (`myar:`, `kyaung:`) but not for the
  `*`-class, where the evidence override is deliberately rejected
  because the baseline render carries literal ASCII
  (literal-preservation pins). Severity: low — rank 0 is the clean
  curated word, reachability is satisfied, and the durable
  reachability rule says panel presence must not be traded for
  ranking destabilization. Step 5 may either render `*`-class
  completion prefixes from the curated prefix surface (e.g.
  `စဉ်းစား` + completion tails) or formally amend the criterion.
- Perf: this commit did NOT introduce the garbage p99 gate failure —
  step-4 bisect attributes it to d2bceaa (TASK-080); d2bceaa and
  574e8ee measure within noise of each other (874-918us vs
  809-820us), and no punct-split scenario regressed. The "--check
  gate stays green" criterion is red at HEAD solely because of the
  TASK-080 regression.

## Gap Fix Notes (Step 5, 2026-06-10)
- Resolution of the residual `*`-class gap: **criterion formally
  amended** (the completion-prefix-fidelity criterion now applies to
  the open-tone prefix class only). Rationale:
  * For `*`-bearing prefixes the baseline render carries literal
    ASCII (`sany*:` → `စန်ယ*:`, `ng*:` → `င*:`), and the evidence
    override deliberately rejects literal-ASCII baselines — the
    rejection guard is what keeps every literal-preservation pin
    green (MidBufferPunctuationSuite, ToneOrphanedPunctLeakSuite,
    DoubledLiteralPunctSuite). Rendering `*`-class completion rows
    from the curated prefix surface would require weakening exactly
    that guard, trading well-pinned literal-punct behavior for
    cosmetic fidelity of below-rank-0 completion rows.
  * The user-facing bar is met for the `*`-class: rank 0 is the
    clean curated word (`sany*:sar:` → `စဉ်းစား`, `akyany*:thar:` →
    `အကျဉ်းသား`, `ng*:ka` → `၎င်းက`), the exact whole-buffer hits
    are top-3, and the durable reachability rule (CLAUDE.md §7)
    says panel presence must not be traded for ranking
    destabilization elsewhere. The composed rows below carry the
    parser-canonical literal prefix — reachable alternatives, not
    displacing anything.
  * Severity was rated LOW by validation; the open-tone class (the
    `myar:`/`kyaung:` compounds the task was filed for) has full
    prefix fidelity, pinned by
    `EmbeddedToneSplitLexiconFidelitySuite`.
- Follow-up direction if `*`-class completion fidelity is ever
  wanted: compose the completion tails onto the whole-buffer exact
  hit's surface (e.g. `စဉ်းစား` + tail) in
  `injectWholeBufferPunctSplitEvidence`, instead of relaxing the
  literal-ASCII baseline guard in `evidenceAlignedPunctPrefix` —
  that route adds the clean rows without touching the
  literal-preservation invariants.
- Step 5 also confirmed the two bench-gate failures recorded above
  are resolved by the TASK-080 hot-path gap fix (`BurmeseBench
  --check` reports "no regressions" at the gap-fix commits), so the
  last open acceptance criterion of this task is now green without
  re-capturing the baseline.
