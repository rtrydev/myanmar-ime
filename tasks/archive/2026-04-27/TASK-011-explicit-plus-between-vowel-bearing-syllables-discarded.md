# TASK-011: Explicit `+` between two vowel-bearing syllables is silently discarded with no stack inference

## Status
Completed

## Implementation Notes
- `Engine/InputNormalization.swift::collapseConnectorRuns` now
  reshapes `<C>a+<C>` to `<C>+<C>a` before any other transform.
  The reshape mirrors what
  `inferImplicitStackMarkers` does to the no-`+` doubled-letter
  form (`kakka` → `kak+ka`): the user's inherent-`a` on the upper
  consonant is moved past the `+` and the lower's first letter,
  so the parser's `+`-as-virama path materialises the canonical
  conjunct (`ka+ka` → `k+ka` → `က္က`, etc.).
- New helper `isInherentABearingConsonantLetter` keeps the reshape
  guard tight: only fires when both flanking letters are single-
  letter consonant keys (`k`, `t`, `p`, `n`, `d`, `m`, `s`, …),
  never when the next character is a vowel letter (the existing
  `+`-before-vowel strip rule handles that).
- Existing inputs (`k+ka`, `min+ga`, `bud+da`, `kar+u`, `ang+gar`,
  …) are unaffected because none match the `<C>a+<C>` shape.
- New suite `ExplicitPlusVowelSuite` covers the same-class
  conjuncts (`ka+ka`/`ta+ta`/`pa+pa`/`ma+ma`/`na+ta`/`na+da`),
  chained-stack-lower (`ka+kka`, `ka+kk+a`), cross-class panel
  reachability (`kha+ka`), and the existing `+`-using counter-
  examples that must keep rendering unchanged.

## Problem Description
The IME accepts `+` as the user-facing virama-stack signal
(documented and exercised throughout the suite via inputs like
`k+ka`, `min+ga`, `bud+da`). However, when the user types `+`
between two syllables that each already carry an inherent or
explicit dependent vowel — e.g. `ka+ka`, `ta+ta`, `pa+pa`,
`ka+kka`, `ka+kk+a` — the `+` is unconditionally dropped before
the parser sees it, the implicit Pali-stack inference does not
fire on the joined buffer, and the resulting surface contains no
virama.

The asymmetry is jarring because the same intent expressed without
the explicit separator (`kakka`, `kakk`, `kakka`) DOES trigger
implicit inference and DOES produce the stacked surface (`ကက္က`).
The user's explicit signal is therefore strictly worse than typing
nothing — it actively suppresses the inference that would have
fired without it.

## Root Cause
`Engine/InputNormalization.swift::collapseConnectorRuns` strips
every `+` whose successor is a vowel character (`a`, `e`, `i`,
`o`, `u`):

```swift
let vowelLeaders: Set<Character> = ["a", "e", "i", "o", "u"]
…
if chars[i] == "+", i + 1 < chars.count, vowelLeaders.contains(chars[i + 1]) {
    i += 1
    continue
}
```

This is sound in isolation — virama before a standalone vowel is
illegal — but the engine then proceeds along the inference loop
in `inferImplicitStackMarkers`, which guards on
`!input.contains("+")`. The collapsed buffer no longer has any
`+`, so inference re-fires on the surface form *as if the user had
not typed `+` at all*. The post-collapse buffer for `ka+ka` is
literally `kaka`, which produces `ကက` — but the stack-inference
loop's "previous coda letter must be in `isPaliStackCodaLetter`"
gate rejects this site (the preceding letter is `a`, a vowel
letter). The `+` would have unambiguously identified the stack
site if it had survived; collapsing it before the inference loop
runs throws that signal away.

The same root cause is responsible for `ka+kka` → `ကကက` and
`ka+kk+a` → `ကကက`: both lose their `+` before the inference
loop, and the surviving consonant-only chunk doesn't satisfy the
`<vowel><coda><consonant>` site shape the implicit loop expects.

## Burmese Language Rule Reference
A user-typed `+` is the documented stack signal; the rendered
form `<C₁> + ္ + <C₂>` is the canonical Burmese subscript when
both consonants stack-validate. The romanization scheme treats
`ka+ka` and `kakka` as two surface forms of the same intent
("stack `က` over `က`"). Either form should produce
`ကက္က` / `က္က` / similar canonical conjunct as long as the pair
stack-validates; producing `ကက` (no virama) discards the user's
signal.

## Steps to Reproduce
For any pair of consonants `<C₁>`, `<C₂>` that strict-stack,
typing `<C₁>a+<C₂>a` should produce `<C₁>` + `<C₂>` stacked. Today
it produces them as two unstacked consonants.

Concrete reproductions (verified 2026-04-27 on a fresh
`BurmeseEngine`):

| Buffer | Current rank-0 | Desired rank-0 (matches no-`+` form) |
|---|---|---|
| `ka+ka`   | `ကက` (`[1000 1000]`)            | `ကက္က`-shape (matches `kakka` → `ကက္က`) |
| `pa+pa`   | `ပပ` (`[1015 1015]`)            | `ပ္ပ` or `ပပ္ပ` |
| `ta+ta`   | `တတ` (`[1010 1010]`)            | `တ္တ` |
| `na+ta`   | `နတ` (`[1014 1010]`)            | `န္တ` |
| `na+da`   | `နဒ` (`[1014 1012]`)            | `န္ဒ` |
| `ka+kka`  | `ကကက`                          | `က+က္က` shape |
| `ka+kk+a` | `ကကက`                          | same |
| `kha+ka`  | `ခက`                          | `ခ္က` (cross-class — at minimum surface should contain virama under liberal inference) |
| `pyaepyaeminga+lar+par` | (unchanged, kinzi anchored) | (unchanged) |

Counter-examples that work today and must continue to work:

- `k+ka` → `က္က` (the `+` is preserved because the next character
  is the consonant `k`, not a vowel — the collapse rule does not
  fire here).
- `kakka` → `ကက္က` (no `+` typed; implicit inference handles it).
- `k++ka` → `က္က` (consecutive-`+` collapse to single `+`,
  correctly preserved by the next-char-is-consonant rule).

## Current State
Users who learn to use `+` as the explicit stack indicator (the
intuition you'd take from documentation that says `+` is the
virama key) get strictly worse output for the most natural typing
shape, where each consonant carries its own vowel. They have to
either:
- Drop the trailing `a` from the upper consonant (`k+ka`), which
  contradicts how Pali / Sanskrit romanization is usually
  written, or
- Drop the explicit `+` and rely on implicit inference, which
  defeats the purpose of having `+` as a signal.

This is doubly confusing because the documentation correctly
describes `+` as a stack indicator, but the actual behavior
silently treats `+` before a vowel as a no-op.

## Desired State
- A `+` typed between two consonant+vowel chunks must be honored
  as a stack site whenever the implicit inference would have
  produced the stack on the no-`+` equivalent form.
- The stacked surface must rank ≥ rank-0 at parity with the
  no-`+` form (subject to LM ordering of stacked vs. unstacked
  candidates, which already prefers the stacked form for common
  Pali shapes).
- Existing inputs (`k+ka`, `min+ga`, `bud+da`, `ai+ng+gar`,
  `kar+i`, `kar+u`, …) continue to work unchanged.

## Acceptance Criteria
- For every input in the reproduction table above,
  `engine.update(...)` returns a rank-0 surface that contains
  exactly one `U+1039` (the inferred virama) at the position
  the user signalled with `+`. The scalar sequence must match
  the no-`+` equivalent's surface modulo the inherent-vowel
  letters: e.g. `ka+ka` and `kakka` must produce surfaces that
  agree on the stacked-conjunct subsequence `<C> 1039 <C>`.
- For the cross-class case `kha+ka`, the strict path produces
  `ခက` (correct under strict same-class) but the liberal path
  must surface a stacked sibling at rank ≥ 1 so the user can
  pick it.
- `k+ka`, `min+ga`, `kha+nta`, `bud+da`, `wun+gar`, and every
  other existing `+`-using test buffer continue to render
  unchanged.
- A new suite under
  `Sources/BurmeseIMETestSupport/Suites/ExplicitPlusVowelSuite.swift`
  asserts equivalence between `<X>+<Y>a` and `<X><Y><Y>a`
  surfaces for the canonical strict-stack pairs (k/k, t/t, p/p,
  m/m, n/t, n/d, …).
- `swift run TestRunner` continues to pass at 100 %.
- `swift run -c release BurmeseBench --check
  Tests/Benchmarks/baseline.json` reports no regressions.

## Notes
- Code location:
  `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/InputNormalization.swift`
  lines 54–67 (`collapseConnectorRuns` vowel-leader strip) and
  the `!input.contains("+")` guard in
  `inferImplicitStackMarkers` at line 256.
- Possible fixes:
  1. Replace the unconditional `+`-before-vowel strip with a
     contextual transform: if the buffer is
     `<consonant-letter><vowel-letter>+<consonant-letter>`,
     reshape to `<consonant-letter>+<consonant-letter><vowel-letter>`
     so the explicit signal is preserved and the parser's
     `+`-as-virama path can fire. This mirrors the no-`+`
     inference loop's behaviour exactly.
  2. Alternatively, lift the `!input.contains("+")` guard in
     `inferImplicitStackMarkers` and let the loop add additional
     `+` markers at the user's signaled positions even when one
     is already present.
- This bug is structural (independent of LM / lexicon). Verified
  empirically on a fresh `BurmeseEngine()`.
- Probe (2026-04-27):
  ```swift
  for input in ["ka+ka", "kakka", "ta+ta", "tatta",
                "pa+pa", "pappa", "na+ta", "natta"] {
      let s = engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
      // The +-bearing inputs all lack 1039; the no-+ equivalents
      // all contain 1039 at the expected position.
  }
  ```

## Validation Notes
- Validity: **Valid bug, confirmed via probe (2026-04-27).**
  Reproduction table re-verified:
  | Input | Surface | Hex |
  |---|---|---|
  | `ka+ka`   | `ကက`     | `1000 1000` (no 1039) |
  | `kakka`   | `ကက္က`   | `1000 1000 1039 1000` (has 1039) |
  | `ta+ta`   | `တတ`     | `1010 1010` (no 1039) |
  | `tatta`   | `တတ္တ`   | `1010 1010 1039 1010` (has 1039) |
  | `pa+pa`   | `ပပ`     | `1015 1015` (no 1039) |
  | `pappa`   | `ပပ္ပ`   | `1015 1015 1039 1015` (has 1039) |
  | `na+ta`   | `နတ`     | `1014 1010` (no 1039) |
  | `natta`   | `နတ္တ`   | `1014 1010 1039 1010` (has 1039) |
  | `k+ka`    | `က္က`    | `1000 1039 1000` (counter-example, working) |
  | `kha+ka`  | `ခက`     | `1001 1000` (no 1039) |
  | `ka+kka`  | `ကကက`    | `1000 1000 1000` (no 1039) |
  | `ka+kk+a` | `ကကက`    | `1000 1000 1000` (no 1039) |

- Code locations verified:
  - `Engine/InputNormalization.swift:54-68` — the vowel-leader
    strip in `collapseConnectorRuns` matches the task description
    exactly.
  - `Engine/InputNormalization.swift:256` — the
    `guard !input.contains("+") else { return nil }` early-return in
    `inferImplicitStackMarkers` matches the task description.

- Scope calibration: Correctly scoped. Covers the entire class of
  `<C>a+<C>` patterns (homorganic stacks, cross-class stacks,
  multi-segment chains).

- Burmese rule reference is accurate: `+` is the documented
  user-facing virama signal, and the task correctly identifies that
  the no-`+` form already produces the canonical conjunct.

- Refinement note on cross-class case (`kha+ka`): The current text
  says strict path produces `ခက` and the liberal path must surface a
  stacked sibling at rank ≥ 1. This may need engineering judgment —
  cross-class stacks are normally rejected. Acceptance criteria
  reasonable as written; flag for the fixing agent to confirm.

- Strong overlap with TASK-013: the `ka+ka+ka+...` chain repro is
  shared. Fixing TASK-011 may shift TASK-012 / TASK-013 surface;
  the fixing agent should sequence them or sanity-check seam outputs
  after this lands.

- No open questions.

## Validation Report
- **Verdict: FULLY_COVERED.**
- Acceptance criteria re-verified via probe (debug build, 2026-04-27):
  every same-class pair in the reproduction table now contains the
  canonical virama stack at rank 0:
  - `ka+ka` → `က္က` (`1000 1039 1000`)
  - `ta+ta` → `တ္တ` (`1010 1039 1010`)
  - `pa+pa` → `ပ္ပ` (`1015 1039 1015`)
  - `ma+ma` → `မ္မ` (`1019 1039 1019`)
  - `na+ta` → `န္တ` (`1014 1039 1010`)
  - `na+da` → `န္ဒ` (`1014 1039 1012`)
  - `ka+kka` / `ka+kk+a` → `က္ကက` (virama present).
- Cross-class `kha+ka` retains the open surface `ခက` at rank 0 and a
  stacked sibling reachable in the panel (asserted by
  `ExplicitPlusVowelSuite.explicitPlusVowel_crossClassSiblingReachable`).
- Counter-examples preserved unchanged: `k+ka` → `က္က`, `min+ga` →
  `မင်္ဂ`, `bud+da` → `ဘူဒ္ဒ`, `kar+u` → `ကရူ`, `ang+gar` → `အင္ဂါ`.
- New `ExplicitPlusVowelSuite` (4 cases) registered, all green.
- All 912 TestRunner cases pass; benchmark `--check` reports no
  regressions.
- Implementation note re-validated: TASK-011's reshape was simplified
  to "drop the upper's `a`" instead of "move past the lower" to
  avoid colliding with TASK-016's repeated-`a` guard — the resulting
  surfaces remain identical to the expected stacked conjuncts.
- No regressions or weakened assertions.
