# Myanmar IME for macOS

A native macOS Input Method Editor (IME) for typing Burmese/Myanmar script
using a standard Latin (QWERTY) keyboard. Built in Swift on top of the
**Hybrid Burmese** romanization scheme — a grammar-aware engine that
enforces orthographic legality and ranks candidates through grammar
alternatives, a trigram language model, bundled lexicon frequency, and a
learned per-user history.

---

## Overview

Myanmar IME is a fully native macOS input method. The engine is built
around formal Burmese orthographic rules: if a consonant cannot legally
take a vowel or medial pattern, the combination never reaches the output,
and spelling ambiguities are resolved through the candidate window.

The core (`BurmeseIMECore`) is a pure Swift package with no macOS-only
dependencies — it builds and runs anywhere Swift runs. All platform glue
lives in `native/macos/`.

---

## Features

### Grammar-Aware Composition
The engine validates every candidate against a formal orthographic
legality table before it reaches the candidate window. Consonant–medial–
vowel triples are checked against allowed onset classes, medial rules,
and vowel realizations, ensuring no malformed Burmese syllable is ever
emitted.

### N-Best Viterbi Syllable Parser
Incremental composition uses a weighted Viterbi dynamic-programming
search across syllable states. The parser scores the globally best parse
over the entire buffer — not syllable by syllable — enabling multi-
syllable phrase candidates. The default beam width is
`max(maxResults × 16, 64)`.

### Sliding-Window Composition
Straight N-best DP is quadratic in buffer length. For buffers longer
than ~16 characters (`maxOnsetLen + maxVowelLen + 4`), the engine splits
input into a `frozenPrefix` + `activeTail`:

- The prefix is rendered once with a single-best parse and memoized in a
  small cache. Typing left-to-right gives one cache miss per window-
  boundary advance.
- Only the active tail hits the N-best path; candidates are reconstructed
  by prepending the cached prefix.
- Because no romanization rule spans more than
  `maxOnsetLen + maxVowelLen` characters, the window boundary is always
  outside any possible rule match, so freezing the prefix is safe.

### Candidate Ranking Pipeline
Candidates are ranked by:
1. **Grammar legality** — Orthographically legal forms score highest
   (hard filter).
2. **Language model log-prob** — Kneser-Ney trigram score from the
   bundled `BurmeseLM.bin`, including frozen-prefix + active-tail
   concatenation when the sliding window is active.
3. **Alias cost** — Canonical spellings rank above shortcut aliases
   (used as a tiebreaker within an LM tier).
4. **Parser score** — Best Viterbi path score over the buffer.
5. **Lexicon frequency** — Bundled unigram priors from the SQLite store.
6. **User history** — Previously committed picks for the same alias key
   are promoted to the top of the panel. Can be disabled per user.

Candidates trailing the LM leader by more than a configurable margin
are pruned to keep the panel focused on plausible interpretations.

### Candidate Disambiguation
Users type a base reading (`kyar`, `thar`) and choose among grammar and
lexicon candidates such as `ကြား` / `ကျား` or `သာ` / `သါ` from the
candidate panel.

### Hybrid Burmese Romanization
The romanization scheme maps 33 base consonants × medial combinations ×
97 vowel/final tokens. The structural encoding follows the pattern:

```
[h] <consonant> [w] [y|y2] <vowel_suffix>
```

| Prefix/Suffix | Myanmar sign | Meaning |
|---|---|---|
| `h` prefix | ှ | ha-htoe medial |
| `y` suffix | ြ | ya-yit medial |
| `y2` suffix | ျ | ya-pin medial |
| `w` suffix | ွ | wa-hswe medial |

**Examples:**

| Roman input | Myanmar output | Notes |
|---|---|---|
| `thar` | သာ | onset `th` + vowel `ar` |
| `kyaw` | ကြော် | onset `k` + ya-yit + vowel `aw` |
| `min+galarpar` | မင်္ဂလာပာ | multi-syllable with virama stack |
| `hkwy2` | ကျွှ | onset with three medials |
| `gha` | ဃ | consonant `gh` (gha) + inherent vowel |
| `ssa` | ဿ | great-sa consonant `ss` with inherent vowel |
| `ii.` / `ii` | ဣ / ဤ | short / long independent i, no onset needed |
| `oo` / `oo:` | ဩ / ဪ | independent o, plain and tonal |
| `ywe` | ၍ | standalone locative/conjunctive particle |
| `ei` | ၏ | standalone genitive particle |

### 11 Medial Combinations
```
[h]  [w]  [h,w]  [y2]  [h,y2]  [w,y2]  [h,w,y2]  [y]  [h,y]  [w,y]  [h,w,y]
```

### Cluster-Sound Shortcuts
In addition to the structural romanization, common cluster sounds have
phonetic shortcuts that save keystrokes:

| Shortcut | Myanmar | Structural equivalent |
|---|---|---|
| `j` / `jw` | ကျ / ကျွ | `ky2` / `kwy2` |
| `ch` / `chw` | ချ / ချွ | `khy2` / `khwy2` |
| `gy` / `gyw` | ဂျ / ဂျွ | `gy2` / `gwy2` |
| `sh` / `shw` | ရှ / ရှွ | `hr` / `hrw` |

So `jwantaw` → ကျွန်တော်, `chit` → ချစ်, `gypan` → ဂျပန်. Shortcuts coexist
with structural typing — canonical input is unchanged, and alternative
readings still appear in the candidate list.

Aspirated sonorants already fall out of the `h`-prefix medial scheme:
`hma` → မှ, `hla` → လှ, `hnga` → ငှ, `hna` → နှ.

### Unicode Canonical Output
Output characters are emitted in Unicode canonical order (ျ < ြ < ွ < ှ).
Leading dependent vowels are automatically prefixed with U+200C
(zero-width non-joiner). No Latin characters ever appear in committed
output.

### Bundled SQLite Lexicon
The lexicon is compiled from a TSV source file into a bundled read-only
SQLite database:

- `entries(id, surface, canonical_reading, unigram_score)` — log-scale
  frequency
- `reading_index(canonical_reading, entry_id, rank_score)` — prefix
  lookup index
- `reading_alias_index(alias_reading, canonical_reading, entry_id, rank_score, alias_penalty)`
  — digitless compose lookup index

Contextual phrase ranking is supplied at runtime by the trigram language
model (`LanguageModel/FORMAT.md`, `TrigramLanguageModel`), not by the
SQLite schema.

### Learned Typing History
Every commit is written through `SQLiteUserHistoryStore` keyed on the
alias-normalized reading. On subsequent keystrokes with the same reading,
past picks are promoted to the top of the candidate panel. Learning can
be toggled off, and individual entries can be inspected and deleted from
the Preferences app. The database lives at
`~/Library/Application Support/BurmeseIME/UserHistory.sqlite`.

### Burmese Digits and Measure-Word Suggestions
Leading ASCII digits convert directly to Myanmar digits (U+1040–U+1049),
with the Arabic form offered as an alternate candidate. When measure-
word suggestions are enabled, pure-digit buffers produce contextual
pairings — `၂၀၂၄ ခုနှစ်` (year), `၁၀၀ ကျပ်` (currency), `၁၅ ရက်` (day),
etc. The suggestion table lives at
`Packages/BurmeseIMECore/Sources/BurmeseIMECore/Data/NumberMeasureWords.tsv`
and is hot-reloadable without a Swift rebuild.

### Burmese Punctuation Auto-Mapping
Optional feature that substitutes ASCII `. , ! ? ;` with their Myanmar
equivalents (`။` / `၊`) when the surrounding context is Myanmar. Off by
default; enable from Preferences → Text output.

### Native macOS Integration
- Built on **InputMethodKit** (`IMKInputController`).
- Uses the native **IMKCandidates** panel
  (`kIMKSingleColumnScrollingCandidatePanel`).
- Marked text via `setMarkedText`, committed text via `insertText`.
- Two input modes: **Compose** (က) and **Roman** (ABC).
- Configurable candidate page size (3 / 5 / 9 / 12), with arrow-key and
  Tab/Shift-Tab navigation. Tab is translated to Down-arrow; Shift-Tab
  to Up-arrow so users familiar with CJK IMEs get expected behaviour.
- Companion **Preferences** app (`/Applications/BurmeseIMEPreferences.app`)
  surfaces every setting live — cluster-alias shortcuts, LM prune
  margin, anchor commit threshold, punctuation mapping, measure words,
  learning toggle, history browser, and diagnostic paths. Changes
  propagate to the running IME via the shared `UserDefaults` suite.

---

## Architecture

```
myanmar-ime/
├── Packages/BurmeseIMECore/              # Swift Package (core library)
│   ├── Sources/
│   │   ├── BurmeseIMECore/
│   │   │   ├── BurmeseEngine.swift            # Orchestration: update(buffer:) → CompositionState
│   │   │   ├── SyllableParser.swift           # N-best Viterbi DP parser
│   │   │   ├── Grammar.swift                  # Orthographic legality tables
│   │   │   ├── Romanization.swift             # Consonant/medial/vowel mappings + cluster aliases
│   │   │   ├── ReverseRomanizer.swift         # Myanmar → romanization (tests + lexicon building)
│   │   │   ├── Unicode.swift                  # Myanmar block constants and char classification
│   │   │   ├── Types.swift                    # Public API types
│   │   │   ├── CandidateStore.swift           # Protocol: lookup(prefix:previousSurface:)
│   │   │   ├── SQLiteCandidateStore.swift     # SQLite-backed lexicon store
│   │   │   ├── UserHistoryStore.swift         # Protocol + default paths for learned history
│   │   │   ├── SQLiteUserHistoryStore.swift   # SQLite-backed user-history store
│   │   │   ├── IMESettings.swift              # UserDefaults-suite settings shared across processes
│   │   │   ├── IMEResources.swift             # Bundle-aware resource locator
│   │   │   ├── PunctuationMapper.swift        # ASCII → Myanmar punctuation mapping
│   │   │   ├── NumberMeasureWords.swift       # Measure-word suggestion table loader
│   │   │   ├── Data/
│   │   │   │   └── NumberMeasureWords.tsv     # Bundled measure-word table
│   │   │   └── LanguageModel/
│   │   │       ├── FORMAT.md                  # Binary format spec for BurmeseLM.bin
│   │   │       ├── LanguageModel.swift        # Protocol for language model scoring
│   │   │       └── TrigramLanguageModel.swift # Kneser-Ney trigram LM loader
│   │   ├── BurmeseIMETestSupport/        # Shared test framework + suites
│   │   ├── BurmeseBench/                 # Benchmark executable + regression check
│   │   └── LexiconBuilder/main.swift     # TSV → SQLite compilation pipeline
│   ├── Tests/
│   │   ├── BurmeseIMECoreTests/          # XCTest drivers (one file iterating every suite)
│   │   ├── TestRunner/main.swift         # CLI runner (works without XCTest)
│   │   └── Benchmarks/baseline.json      # Committed perf baseline for --check
│   ├── Tools/corpus_builder/             # Offline data pipeline (see its own README)
│   └── Data/
│       └── BurmeseLexiconSource.tsv      # Word list source
└── native/macos/
    ├── BurmeseIME/                       # Headless IMK bundle → ~/Library/Input Methods/
    ├── BurmeseIMEPreferences/            # SwiftUI settings app → /Applications/
    ├── installer/                        # build.sh + postinstall for the unsigned .pkg
    ├── BurmeseIME.xcworkspace            # Xcode workspace with all schemes
    ├── BurmeseIMEApp.xcodeproj           # Project holding both apps + installer target
    └── Data/
        ├── BurmeseLexicon.sqlite         # Prebuilt lexicon database
        └── BurmeseLM.bin                 # Trigram language model binary
```

### Conversion pipeline

A keystroke lands in `BurmeseInputController` (inside the IME bundle),
which accumulates a raw Roman buffer and calls
`BurmeseEngine.update(buffer:context:)` on every change.

```
buffer ─► BurmeseEngine.update
            │
            ├─ splitComposablePrefix       composable chars vs. literal tail
            ├─ Romanization.normalize      alias folding, digit stripping
            ├─ right-shrink probe loop     drop trailing chars until parse is legal
            ├─ sliding-window split        frozen prefix + active tail (long inputs)
            ├─ SyllableParser.parseCandidates
            │     (N-best Viterbi DP over onset+vowel rules)
            ├─ CandidateStore.lookup       lexicon prefix match
            └─ merge, rank, expand aa      returns CompositionState
```

### Public API

```swift
enum InputMode { case compose, roman }

struct CompositionState {
    var rawBuffer: String
    var selectedCandidateIndex: Int
    var candidates: [Candidate]
    var committedContext: [String]
}

struct Candidate {
    let surface: String          // Myanmar text
    let reading: String          // Romanization
    let source: CandidateSource  // .grammar | .lexicon | .history
    let score: Double
}

final class BurmeseEngine {
    init(
        candidateStore: any CandidateStore = EmptyCandidateStore(),
        historyStore: any UserHistoryStore = EmptyUserHistoryStore(),
        languageModel: any LanguageModel = NullLanguageModel(),
        settings: IMESettings? = nil
    )

    func update(buffer: String, context: [String]) -> CompositionState
    func commit(state: CompositionState) -> String
    func recordSelection(state: CompositionState)
    func cancel(state: CompositionState) -> String
}

protocol CandidateStore {
    func lookup(prefix: String, previousSurface: String?) -> [Candidate]
}

protocol UserHistoryStore {
    func lookup(prefix: String, previousSurface: String?) -> [Candidate]
    func record(reading: String, surface: String)
    func remove(reading: String, surface: String)
    func listAll() -> [HistoryEntry]
    func clearAll()
}

protocol LanguageModel {
    func scoreSurface(_ surface: String, context: [String]) -> Double
}
```

---

## Requirements

- **macOS 14 (Sonoma)** or later
- **Xcode 15+** with Command Line Tools (Swift 6.0, InputMethodKit)
- No external runtime dependencies (SQLite3 is a system framework)

---

## Building

### Core engine (primary dev loop)

```bash
cd Packages/BurmeseIMECore
swift build
swift run TestRunner
```

`TestRunner` is a hand-rolled CLI that exercises the same cases as the
XCTest suite and prints `ALL N TESTS PASSED` at the end. It works with a
plain SPM toolchain where `swift test` may fail with *no such module
'XCTest'*. If you have the full Xcode toolchain, `swift test` runs the
XCTest targets too.

### Lexicon rebuild

The `LexiconBuilder` executable compiles the TSV word list into the
bundled SQLite database. Only needed when `BurmeseLexiconSource.tsv`
changes.

```bash
cd Packages/BurmeseIMECore
swift run LexiconBuilder \
    Data/BurmeseLexiconSource.tsv \
    ../../native/macos/Data/BurmeseLexicon.sqlite
```

The TSV format is:

```
surface<TAB>frequency[<TAB>override_reading]
```

- `surface` — Myanmar text (e.g. `မင်္ဂလာပါ`)
- `frequency` — Raw corpus count used to compute log-scale unigram score
- `override_reading` — Optional explicit romanization for irregular
  entries

### macOS apps + installer

Open the Xcode workspace and pick a scheme:

```bash
open native/macos/BurmeseIME.xcworkspace
```

| Scheme | What it builds |
|---|---|
| `BurmeseIME` | Headless IMK bundle (the IME itself) |
| `BurmeseIMEPreferences` | SwiftUI settings app |
| `BurmeseIMEInstaller` | Aggregate target: builds both and produces `build/BurmeseIME-Install.pkg` |

`BurmeseIMEInstaller` uses Xcode's automatic signing (stable team
signature) — that's what lets TCC persist grants instead of re-prompting.
A CLI equivalent is `native/macos/installer/build.sh`.

Neither app is sandboxed. Shared settings live in
`~/Library/Preferences/group.com.myangler.inputmethod.burmese.plist`,
read by both processes via `UserDefaults(suiteName:)`.

---

## Installation

1. Build the pkg: in Xcode, select scheme **BurmeseIMEInstaller** → ⌘B.
   Output lands at `native/macos/build/BurmeseIME-Install.pkg`.
2. Right-click the pkg → **Open** (the pkg is unsigned, so a
   double-click is blocked by Gatekeeper).
3. The installer:
   - Places `BurmeseIME.app` in `~/Library/Input Methods/`
   - Places `BurmeseIMEPreferences.app` in `/Applications/`
   - Launches the Preferences app to kick off IME self-registration
4. Enable the input source:
   - Open **System Settings → Keyboard → Text Input → Edit**.
   - Click **+**, search for **Burmese**, add it.
5. Switch input modes from the menu bar:
   - **က** — Burmese Compose mode
   - **ABC** — Roman passthrough mode

### Updating

Re-run the pkg. Postinstall removes the previous IME bundle before
installing the new one. No uninstall step needed.

### Uninstall

```bash
rm -rf "$HOME/Library/Input Methods/BurmeseIME.app"
rm -rf /Applications/BurmeseIMEPreferences.app
rm -f  "$HOME/Library/Preferences/group.com.myangler.inputmethod.burmese.plist"
```
Then remove the input source in System Settings → Keyboard → Text Input.

---

## Key Bindings (Compose Mode)

| Key | Action |
|-----|--------|
| Any printable ASCII (`!`–`~`, excluding space) | Extend the composition buffer. Non-composable characters (digits, punctuation) flow through the engine's literal-tail pipeline. |
| Arrow keys, Page Up / Page Down | Navigate the candidate panel |
| `Tab` / `Shift+Tab` | Next / previous candidate (translated to arrows internally) |
| `Space` (first) | Commit selected candidate (and insert a literal space if *Commit on space* is enabled) |
| `Space` (no composition) | Insert ASCII space |
| `Return` | Commit selected candidate |
| `Backspace` | Delete last character from buffer |
| `Escape` | Commit raw Latin buffer unchanged, cancel composition |

---

## Testing

Every case is defined once in `Sources/BurmeseIMETestSupport/Suites/` and
exposed via `BurmeseTestSuites.all`. Two runners iterate that shared list:

- `swift run TestRunner` — CLI driver (works without XCTest)
- `swift test` / Xcode Test navigator — `BurmeseSuiteXCTests.swift`
  drives every suite through a single thin XCTest wrapper

Suites under `Sources/BurmeseIMETestSupport/Suites/`:

| Suite | Coverage |
|-------|----------|
| `RomanizationSuite` | Consonants, vowel sorting, normalization, alias helpers |
| `GrammarSuite` | Medial legality, valid/invalid syllable combinations |
| `ReverseRomanizerSuite` | Myanmar → roman + round-trip stability |
| `ClusterAliasSuite` | Parser-level cluster-alias onset expansions |
| `EngineSuite` | Public API: buffer lifecycle, commit/cancel, ranking |
| `LexiconRankingSuite` | Merge ordering, alias penalties, real-lexicon spot checks |
| `LanguageModelSuite` | Binary-format round-trip, unigram/bigram/trigram backoff |
| `PunctuationSuite` | Punctuation mapper + in-composition tail conversion |
| `NumberMeasureWordsSuite` | Measure-word expansion, year/currency patterns |
| `UserHistorySuite` | SQLite history store, score decay, engine integration |
| `IMESettingsSuite` | UserDefaults suite round-trip, engine honors settings |
| `SQLiteCandidateStoreSuite` | Alias-aware prefix lookup (bundled + legacy schema) |
| `PropertySuite` | 5 properties: legal syllables parse, no Latin interleaving (×2), sliding-window equivalence, anchor monotonicity |
| `FuzzSuite` | Budget-capped random buffers (`FUZZ_BUDGET_MS`, default 1000ms) |

**Key invariants:**
- All committed output contains only Myanmar Unicode (U+1000–U+109F) and
  U+200C — no Latin interleaved inside composed runs.
- Forward parse → reverse romanize → forward parse produces the same
  surface (round-trip stable).
- Illegal consonant+medial pairs never appear in committed output.

### Benchmarks

```bash
cd Packages/BurmeseIMECore
swift run -c release BurmeseBench                                  # JSON on stdout
swift run -c release BurmeseBench --check Tests/Benchmarks/baseline.json
swift run -c release BurmeseBench --update Tests/Benchmarks/baseline.json
swift run -c release BurmeseBench --scenario medium
```

Scenarios: `short` (6-char buffer × 1000), `medium` (11-char × 1000),
`long` (30-char × 500), `incremental` (38-char typed one key at a time).
Metrics: p50/p95/p99/max per scenario in microseconds. Warm-up = 50
iterations; each scenario runs three times with the middle-p95 run
reported. `--check` exits 1 on >20% p95 or >30% p99 regression against
the committed baseline.

---

## Lexicon

The bundled lexicon (`BurmeseLexiconSource.tsv`) provides:

- Log-scale unigram frequency scores normalized to the 0–1000 range
  (corpus-derived; see `Packages/BurmeseIMECore/Tools/corpus_builder/`)
- Optional explicit reading overrides for irregular or high-priority
  entries

The lexicon grows by appending rows to the TSV and re-running
`LexiconBuilder`. The engine and schema remain unchanged as the corpus
expands.

---

## Roadmap

- [x] `BurmeseIMECore` — Grammar, romanization, N-best Viterbi parser,
      sliding-window composition, SQLite lexicon
- [x] Cluster-sound shortcuts (`j`, `ch`, `gy`, `sh` + `w` variants)
- [x] `LexiconBuilder` — TSV → SQLite compilation pipeline
- [x] Unit tests — Grammar, romanization, engine, fixture regressions
- [x] `BurmeseIME` — headless IMK bundle with `IMKInputController`
      integration and key handling
- [x] `BurmeseIMEPreferences` — SwiftUI settings app with live
      cross-process reconciliation
- [x] `BurmeseIMEInstaller` — aggregate Xcode target + unsigned `.pkg`
      one-click installer
- [x] Trigram language model — Kneser-Ney scored re-ranking over
      grammar and lexicon candidates
- [x] User history store — `UserHistory.sqlite` writes on every commit
      with alias-normalized keys; entries surfaced + manageable from the
      Preferences app
- [x] Burmese digits, punctuation auto-mapping, measure-word suggestions
- [x] Corpus data pipeline — `Tools/corpus_builder/` builds aligned
      lexicon + LM from a public corpus

---

## Design Decisions

**Why grammar-first?** Starting from formal orthographic rules makes
illegal combinations structurally impossible, rather than filtering them
after the fact.

**Why Viterbi instead of longest-match?** Longest-match is ambiguous
over multi-syllable buffers. Viterbi DP scores the globally best parse,
so the engine ranks whole-word and phrase candidates rather than
resolving syllables greedily left to right.

**Why a sliding window?** N-best DP is quadratic in buffer length
because each DP state carries a growing output string. Freezing the
prefix once it is outside any possible rule match keeps per-keystroke
work bounded on long inputs.

**Why SQLite?** The lexicon is a read-only asset bundled with the app.
SQLite provides prefix-index queries and bigram lookups with zero
network or server dependency, sub-millisecond latency, and a stable
on-disk format that survives app updates.

**Why an unsigned pkg + per-user install?** Distributing an IME through
the Mac App Store requires notarization and a paid Developer Program
membership. A `pkgbuild`-produced unsigned pkg signed ad-hoc for the pkg
wrapper (but with team-signed app bundles inside) is enough for personal
use and trusted sideload: Gatekeeper asks once for the pkg, after which
the team-signed apps run without per-launch prompts.

**Why no sandbox?** Sandboxed apps sharing state via an App Group need
that App Group officially registered with Apple under the team — only
possible with paid Developer Program membership. With free Apple
Development signing, macOS can't persist the TCC grant for App-Group
data access and re-prompts on every IME launch. Dropping the sandbox
removes the App Group dependency; the two processes share settings
through a plain `UserDefaults` suite file in
`~/Library/Preferences/`. Trade-off: no MAS distribution path, which
isn't a goal here.
