# Myanmar IME

A native Input Method Editor for typing Burmese/Myanmar script from a
standard Latin keyboard. The shared engine is written in Swift and uses a
grammar-aware Hybrid Burmese romanization: it parses the whole composing
buffer, filters illegal orthography, and ranks candidates with parser
scores, a bundled SQLite lexicon, a trigram language model, and learned
per-user history.

**Current status.** The core package is shared by both native shells.
macOS ships an InputMethodKit bundle plus a SwiftUI Preferences app and
unsigned `.pkg` installer. Linux ships an IBus engine plus a GTK4 /
libadwaita Preferences app packaged as `ibus-myangler.deb`; see
[`native/linux/README.md`](native/linux/README.md). On this checkout,
`swift run TestRunner` passes **1636/1636 cases** and **8959/8959
assertions**.

---

## Quick Start

### Core Engine

```bash
cd Packages/BurmeseIMECore
swift build
swift run TestRunner
```

`TestRunner` is the primary development loop. It runs the same shared
test suites as the XCTest target and works on plain Swift toolchains
where `swift test` may not provide XCTest.

### macOS

```bash
open native/macos/BurmeseIME.xcworkspace
```

Schemes:

| Scheme | Builds |
|---|---|
| `BurmeseIME` | Headless IMK bundle installed under `~/Library/Input Methods/` |
| `BurmeseIMEPreferences` | SwiftUI settings app installed under `/Applications/` |
| `BurmeseIMEInstaller` | Aggregate target that builds both apps and writes `native/macos/build/BurmeseIME-Install.pkg` |

Install the package by right-clicking it and choosing **Open**. Then add
the input source in **System Settings -> Keyboard -> Text Input**.

### Linux

```bash
cd native/linux
./scripts/dev-install.sh
ibus restart
```

The dev install stages the engine, Swift shim, schema, desktop file, and
IBus component under `~/.local/`. Add **Myangler (Burmese, Romanized)**
from your desktop's Region & Language / Input Sources panel. For a
release-style package:

```bash
cd native/linux
./scripts/build-deb.sh
sudo apt install build/ibus-myangler_*.deb
ibus restart
```

The `.deb` uses a release Swift shim built with `-static-stdlib`, so end
user systems do not need Swift installed.

---

## What It Does

### Grammar-Aware Composition

The engine models Burmese syllable structure instead of doing plain
string replacement. It checks onset, medial, vowel, coda, asat, virama,
tone, and Unicode storage-order rules before a candidate reaches the
panel. Illegal surfaces are either dropped in favor of clean siblings or
fall back to the raw typed buffer when no Burmese interpretation is safe.

The durable invariants enforced today include:

- no dependent vowel or combining mark without an anchor;
- no medial after a vowel mark;
- no second independent-vowel anchor inside an open cluster;
- no duplicated ya-asat coda chains;
- no asat after a tone mark, after a digit, or after an incompatible
  dependent vowel;
- no multi-cluster dependent-vowel run on one base, except the explicit
  legal storage shapes such as `102D 102F` and `1031 + 102B/102C`;
- no raw composing punctuation wedged between Myanmar scalars.

### Whole-Buffer Parsing

Composition uses an N-best Viterbi parser over syllable states. The
parser scores the whole buffer, not one syllable at a time, so
multi-syllable and phrase candidates can win when the lexicon and
language model support them.

Long buffers use a sliding window. A stable prefix is rendered once and
memoized; only the active tail is re-parsed. Split guards avoid cutting
inside onset digraphs, cluster aliases, coda sites, or other spans where
a later keystroke could still change the syllable.

### Ranking

The production engine combines:

1. orthographic legality and sanitizer results;
2. parser score, structure cost, and alias cost;
3. bundled SQLite lexicon frequency and alias rows;
4. Kneser-Ney trigram LM scores from `BurmeseLM.bin`;
5. learned user history keyed by alias-normalized reading.

The macOS IMK controller and Linux IBus FFI both load the same bundled
SQLite lexicon and trigram LM at startup, then attach a writable
SQLite-backed user-history store. Ranking questions should therefore be
validated with that production-equivalent stack, not with a bare
`BurmeseEngine()` unless the claim is explicitly about parser or
sanitizer behavior.

### Literal Escape Hatch

The candidate panel is never empty for non-empty typeable input. If the
engine cannot find a clean Burmese parse, it synthesizes a raw literal
candidate whose surface is exactly what the user typed.

Policy:

- if no candidates survive, the raw buffer is the only candidate;
- if the top candidate still contains mostly unconverted ASCII, the raw
  buffer is promoted to rank 0;
- if a known lexicon entry is rank 0, the raw echo is skipped to keep the
  common Burmese path clean;
- otherwise the raw buffer is appended as a lower-ranked escape hatch.

This is why users can type English, URLs, symbols, or partial Burmese
inside the IME without losing keystrokes.

---

## Romanization

The engine uses a spelling-aligned Hybrid Burmese romanization. Basic
onset shape:

```text
[h] <consonant> [w] [y] <vowel/final suffix>
```

Key points:

- `h` before a sonorant is ha-htoe: `hma`, `hna`, `hla`, `hnga`.
  `mhar` is not "ma + ha-htoe"; the standard typing is `hmar`.
- `y` after a consonant is the structural ya-yit medial. Common
  ya-pin-dominant sounds are also reachable through shortcuts and
  candidate alternates.
- `+` is an explicit syllable / stack boundary. Recent fixes make
  user-typed `+` at least as strong as inferred stack markers when the
  LM tries to prefer a different segmentation.
- User-facing digits are literal digits, not variant selectors. The
  `2` and `3` suffixes in rule tables and reverse-romanizer output are
  internal disambiguators only.

Examples:

| Input | Candidate | Notes |
|---|---|---|
| `thar` | `သာ` | `th` onset + long `ar` |
| `kyaw` | `ကျော်` / `ကြော်` | ya-pin / ya-yit variants rank by context |
| `jwantaw` | `ကျွန်တော်` | cluster shortcut |
| `chit` | `ချစ်` | cluster shortcut |
| `gypan` | `ဂျပန်` | loanword-friendly cluster shortcut |
| `hma` | `မှ` | ha-htoe is prefix `h` |
| `min+galarpar` | `မင်္ဂလာပါ` | explicit virama-stack boundary |
| `ii.` / `ii` | `ဣ` / `ဤ` | independent vowels |
| `oo` / `oo:` | `ဩ` / `ဪ` | independent o family |
| `ywe` | `၍` | standalone particle |
| `ei` | `၏` | standalone particle |

### Cluster Shortcuts

Shortcuts coexist with structural typing:

| Shortcut | Typical surface | Structural family |
|---|---|---|
| `j`, `jw` | `ကျ`, `ကျွ` | ka + ya-pin, with ya-yit sibling reachable |
| `ch`, `chw` | `ချ`, `ချွ` | kha + ya-pin, with ya-yit sibling reachable |
| `gy`, `gyw` | `ဂျ`, `ဂျွ` | ga + ya-pin |
| `sh`, `shw` | `ရှ`, `ရွှ` | ra + ha / wa + ha |

A narrow open alias gap remains: phonetic `y` should be able to reach
some spelling-`r` lemmas such as `hsayar -> ဆရာ`. Broader loanword
spellings investigated alongside that were validated as wrong-input
artifacts and are not planned as fuzzy matching.

### Variants and Digits

Several letters share a reading: တ/ဋ, လ/ဠ, ဥ/ဦ, and others. Users type
the digit-less reading and choose the desired surface from the candidate
panel. History then promotes the chosen surface next time.

ASCII digits typed by the user stay at the typed position and are
offered as Myanmar-digit and ASCII-digit surfaces:

- `min+galar2par2` -> `မင်္ဂလာ၂ပါ၂` / `မင်္ဂလာ2ပါ2`;
- `ky2an` is `k` + literal `2` + `an`, never a request for ya-pin;
- `t2ote`, `u2`, `pa2`, `kar2` keep the `2` as a literal digit.

### Punctuation

`.` and `:` are composing tone keys when they complete a Burmese
syllable, so `thar.` correctly surfaces the creaky-tone form `သာ့`,
with literal `သာ.` still reachable. Literal punctuation is preserved
when it is clearly document punctuation or part of a literal tail.

Optional punctuation mapping rewrites ASCII `. , ! ? ;` to Myanmar
punctuation when the setting is enabled and the surrounding context is
Myanmar. It is off by default.

---

## Architecture

```text
myanmar-ime/
├── Packages/BurmeseIMECore/
│   ├── Sources/BurmeseIMECore/
│   │   ├── Engine/                 BurmeseEngine split by ranking,
│   │   │                           normalization, punctuation, digits,
│   │   │                           frozen-prefix cache, sanitizers
│   │   ├── Parser/                 SyllableParser N-best DP
│   │   ├── Grammar.swift           orthographic legality tables
│   │   ├── Romanization.swift      rule tables and aliases
│   │   ├── ReverseRomanizer.swift  Myanmar -> romanization
│   │   ├── SQLiteCandidateStore.swift
│   │   ├── SQLiteUserHistoryStore.swift
│   │   ├── IMESettings.swift
│   │   └── LanguageModel/
│   ├── Sources/BurmeseIMETestSupport/
│   │   └── Suites/                 single source of all test cases
│   ├── Sources/BurmeseBench/       performance benchmark
│   ├── Sources/LexiconBuilder/     TSV -> SQLite compiler
│   ├── Tools/corpus_builder/       corpus -> TSV + SQLite + LM
│   └── Tests/
├── native/macos/                   IMK bundle, SwiftUI Preferences, pkg
└── native/linux/                   IBus engine, Swift shim, GTK prefs, deb
```

The core package has no macOS-only runtime dependency. SQLite imports use
`SQLite3` on macOS and the `CSQLite` system-library target on Linux.

### Conversion Pipeline

```text
raw buffer
  -> split literal head / digit prefix / composable run / literal tail
  -> normalize roman input
  -> parse with N-best DP, stack inference, and sliding window as needed
  -> merge grammar, lattice, lexicon, LM, and history candidates
  -> apply sanitizer passes
  -> attach literals and digit surfaces
  -> inject raw-buffer fallback
  -> return CompositionState
```

The native shells call `BurmeseEngine.update(buffer:context:)` on each
keystroke, display `CompositionState.candidates`, then call
`commit(state:)` and `recordSelection(state:)` when the user chooses a
candidate.

### Settings and History

Shared settings:

| Setting | Default |
|---|---|
| Candidate page size | `9` |
| Commit on space | `false` |
| Cluster aliases | `true` |
| LM prune margin | `8.0` |
| Anchor commit threshold | `8` |
| Burmese punctuation mapping | `false` |
| Number measure-word suggestions | `false` |
| Learning | `true` |

macOS stores settings in the shared
`group.com.myangler.inputmethod.burmese` UserDefaults suite and history
under `~/Library/Application Support/BurmeseIME/UserHistory.sqlite`.
Linux mirrors settings through GSettings schema
`com.myangler.inputmethod.burmese` and stores history at
`~/.local/share/myangler/UserHistory.sqlite`.

---

## Building and Testing

### Requirements

- Swift 6.0+.
- SQLite development headers. macOS gets SQLite from the SDK; Linux needs
  `libsqlite3-dev`.
- Linux native shell builds additionally need IBus, GLib, json-glib,
  meson, ninja, GTK4, libadwaita, PyGObject, and Debian packaging tools;
  see [`native/linux/README.md`](native/linux/README.md).

### Tests

All cases live in
`Packages/BurmeseIMECore/Sources/BurmeseIMETestSupport/Suites/` and are
registered once in `BurmeseTestSuites.all`. `TestRunner` and the XCTest
driver both iterate that list.

```bash
cd Packages/BurmeseIMECore
swift run TestRunner
```

The runner emits `.` for passes and `F` for failures. A clean run ends
with:

```text
=== Summary ===
  Cases: 1636/1636 passed
  Assertions: 8959/8959 passed
ALL 8959 TESTS PASSED
```

Use the right engine layer for a test:

- parser-only: rule matching and DP legality;
- bare `BurmeseEngine()`: engine post-processing, sanitizer, literal
  fallback, and non-ranking invariants;
- production-equivalent engine with bundled SQLite + trigram LM:
  user-visible rank-0 and multi-syllable ranking claims.

### Benchmarks

```bash
cd Packages/BurmeseIMECore
swift run -c release BurmeseBench
swift run -c release BurmeseBench --check Tests/Benchmarks/baseline.json
swift run -c release BurmeseBench --update Tests/Benchmarks/baseline.json
```

The baseline is per platform. `--check` compares only the current host's
section and fails if p95 regresses more than 20% or p99 more than 30%.
When adding a benchmark scenario, update every platform section already
present in `baseline.json`; the drift suite enforces scenario parity.

### Lexicon and LM Data

These files are generated together and must not be hand-edited:

- `Packages/BurmeseIMECore/Data/BurmeseLexiconSource.tsv`;
- `native/macos/Data/BurmeseLexicon.sqlite`;
- `native/macos/Data/BurmeseLM.bin`;
- Linux staging copies/symlinks under `native/linux/data/staging/`.

Regenerate through the corpus pipeline:

```bash
cd Packages/BurmeseIMECore/Tools/corpus_builder
python -m corpus_builder.build all \
    --corpus chuuhtetnaing/myanmar-c4-dataset \
    --tsv-out ../../Data/BurmeseLexiconSource.tsv \
    --lm-out  ../../../../native/macos/Data/BurmeseLM.bin \
    --vocab-size 80000 \
    --prune 0 10 20
```

`LexiconBuilder` is the final TSV -> SQLite stage, but it should not be
run in isolation against hand-edited data because the SQLite IDs and LM
word IDs must stay aligned. `LexiconLMDriftSuite` guards that contract.

---

## Installation

### macOS

1. Build `BurmeseIMEInstaller` in Xcode or run
   `native/macos/installer/build.sh`.
2. Right-click `native/macos/build/BurmeseIME-Install.pkg` -> **Open**.
3. The installer places `BurmeseIME.app` in
   `~/Library/Input Methods/` and `BurmeseIMEPreferences.app` in
   `/Applications/`.
4. Add **Burmese** in System Settings -> Keyboard -> Text Input.
5. Switch between **က** compose mode and **ABC** passthrough mode from
   the input-source menu.

Uninstall:

```bash
rm -rf "$HOME/Library/Input Methods/BurmeseIME.app"
rm -rf /Applications/BurmeseIMEPreferences.app
rm -f  "$HOME/Library/Preferences/group.com.myangler.inputmethod.burmese.plist"
```

### Linux

```bash
sudo apt install ./native/linux/build/ibus-myangler_*.deb
ibus restart
```

Then add **Myangler (Burmese, Romanized)** from Region & Language /
Input Sources. Runtime dependencies are declared by the package; a Swift
toolchain is required only on the build host.

User data lives at `~/.local/share/myangler/` and GSettings/dconf under
`/com/myangler/inputmethod/burmese/`. `apt purge ibus-myangler` removes
binaries and schemas but leaves history intact by design.

---

## Key Bindings

| Key | Compose-mode action |
|---|---|
| Printable ASCII | Extend the composition buffer |
| Space | Commit the selected candidate; optionally insert a literal space |
| Return / Enter | Commit the selected candidate |
| Backspace | Delete the last buffer character |
| Escape | Commit the raw Latin buffer unchanged |
| Arrow keys, Page Up / Page Down | Navigate the candidate panel |
| Tab / Shift-Tab | Next / previous candidate |
