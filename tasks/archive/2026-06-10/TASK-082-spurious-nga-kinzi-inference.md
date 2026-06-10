# TASK-082: Spurious kinzi inference over a nga onset (`င်္င`) corrupts the whole panel for `…n|ng…` boundaries and makes long anusvara compounds unwritable

## Status
Completed

## Implementation Notes
All changes in `Engine/InputNormalization.swift`
(`inferImplicitStackMarkers` and helpers); the fix targets the
inference trigger as recommended — `Grammar.isValidStack` is untouched
and explicit user-typed `+` remains the escape hatch.

1. `inferredPaliStackIsLiberal` (central upper×lower loop): nga
   (U+1004) is excluded as a stack LOWER for every upper. This kills
   the strict `min+nganay` / regular-loop nga-lower sites for the
   whole `…n|ng…` / `…ng|ng…` class.
2. Mid-buffer `ai+ng` collapse: the valid-lower predicate now requires
   a non-nga lower, so `naingngank`-class buffers route to the
   existing blocked path (plain nga onset wins naturally).
3. Buffer-leading `aing<…>` fast path: same non-nga predicate, plus a
   new lowers-empty liberal fallback (`ainga` → `ai+nga`, liberal)
   mirroring the mid-buffer branch, so the previously pinned
   `DiphthongPlusBareNgaSuite.infer_bufferLeading_unchanged` output
   shape is preserved with the open form at rank 0.

The windowed exact-match amplifier needed no separate change: with the
fabricated kinzi gone, the windowed frozen-prefix + tail composition
renders `နိုင်ငံခြားသား` compositionally and it is present in the
final panel (pinned by the new suite's incremental case).

**Documented test adjustment** (per the regression rule):
`KinziInferenceSuite.inferredKinzi_velarLowersWinTop1` contained
`"minnga"` in its velar-lower sweep, pinning kinzi-over-nga
(`မင်္င…`) at production rank 0. That member was a mechanical sweep
over the velar `stackClass` (k, kh, g, gh, ng) and is wrong for the
`ng` member: `င်္င` has no attested standard-orthography use (validated
in this task's Burmese rule reference), and `minnga` is itself an
incremental state of the `minnganay` bug class — keeping it would
preserve the mid-typing corruption the task exists to fix. The member
was removed with an explanatory comment; the other four members are
untouched. The liberal panel-reachability pins in
`DiphthongPlusBareNgaSuite` (single-`ng` `mainga`/`kainga` kinzi
sibling at rank ≥ 1) are fully preserved — the fix is scoped to the
strict/collapse paths.

New suite: `Suites/NgaOnsetKinziInferenceSuite.swift` (bare-engine
any-candidate kinzi-over-nga ban for the doubled-`ng` bug class,
production rank-0 checks, incremental `naingngankhyar:thar:` with
final-panel `နိုင်ငံခြားသား` presence, plain-`နိုင်ငံက` reachability,
and `mingalarpar`/`kingga` legitimate-kinzi controls). Full runner
green (1663 cases / 9110 assertions); `BurmeseBench --check` reports
no regressions.

## Problem Description
When a buffer contains a nasal-coda vowel rule followed by a nga-onset
syllable (the shapes `…in` + `ng…` / `…aing` + `ng…` / `…ngan` + `<C>…`,
i.e. the letter sequence `ngng` or `nng`), the implicit kinzi/stack
inference fires and fabricates a kinzi-over-nga surface
(`<…>1004 103A 1039 1004<…>` = `င်္င`), a shape that is essentially
unattested in Burmese. Because inferred-stack surfaces are promoted to
rank 0 unconditionally on the implicit path, and because sibling
candidates get pruned, the *entire* candidate panel can consist of
fabricated kinzi non-words.

This breaks the country/state word family — `နိုင်ငံ` (top-50 frequency)
plus suffix — in two user-visible ways:

1. Mid-typing flip-flop: the correctly rendered prefix `နိုင်ငံ`
   visibly corrupts to `နိုင်္ငန်` on the next consonant keystroke,
   snaps back when a lexicon boundary is reached, then corrupts again
   (`naingngan` → `နိုင်ငံ`; `naingngank` → `နိုင်္ငန်က`;
   `naingngankhyar:` → `နိုင်ငံခြား`; `naingngankhyar:t` →
   `နိုင်္ငန်ခြားတ`).
2. Terminal unreachability for longer compounds: at
   `naingngankhyar:thar:` (a shipped lexicon entry, `နိုင်ငံခြားသား`
   "foreigner") every Myanmar candidate in the panel carries the
   fabricated kinzi; the correct surface is unreachable at any rank.

Amplifiers for the long-buffer case (>= `compositionWindowSize` = 18
chars): the windowed branch performs lexicon lookup on the active tail
only, so the whole-buffer exact alias hit cannot rescue the panel, and
`hasExactLexiconMatch == true` simultaneously disables the anchor reuse
that preserved the correct `နိုင်ငံ…` rendering — the gate removes the
anchor *and* fails to substitute the lexicon entry it detected.

## Root Cause
- `inferImplicitStackMarkers`
  (`Engine/InputNormalization.swift:738`) treats the `in<C>` kinzi
  signal as applying when the following onset is `ng` itself, inserting
  an inferred boundary that renders kinzi (superscript nga) over a nga
  base. No legality/attestation check excludes `1004` as the kinzi
  lower consonant.
- `bestStrictInferredStackIndex` promotion
  (`Engine/BurmeseEngine.swift:2131–2167`) lifts the inferred surface to
  rank 0 unconditionally for implicit (non-`+`) buffers; the anusvara
  sibling (`ငံ` digitless `ngan` → `ငန်`) and the lattice/lexicon
  surfaces lose the top slot, and the LM-margin prune plus page-size cap
  push them out of the panel entirely.
- Windowed-path interaction (`Engine/BurmeseEngine.swift:968–1043`):
  `hasExactLexiconMatch` (line 975) suppresses `anchorApplies`, but the
  windowed branch then performs only the tail lexicon lookup (lines
  1512–1538), so the detected whole-buffer entry is never injected.

## Burmese Language Rule Reference
Kinzi is a superscript nga (`င် ် ္`) written over the *following*
consonant and occurs over velars/dentals etc. (`င်္ဂ`, `င်္ခ`, `င်္တ`…)
in Pali-derived words (`မင်္ဂလာ`, `အင်္ဂါ`, `သင်္ဘော`). Kinzi over nga
itself (`င်္င`) does not occur in Burmese orthography. The sequence
`<vowel>…ng` + `ng<vowel>` across a syllable boundary is written with a
plain nga onset (e.g. `နိုင်ငံ` = `နိုင်` + `ငံ`), never with kinzi.

## Steps to Reproduce
1. Production-equivalent engine with bundled artifacts.
2. Type `naingngan` (renders `နိုင်ငံ`), then continue with any
   consonant that does not immediately complete a lexicon entry, e.g.
   `naingngank`, `naingngankhyar:t`, or the full
   `naingngankhyar:thar:`.
3. Observe rank 0 and the full panel at each step.
4. Minimal trigger without the windowing amplifier: `minnganay`
   (intended `မင်ငနေ`-family) — rank 0 is `မင်္ငနေ`.

## Current State
- `minnganay` → rank 0 `မင်္ငနေ` (kinzi over nga).
- `naingngank` → rank 0 `နိုင်္ငန်က`; previously displayed `နိုင်ငံ`
  prefix corrupts on screen.
- `naingngankhyar:thar:` → all six Myanmar candidates carry
  `နိုင်္င…`; the lexicon entry `နိုင်ငံခြားသား` is absent; literal is
  the only escape.

## Desired State
- Kinzi inference never proposes `1004` (nga) as the kinzi lower
  consonant; the `…ng|ng…` boundary renders a plain nga onset.
- The anusvara/plain reading (`နိုင်ငံက…`, `မင်ငနေ`) holds rank 0 (or
  at minimum the panel) for these boundaries, and previously rendered
  `နိုင်ငံ` prefixes do not visibly corrupt as the user continues
  typing.
- When `hasExactLexiconMatch` detects a whole-buffer entry on a
  windowed-length buffer, that entry must actually be injectable into
  the panel (do not suppress the anchor and then drop the entry).

## Acceptance Criteria
- `minnganay` rank 0 contains no `1004 103A 1039 1004` sequence; a
  kinzi-free candidate is top-1.
- Incremental typing of `naingngankhyar:thar:` never shows a
  `နိုင်္င` prefix at rank 0, and the final panel contains
  `နိုင်ငံခြားသား`.
- Legitimate kinzi behavior is unchanged: `mingalarpar` family,
  `kinggar`-style `gg` signals (DoubledLetterKinziSuite), explicit
  `+`-typed kinzi (ExplicitPlusKinziDisplacementSuite,
  WindowingKinziAcrossThresholdSuite, KinziInferenceSuite,
  MingalarKinziLongBufferSuite) all stay green.
- `BurmeseBench --check` passes (stack-inference touches the hot
  path).

## Notes
- Code: `Engine/InputNormalization.swift:738`
  (`inferImplicitStackMarkers`), `Engine/BurmeseEngine.swift:2131`
  (unconditional implicit-stack promotion), 968–1043 + 1512–1538
  (exact-match gate vs windowed tail-only lexicon).
- Verified: lexicon-attested continuations (`naingnganray:`,
  `naingnganthar:`, `naingngantakar`) are rescued by exact hits, and
  long clean compounds (`myanmarnaingngantwin`) are rescued by the
  lattice — the failure window is mid-word states plus compounds whose
  exact hit exists but cannot be injected in windowed mode. The fix
  should address the inference trigger first; the windowed exact-match
  injection hole is the secondary amplifier.
- No existing suite covers `ngng` boundaries (checked: DoubledLetter-
  KinziSuite covers `gg`; Windowing/Kinzi suites cover real kinzi
  words).

## Validation Notes
- **Verdict: valid as written.** Reproduced at commit 795465c:
  `minnganay` rank 0 = `မင်္ငနေ` (kinzi-free sibling at rank 1);
  `naingngank` rank 0 = `နိုင်္ငန်က` (the plain `နိုင်ငံက` survives at
  rank 2 in this mid-word state — panel corruption is partial here);
  `naingngankhyar:` snaps back to `နိုင်ငံခြား`; `naingngankhyar:t`
  corrupts again (rank 0 `နိုင်္ငန်ခြားတ`); and the terminal
  `naingngankhyar:thar:` panel is fully corrupted — all six Myanmar
  candidates carry `နိုင်္င…` and the shipped entry `နိုင်ငံခြားသား`
  (alias penalty 1, verified present in the store) is absent.
- Root cause verified empirically and by code reading:
  `inferImplicitStackMarkers("minnganay")` returns
  `min+nganay` (1 strict insertion, 0 liberal) and
  `inferImplicitStackMarkers("naingngank")` returns `nai+ngank` —
  nothing excludes nga as the stack lower because
  `Grammar.isValidStack(upper: nga, lower: nga)` is true (both class 0
  velar in `stackClass`, Grammar.swift:235–266). The unconditional
  implicit-path promotion is confirmed by the comment at
  BurmeseEngine.swift:2143–2146 ("the implicit-inference path …
  continues to promote unconditionally") and the windowed counterpart
  at 2185–2204; `anchorApplies = priorAnchor != nil &&
  !hasExactLexiconMatch` at lines 989–990 and the tail-only windowed
  lookup at 1512–1538 match the amplifier description.
- Burmese rule check: correct. Kinzi (superscript nga via
  `1004 103A 1039`) occurs over velars/dentals/labials in Pali-derived
  words (`မင်္ဂလာ`, `အင်္ဂါ`, `သင်္ဘော`); kinzi over nga itself
  (`င်္င`) has no attested standard-orthography use. The hedge
  "essentially unattested" is appropriate. Note for the fixing agent:
  the right place to special-case is the *kinzi inference trigger*
  (nga as the inferred lower), not `Grammar.isValidStack` itself —
  same-class velar stacking must stay valid for `င်္ဂ`-style pairs and
  explicit `+` input remains the user's escape hatch.
- All five suite names cited in the acceptance criteria exist in
  `Sources/BurmeseIMETestSupport/Suites/`.
- Scope: correctly scoped — primary fix (inference trigger) plus the
  named secondary amplifier (windowed exact-match injection hole),
  with the amplifier explicitly subordinated. No changes made beyond
  these notes.

## Validation Report (Step 4, 2026-06-10, HEAD 574e8ee)
- **Verdict: FULLY_COVERED.**
- All acceptance criteria verified: `NgaOnsetKinziInferenceSuite`
  (5 cases) passes inside the full runner; covers the any-candidate
  kinzi-over-nga ban, production rank-0 checks, the incremental
  `naingngankhyar:thar:` walk with final-panel `နိုင်ငံခြားသား`
  presence, plain-onset reachability, and legitimate-kinzi controls.
- Class coverage verified beyond the suite with an independent probe:
  no candidate carries `1004 103A 1039 1004` for 11 additional
  nasal-coda + nga-onset buffers (`kannga`, `tinngar`, `yinngay`,
  `thinnga`, `ngannga`, `anngat`, `onnga`, `ainngar`,
  `naingngarmay`, `kyaungnga`, `minnga`). Explicit `min+nga` still
  renders the user-forced stack — the documented escape hatch, per
  the durable explicit-`+` rule. Legitimate kinzi controls
  (`mingalar`, `thingbo:`, `kingga`) unchanged.
- **Test adjustment audit:** the only existing-suite modification in
  the whole Step 3 range is the removal of the `minnga` member from
  `KinziInferenceSuite.inferredKinzi_velarLowersWinTop1`. Justified:
  the member was a mechanical sweep over the velar stackClass and
  pinned the exact bug this task fixes (`င်္င` is unattested — the
  homorganic nasal before a velar IS the kinzi, so nga-over-nga is
  orthographic nonsense). The replacement pin lives in
  `NgaOnsetKinziInferenceSuite`; the other four sweep members are
  untouched. Not a weakening.
- No perf regression traced to this commit: garbage_incremental p99
  measured 399-400us at 1351fbd (includes this fix; the garbage
  buffer contains `ng` boundaries, so the changed inference code does
  run on it), at parity with pre-pipeline 795465c (389-393us).
