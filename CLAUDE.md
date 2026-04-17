# Claude Code Guide — Myanmar IME

Orientation doc for working on this repo with Claude Code. See `README.md`
for user-facing documentation.

## Layout

```
Packages/BurmeseIMECore/   Swift Package — pure conversion engine, no UI
  Sources/BurmeseIMECore/        Engine source
  Sources/BurmeseIMETestSupport/ Shared test framework + suites (single source)
  Sources/LexiconBuilder/        TSV → SQLite lexicon compiler
  Sources/BurmeseBench/          Perf benchmark + regression check
  Tests/TestRunner/              CLI driver (iterates BurmeseTestSuites.all)
  Tests/BurmeseIMECoreTests/     XCTest drivers (one XCTestCase per suite)
  Tests/Benchmarks/baseline.json Committed perf baseline
  Data/                          Lexicon source TSV
native/macos/              Xcode project with two apps + installer
  BurmeseIME/              Headless IMK bundle (installs to ~/Library/Input Methods/)
  BurmeseIMEPreferences/   SwiftUI settings app (installs to /Applications/)
  installer/               build.sh + postinstall for the unsigned .pkg
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

Every test case lives under `Sources/BurmeseIMETestSupport/Suites/` and
is exposed via the `BurmeseTestSuites.all` index. Both `TestRunner` and
the XCTest drivers iterate that same list — when adding a case, edit the
matching suite file and both runners pick it up. `FUZZ_BUDGET_MS` caps
the fuzz suite's wall-clock time (default 1000 ms).

### Benchmarks

```bash
swift run -c release BurmeseBench                               # emit JSON
swift run -c release BurmeseBench --check Tests/Benchmarks/baseline.json
swift run -c release BurmeseBench --update Tests/Benchmarks/baseline.json
swift run -c release BurmeseBench --scenario medium
```

Four scenarios (`short`/`medium`/`long`/`incremental`). `--check` exits 1
if p95 regresses >20% or p99 regresses >30% vs the committed baseline.
Update the baseline only when an intentional perf change lands.

### Lexicon rebuild

```bash
cd Packages/BurmeseIMECore
swift run LexiconBuilder \
    Data/BurmeseLexiconSource.tsv \
    ../../native/macos/Data/BurmeseLexicon.sqlite
```

Only needed when `BurmeseLexiconSource.tsv` changes.

### macOS apps + installer

Open `native/macos/BurmeseIME.xcworkspace` in Xcode. Three schemes:

- `BurmeseIME` — the headless IMK bundle. Build to iterate on the
  controller / IMK glue.
- `BurmeseIMEPreferences` — the SwiftUI settings app.
- `BurmeseIMEInstaller` — aggregate target that builds both apps and
  packages them into an unsigned `.pkg` at
  `native/macos/build/BurmeseIME-Install.pkg`. ⌘B on this scheme runs
  `pkgbuild` under Xcode's automatic signing, giving the apps a stable
  team signature (required for TCC to persist App-Group grants — see
  below).

Install by right-clicking the pkg → Open (unsigned, Gatekeeper blocks
double-click). Postinstall relocates the IME to
`~/Library/Input Methods/` and launches the Preferences app; enable the
input source in System Settings → Keyboard → Text Input.

Neither target is sandboxed. Earlier iterations sandboxed both and shared
state through an App Group, but free Apple Development signing can't
register App Groups centrally so macOS re-prompted "would like to access
data from other apps" on every launch. Unsandboxed, both apps read/write
the same `~/Library/Preferences/group.com.myangler.inputmethod.burmese.plist`
via `UserDefaults(suiteName:)` — no entitlements, no prompts.

The CLI `installer/build.sh` does the same packaging for headless builds
(does not override signing).

## Architecture

### Conversion pipeline

A keystroke lands in `BurmeseInputController` (inside the IME bundle),
which accumulates a raw Roman buffer and calls
`BurmeseEngine.update(buffer:context:)` on every change.

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

### Statistical scoring

Candidate ranking is anchored by a word-level Kneser-Ney trigram LM
(`LanguageModel/FORMAT.md`) loaded via `TrigramLanguageModel`. `BurmeseEngine`
combines: orthographic legality (hard filter) → alias cost → LM log-prob →
parser tie-breaker. The LM `.bin` and the SQLite lexicon are produced in
one pass by `Packages/BurmeseIMECore/Tools/corpus_builder/` so their vocabularies stay aligned.

## Working in this repo

- Core engine changes: edit under `Packages/BurmeseIMECore/Sources/BurmeseIMECore/`,
  run `swift run TestRunner` from the package dir.
- Adding a test: prefer adding to both
  `Tests/BurmeseIMECoreTests/` (XCTest) and `Tests/TestRunner/main.swift`
  so it runs without Xcode.
- Keystroke behavior changes: edit
  `native/macos/BurmeseIME/BurmeseInputController.swift` and test in the
  running IME (no unit-test harness for IMK).
- Settings UI changes: edit `native/macos/BurmeseIMEPreferences/ContentView.swift`.
  Settings propagate across the process boundary via the shared
  `UserDefaults` suite; the controller reconciles on the next keystroke
  (see `reconcileClusterAliasesIfNeeded` — it exists because
  SyllableParser bakes `useClusterAliases` at init time).
- Rule changes: update `Romanization.swift` and/or `Grammar.swift`; the
  parser picks them up automatically via `SyllableParser.init()`.
