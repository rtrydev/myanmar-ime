# Claude Code Guide — Myanmar IME

Orientation doc for working on this repo with Claude Code. See `README.md`
for user-facing documentation.

## Layout

```
Packages/BurmeseIMECore/   Swift Package — pure conversion engine, no UI
  Sources/BurmeseIMECore/  Engine source
  Sources/TestRunner/      CLI test driver (replaces XCTest when unavailable)
  Sources/LexiconBuilder/  TSV → SQLite lexicon compiler
  Tests/                   XCTest suite (requires Xcode toolchain)
  Data/                    Lexicon source + prebuilt SQLite
native/macos/              Xcode app + IMKInputController extension
LegacyFixtures/myangler.js Reference JS implementation (parity fixture)
```

The core package has **no macOS-only dependencies** — it builds and runs
anywhere Swift runs. All platform glue lives in `native/macos/`.

## Build and Test

### Core engine (primary dev loop)

```bash
cd Packages/BurmeseIMECore
swift build
swift run TestRunner    # ← use this, not `swift test`
```

`swift test` may fail with *no such module 'XCTest'* on plain SPM toolchains.
`TestRunner` is a hand-rolled CLI that exercises the same cases and prints
`ALL N TESTS PASSED`; prefer it for quick iteration.

### Lexicon rebuild

```bash
cd Packages/BurmeseIMECore
swift run LexiconBuilder \
    Data/BurmeseLexiconSource.tsv \
    ../../native/macos/Data/BurmeseLexicon.sqlite
```

Only needed when `BurmeseLexiconSource.tsv` changes.

### macOS app + input method

Open `native/macos/BurmeseIME.xcworkspace` in Xcode and build the
`BurmeseIMEApp` scheme. The app installs the input method extension; enable
it in System Settings → Keyboard → Input Sources.

## Architecture

### Conversion pipeline

A keystroke lands in `BurmeseInputController` (the IMK extension), which
accumulates a raw Roman buffer and calls `BurmeseEngine.update(buffer:context:)`
on every change.

```
buffer ─► BurmeseEngine.update
            │
            ├─ splitComposablePrefix       composable chars vs. literal tail
            ├─ Romanization.normalize      alias folding (e.g. ph → f)
            ├─ right-shrink probe loop     drop trailing chars until parse is legal
            ├─ sliding-window split        frozen prefix + active tail (long inputs)
            ├─ SyllableParser.parseCandidates
            │     (N-best Viterbi DP over onset+vowel rules)
            ├─ CandidateStore.lookup       lexicon prefix match
            └─ merge, rank, expand aa      returns CompositionState
```

### Key types

- **`BurmeseEngine`** — orchestrates composition. Stateful only for its
  frozen-prefix cache (see *Performance* below). Ranking order: grammar
  legality → alias cost → parser score → lexicon frequency.
- **`SyllableParser`** — pure, `Sendable`. N-best Viterbi DP. Each DP
  transition matches a precomputed *onset* (consonant + optional medials)
  optionally followed by a *vowel*. Beam width defaults to
  `max(maxResults * 16, 64)`.
- **`Grammar`** — static orthographic legality tables
  (`canConsonantTakeMedial`, `validateSyllable`, `requiresTallAa`).
  Illegal syllables get a huge score penalty instead of hard rejection,
  so the engine degrades gracefully.
- **`Romanization`** — rule tables, alias variants, normalization, lookup
  keys. Source of truth for the romanization scheme.
- **`CandidateStore`** — protocol; `SQLiteCandidateStore` is prod,
  `EmptyCandidateStore` is the default for tests. Returns
  frequency-ranked lexicon candidates for a reading prefix.
- **`ReverseRomanizer`** — Myanmar → Roman for tests/debugging.

### Performance: sliding window

Straight N-best DP is quadratic in output-string length because every DP
state carries a growing output string. On buffers >~16 chars this becomes
noticeable per keystroke.

Mitigation in `BurmeseEngine`:

- `compositionWindowSize = parser.maxOnsetLen + parser.maxVowelLen + 4`
  (~16 chars).
- If the normalized buffer is longer, split into `frozenPrefix` + `activeTail`.
  The prefix is rendered once via single-best parse and memoized in
  `FrozenPrefixCache` (lock-protected single slot). Typing left-to-right
  gives one cache miss per window-boundary advance.
- Only `activeTail` hits the N-best path; candidates are reconstructed by
  prepending the cached prefix output/reading.
- The right-shrink probe loop also runs on the tail only.
- Lexicon lookup is skipped when a frozen prefix is active.

Because no romanization rule spans more than `maxOnsetLen + maxVowelLen`
chars, the window boundary is always outside any possible rule match, so
freezing the prefix is safe.

### Legacy parity

`LegacyFixtures/myangler.js` is the original browser engine, kept as a
reference fixture. `Tests/.../LegacyFixtureTests.swift` asserts parity on
known-good cases and documents intentional divergences (e.g. illegal
combinations stay raw in preedit instead of leaking into output).

## Working in this repo

- Core engine changes: edit under `Packages/BurmeseIMECore/Sources/BurmeseIMECore/`,
  run `swift run TestRunner` from the package dir.
- Adding a test: prefer adding to both `Tests/` (XCTest) and
  `Sources/TestRunner/main.swift` so it runs without Xcode.
- UI/keystroke behavior changes: edit `native/macos/BurmeseIMEExtension/BurmeseInputController.swift`
  and test in the running IMK extension (no unit-test harness for IMK).
- Rule changes: update `Romanization.swift` and/or `Grammar.swift`; the
  parser picks them up automatically via `SyllableParser.init()`.
