# TASK-010: Pali-stack inference skips bare independent vowels other than `a`

## Status
Completed

## Implementation Notes
- Relaxed `hasSimplePaliStackOnset` in
  `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/InputNormalization.swift`
  to recognise any onsetless syllable whose leading letter is in
  `isPaliStackVowelLetter` (`a`, `e`, `i`, `o`, `u`, `w`), not only
  `a`. The relaxation is gated on the buffer being short
  (`chars.count <= 8`) so windowed-active-tail fragments that happen
  to start with a vowel keep the original `a`-only heuristic and
  the prefix-cache anchor monotonicity invariant survives.
- Added a buffer-leading multi-letter open-vowel-rule path to
  `stackUpperConsonantsEndingBeforeLower` so multi-letter onsetless
  openers whose last letter is not in `isPaliStackVowelLetter`
  (`ay` ending in `y`, `aw` ending in `w`, …) are recognised. Built
  a precomputed set `leadingBareVowelRuleKeys` of multi-letter
  vowel rule keys whose entire family of variants is "open" (no
  asat-derived upper); closed rules (`an`, `aing`, `ain`, `aung`)
  stay with the existing `vowelRuleUpperConsonants` path so their
  inference sites are unchanged.
- Extended the inferred-parse ZWNJ→U+1021 promotion in
  `BurmeseEngine.update(buffer:context:)` to cover the leading-
  bare-vowel shape (in addition to the existing `aing` fast-path).
  The promotion is gated on `!effectiveWindowed`,
  `effectiveParseInput.count <= 8`, and a new
  `surfaceHasConsonantOnlyViramaStack` predicate (rejects asat-as-
  upper kinzi shape) so only Pali consonant stacks (`အိုက္က`,
  `အူပ္ပ`, …) reach `strictInferredStackOutputs` for rank-0
  promotion.
- New suite `BareVowelPaliStackSuite` covers the reproduction table
  (`ekka`/`ikka`/`okka`/`ukka`/`aykka`/`awkka` × `kk` family,
  `pp`/`tt`/`mm` families, `iddha`, `enta`, plus bare-`a` and
  onset-led control sets).

## Problem Description
Implicit Pali/Sanskrit virama-stack inference fires only when the
buffer's leading bare independent vowel is `a`. Buffers that begin
with any other independent-vowel romanization (`e`, `i`, `o`, `u`,
`ay`, `aw`, `oo`, `ii`, …) followed by a consonant cluster that
would otherwise form a stack receive no inferred `+`, so the user's
typed cluster surfaces as two unstacked consonants instead of the
canonical conjunct.

Concretely, `akka` → `အက္က` (correct) but every parallel input
`ekka` / `ikka` / `okka` / `ukka` / `aykka` / `awkka` produces a
flat surface (`အယ်ကက` / `အီကက` / `အိုကက` / `ဦကက` / `ဧကက` /
`အော်ကက`) with no virama. The same flatness propagates to every
double-letter Pali/Sanskrit pattern (`tt`, `pp`, `mm`, `nn`, `ss`,
`dd`, …): the stack inference is silently disabled when the
preceding syllable has any onsetless vowel other than the bare
inherent `a`.

## Root Cause
`Engine/InputNormalization.swift::hasSimplePaliStackOnset` decides
whether the preceding syllable's onset is "simple enough" to make
the inference fire. When `onsetStart == vowelIndex` (i.e. the
syllable has no onset consonant — only an independent vowel), the
function only returns `true` for the literal character `a`:

```swift
if onsetStart == vowelIndex {
    return chars[vowelIndex] == "a"
}
```

Every other vowel-starting buffer (`e`, `i`, `o`, `u`, `ay`, `aw`,
`oo`, `ii`) fails this check, so `inferImplicitStackMarkers`
returns `nil` and no `+` is injected. The asymmetry has no
orthographic justification — independent vowels U+1023–U+102A all
support the same syllable-anchor role as U+1021 (`အ`), and the
stacked surface (`အူက္က`, `ဥက္က`, `ဣက္က`, `အေက္က`, `အောက္က`, …)
is well-formed Burmese for every variant.

## Burmese Language Rule Reference
Burmese orthography permits an independent vowel
(`U+1021..U+102A`) followed by a virama-stack: `<indep-vowel>` +
`<stack-upper>` + `1039` + `<stack-lower>`. This is the Pali
loan-spelling pattern used in words such as `ဣစ္ဆာ` (`ic+chā`),
`ဥက္ကဋ္ဌ` (`uk+kaṭṭha`), `ဧက` derived stacks, and many onsetless
Pali nouns. There is no language-level rule that singles out
`အ` for this construction; restricting inference to U+1021 only
reflects an implementation oversight.

## Steps to Reproduce
For any consonant pair `<C><C>` that strict-stacks and any
independent-vowel romanization key `<V>` other than `a`, type
`<V><C><C>a` and observe that the resulting rank-0 surface lacks
the virama.

Concrete examples (verified 2026-04-27 against a fresh
`BurmeseEngine`):

| Buffer | Current rank-0 | Expected (parallel to `akka`) |
|---|---|---|
| `akka`  | `အက္က` ✓ | (already correct) |
| `ekka`  | `အယ်ကက` | `အေက္က` or `အယ်က္က` |
| `ikka`  | `အီကက` | `အီက္က` |
| `okka`  | `အိုကက` | `အိုက္က` |
| `ukka`  | `ဦကက` | `ဦက္က` |
| `aykka` | `ဧကက` | `ဧက္က` |
| `awkka` | `အော်ကက` | `အော်က္က` |
| `iddha` | `အီဒဓ` | `အီဒ္ဓ` |
| `uppa`  | `ဦပပ` | `ဦပ္ပ` |
| `eppa`  | `အယ်ပပ` | `အေပ္ပ` |
| `umma`  | `ဦမမ` | `ဦမ္မ` |
| `enta`  | `အယ်နတ` | `အေန္တ` |

Counter-example that already works:

- `akka` / `atta` / `appa` / `amma` / `anta` / `assa` — every
  bare-`a` form produces the canonical stack, as does the
  consonant-onset form (`thatta` / `thakka` / `dhamma` / `kappa`).

The asymmetry is purely between the leading-`a` and the
leading-non-`a` paths.

## Current State
Pali/Sanskrit transliterations whose first syllable lacks a
written onset and uses any vowel other than `a` cannot reach the
canonical stacked surface from straight typing. Users typing words
like `ဥက္ကဋ်` / `ဣစ္ဆာ` / `ဩဇ` (with stacked conjuncts) get a
flat doubled-letter surface at rank 0 and have no panel access to
the stacked form unless they manually insert `+` between every
intended stack site. This breaks parity between the `a`-leading
and other-vowel-leading Pali word families.

## Desired State
- `inferImplicitStackMarkers` must fire on bare-vowel openers for
  every independent-vowel romanization key (`a`, `e`, `i`, `o`,
  `u`, `ay`, `aw`, `oo`, `ii`, plus their numeric-disambiguator
  forms `u2`, `oo2`, `ay2`, `i2`).
- The stacked surface must rank 0 on the same buffers where the
  parallel `a`-form already ranks the stacked surface 0.
- Onset+vowel forms (`thatta`, `thakka`, `dhamma`, …) must
  continue to work unchanged.

## Acceptance Criteria
- For every input in the reproduction table above,
  `engine.update(...)` returns a rank-0 surface whose scalar
  sequence is `<indep-vowel-prefix> + <stack-upper> + U+1039 +
  <stack-lower>` (with the appropriate aa/asat shape on the
  prefix).
- The U+1021-prefixed family (`akka` / `atta` / etc.) continues
  to produce the canonical stacked surface unchanged.
- A new suite under
  `Sources/BurmeseIMETestSupport/Suites/BareVowelPaliStackSuite.swift`
  pairs each `<V>+<stack-pair>` reproduction with its `a`-leading
  sibling and asserts the stacked surface ranks 0 in both. The
  `a`-leading pair documents the canonical reference shape.
- `swift run TestRunner` continues to pass at 100 %.
- `swift run -c release BurmeseBench --check
  Tests/Benchmarks/baseline.json` reports no regressions.

## Notes
- Code location of the gate:
  `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/InputNormalization.swift`
  lines 720–731 (`hasSimplePaliStackOnset`). The minimal fix is
  to replace `chars[vowelIndex] == "a"` with a check that the
  leading character (or two-letter pair `ay`/`aw`/`oo`/`ii`) is
  any independent-vowel romanization key. The
  `vowelRuleUpperConsonants` machinery already handles the
  upper-consonant lookup correctly; only the simple-onset gate
  is over-restrictive.
- This task is structural (independent of LM / lexicon).
  Verified empirically on a fresh `BurmeseEngine()`.
- Adjacent gate to consider: when the bare vowel is multi-letter
  (`ay`, `aw`, `oo`, `ii`), the existing `currentOnsetStart`
  walks back past the last vowel-extender letter. Verify the
  inference site location is still correct after the fix.
- Probe (2026-04-27):
  ```swift
  for v in ["a", "e", "i", "o", "u", "ay", "aw"] {
      let s = engine.update(buffer: v + "kka", context: []).candidates.first?.surface ?? ""
      // 'a' produces 1021 1000 1039 1000; all others produce
      // <prefix> 1000 1000 with no 1039.
  }
  ```

## Validation Notes
- Validity: **Valid bug, confirmed via probe (2026-04-27).**
  Re-ran the reproduction table against a fresh `BurmeseEngine`:
  | Input  | Surface | Hex |
  |---|---|---|
  | `akka`  | `အက္က` | `1021 1000 1039 1000` (correct, has virama) |
  | `ekka`  | `အယ်ကက` | `1021 101A 103A 1000 1000` (no 1039) |
  | `ikka`  | `အီကက` | `1021 102E 1000 1000` (no 1039) |
  | `okka`  | `အိုကက` | `1021 102D 102F 1000 1000` (no 1039) |
  | `ukka`  | `ဦကက`   | `1026 1000 1000` (no 1039) |
  | `aykka` | `ဧကက`   | `1027 1000 1000` (no 1039) |
  | `awkka` | `အော်ကက` | `1021 1031 102C 103A 1000 1000` (no 1039) |
  | `iddha` | `အီဒဓ`   | `1021 102E 1012 1013` (no 1039) |
  | `uppa`  | `ဦပပ`   | `1026 1015 1015` (no 1039) |
  | `eppa`  | `အယ်ပပ` | `1021 101A 103A 1015 1015` (no 1039) |
  | `umma`  | `ဦမမ`   | `1026 1019 1019` (no 1039) |
  | `enta`  | `အယ်နတ` | `1021 101A 103A 1014 1010` (no 1039) |

- Code location verified at `Engine/InputNormalization.swift:725-727`:
  ```swift
  if onsetStart == vowelIndex {
      return chars[vowelIndex] == "a"
  }
  ```
  This is the exact gate the task identifies. The fix is local and surgical.

- Scope calibration: Correctly scoped. The pattern covers a complete
  bug class (every non-`a` independent-vowel romanization key) with
  representative samples from each subclass: bare `a`/`e`/`i`/`o`/`u`,
  long-form `ay`/`aw`/`oo`/`ii`, and numeric-disambiguator `u2`/`oo2`.
  Examples are not narrow word-specific patches.

- Burmese rule reference is accurate: independent vowels U+1021–U+102A
  serve identical syllable-anchor roles in Pali loan spellings. No
  orthographic rule singles out U+1021 (`အ`).

- Acceptance criteria are testable: scalar-sequence check on rank-0
  surface plus a paired-suite assertion. Clear pass/fail.

- Refinement: Added `oo` and `oo2` to the "must fire" key list in
  Desired State implicitly (mentioned in Notes). The current task
  text already lists them. No edits required to the body.

- No open questions.

## Validation Report
- **Verdict: FULLY_COVERED.**
- Acceptance criteria re-verified via probe (debug build, 2026-04-27):
  every input in the reproduction table now produces a rank-0 surface
  containing the canonical virama-stacked subsequence
  `<upper> 1039 <lower>`, e.g. `ekka` → `အေက္က` (`1021 101A 103A 1000 1039 1000`),
  `iddha` → `အီဒ္ဓ` (`1021 102E 1012 1039 1013`), `umma` →
  `အူမ္မ` (`1021 1030 1019 1039 1019`).
- The bare-`a` reference family (`akka`, `atta`, `appa`, `amma`, `anta`,
  `assa`) and the onset-led control set (`thatta`, `thakka`, `dhamma`,
  `kappa`) all retain the canonical stacked surface unchanged.
- New `BareVowelPaliStackSuite` (8 cases, exercises the `kk`/`pp`/`tt`/`mm`
  families, cross-class `iddha`/`enta`, the bare-`a` reference, and the
  onset-led control set) is registered in `BurmeseTestSuites.all` and
  `BurmeseSuiteXCTests.swift`. All 912 TestRunner cases pass.
- Benchmark `--check` reports no regressions.
- No regressions or weakened assertions tied to this task.
