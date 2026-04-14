# Myanmar IME for macOS

A native macOS Input Method Editor (IME) for typing Burmese/Myanmar script
using a standard Latin (QWERTY) keyboard. Built in Swift on top of the
**Hybrid Burmese** romanization scheme — a grammar-aware engine that
enforces orthographic legality and ranks candidates through grammar
alternatives, lexicon frequency, and user history.

---

## Overview

Myanmar IME is a fully native macOS input method. The engine is built
around formal Burmese orthographic rules: if a consonant cannot legally
take a vowel or medial pattern, the combination never reaches the output,
and digit-marked spelling ambiguities are resolved through the candidate
window instead of forcing users to type `2` or `3`.

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
1. **Grammar legality** — Orthographically legal forms score highest.
2. **Alias cost** — Canonical spellings rank above shortcut aliases.
3. **Parser score** — Best Viterbi path score over the buffer.
4. **Lexicon frequency** — Log-scale unigram and bigram scores from the
   bundled corpus.
5. **User history** — Selection count + recency boost (planned).

### Digitless Candidate Disambiguation
Compose mode accepts digitless input only. Instead of typing `ky2ar:` or
`thar2`, users type the base reading (`kyar`, `thar`) and choose among
grammar and lexicon candidates such as `ကြား` / `ကျား` or `သာ` / `သါ`.

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
- `bigram_context(prev_surface, next_entry_id, score)` — contextual
  phrase ranking

### Native macOS Integration
- Built on **InputMethodKit** (`IMKInputController`).
- Uses the native **IMKCandidates** panel
  (`kIMKSingleRowSteppingCandidatePanel`).
- Marked text via `setMarkedText`, committed text via `insertText`.
- Two input modes: **Compose** (က) and **Roman** (ABC).
- 5-candidate page with arrow-key navigation and `Option+1–5` selection.

---

## Architecture

```
myanmar-ime/
├── Packages/BurmeseIMECore/              # Swift Package (core library)
│   ├── Sources/
│   │   ├── BurmeseIMECore/
│   │   │   ├── BurmeseEngine.swift       # Orchestration: update(buffer:) → CompositionState
│   │   │   ├── SyllableParser.swift      # N-best Viterbi DP parser
│   │   │   ├── Grammar.swift             # Orthographic legality tables
│   │   │   ├── Romanization.swift        # Consonant/medial/vowel mappings + cluster aliases
│   │   │   ├── ReverseRomanizer.swift    # Myanmar → romanization (tests + lexicon building)
│   │   │   ├── Unicode.swift             # Myanmar block constants and char classification
│   │   │   ├── Types.swift               # Public API types
│   │   │   ├── CandidateStore.swift      # Protocol: lookup(prefix:previousSurface:)
│   │   │   └── SQLiteCandidateStore.swift  # SQLite-backed lexicon store
│   │   ├── LexiconBuilder/main.swift     # TSV → SQLite compilation pipeline
│   │   └── TestRunner/main.swift         # CLI test driver (runs without XCTest)
│   ├── Tests/BurmeseIMECoreTests/        # XCTest suite (Xcode toolchain)
│   └── Data/
│       ├── BurmeseLexiconSource.tsv      # Word list source
│       └── BurmeseLexicon.sqlite         # Prebuilt lexicon database
└── native/macos/                         # Xcode app + IMK extension
```

### Conversion pipeline

A keystroke lands in `BurmeseInputController` (the IMK extension), which
accumulates a raw Roman buffer and calls
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
    func update(buffer: String, context: [String]) -> CompositionState
    func commit(state: CompositionState) -> String
}

protocol CandidateStore {
    func lookup(prefix: String, previousSurface: String?) -> [Candidate]
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

### macOS app + input method

```bash
open native/macos/BurmeseIME.xcworkspace
# Build scheme: BurmeseIMEApp (Release)
```

---

## Installation (Internal Sideload)

1. **Build** `BurmeseIMEApp` in Xcode with local code signing (no
   provisioning profile required for personal use).
2. **Copy** the built app to the Input Methods directory:
   ```bash
   cp -R BurmeseIMEApp.app ~/Library/Input\ Methods/
   ```
3. **Launch** the app once so macOS registers the input method bundle:
   ```bash
   open ~/Library/Input\ Methods/BurmeseIMEApp.app
   ```
4. **Wait a few seconds** after first launch.
   - The app runs as a background agent, so it does not appear in the Dock.
   - Registration is completed by a short helper process on launch. Give
     macOS 5–10 seconds, then close and reopen System Settings if it was
     already open.
5. **Enable** the input source:
   - Open **System Settings → Keyboard → Text Input → Edit**.
   - Click **+**, search for **Burmese**, and add it.
6. **Switch** input modes using the macOS input menu in the menu bar:
   - **က** — Burmese Compose mode
   - **ABC** — Roman passthrough mode

---

## Key Bindings (Compose Mode)

| Key | Action |
|-----|--------|
| `a–z`, `+`, `*`, `'`, `:`, `.` | Extend the composition buffer |
| Arrow keys | Move between candidates |
| `Option+1–5` | Select candidate 1–5 |
| `Space` (first) | Commit selected candidate |
| `Space` (second) | Insert ASCII space |
| `Return` | Commit selected candidate |
| `Backspace` | Delete last character from buffer |
| `Escape` | Commit raw Latin buffer unchanged, cancel composition |
| `0–9` | Commit pending candidate, then insert the digit literally |
| Punctuation | Commit candidate, then pass punctuation through |

---

## Testing

Tests live in two parallel targets that share the same cases:

| File | Coverage |
|------|----------|
| `Sources/TestRunner/main.swift` | CLI driver for `swift run TestRunner` |
| `Tests/BurmeseIMECoreTests/EngineTests.swift` | Public API: empty buffer, input, commit/cancel, normalization |
| `Tests/BurmeseIMECoreTests/GrammarTests.swift` | Medial legality per consonant, valid/invalid syllable combinations |
| `Tests/BurmeseIMECoreTests/RomanizationTests.swift` | Consonants, vowel sorting, normalization, alias helpers |
| `Tests/BurmeseIMECoreTests/ReverseRomanizerTests.swift` | Myanmar → roman, round-trip stability |
| `Tests/BurmeseIMECoreTests/LegacyFixtureTests.swift` | Known-good conversions, cluster shortcuts, aspirated sonorants, leading vowels |
| `Tests/BurmeseIMECoreTests/SQLiteCandidateStoreTests.swift` | Alias-aware lexicon prefix lookup against the bundled database |

**Key invariants:**
- All committed output contains only Myanmar Unicode (U+1000–U+109F) and
  U+200C — no Latin leakage.
- Forward parse → reverse romanize → forward parse produces the same
  surface (round-trip stable).
- Illegal consonant+medial pairs never appear in committed output.

---

## Lexicon

The bundled lexicon (`BurmeseLexiconSource.tsv`) provides:

- Log-scale unigram frequency scores normalized to the 0–1000 range
- Bigram context scores for phrase-level candidate ranking
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
- [x] `BurmeseIMEExtension` — `IMKInputController` integration and key
      handling
- [x] `BurmeseIMEApp` — SwiftUI settings/onboarding container app
- [x] Xcode workspace — `BurmeseIME.xcworkspace` with app + extension
      targets
- [ ] User history store — `UserHistory.sqlite` with selection count +
      recency boost

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

**Why internal sideload?** Distributing an IME through the Mac App Store
requires notarization and additional entitlements. Sideload installation
to `~/Library/Input Methods/` is the standard path for all third-party
macOS IMEs and requires only local signing.
