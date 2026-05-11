# Claude Code Guide - Myanmar IME

Compact orientation for agents working in this repository. `README.md`
is the user-facing / contributor-facing overview; this file captures the
repo-specific practices and behavioral decisions that prevent repeated
wrong turns.

## Non-Negotiables

**Do not bootstrap system tooling locally.** If a build dependency is
missing, stop and ask the user to install the system package. Do not
install build tools with `pip --user`, unpack `-dev` packages into
`/tmp`, vendor headers, symlink runtime libraries, or shadow system
tools. This applies on Linux and macOS. Give the exact install command
and retry after the user runs it.

Examples:

```bash
sudo apt install libsqlite3-dev pkg-config
sudo apt install libibus-1.0-dev libglib2.0-dev libjson-glib-dev meson ninja-build
swiftly install 6.3.1
```

**Generated data is not edited by hand.** The TSV lexicon, SQLite
lexicon, and trigram LM are one pipeline output. Change the corpus
builder, regenerate all outputs together, and keep
`LexiconLMDriftSuite` green.

**Use the shared test suite.** The primary loop is:

```bash
cd Packages/BurmeseIMECore
swift build
swift run TestRunner
```

Current local status: 1355/1355 cases and 5721/5721 assertions pass.
`swift test` is secondary; plain SPM toolchains may not provide XCTest.

## Layout

```text
Packages/BurmeseIMECore/        pure Swift engine package
  Sources/BurmeseIMECore/
    Engine/                     BurmeseEngine split by topic
    Parser/                     SyllableParser N-best DP
    LanguageModel/              trigram LM protocol and mmap loader
    Data/                       bundled non-lexicon resources
  Sources/BurmeseIMETestSupport/
    Suites/                     single source of all cases
  Sources/LexiconBuilder/       TSV -> SQLite compiler
  Sources/BurmeseBench/         perf benchmark
  Tests/TestRunner/             CLI test runner
  Tests/Benchmarks/baseline.json
  Tools/corpus_builder/         corpus -> TSV + SQLite + LM
native/macos/                   IMK bundle, SwiftUI prefs, installer
native/linux/                   IBus C engine, Swift FFI, GTK prefs, deb
tasks/                          open/archived task notes, mostly ignored
```

The core has no macOS-only runtime dependency. SQLite imports must use:

```swift
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#endif
```

`BurmeseIMECore`, `BurmeseIMETestSupport`, and `LexiconBuilder` already
depend on `CSQLite` for Linux in `Package.swift`; new SQLite-using
targets need the same conditional dependency.

## Engine Layers

Pick the lowest layer that can reproduce the behavior, but do not use a
lower layer for a user-visible ranking claim.

| Layer | Construct | Use for |
|---|---|---|
| Parser-only | `SyllableParser()` | rule matching, DP, direct legality scans |
| Bare engine | `BurmeseEngine()` | sanitizer behavior, literal fallback, digits/punctuation, non-ranking engine invariants |
| Production-equivalent | `BurmeseEngine(candidateStore: SQLiteCandidateStore(...), languageModel: TrigramLanguageModel(...))` | rank-0 output, multi-syllable ranking, lexicon/LM/lattice behavior |

The macOS controller and Linux FFI both load bundled
`BurmeseLexicon.sqlite`, `BurmeseLM.bin`, and a writable user-history
store. A bare-engine result can disagree with the shipped IME; that is
diagnostic information, not product truth.

Production-data test suites use `BundledArtifacts.lexiconPath` and
`BundledArtifacts.trigramLMPath`, then skip cleanly if artifacts are
absent. Copy that pattern for rank-0 claims. Existing examples include
`AnchorStabilitySuite`, `LexiconRankingSuite`,
`MidBufferStackInferenceSuite`, `WindowingKinziAcrossThresholdSuite`,
and `ExplicitPlusKinziDisplacementSuite`.

## Durable Behavior Rules

These are the logic decisions distilled from the archived tasks and the
current suites.

### 1. Grammar and Sanitizers

Candidates should be orthographically legal before they reach the panel.
The parser legality scan and engine sanitizers must stay in lockstep for
the same scalar classes.

Sanitizers normally filter only when at least one clean sibling survives.
When every Myanmar candidate is structurally bad, preserve the user's
escape hatch by promoting the raw literal fallback.

Important rejected shapes:

- orphan ZWNJ + dependent mark when an independent-vowel sibling exists;
- medial scalars after dependent-vowel marks;
- repeated or chained independent-vowel anchors inside one open cluster;
- doubled ya-asat coda chains on any anchor;
- asat after tone, after a digit, or after an incompatible dependent
  vowel;
- cross-category dependent-vowel chains on one base except the legal
  `102D 102F` and `1031 + 102B/102C` storage shapes;
- composing punctuation (`*`, `'`, `:`, `.`) wedged between Myanmar
  scalars;
- phantom mid-surface `1021 + dep-vowel` anchors when a standalone
  independent-vowel sibling is available.

### 2. Literal Fallback

For non-empty typeable input, the panel must not be empty.
`injectLiteralFallback` synthesizes `surface == reading == rawBuffer`.

Positioning:

- empty candidate list -> literal only;
- sanitizer-retained illegal rank 0 or mostly-unconverted ASCII rank 0
  -> literal at rank 0;
- clean lexicon hit at rank 0 -> no literal echo;
- otherwise -> append literal at the bottom.

The literal surface is the raw buffer, not the digit-mapped display
surface. This is especially important for inputs such as `comp2`.

### 3. Digits Are Literal

ASCII digits in user input are never variant selectors. They stay at the
typed position and are offered as Myanmar-digit and ASCII-digit
candidates. Internal keys such as `ny2`, `t2`, `ky2`, `ay2`, and `u2`
exist in rule tables, reverse romanizer output, and alias indexes; the
user-facing path treats the digit as data.

Consequences:

- `ky2an` must not become `ကျန်`;
- `t2ote` must not become a `t2` retroflex variant without the literal
  digit;
- `min+galar2par2` keeps both `2`s at their typed positions;
- a digit never anchors asat or dependent marks.

### 4. Punctuation and Tones

`.` and `:` are composing tone keys when they complete a Burmese
syllable. `thar.` -> `သာ့` at rank 0 is correct by design, with literal
`သာ.` still reachable. Do not "fix" this into punctuation-first
behavior.

Literal punctuation stays literal when it is a document-punctuation tail,
part of a literal split, or an English contraction / ASCII run. Optional
Burmese punctuation mapping is a setting-driven output transform, off by
default, and applies only in Myanmar context.

### 5. Romanization Conventions

Ha-htoe is a prefix before the consonant: `hma`, `hna`, `hla`, `hnga`,
`hmar`. Inputs like `mhar` mean `ma + ha...` under this scheme; archived
TASK-065 is invalid for that reason.

`y` after a consonant is structural ya-yit. Ya-pin-dominant clusters are
promoted by engine ranking and cluster shortcuts (`j`, `ch`, `gy`, `sh`)
while ya-yit siblings stay reachable. TASK-058 fixed the `Cyw` / `Cwy`
typing-order asymmetry.

Open TASK-062 is deliberately narrow: add a phonetic `y` -> spelling `r`
reading alias for native lemmas such as `hsayar -> ဆရာ`. It is not a
general fuzzy-matching or loanword-pronunciation project.

### 6. Explicit `+`

User-typed `+` is a hard syllable / stack boundary. The LM may rank among
legal stack variants, but it should not displace the user's explicit
kinzi/stack intent with an unrelated segmentation. TASK-031 made
explicit `+` as strong as inferred stack markers for rank-0 promotion.

### 7. Variants and Panel Reachability

Homophonous variants should surface in the candidate panel for the
digit-less reading. They do not have to be rank 0 or on the first page.
TASK-063 was invalid because the structural variant was present but the
test was paging-blind.

User history records the selected surface under the alias-normalized
reading and may promote that surface above the LM/lexicon order later.

**General reachability rule.** The user's intended conversion must
*appear in the candidate panel at all*, top 3 strongly preferred. A
candidate that is reachable below rank 0 is a soft issue, not a
critical bug, and should not be "fixed" by changes that destabilize
ranking elsewhere. Some cases are structurally undecidable from buffer
text alone — e.g. a committed `<C><V>a` shape (silent-absorption)
versus an in-flight typing prefix of a corpus word (`apha` mid-stream
of `aphaya`) — and rank-0 promotion would require a commit-vs-preview
signal the engine does not have. In such cases, panel presence
satisfies the rule; do not trade ranking regressions for rank-0
purity. See archived TASK-039 / TASK-042 for the worked example.

### 8. Windowing and Performance

Long buffers use frozen-prefix + active-tail composition. Never split
inside an onset digraph, cluster alias, coda/stack site, or context where
a future keystroke can still change the prior syllable. Anchor stability
must not be tested with buffers whose expected prefix depends on a known
ranking bug.

Performance regressions are guarded by `BurmeseBench` and a per-platform
baseline. Cache changes should preserve parser diversity for realistic
well-formed input, not just pass pathological repeated-letter tests.

## Build and Test Details

### Core

```bash
cd Packages/BurmeseIMECore
swift build
swift run TestRunner
```

The runner prints one character per case, then a failure report and
summary. Passing cases are intentionally unnamed. Cases run in parallel,
so tests must use fresh engines, UUID-specific `IMESettings(suiteName:)`,
and isolated temp paths.

`FUZZ_BUDGET_MS` controls the fuzz suite wall-clock budget, default
1000 ms.

### Benchmarks

```bash
swift run -c release BurmeseBench
swift run -c release BurmeseBench --check Tests/Benchmarks/baseline.json
swift run -c release BurmeseBench --update Tests/Benchmarks/baseline.json
swift run -c release BurmeseBench --scenario medium
```

`--check` fails on >20% p95 or >30% p99 regression. The baseline has
separate platform sections. Adding a scenario requires updating every
platform key already present; `BenchBaselineFormatSuite` checks parity.

`--check` defaults to `--samples 5`: the full scenario sweep is run
five times and the per-scenario median p50/p95/p99 is compared against
the baseline. Median-of-N is required to keep the gate meaningful on
noisy Linux dev hosts where a single run trips threshold scenarios
(notably `plus_chain_30` p99) ~1/5 times even when the underlying perf
state is healthy. Override with `--samples N` for ad-hoc runs;
`--update` defaults to a single sample so captured baselines reflect a
fresh measurement (and should be re-run a few times to confirm the
captured numbers are not anomalous).

### Corpus Data

```bash
cd Packages/BurmeseIMECore/Tools/corpus_builder
python -m corpus_builder.build all \
    --corpus chuuhtetnaing/myanmar-c4-dataset \
    --tsv-out ../../Data/BurmeseLexiconSource.tsv \
    --lm-out  ../../../../native/macos/Data/BurmeseLM.bin \
    --vocab-size 80000 \
    --prune 0 10 20
```

`0 10 20` is the shipping LM prune default. Change corpus-builder code
and its tests before regenerating data; do not patch the generated TSV,
SQLite, or LM binary directly.

## Native Shells

### macOS

`native/macos/` contains the IMK bundle, SwiftUI Preferences app, and
installer. The controller loads the shared production stack at startup:
SQLite lexicon, trigram LM, SQLite user history, and shared
`IMESettings`.

CLI builds that need full Xcode should set `DEVELOPER_DIR` inline:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project native/macos/BurmeseIMEApp.xcodeproj \
             -scheme BurmeseIMEPreferences \
             -configuration Debug build
```

Do not run `sudo xcode-select -s` for this repo. The two apps are not
sandboxed; they share settings through
`~/Library/Preferences/group.com.myangler.inputmethod.burmese.plist`.

There is no automated IMK keystroke harness. Controller changes need a
local install and manual typing in real apps.

### Linux

`native/linux/` ships `ibus-myangler.deb`.

- `ibus-engine/`: C IBus engine, meson build, D-Bus process.
- `swift-shim/`: `libBurmeseIMEFFI.so`, a Swift dynamic library exposing
  the C ABI in `ibus-engine/src/ffi.h`.
- `preferences/`: PyGObject + GTK4 + libadwaita app.
- `data/`: GSettings schema, IBus component XML, desktop file, icon.
- `debian/` and `scripts/`: packaging and dev-install entry points.

Dev loop:

```bash
cd native/linux
./scripts/dev-install.sh
ibus restart
```

Release package:

```bash
cd native/linux
./scripts/build-deb.sh
sudo apt install build/ibus-myangler_*.deb
ibus restart
```

The engine binary also supports:

```bash
ibus-engine-myangler --xml
ibus-engine-myangler --diagnostics
ibus-engine-myangler --reverse-romanize "ကျား"
ibus-engine-myangler --ibus
```

Linux settings mirror `IMESettings.Key` through GSettings schema
`com.myangler.inputmethod.burmese`. `cluster-aliases-enabled` rebuilds
the Swift engine because `SyllableParser` bakes that flag at init time.

## Working Patterns

- Core parser or engine change: edit under
  `Packages/BurmeseIMECore/Sources/BurmeseIMECore/`, add/adjust a suite
  under `Sources/BurmeseIMETestSupport/Suites/`, run `swift run
  TestRunner`.
- Ranking claim: use a production-equivalent helper with
  `BundledArtifacts`; do not write `BurmeseEngine()` and generalize.
- Sanitizer change: assert the scalar predicate directly and add engine
  cases proving clean siblings win while raw fallback remains available.
- Native macOS keystroke change: edit
  `native/macos/BurmeseIME/BurmeseInputController.swift`, build/install,
  and test in the running IME.
- Native Linux keystroke change: edit `native/linux/ibus-engine/src/`,
  run meson tests where relevant, dev-install, restart IBus, and type in
  a real client such as `gedit`.
- Preferences change: macOS uses `IMESettingsViewModel` +
  `UserDefaults(suiteName:)`; Linux uses GSettings bindings in
  `native/linux/preferences/` and FFI setters.
- SQLite-backed feature: use the dual import guard and update target
  dependencies if the new code lives outside the existing SQLite-aware
  targets.
- Throwaway probes belong under `/tmp/`; anything worth preserving
  becomes a suite case. Always choose the engine layer first.

## Open Tasks

Open tasks are listed in [`tasks/README.md`](tasks/README.md). Archived
tasks are useful as design history, but many are filesystem-only because
`tasks/` is ignored in this repository. Treat invalid archived tasks as
product decisions, not loose ends.
