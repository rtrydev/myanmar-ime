# TASK-045: Implicit kinzi inference is fully suppressed when ANY explicit `+` is present in the buffer, breaking panel reachability for kinzi-bearing prefixes followed by an explicit syllable boundary

## Status
Completed

## Implementation Notes
- **`Engine/InputNormalization.swift`** — Replaced the
  `guard !input.contains("+") else { return nil }` early-out at line
  660 with a per-`+`-segment dispatcher
  (`inferImplicitStackMarkersAcrossPlusSegments`). The dispatcher
  splits `input` on `+`, runs the existing inference body on each
  segment with offset-translated `digitBoundaries`, and reassembles
  the per-segment results — preserving every user-typed `+` plus
  every site the engine inferred inside each segment. Aggregate
  insertion counts (`insertions` / `liberalInsertions` /
  `vowelRuleLiberalInsertions` / strict-only / promotable-only) are
  the sums of the per-segment counts; `strictOnlyInput` and
  `promotableOnlyInput` reassemble piecewise so a segment that
  produced a variant contributes that variant and a segment that did
  not contributes its full inferred form.
- **`Engine/InputNormalization.swift::inferredEndsInBareStackableLower`**
  — TASK-011's `<C>a+<C>` → `<C>+<C>` reshape strips the inherent
  `a` before every user-typed `+`, so input `minga+ka` arrives at
  this function as `ming+ka`. After the per-segment dispatcher
  inserts `+` inside `ming` (yielding `min+g`) and reassembles, the
  resulting `min+g+ka` would chain two virama-stacks across `g` and
  produce a malformed double-virama surface. The new helper detects
  this case (the segment's inferred input ends with `+<stackable
  consonant letter>` and the next segment starts with a stackable
  consonant) and re-inserts the inherent `a` between the inferred
  lower and the user's `+`. The reassembled buffer becomes
  `min+ga+ka`, the parser materialises kinzi on the inferred side,
  and the user's `+` falls through the `softBoundaryContext` gate
  as a syllable break (since virama cannot bond to a vowel-bearing
  upper).
- **`Engine/BurmeseEngine.swift::ingestInferredParses`** — Added a
  third preserve branch that catches inferred parses whose surface
  carries a kinzi triple (`1004 103A 1039`) but also carries a
  user-typed cross-class virama. Buffers like `ka+minga` reshape
  to `k+minga`; per-segment inference yields `k+min+ga`; the parser
  materialises `က္မင်္ဂ` (cross-class `k+m` virama AND canonical
  kinzi). The strict `surfaceHasOnlyNativeViramaStacks` check rejects
  the surface because of the cross-class `k+m`, so without an extra
  branch the LM-margin prune drops the kinzi-bearing candidate from
  the panel. The new branch routes such surfaces into
  `liberalKinziOutputs` so they survive pruning without being
  promoted to rank 0.
- **New test suite `PlusDisjointKinziInferenceSuite`** — Covers all
  bug-class buffers from the *Steps to Reproduce* table on both bare
  and production-equivalent engines, asserts the kinzi triple is
  present in the panel for every `<C>(in|an|on)<...>+<...>` and
  `<...>+<C>(in|an|on)<...>` shape, and verifies the per-segment
  inference helper emits the expected `min+ga`-bearing rewrite for
  each input class. Also includes a regression guard for the
  TASK-031 explicit-`+` rank-0 promotion (`min+ga` keeps kinzi at
  rank 0).

## Problem Description
When the user types a kinzi-prone shape (`<C>inga`, `<C>anga`,
`<C>onga`, …) followed by an explicit `+` syllable boundary at any
later position in the buffer (e.g. `minga+lar`, `tinga+thar`,
`thaungminga+lar`, `ka+minga+lar`), the kinzi-bearing surface is
**absent from the entire candidate panel** — not just demoted from
rank 0. The same shape without the trailing `+` (`minga`,
`tinga`, `thaungminga`) renders the kinzi correctly at rank 0 with
multiple kinzi-bearing siblings in the panel.

This is a panel-reachability bug, not a ranking issue. There is no
candidate the user can pick that produces the kinzi cluster
`င်္` (U+1004 U+103A U+1039) anywhere in the surface. The user has
no way to reach the canonical Burmese spelling for any compound
word that contains a kinzi-bearing morpheme followed by an explicit
syllable break.

The bug also fires when the explicit `+` precedes the kinzi-prone
syllable: `ka+minga` produces no kinzi candidate even though the
kinzi inference site (`n+g` within `minga`) is wholly to the right
of the user's `+`. The presence of any `+` anywhere in the buffer
disables the inference globally.

## Root Cause
`Engine/InputNormalization.swift::inferImplicitStackMarkers` (line
647) returns `nil` immediately when the input contains any `+`:

```swift
guard !input.contains("+") else { return nil }
```

This is the function that emits the kinzi-bearing reshape (e.g.
`minga` → `min+ga`) for the parser to consume. With the function
short-circuited, the parser only sees the literal buffer
(`minga+lar` → `m`, `i`, `n`, `g`, `a`, `+`, `l`, `a`, `r`), which
admits the no-kinzi parse `မင်ဂလာ` but never the kinzi parse
`မင်္ဂလာ`. The TASK-031 explicit-`+` rank-0 promotion does not
help here because it operates over parses whose reading exactly
matches the user's literal input — the kinzi parse's reading would
be `min+ga+lar`, which does not match the user's `minga+lar`.

The early-out was historically defensible: when the user types
`+`, they are placing every stack site themselves, so the
engine's implicit-stack inference is presumed redundant. That
assumption breaks down whenever the implicit-stack site is
**disjoint** from the user's `+` site. The `+` between `lar` and
its predecessor in `minga+lar` says nothing about whether `n+g`
inside `minga` should also kinzi.

A correct fix would either:

1. Run `inferImplicitStackMarkers` on each `+`-delimited segment
   independently and reassemble, or
2. Treat the user's `+` as additive (every position the user
   marked + every position the engine infers) rather than
   exclusive (skip inference if any `+` is present).

## Burmese Language Rule Reference
Kinzi (`င်္`, U+1004 U+103A U+1039) is the orthographic
realisation of `ng + ္ + <stackable>` in modern Burmese. It is
the only legal stack shape when the upper consonant is `င` (nga).
Words like `မင်္ဂလာ` (auspicious / `mingalar`), `သင်္ဂီတ`
(music / `thingiha`), `တင်္သန်း` (`tinghan`), `ရင်္ဂ` (stage),
and `ပင်္ကု` (kingdom) all carry kinzi at the morpheme boundary.
A user typing `မင်္ဂလာပါ` (`mingalarpar`, "hello") and breaking
it as `minga+lar+par` to mark word-internal syllable boundaries
must be able to reach `မင်္ဂလာပါ` from the panel.

The user's `+` is a *syllable boundary marker*, orthogonal to
whether the boundary itself is a stack site. A user typing
`<word with kinzi>+<particle>` is asking for two units: the
word (with its internal kinzi) and the particle. Suppressing
the internal kinzi inference because the user added a particle
boundary is a category error.

## Steps to Reproduce
With the production-equivalent engine (bundled SQLite lexicon +
trigram LM), evaluate any of the following buffers and inspect
the candidate panel for surfaces containing the scalar triple
`U+1004 U+103A U+1039` (kinzi):

| Buffer | Kinzi in top 10? | Rank-0 surface (production-equivalent) |
|---|---|---|
| `minga` | yes | `မင်္ဂ` (kinzi) |
| `minga+lar` | **no** | `မင်ဂလာ` (no kinzi) |
| `minga+lar+par` | **no** | `မင်ဂလာပါ` (no kinzi) |
| `minga+ka` | **no** | `မည်င္က` (no kinzi; bare engine: `မင်ဂ္က`) |
| `tinga+lar` | **no** | `တီငလာ` (no kinzi; bare engine: `တင်ဂလာ`) |
| `tinga+thar` | **no** | `တီငသာ` (no kinzi; bare engine: `တင်ဂသာ`) |
| `thaungminga` | yes | `သောင်မင်္ဂ` (kinzi present) |
| `thaungminga+lar` | **no** | `သောင်မင်ဂလာ` (no kinzi) |
| `ka+minga` | **no** | `ကမင်ဂ` (no kinzi) |
| `ka+minga+lar` | **no** | `ကမင်ဂလာ` (no kinzi) |

For comparison, `min+ga+lar` (explicit `+` AT the kinzi site)
correctly produces `မင်္ဂလာ` because the parser receives the
explicit stack marker.

Direct probe (panel-reachability test):

```swift
import BurmeseIMECore
import BurmeseIMETestSupport
let engine = BurmeseEngine(
    candidateStore: SQLiteCandidateStore(path: BundledArtifacts.lexiconPath!)!,
    languageModel: try TrigramLanguageModel(path: BundledArtifacts.trigramLMPath!)
)
let r = engine.update(buffer: "minga+lar", context: [])
let hasKinzi = r.candidates.contains { surface in
    let s = Array(surface.surface.unicodeScalars).map(\.value)
    for i in 0..<max(0, s.count - 2) where s[i] == 0x1004 && s[i+1] == 0x103A && s[i+2] == 0x1039 {
        return true
    }
    return false
}
// hasKinzi == false (bug)
```

## Current State
For every kinzi-prone prefix (`<C>inga`, `<C>anga`, `<C>onga`,
…) followed elsewhere in the buffer by `+`, the kinzi spelling
is unreachable. The user is forced to either:

1. Type the explicit kinzi at the kinzi site itself (`min+ga+lar`
   instead of `minga+lar`), which is a foreign keyboarding habit
   and inconsistent with the unboundary-form (`mingala…`) where
   the user does not insert any `+`.
2. Fall back to the no-kinzi spelling `မင်ဂလာ`, which is
   orthographically incorrect for this morpheme.

## Desired State
- The kinzi-bearing surface for the implicit-stack-bearing
  segment must appear in the candidate panel (top 3 strongly
  preferred per CLAUDE.md "general reachability rule") for every
  `<kinzi-prone-prefix>+<...>` and `<...>+<kinzi-prone-prefix>`
  buffer.
- Rank-0 promotion of the kinzi form is desirable but not
  strictly required; panel presence (any rank ≥ 1) satisfies the
  reachability bar.
- The fix must not regress the existing TASK-031 behaviour: when
  the user explicitly types `+` AT the kinzi site (`min+ga`),
  the kinzi parse must still win rank 0.
- The fix must not regress windowed buffers (TASK-005 / TASK-044):
  long buffers where the implicit kinzi was inferred in a
  previously-rendered prefix must still keep that kinzi as the
  buffer grows.

## Acceptance Criteria
- A new test suite (production-equivalent, using the
  `BundledArtifacts` helper pattern) covers the bug-class
  buffers from the *Steps to Reproduce* table. For each buffer,
  assert that **at least one** candidate in the top 10 carries
  the kinzi triple `U+1004 U+103A U+1039`.
- For the same buffers, assert that the kinzi-bearing surface
  contains the same morpheme (e.g. `မင်္ဂ` for any `<...>minga<...>`
  buffer) as the kinzi-rendered counterpart of the no-`+` shape
  (`minga` → `မင်္ဂ`).
- All existing kinzi suites stay green:
  `MingalarKinziLongBufferSuite`, `ExplicitPlusKinziDisplacementSuite`,
  `WindowingKinziAcrossThresholdSuite`,
  `WindowingKinziPromotionSuite`, `KinziInferenceSuite`,
  `KinziTallAaSuite`, `AnchorStabilitySuite`,
  `LangKinziSuite`, `DoubledLetterKinziSuite`.
- `swift run TestRunner` continues to pass at 100 percent.
- `swift run -c release BurmeseBench --check
  Tests/Benchmarks/baseline.json` reports no regressions. The
  inference fast-path on the no-`+` hot path must not regress
  measurably; the new work only fires on `+`-bearing buffers.

## Notes
- Relevant code locations:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/InputNormalization.swift:660`
    — the `guard !input.contains("+") else { return nil }`
    early-out that this task removes / replaces.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift:1136`
    — primary site that calls `inferImplicitStackMarkers`.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/FrozenPrefixCache.swift:115`
    — the windowed/cached path also calls into the inference;
    must continue to work.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift:1299`
    — TASK-031 explicit-`+` rank-0 promotion. Coexists with the
    fix; do not regress.
- Suggested implementation sketch:
  - Split the input on `+`, run `inferImplicitStackMarkers` on
    each segment independently, and reassemble with `+`
    separators preserved. Each per-segment insertion count
    contributes to the aggregate `insertions` /
    `liberalInsertions` totals returned by the function.
  - Alternative: a single-pass scan that augments — rather than
    replaces — the user's `+` positions with inferred sites at
    every kinzi-prone `<C>inga / Cangs / Conga` boundary
    elsewhere in the buffer.
- Bug verified 2026-05-10 against current `main` (commit
  `714d9cc`) on production-equivalent engine and on bare engine
  (which also misses the kinzi for the same buffers — confirms
  the bug is in the parser-input shaping path, not in the
  ranker).

## Validation Notes
- **Verdict: valid.** Bug reproduces on both bare and production
  engines exactly as described. The line-660 early-out is the
  smoking gun and the suggested fix shape (per-segment inference
  or additive scan) is sound. All 10 inputs in the *Steps to
  Reproduce* table behave as documented.
- **Refinements made:** Updated the rank-0 surface table to note
  that bare-engine surfaces differ from production-equivalent for
  three rows (`minga+ka`, `tinga+lar`, `tinga+thar`). The bug is
  the same (kinzi missing); only the no-kinzi rendering differs
  between engine layers because the LM picks a different
  no-kinzi sibling at rank 0.
- **Scope:** Correctly scoped. The example set already covers the
  general class (`<C>inga`/`anga`/`onga` shapes both before and
  after `+`, with single and chained `+`). Examples are not
  word-specific — they exercise the `+`-suppression rule across
  buffer-leading, mid-buffer, and chained-`+` configurations.
- **Acceptance criteria:** Testable as written. The `top 10` cap
  in the criterion is defensible per CLAUDE.md general
  reachability rule (top 3 strongly preferred, panel presence at
  any rank satisfies the bar).
- **Burmese rule reference:** The kinzi description (U+1004 +
  U+103A + U+1039) is correct. The example word `သင်္ဂီတ` is
  correctly transliterated as `thingiha` is dubious — the
  conventional transliteration is `thingita` or `thingiata`. This
  is illustrative only and does not affect the fix; left as-is.
- **Related code paths verified:** Line 660 guard exists in
  `Engine/InputNormalization.swift`. Engine call sites at line
  1136 (primary) and the `FrozenPrefixCache.swift` windowed path
  also call into the inference. TASK-031 explicit-`+` rank-0
  promotion at line 1299 must remain compatible.

## Validation Report
- **Verdict: FULLY_COVERED.**
- Implementation fix at commit `564291c` replaces the line-660
  early-out with a per-`+`-segment dispatcher in
  `inferImplicitStackMarkersAcrossPlusSegments`, plus a kinzi-
  preserving branch in `ingestInferredParses` so cross-class
  virama outputs that also carry kinzi survive the LM-margin
  prune.
- New suite `PlusDisjointKinziInferenceSuite` covers all 8
  bug-class buffers from the *Steps to Reproduce* table (the
  three with no-kinzi rank-0 cells are still asserted in the
  panel-reachability case set), the morpheme-equality assertion
  for `မင်္ဂ`-bearing buffers, the bare-engine equivalents, the
  TASK-031 explicit-`+` rank-0 regression guard, and the
  per-segment inference structural property. All cases pass on
  both bare and production-equivalent engines.
- All AC-required regression-guard suites
  (`MingalarKinziLongBufferSuite`,
  `ExplicitPlusKinziDisplacementSuite`,
  `WindowingKinziAcrossThresholdSuite`,
  `WindowingKinziPromotionSuite`, `KinziInferenceSuite`,
  `KinziTallAaSuite`, `AnchorStabilitySuite`, `LangKinziSuite`,
  `DoubledLetterKinziSuite`) remain green.
- `swift run TestRunner`: 1479/1479 cases, 7387/7387 assertions
  pass.
- `swift run -c release BurmeseBench --check
  Tests/Benchmarks/baseline.json`: no regressions.
- No tests removed, weakened, or suppressed. The only existing
  suite touched in this commit-range is `ExplicitPlusVowelChainSuite`
  (modified by TASK-047, not TASK-045).
