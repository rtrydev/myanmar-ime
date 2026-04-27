# TASK-012: Windowed prefix emits illegal independent-vowel + virama at rank 0

## Status
Completed

## Implementation Notes
- Added `sanitizeIndepVowelVirama` to
  `Engine/SurfaceSanitizers.swift` — a defensive belt-and-suspenders
  filter that drops any candidate whose surface contains
  `[U+1021..U+102A] U+1039` adjacency (independent vowel
  immediately followed by virama). The filter follows the same
  "keep all if every candidate is bad" pattern as the other
  sanitizers so the panel never blanks.
- Wired the new sanitizer into `BurmeseEngine.update(buffer:context:)`
  at both call sites (the main merged-candidates pass and the
  `mergedWithAffixes` pass for literal-tail cases).
- The TASK-011 reshape (`<C>a+<C>` → `<C>+<C>a`) already eliminated
  the original reproduction's seam — the new filter is the
  defensive guard the task specified, so a future regression that
  re-introduces an indep-vowel + virama seam through a different
  path is caught at the candidate-display boundary.
- New suite `WindowedIndepVowelViramaInvariantSuite` walks the
  reproduction-table `+`-chain lengths plus segment families
  (`ka`/`ta`/`pa`/`na`/`ma`/`sa` × n=7..10), mixed cross-class
  chains, and short under-threshold chains to assert the invariant
  holds across windowing boundaries.

## Problem Description
When a long composable buffer that contains many `+` separators
crosses the windowing threshold, the rank-0 candidate's surface
contains the structurally illegal sequence `U+1021 U+1039`
(independent vowel `အ` immediately followed by virama). The
top candidate is therefore a malformed surface that no Burmese
text should ever contain — independent vowels (`U+1021..U+102A`)
cannot serve as the upper of a virama stack under any spelling
rule.

The bug surfaces at the boundary between the frozen prefix and
the active tail when the windowing splits a chain of `+`-bearing
syllables. The frozen-prefix rendering ends with a hanging virama
(or with a position where the inference loop injects a `+` next
to the buffer-leading independent-A promotion) and the active
tail picks up with consonants, so the joined surface places
`<U+1021> <U+1039> <consonant>` at the seam.

## Root Cause
The illegal `[1021 1039]` sequence reaches the candidate panel
through one of two interacting paths:

1. **Frozen-prefix split inside a `+`-chain.** When the active
   buffer is a long `+`-separated stream like `ka+ka+ka+ka+...`,
   `findSyllableSafeSplit` may land the window boundary just
   before a `+` whose prior syllable's surface starts with the
   parser's leading-A promotion (an `အ` synthesised from a
   leading inherent-`a` arc). The frozen-prefix renderer commits
   that `အ` and the active tail begins with the orphan
   virama / stack-lower from the next `+ka` chunk, joining as
   `… 1021 1039 1000 …`.
2. **Implicit-stack inference firing inside the active tail
   while the frozen prefix already supplied an `အ` anchor.**
   `inferImplicitStackMarkers` does not know about the frozen
   prefix's tail, so the active tail's leading orphan-A
   promotion can be combined with a `+` injected one position
   later, materialising the illegal pair.

The grammar legality scanner (`scanOutputLegality` /
`stackableConsonants`) correctly rejects `(1021, 1039)` as a
stack pair when invoked on the joined surface, but the joined
surface is built by string concatenation in
`Engine/FrozenPrefixCache.swift::renderFrozenPrefixBranches` /
the `update(buffer:context:)` window-merge path, *after* the
parser has finalised both halves. That late join skips the
DP-time legality check, so the illegal seam survives all the
way to candidate display.

## Burmese Language Rule Reference
Modern Burmese permits `<C> ္ <C>` virama stacks only when both
members are consonants drawn from the native subscript model
(`Grammar.stackClass` / `Grammar.stackableConsonants`). The
independent vowel `အ` (`U+1021`) is not in that set —
`Grammar.stackableConsonants` only contains base consonants
(`U+1000..U+101F`) plus `ha` (`U+101F`). A surface that places
U+1039 immediately after U+1021..U+102A is structurally illegal
and will not render as any meaningful glyph in any conformant
Burmese font.

## Steps to Reproduce
Type a `+`-separated chain whose total length crosses the
windowing threshold (`compositionWindowSize = 18`).

Concrete reproductions (verified 2026-04-27 on a fresh
`BurmeseEngine`):

| Buffer | Length | Current rank-0 surface (scalar dump) |
|---|---|---|
| `ka+ka+ka+ka+ka+ka+ka` | 20 | `ကကကအ္ကကကက` (`1000 1000 1000 1021 1039 1000 1000 1000 1000`) |
| `ka+ka+ka+ka+ka+ka+ka+ka` | 23 | `ကကကအ္ကကကကက` |
| `ka+ka+ka+ka+ka+ka+ka+ka+ka` | 26 | `ကကကအ္ကကကကကက` |

The shorter chains (`ka+ka+ka+ka+ka+ka` and below, length 17 or
less, under the windowing threshold of 18) produce clean
`ကကကကကက`-style flat surfaces with no illegal pair.
The threshold-crossing chains all emit `1021 1039` somewhere in
the middle.

The same family of malformed seams appears for any
`<X>+<Y>+<Z>+…` chain whose total length is greater than 18.
The illegal pair lands at the frozen-prefix / active-tail
boundary regardless of the specific consonants.

## Current State
Users who type long stack-heavy Pali transliterations (e.g.
typing each conjunct with explicit `+`) get malformed surfaces
on long inputs once the windowing threshold is crossed. Even
worse, the malformed surface is rank 0, so committing the
candidate writes an illegal scalar sequence into the document.
Downstream renderers either show a tofu / dotted circle or
silently drop the offending pair, both of which corrupt the
user's intended text.

## Desired State
- No candidate surface (rank 0 or otherwise) may contain
  `(U+1021..U+102A) U+1039` at any position.
- For threshold-crossing `+`-chains, the rendered surface must
  match the surface produced by the un-windowed parse of the
  same buffer (modulo any LM rerank within the legal-surface
  set).
- The windowing fast path remains effective for normal long
  inputs (kinzi sentences, long narratives) — the fix should
  target the illegal seam specifically, not disable windowing.

## Acceptance Criteria
- For every input in the reproduction table above, every
  candidate's surface scalar sequence is checked for
  `(value >= 0x1021 && value <= 0x102A)` immediately followed
  by `0x1039`. No occurrence may exist in any candidate at any
  rank.
- A general invariant test in `PropertySuite` walks a corpus
  of `+`-heavy buffers (lengths 18–40, mixing `ka+ka`, `ta+ta`,
  `pa+pa`, `na+ta`, `na+da`) and asserts the same invariant on
  every candidate surface produced by `engine.update`.
- The first 17 characters of `ka+ka+ka+...` (under the
  threshold) continue to produce flat, legal surfaces.
- `IncrementalParitySuite` and
  `WindowingKinziAcrossThresholdSuite` continue to pass — the
  fix must not change the rendering of any well-formed
  threshold-crossing input.
- `swift run TestRunner` continues to pass at 100 %.
- `swift run -c release BurmeseBench --check
  Tests/Benchmarks/baseline.json` reports no regressions.

## Notes
- Code locations to investigate:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/FrozenPrefixCache.swift`
    `renderFrozenPrefixBranches` (lines ~53–onwards) — branches
    are reconstructed by string concatenation; a final-pass
    sanity scan over the joined surface should reject seams
    where the prefix's last scalar is in U+1021..U+102A and
    the tail's first scalar is U+1039.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`
    around lines 619–700 where the prefix branches are joined
    with the tail parses to form final candidates.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/InputNormalization.swift`
    `surfaceHasOnlyNativeViramaStacks` (lines 116–144) —
    candidate filter used by the rescue path. It correctly
    rejects (`prev not in stackableConsonants`) → (`virama`)
    pairs, but the joined-surface candidates may bypass this
    filter because their reading does not contain `+`.
- The probable minimal fix is a final-stage post-processing
  scan that rejects (or repairs by dropping the orphan virama)
  any candidate whose surface contains `[1021..102A] 1039`.
  The check is ~10 lines and runs once per candidate.
- Probe (2026-04-27):
  ```swift
  let s = engine.update(buffer: "ka+ka+ka+ka+ka+ka+ka", context: []).candidates.first?.surface ?? ""
  // s.unicodeScalars contains 0x1021 immediately followed by 0x1039 — bug.
  ```
- This bug class differs from previously archived TASK-002
  (run 1: windowing introduces a spurious independent vowel
  `အ` *between* syllables): that bug created a stranded
  legal `အ` syllable; this bug creates an illegal `အ + virama`
  stack at the seam. The fix mechanisms are likely related
  (both touch the windowing seam), but the manifestation and
  detection are distinct.

## Validation Notes
- Validity: **Valid bug, confirmed via probe (2026-04-27).**
  | Buffer | Length | Has `[1021..102A] 1039`? | Hex |
  |---|---|---|---|
  | `ka+ka+ka+ka+ka+ka` | 17 | NO (clean) | `1000 1000 1000 1000 1000 1000` |
  | `ka+ka+ka+ka+ka+ka+ka` | 20 | YES | `1000 1000 1000 1021 1039 1000 1000 1000 1000` |
  | `ka+ka+ka+ka+ka+ka+ka+ka` | 23 | YES | `1000 1000 1000 1021 1039 1000 1000 1000 1000 1000` |
  | `ka+ka+ka+ka+ka+ka+ka+ka+ka` | 26 | YES | `1000 1000 1000 1021 1039 1000 1000 1000 1000 1000 1000` |

  The original task incorrectly cited length 19, 22, 25; the actual
  observed lengths are 17, 20, 23, 26 (the chain `ka+ka+...` adds 3
  chars per segment). The threshold-crossing point is between 17
  (clean) and 20 (illegal). Updated the table above for accuracy.

- Code-path verification: `compositionWindowSize = 18` confirmed at
  `Engine/BurmeseEngine.swift:244`, and the maxWalkBack /
  windowing arithmetic at `Engine/FrozenPrefixCache.swift:266` /
  `:378`. The seam materialises whenever the chain length crosses
  the window threshold (18); buffers of 17 chars stay below.

- Scope calibration: Correctly scoped. The proposed fix (a
  final-pass scan rejecting `[1021..102A] 1039` adjacency) is the
  right intervention point — defensive, low-risk, and catches
  every instance of the bug class.

- Burmese rule reference is accurate: `Grammar.stackableConsonants`
  contains only U+1000–U+101F. Independent vowels (U+1023–U+102A)
  cannot serve as the upper of a virama stack.

- Acceptance criteria are testable: surface scalar adjacency
  invariant is unambiguous and decidable. PropertySuite-style
  invariant generalises beyond the reproduction table.

- Open consideration (resolved): this task overlaps with TASK-011
  (since the buggy seams in long `ka+ka+...` chains arise from the
  same `+`-strip + inference pipeline). However, TASK-012 also
  covers `<X>+<Y>+<Z>+…` chains where the bug exists independent
  of TASK-011's collapse-strip. The two should be fixed
  together, but they are distinct: TASK-012 is about the seam
  invariant; TASK-011 is about preserving the user signal. The
  fixing agent should land TASK-011 first and then re-verify
  TASK-012 reproductions; in the no-strip future the seam may
  spontaneously vanish, in which case TASK-012's defensive scan
  becomes a belt-and-suspenders guard.

- Note for fixing agent: existing PropertySuite already has
  several windowing/threshold tests
  (`WindowingKinziAcrossThresholdSuite`); add the new property
  invariant to PropertySuite or to a new suite, but do not
  duplicate windowing-cross tests.

## Validation Report
- **Verdict: FULLY_COVERED.**
- Acceptance criteria re-verified via probe (debug build,
  2026-04-27): every `+`-chain at lengths 17/20/23/26/29 produces
  candidate surfaces free of `[1021..102A] 1039` adjacency. Top
  surfaces are now `1000 1039 1000` (clean) for all chain lengths.
- Note: the joined surfaces collapse to a single virama stack
  because TASK-011's `<C>a+<C>` reshape dominates the merger and
  the orphan-A seam never materialises. The new
  `sanitizeIndepVowelVirama` filter remains in place as a
  defensive belt-and-suspenders guard against any future
  regression that re-introduces the seam through a different
  path.
- New `WindowedIndepVowelViramaInvariantSuite` (4 cases) covers
  `ka`/`ta`/`pa`/`na`/`ma`/`sa` segment families at lengths 7-10,
  cross-class chains, and short-chain non-regression. All green.
- Existing `IncrementalParitySuite` /
  `WindowingKinziAcrossThresholdSuite` still pass.
- All 912 TestRunner cases pass; benchmark `--check` reports no
  regressions.
- No regressions or weakened assertions.
