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

### Behavioral probes

When validating task completion or debugging edge cases, a one-off probe
linked against the built module is faster than writing a full test case.
Probes are useful for inspecting scalars, scores, and ranked candidates
interactively without adding noise to the suites.

1. Build the core package first (see above) — the probe links against
   the per-file `.swift.o` objects under `.build/arm64-apple-macosx/debug/`.

2. Write the probe to `/tmp/<name>-probe.swift`. Import the module,
   instantiate `SyllableParser()` (and `BurmeseEngine` / `ReverseRomanizer`
   as needed), and print scalar hex alongside the rendered surface so
   combining-mark issues are visible:

   ```swift
   import Foundation
   import BurmeseIMECore

   let parser = SyllableParser()
   func hex(_ s: String) -> String {
       s.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
   }
   for key in ["hmon", "k+ya"] {
       if let p = parser.parse(key).first {
           print("\(key)\tscore=\(p.score)\tlegal=\(p.legalityScore)\t\(hex(p.output))\t\(p.output)")
       }
   }
   ```

3. Compile and run (from the `Packages/BurmeseIMECore` directory):

   ```bash
   xcrun swiftc -module-cache-path .build/module-cache \
     -I .build/arm64-apple-macosx/debug/Modules \
     /tmp/<name>-probe.swift \
     .build/arm64-apple-macosx/debug/BurmeseIMECore.build/*.swift.o \
     -o /tmp/<name>-probe
   /tmp/<name>-probe
   ```

   Use **bare `xcrun swiftc`** — do *not* prefix with
   `DEVELOPER_DIR=/Applications/Xcode.app/...`. `swift build` runs under the
   system toolchain (whichever `xcode-select -p` resolves — on this machine
   `/Library/Developer/CommandLineTools`), and the probe must link against
   modules compiled by the same toolchain. Pointing the probe at Xcode's
   bundled Swift produces *"module compiled with Swift X.Y.Z cannot be
   imported by the Swift X.Y compiler"* even when the version numbers look
   close. (The `DEVELOPER_DIR` override is only needed for `xcodebuild`
   invocations further below, which require the full Xcode SDK.)

Notes:
- `SyllableParser.parse(_:)` returns only the top candidate;
  `parseCandidates(_:maxResults:)` exposes the ranked N-best if tie-breakers
  matter. `score` is the DP score (illegal parses are penalized ≤-10000);
  `legalityScore` is 0 for strictly illegal outputs.
- `Romanization.normalize` strips digits (`"ny2"` → `"ny"`), so probing
  digit-disambiguated keys via `parser.parse` reflects what the composing
  buffer sees. Use `Romanization.consonantToRoman[Myanmar.X]` to look up
  the canonical key for a given consonant before building the input.
- `SyllableParse.output` is the parser's raw emission. Engine-level
  post-processing (e.g. `correctAaShape` switching U+102C↔U+102B) runs
  in `BurmeseEngine`, not here — instantiate the full engine if a probe
  needs to match lexicon surfaces exactly.
- Keep probes under `/tmp/` — they are intentionally throwaway. A finding
  worth keeping graduates to a `TestCase` under `Sources/BurmeseIMETestSupport/Suites/`.

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

#### Building from the CLI with `xcodebuild`

`xcode-select -p` on this machine points at
`/Library/Developer/CommandLineTools`, so a bare `xcodebuild` invocation
fails with *tool 'xcodebuild' requires Xcode*. Override the developer
dir inline instead of running `sudo xcode-select -s`:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild -project native/macos/BurmeseIMEApp.xcodeproj \
               -scheme BurmeseIMEPreferences \
               -configuration Debug build
```

Swap `-scheme` for `BurmeseIME` or `BurmeseIMEInstaller` as needed.
Output is noisy — pipe through `tail -5` to confirm
`** BUILD SUCCEEDED **`, or `grep -E "error:|warning:"` to surface
issues. Products land in
`~/Library/Developer/Xcode/DerivedData/BurmeseIMEApp-*/Build/Products/Debug/`.

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

Like Pinyin, Kotoeri, and other system IMEs, the engine is designed to
let users freely interlace Myanmar with Latin, digits, punctuation, or
any other characters in the surrounding document. Two mechanisms enable
this:

- **Literal tail (intra-run):** `splitComposablePrefix` peels
  non-composable trailing chars (digits, punctuation, symbols) off the
  buffer. The composable prefix converts to Myanmar; the literal tail is
  re-appended verbatim to each candidate surface (see [`BurmeseEngine.swift:986`](Packages/BurmeseIMECore/Sources/BurmeseIMECore/BurmeseEngine.swift#L986)).
  So `thar.` commits as `သာ.` without breaking composition.
- **Raw passthrough (inter-run):** when the composable prefix has no
  legal Burmese parse, the engine emits the raw buffer verbatim. The IMK
  controller (see [`BurmeseInputController.swift:193`](native/macos/BurmeseIME/BurmeseInputController.swift#L193))
  keeps typeable ASCII in the buffer rather than force-committing, so
  users can type English words inline and get them back unchanged.

Invariant: within a single composed run, Myanmar output never has Latin
characters interleaved *between* Myanmar chars (see `PropertySuite` /
`FuzzSuite`). Mixing scripts across runs in the document is by design.

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

### Variant disambiguation and the `2` / `3` suffixes

Several Burmese consonants and vowels share a spoken reading — e.g.
တ/ဋ both read as `t`, ပ/ဋ both read as `p`, လ/ဠ both read as `l`,
ဥ/ဦ both read as `oo`, အ/ဧ both read as `a`. `Romanization.swift`
disambiguates these **internally** by giving the variant entries a
numeric suffix in the rule key:

| Digit-less key | Myanmar | Suffixed key | Myanmar (variant) |
|---|---|---|---|
| `t` | တ | `t2` | ဋ |
| `p` | ပ | `p2` | ဋ |
| `l` | လ | `l2` | ဠ |
| `oo` | ဥ | `oo2` | ဦ |
| `aa` | အာ | `aa2` | အါ |

These suffixes are **not part of the user-facing romanization scheme.**
Users type without digits (`ta`, `pa`, `loo`, …), and both variants
appear in the candidate panel — the common one on top, the rare one
below, ranked by LM + lexicon frequency. Picking the variant from the
panel is how the user selects it; on commit, the engine writes the
surface of the chosen candidate, and `SQLiteUserHistoryStore` records
the pick so the learned history promotes it next time the same
digitless reading is typed.

ASCII digits in the user-input buffer are always literal. Typing `2`
produces Myanmar digit `၂` (with ASCII `2` as an alternate). Typing
`min+galar2par2` produces `မင်္ဂလာ၂ပါ၂` — the two `၂`s at the
positions the user typed `2`, not variant disambiguators. The numeric
suffixes appear only inside:

- `Romanization.consonantRules` / `vowelRules` rule keys (internal)
- `ReverseRomanizer` output when there is no canonical digit-less
  reading for an irregular form (used by `LexiconBuilder` to populate
  `reading_alias_index`)
- SQLite `reading_alias_index.alias_reading` rows compiled from
  reverse-romanized readings

The user→parser path must never interpret a digit as a variant selector.

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
