# TASK-079: aw-family creaky-asat coda (`ော့်` / `ေါ့်`) is rejected by the legality scan, making the creaky possessive forms unwritable

## Status
Completed

## Implementation Notes
Three changes, all data-driven (no word-specific patches):

1. `Parser/Finalization.swift` (`scanOutputLegality`, the `103A`
   backward walk's `w == 0x1037` branch): peel the aw-cluster
   `1031 102B|102C` when it sits immediately before the creaky dot,
   setting `sawVowelCluster` so medial-bearing onsets (`ကျော့်`)
   continue through the existing medial skip. The carve-out requires
   the leading `1031`, so the genuinely illegal tone-closed shapes
   (`ကာ့်` = `102C 1037 103A` without `1031`, `ကေ့်` = lone e-kar,
   visarga + asat, digit-anchored asat) stay rejected.
2. `Engine/PunctuationHandling.swift`: new
   `asatAcceptingCreakyDotSuffixes` set, derived from the
   romanization vowel table (roman ends in `.`, Myanmar output ends
   with `1031 102B|102C 1037` — today `aw.` / `aw2.`). Used by
   `starCompletesCreakyAsatCoda` in
   `shouldSplitEmbeddedComposingPunct` so the `.*` adjacency in
   `taw.*ko`-class buffers no longer forces an embedded-punct split
   (the `*` is the syllable's coda asat), letting the whole-buffer
   parse + alias lookup serve `ကျွန်တော့်ကို`.
3. Same file, `renderFrozenPunctSegments`: a `*` completing the
   creaky-asat coda stays attached to the composable run instead of
   flushing as a literal, so frozen prefixes containing `…aw.*`
   render the full `ော့်` coda.

New suite: `Suites/AwCreakyAsatCodaSuite.swift` (direct predicate
accept/reject sweeps, bare-engine composition `taw.*`/`naw.*`/
`maw.*`/`khaw.*`, asat-less non-regression, production exact-alias
reachability for `ကျွန်တော့်`/`နော့်`/`တော့်`, and the
`kwyantaw.*ko` compound). Full runner green (1654 cases / 9028
assertions) and `BurmeseBench --check` reports no regressions.

## Problem Description
The storage shape `<C> 1031 102C 1037 103A` (e.g. `တော့်`, `နော့်`) —
the creaky-tone aw vowel closed with asat — is regular, extremely common
Burmese orthography (the creaky possessive/emphatic of every `ော်` word:
`ကျွန်တော့်` "my", `တော့်`, `နော့်`, `မော့်`, …). The parser's output
legality scan classifies it as illegal. Two user-visible consequences:

1. The grammar cannot compose it: typing the reading (`taw.` + `*`, the
   exact shape the reverse romanizer itself generates as the canonical
   reading `…aw.*`) yields only the asat-less `တော့` sibling.
2. Worse, the exact alias-index lexicon hits carrying the correct
   surface (`ကျွန်တော့်` alias `kwyantaw.*` penalty 0, `နော့်` alias
   `naw.*` penalty 0) are stripped from the panel by
   `sanitizeMalformedMyanmarMarks`, because the scan marks them
   malformed while "clean" siblings (the wrong, asat-less forms) exist.
   The words are unreachable at any rank.

`ကျွန်တော့်` is among the highest-frequency words in colloquial Burmese;
its lexicon row exists but cannot be typed.

## Root Cause
`SyllableParser.scanOutputLegality`
(`Packages/BurmeseIMECore/Sources/BurmeseIMECore/Parser/Finalization.swift:248`)
applies the "asat must not follow a tone mark" rejection (the rule that
correctly rejects `kar:.*`-style orphan shapes) without carving out the
canonical creaky-asat coda ordering `1037 103A` when it closes the
aw-family vowel `1031 102C` / `1031 102B`. The dot-below (ccc=7) is
stored before asat (ccc=9) by Unicode canonical order — the same
ordering the romanization table itself emits for `an.`
(`\u{1014}\u{1037}\u{103A}` = `န့်`) and `e.` (`ယ့်`), both of which the
scan accepts. Probing confirms the false negative is specific to the
aw-family base:

```
scanOutputLegality("သည့်")  = true
scanOutputLegality("ကန့်")  = true
scanOutputLegality("မယ့်")  = true
scanOutputLegality("တော့်") = false   // 1010 1031 102C 1037 103A
scanOutputLegality("နော့်") = false
scanOutputLegality("ကျွန်တော့်") = false
```

Additionally there is no composition path from `aw.` + `*`: the vowel
table (`Romanization.swift`, `aw.` → `\u{1031}\u{102C}\u{1037}`) has no
`aw.*`-equivalent rule, and the explicit `*` cannot attach because the
shape it would produce fails the same legality scan.

## Burmese Language Rule Reference
Creaky tone on an asat-closed aw syllable is written aukmyit + asat:
`ော` + `့` + `်` (U+1031 U+102C U+1037 U+103A). It is the productive
possessive/object form of `ော်` words (`ကျွန်တော် → ကျွန်တော့်`,
`မော်တော် → မော်တော့်`…). On the dot/asat ordering: U+1037 has canonical
combining class 7 and U+103A has ccc 9, so Unicode canonical ordering
(NFC) stores the dot-below BEFORE the asat; the two orders are
canonically equivalent, and this repository's pipeline is uniformly
dot-first — the romanization table emits `1037 103A` for every creaky
asat coda (`an.` → `န့်`, `in.` → `င့်`, `e.` → `ယ့်`) and the shipped
lexicon stores `ကျွန်တော့်` / `နော့်` as `… 1031 102C 1037 103A`
(verified scalar-by-scalar). The current scan conflates this regular
shape with the genuinely illegal "asat after a tone mark on a non-aw
base" shapes.

Fix-direction warning: the scan currently *accepts* the reversed
non-NFC order `… 1031 102C 103A 1037` (the aw-cluster peel handles
asat-then-dot). Do not "fix" this task by reordering surfaces into
that order — lexicon reachability depends on string equality with the
dot-first stored form. The predicate must accept the dot-first cluster.

## Steps to Reproduce
1. Production-equivalent engine with bundled artifacts.
2. Type `kwyantaw.*` (the digit-stripped canonical alias of
   `ကျွန်တော့်`), `naw.*`, or `taw.*`.
3. Inspect the full candidate list.
4. Also assert `SyllableParser.scanOutputLegality("တော့်")` directly.

## Current State
- `kwyantaw.*` panel: `ကျွန်တော့` (no asat), `ကြွံတော့`, `ကျွံတော့`, …
  — `ကျွန်တော့်` absent at every rank.
- `naw.*` panel: `နော့`, `နော့ဝစ်`, `နော့တင်ဟမ်`, literal — `နော့်`
  absent.
- `kwyantaw.*ko` (`ကျွန်တော့်ကို`) produces a literal-only panel of one
  candidate.
- `scanOutputLegality` returns false for `တော့်` / `နော့်` /
  `ကျွန်တော့်`.

## Desired State
- The legality scan accepts `<C/onset cluster> 1031 102C|102B 1037 103A`
  as legal.
- Typing `<…>aw.` then `*` composes the `ော့်` coda, and the exact
  alias hits (`ကျွန်တော့်`, `နော့်`) surface in the panel (top-3
  strongly preferred for penalty-0 exact alias hits).
- The genuinely illegal asat-after-tone shapes (`kar:.*` → tone + orphan
  asat, asat after visarga `1038`, asat after a digit) remain rejected.

## Acceptance Criteria
- `scanOutputLegality` returns true for `တော့်`, `နော့်`,
  `ကျွန်တော့်`, `မော့်` and still returns false for
  `<tone 1038><asat>` shapes and digit-anchored asat.
- `kwyantaw.*` surfaces `ကျွန်တော့်` in the panel; `kwyantaw.*ko`
  surfaces `ကျွန်တော့်ကို` (lexicon entry) with a non-empty Myanmar
  panel.
- `naw.*` surfaces `နော့်`.
- AsatAfterToneSuite, OrphanAsatAfterToneSuite, AsatCodaToneSuite,
  ReverseRomanizerCreakyToneSuite and the rest of the runner stay green.

## Notes
- Code: `Parser/Finalization.swift:248` (`scanOutputLegality`);
  `Engine/SurfaceSanitizers.swift:155` (`sanitizeMalformedMyanmarMarks`
  — the pass that strips the lexicon surfaces once the scan rejects
  them); `Romanization.swift` vowel table `-aw` family (lines ~261–266).
- The reverse romanizer already generates `…aw.*` readings for these
  surfaces (lexicon `canonical_reading` values `kwy2antaw.*`, `naw.*`),
  so forward typing and the lexicon disagree purely because of the scan.
- Distinct from TASK-081: this shape is *regular* orthography mis-rejected
  by the predicate; TASK-081 concerns genuinely irregular lexicalized
  spellings that need a lexicon-attested exemption.

## Validation Notes
- **Verdict: valid.** All probe results reproduced at commit 795465c:
  `scanOutputLegality` returns true for `သည့်` / `ကန့်` / `မယ့်` and
  false for `တော့်` / `နော့်` / `ကျွန်တော့်` / `မော့်`. Panel checks
  confirmed: `kwyantaw.*` offers only the asat-less `ကျွန်တော့` family,
  `naw.*` lacks `နော့်`, `kwyantaw.*ko` is a literal-only panel of one,
  and `taw.*` rank 0 is `တော့` with the `*` silently dropped.
- Lexicon claims verified directly against the shipped store:
  `kwyantaw.*` → `ကျွန်တော့်` (rank_score 724.4, penalty 0) and
  `naw.*` → `နော့်` (706.1, penalty 0) exist; the stored surfaces use
  the dot-first scalar order `1031 102C 1037 103A`.
- Root-cause trace verified by code reading of
  `Parser/Finalization.swift`: in the `103A` backward walk the
  aw-cluster peel (line ~466) only fires when the scalar before the
  asat is a dep-vowel, so for `… 1031 102C 1037 103A` the walk enters
  the `w == 0x1037` branch (line ~508), which requires a consonant
  base immediately before the dot and rejects when it sees `102C`.
  The Romanization vowel table has `aw.` → `1031 102C 1037` and no
  `aw.*` rule, matching the no-composition-path claim.
- Scope: correctly scoped (a predicate fix narrowly targeting the
  `1031 102B|102C 1037 103A` cluster). The examples are representative
  of the whole `ော့်`/`ေါ့်` class, not word-specific.
- Changed: corrected the ordering attribution (Unicode canonical
  combining classes / NFC rather than "UTN-11 canonical ordering" —
  UTN-11's visual spelling order actually lists asat before the dot
  and relies on normalization equivalence) and added a fix-direction
  warning that the predicate must accept the dot-first order used by
  the lexicon and romanization tables, since the reversed order
  already passes the scan but would break lexicon string equality.

## Validation Report (Step 4, 2026-06-10, HEAD 574e8ee)
- **Verdict: FULLY_COVERED.**
- All acceptance criteria verified: `AwCreakyAsatCodaSuite` (6 cases)
  passes inside the full runner (1682/1682 cases, 9178/9178
  assertions); the suite covers predicate accept/reject sweeps, bare
  composition, production exact-alias reachability, and the
  `kwyantaw.*ko` compound.
- Class coverage verified beyond the suite examples with an
  independent probe: `scanOutputLegality` accepts
  `<C> 1031 102B|102C 1037 103A` across 12 distinct onsets x both
  tall-aa/aa shapes (24/24), while visarga+asat and digit-anchored
  asat stay rejected. Production panels for `kyaw.*` (`ကျော့်` rank 0)
  and `ataw.*` (`အတော့်` rank 0) confirm the fix generalizes.
- The Finalization.swift carve-out is correctly scoped: it requires
  the leading `1031` before `102B|102C`, so `ကာ့်` / `ကေ့်` /
  `ကိ့်` / `ကို့်` shapes remain rejected (pinned by the suite).
- No regression traced to this commit: full runner green, and the
  step-4 perf bisect measured garbage_incremental p99 at 399-400us at
  1351fbd (which includes this fix), at parity with the 389-393us
  measured at pre-pipeline 795465c.
