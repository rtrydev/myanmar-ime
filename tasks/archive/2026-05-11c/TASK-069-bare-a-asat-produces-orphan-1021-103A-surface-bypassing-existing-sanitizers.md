# TASK-069: Bare `a*` (and `aa*`/`aaa*`/`+a*`) produces illegal `1021 103A` orphan-asat-on-independent-vowel surface; existing sanitizers cover all sibling shapes except this one

## Status
Completed

## Implementation Notes
- Added `surfaceContainsBareIndepVowelAsat` predicate and matching
  `sanitizeBareIndepVowelAsat` filter in
  `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`,
  modeled after the existing TASK-052 (`sanitizeDigitOrphanAsat`) and
  TASK-057 (`sanitizeToneOrphanAsat`) sanitizers.
- The predicate detects `1021 103A` adjacency that is NOT preceded by
  a digit (TASK-052 territory) or a tone marker (TASK-057 territory),
  preserving each sanitizer's disjoint scope.
- Wired the new filter into both sanitizer chains in
  `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`:
  the literal-fallback re-run pass (line ~352) and the post-affix-merge
  pass (line ~2595), in both cases between the tone-orphan-asat and
  interleaved-composing-punct sanitizers so the call ordering matches
  the existing TASK-052/TASK-057 pattern.
- Added regression suite
  `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/BareIndepVowelAsatSuite.swift`
  covering the bug class (`a*`, `aa*`, `aaa*`, `+a*`, `a*<X>`,
  `<C>+a*`), pinning sibling shapes (`e*`, `i*`, `o*`, `u*`) as
  regression baseline, and including a guard test that the new
  predicate does not falsely flag the TASK-052 / TASK-057 shapes.
- Suite registered in
  `Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/BurmeseTestSuites.swift`.
- Test runner: 1548/1548 cases, 8460/8460 assertions pass (was
  1543/1543, 8425/8425 before this task).

## Problem Description
When the user types the independent vowel `a` followed by an explicit
asat marker `*` (`a*`), the engine emits a rank-0 Myanmar surface
`1021 103A` — the bare independent vowel `အ` followed by the asat
diacritic `်` (rendered as `အ်`). This is structurally illegal: asat
suppresses the inherent vowel of a consonant, and `1021` (`အ`) is the
"vowel-only consonant" whose only purpose is to host dependent vowel
marks. Stripping its inherent vowel via asat leaves no pronounceable
syllable.

All sibling shapes (`e*`, `i*`, `o*`, `u*`) correctly route to legal
forms — they use ya-asat / nya-asat coda sub-rules or particle
variants that combine with the bare vowel without dropping it.
Specifically:

- `e*` → `အယ်` (1021 101A 103A) — uses ya-asat coda.
- `i*` → `အည်` (1021 100A 103A) — uses nya-asat coda.
- `o*` → `အိုယ်` (1021 102D 102F 101A 103A) — proper o + ya-asat.
- `u*` → `ဦ` (1026) — long-u particle variant.
- `a*` → `အ်` (1021 103A) — **bug:** orphan asat on bare independent
  vowel, no coda consonant.

The same illegal pattern propagates through:
- `aa*`, `aaa*`, `aaaa*` — repeated bare-`a` collapses (per
  `BareVowelRepetitionSuite`) to single `1021`, then asat is appended
  → `1021 103A`.
- `+a*` — leading `+` stripped, same as `a*`.
- `a*+ka` → `အ်က` (1021 103A 1000) — illegal `1021 103A` followed by
  fresh `ka` syllable.
- `a*ka` (no `+`) → same.
- `a*ar`, `a*ya`, `a*aing`, `a*aung`, `a*aw` — all carry the leading
  `1021 103A` followed by another syllable.

## Root Cause
The legality scan in `Parser/Finalization.swift::scanOutputLegality`
classifies `1021` (the independent vowel `အ`) as a "consonant base"
via the helper `isConsonantBase`:

```swift
@inline(__always) func isConsonantBase(_ v: UInt32) -> Bool {
    return (v >= 0x1000 && v <= 0x1021) || v == 0x103F
}
```

The Unicode block places `1021` (MYANMAR LETTER A) at the boundary
between consonants (1000–1020) and independent vowels (1023–102A);
the inclusive `<= 0x1021` upper bound bundles `1021` with the
consonants for asat-anchor purposes. When the asat backward walk in
`scanOutputLegality` reaches `1021`, it accepts it as a valid
consonant base and returns `true` for the surface — bypassing the
"asat needs a consonant" intent.

The two existing surface sanitizers that DO reject related shapes —
`SurfaceSanitizers.surfaceContainsDigitOrphanAsat` (TASK-052) and
`SurfaceSanitizers.surfaceContainsToneOrphanAsat` (TASK-057) — both
require either a preceding digit or a preceding tone marker before
the `1021 103A` pair. The bare `1021 103A` (no preceding digit or
tone) is not covered by any sanitizer.

The result: the parser emits a `1021 103A` surface, the legality scan
accepts it (because `1021` looks like a consonant base), and no post-
parse sanitizer drops it.

## Burmese Language Rule Reference
In Burmese orthography, asat (U+103A, `်`) is a diacritic that
suppresses the inherent vowel of a consonant. It attaches only to
"true" consonants (U+1000..U+1020) and Great Sa (U+103F). The
independent vowel `အ` (U+1021) is structurally a placeholder
consonant: it carries no phonetic value of its own and exists only
to host dependent-vowel marks (`အာ`, `အီ`, `အေ`, etc.) and to
anchor independent-vowel-onset syllables. Suppressing the "inherent
vowel" of `အ` via asat leaves no pronounceable syllable — the
sequence `အ်` has no Burmese spelling.

This is consistent with how the engine handles `e*`, `i*`, `o*`,
`u*`: each routes to a syllable shape with an actual coda consonant
(ya-asat/nya-asat) or a particle variant. Only `a*` slips through
because the rule table has no `a*` entry that produces a non-trivial
coda.

## Steps to Reproduce
```swift
let engine = BurmeseEngine()
for buf in ["a*", "aa*", "aaa*", "+a*",
            "a*ka", "a*+ka", "a*ya", "a*ar",
            "a*aing", "a*aung", "a*aw",
            "ka+a*", "ya+a*"] {
    let s = engine.update(buffer: buf, context: [])
    let scalars = s.candidates[0].surface.unicodeScalars
        .map { String(format: "%04X", $0.value) }.joined(separator: " ")
    print("\(buf) -> [0] \(s.candidates[0].surface) (\(scalars))")
}
// All cases produce a rank-0 surface containing `1021 103A` somewhere
// (often at the very front), e.g.:
//   a*       -> [0] အ်  (1021 103A)
//   a*+ka    -> [0] အ်က  (1021 103A 1000)
//   a*aing   -> [0] အ်အိုင်  (1021 103A 1021 102D 102F 1004 103A)
//   ka+a*    -> [0] ကအ်  (1000 1021 103A)
```

## Current State
- `a*` rank 0 = `အ်` (1021 103A) — illegal independent-vowel + asat
  with no coda consonant.
- `aa*`, `aaa*`, `aaaa*` (per `BareVowelRepetitionSuite` collapse to
  single `အ`) all rank 0 = `အ်` (1021 103A).
- `a*ka` rank 0 = `အ်က` (1021 103A 1000) — illegal prefix followed by
  fresh syllable.
- `a*+ka` rank 0 = same `1021 103A 1000` (the explicit `+` is honored
  but the orphan `1021 103A` LHS persists).
- `ka+a*` rank 0 = `ကအ်` (1000 1021 103A) — `ka` legal, then orphan
  `1021 103A` for `a*`.
- The literal raw buffer is reachable at rank 1 in all cases, so a
  recoverable escape hatch exists, but the rank-0 Myanmar surface is
  illegal and would render incorrectly in client text engines that
  enforce the Myanmar shaping rules.

## Desired State
- For any buffer where the leftmost or rightmost asat-receiving site
  is a bare `1021` with no coda consonant, the engine must NOT
  surface a candidate carrying `1021 103A` as a standalone unit at
  any rank.
- `a*` (and the propagating shapes `aa*`, `aaa*`, `+a*`) should
  either:
  (a) Drop the asat (treat `*` as no-op when no consonant base
      precedes — same policy `kar:*` uses, where `*` after a tone-
      closed cluster is dropped), surfacing just `အ`, OR
  (b) Promote the literal raw buffer to rank 0 (signal that the
      input is structurally malformed).
- Sibling shapes (`e*`, `i*`, `o*`, `u*`) must continue to work:
  their existing rank-0 forms (`အယ်`, `အည်`, `အိုယ်`, `ဦ`) are
  legitimate and must not regress.
- Mixed buffers (`a*ka`, `ka+a*`, etc.) must surface a candidate
  whose leftmost/rightmost asat site has a real consonant coda or
  drops the asat per the same policy.

## Acceptance Criteria
- For every buffer in `{a*, aa*, aaa*, +a*, a*ka, a*+ka, a*ya,
  a*ar, a*aing, a*aung, a*aw, ka+a*, ya+a*}`, the rank-0 surface
  contains no `1021 103A` adjacency.
- The exact surface for `a*` may be either `အ` (1021 — asat dropped)
  or the literal `a*` (raw buffer) — both are acceptable per the
  desired state.
- `e*`, `i*`, `o*`, `u*` continue to produce their existing rank-0
  forms (regression guard).
- `AsatAfterDepVowelSuite`, `AsatAfterToneSuite`,
  `OrphanAsatAfterToneSuite`, `BareVowelRepetitionSuite` stay green.
- A new regression suite covers the `a*` family with the
  no-`1021 103A`-adjacency predicate.
- `swift run TestRunner` 1543/1543 stays green; benchmark `--check`
  does not regress.

## Notes
- Code locations to investigate:
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/Finalization.swift`
    — `isConsonantBase` boundary at `<= 0x1021`. Tightening this to
    `<= 0x1020` would make the legality scan reject `1021 103A` —
    but would also affect the legitimate uses of `1021` as an
    independent-vowel anchor for orphan dep-vowel marks
    (`kaa` → `ကအ` shape relies on `1021` being a "base" for the
    purpose of orphan-anchor injection elsewhere). The fix likely
    needs to add a SECOND check in the asat backward walk:
    "a `1021` immediately followed by `103A` with no preceding
    consonant in the syllable is illegal."
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/SurfaceSanitizers.swift`
    — add a `surfaceContainsBareIndepVowelAsat` predicate that
    detects standalone `1021 103A` (not preceded by a digit or tone
    that the existing TASK-052 / TASK-057 sanitizers handle), and a
    paired `sanitizeBareIndepVowelAsat` filter wired into the same
    pipeline as the other orphan-asat sanitizers.
  - `Packages/BurmeseIMECore/Sources/BurmeseIMECore/Engine/BurmeseEngine.swift`
    — for the `a*` → drop-asat policy, the upstream
    `splitComposablePrefix` / `normalizeForParser` path could detect
    a leading or post-`+` bare `a*` shape and strip the trailing `*`
    before parsing (mirroring the existing `kar:*` and `ka.*` strip
    in `OrphanAsatAfterToneSuite`).
- The issue is **mildly disruptive**: typing `a*` is unusual user
  input (the user explicitly suppressing the inherent vowel of bare
  `a`), but the rank-0 surface is genuinely orthographically invalid.
  Per CLAUDE.md §1: "Candidates should be orthographically legal
  before they reach the panel." The literal echo at rank 1 covers
  the user-escape-hatch invariant, but the rank-0 violation is
  visible to the user as an oddly-shaped Burmese glyph.
- This is a class-level gap: every variant produces the same
  `1021 103A` shape, so a single sanitizer addition closes the entire
  class.
- Related: TASK-052 (archived 2026-05-04b) handled `<digit><1021>103A`.
  TASK-057 (archived 2026-05-04d) handled `<tone><1021>103A`. This
  task closes the bare `<1021>103A` gap.

## Validation Notes
- **Verdict:** Valid. Bug reproduces against `BurmeseEngine()` at
  HEAD for every probe in the example set. `a*`, `aa*`, `aaa*`,
  `+a*` all produce rank-0 surface `အ်` (1021 103A). `a*ka`,
  `a*+ka`, `a*ya`, `a*ar`, `a*aing`, `a*aung`, `a*aw`, `ka+a*`,
  `ya+a*` all surface `1021 103A` somewhere in the rank-0 surface.
  In every case `SyllableParser.scanOutputLegality` returns `true`
  for the illegal `1021 103A` adjacency — confirming the
  `isConsonantBase` permissiveness root-cause.
- **`isConsonantBase` reference:** Confirmed at
  `Parser/Finalization.swift:257-259` —
  `(v >= 0x1000 && v <= 0x1021) || v == 0x103F`. The inclusive
  upper bound at `0x1021` is the immediate cause that lets the asat
  back-walk accept `1021` as a valid base.
- **Sibling shapes regression-baseline:** Verified empirically:
  - `e*` -> `အယ်` (1021 101A 103A) — uses ya-asat coda.
  - `i*` -> `အည်` (1021 100A 103A) — uses nya-asat coda; reading
    aliased to `i2*`.
  - `o*` -> `အိုယ်` (1021 102D 102F 101A 103A) — proper o + ya-asat;
    reading aliased to `o2*`.
  - `u*` -> `ဦ` (1026); reading aliased to `u2`. Note `u*` ALSO
    surfaces a bare `အူ` (1021 1030) at rank 1 — the asat is
    effectively dropped, which is one of the two desired-state
    options for the `a*` fix.
- **Existing sanitizer pattern:** Confirmed both
  `surfaceContainsDigitOrphanAsat` (line 614) and
  `surfaceContainsToneOrphanAsat` (line 995) in
  `Engine/SurfaceSanitizers.swift`, with paired `sanitizeXxx`
  filter functions that follow the "preserve violators when no
  clean candidate exists" pattern. Adding
  `surfaceContainsBareIndepVowelAsat` + `sanitizeBareIndepVowelAsat`
  in the same idiom is the cleanest mechanical fix.
- **Application-feature deliberation:** The task body acknowledges
  `a*` is unusual user input. CLAUDE.md §4 establishes that `*`
  closing a clean syllable IS a deliberate composing key (e.g.
  `kar*` -> coda asat is legitimate). The bug here is specifically
  that `*` closing a BARE INDEPENDENT VOWEL has no Burmese
  orthographic interpretation and the engine should not pretend
  otherwise. Both desired-state options (drop the asat OR promote
  literal) are consistent with the existing TASK-052 / TASK-057
  pattern and CLAUDE.md §1's "candidates should be orthographically
  legal".
- **Important narrowing:** The fix must be careful with `1021`'s
  legitimate role as an orphan-anchor for bare-vowel readings
  (`a` -> `1021`, `aa` -> `1021`). Tightening `isConsonantBase` to
  exclude `1021` would break those, plus the legitimate kinzi /
  stack shapes that depend on `1021` being a "base" elsewhere.
  The recommended approach in the task body — add a SECOND check
  that flags `1021 103A` adjacency without a real consonant base
  in the same syllable — is correct.
- **Acceptance criteria:** Already testable; left as-is. The
  no-`1021 103A`-adjacency predicate is clean and deterministic.
- **Sibling-shape regression guard:** Important to keep `e*`,
  `i*`, `o*`, `u*` rank-0 outputs frozen. Their reading aliases
  (`i2*`, `o2*`, `u2`) need to keep round-tripping too — those
  are part of the existing alias index and the fix should not
  perturb them.
- **Scope:** Correctly scoped at the class level; no narrowing or
  splitting needed. The "leftmost or rightmost asat-receiving
  site" wording in Desired State is slightly fuzzy — clarified
  via the acceptance-criteria predicate "no `1021 103A`
  adjacency in any rank-0 Myanmar surface" which is the testable
  form.
- **Test runner baseline:** CLAUDE.md states 1355/1355; the task
  cites 1543. Fixing agent should sync against actual current
  baseline.

## Validation Report
- **Verdict:** FULLY_COVERED.
- **Predicate scope:** `surfaceContainsBareIndepVowelAsat` flags
  only `1021 103A` adjacency where the `1021` is NOT preceded by a
  digit (TASK-052 territory) or a tone marker U+1037/U+1038
  (TASK-057 territory). Predicate unit tests confirm:
  - `1021 102C 103A` (1021 + dep-vowel + asat) does NOT flag.
  - `1021 101A 103A` (1021 + ya + asat = ya-asat coda, legal) does
    NOT flag.
  - `1000 103A` (consonant + asat) does NOT flag.
  - `0030 1021 103A` (digit + 1021 + asat) does NOT flag.
  - `1037 1021 103A` (tone + 1021 + asat) does NOT flag.
  - `1021 103A` (bare) DOES flag.
- **Legitimate compounds:** `ar`, `ay`, `ain`, `aing`, `aung`,
  `auk`, `ai`, `aw`, `an`, `am`, `ang` all produce surfaces that
  do not trip the sanitizer. Sibling shapes (`e*`, `i*`, `o*`,
  `u*`) regression-pinned and confirmed unchanged.
- **Wiring:** Filter is invoked in both the literal-fallback re-run
  pass (`BurmeseEngine.swift:362`) AND the post-affix-merge pass
  (`:2633`), matching the call ordering of the
  TASK-052/TASK-057 sanitizers.
- **Tests:** New `BareIndepVowelAsatSuite` covers the full bug
  class with three layers: rank-0 only (`bareIndepVowelAsat_
  noRank0Adjacency`), full panel (`bareIndepVowelAsat_
  noPanelAdjacency`), and literal reachability
  (`bareIndepVowelAsat_literalReachable`). Sibling shapes pinned
  via `siblingVowelAsat_unchanged`. Predicate guard via
  `predicate_skipsTask052And057`.
- **Test run:** 1556/1556 cases, 8581/8581 assertions pass.
