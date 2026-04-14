# Myanmar IME for macOS

A native macOS Input Method Editor (IME) for typing Burmese/Myanmar script using a standard Latin (QWERTY) keyboard. Built in Swift using the **Hybrid Burmese** romanization scheme — a grammar-aware engine that enforces orthographic legality and ranks candidates through grammar alternatives, lexicon frequency, and user history.

---

## Overview

Myanmar IME replaces a prior browser-based transliteration engine with a fully native macOS input method. The legacy web engine used a flat 490-rule lookup table that permitted illegal Burmese character combinations and leaked raw Latin characters on failed parses (e.g. `foo → fိုို`, `kya2 → ကြ2`). The native engine enforces formal orthographic rules: if a consonant cannot legally take a vowel or medial pattern, the combination never reaches the output, and digit-marked ambiguities are resolved through the candidate window instead of forcing users to type `2` or `3`.

**Key improvements over the legacy web IME:**

| Area | Legacy Web | Native macOS |
|------|-----------|--------------|
| Conversion core | Flat DP over 490 rules with raw fallback | Grammar-aware incremental Viterbi parser |
| Illegal combinations | Emitted as Burmese or mixed script | Remain raw preedit, never committed |
| Candidate source | Direct conversion + 3 dictionary matches | Grammar + lexicon (83k words) + user history |
| Candidate count | Up to 4 visible | 5 per page |
| Candidate UI | Custom HTML popup | Native `IMKCandidates` panel |
| Selection shortcut | `Alt+1–7` | `Option+1–5` |
| `Space` key | Commits + inserts literal space | First Space commits only; second inserts space |
| `Escape` | Leaves raw Latin in editor | Commits raw Latin unchanged and cancels |

---

## Features

### Grammar-Aware Composition
The engine validates every candidate against a formal orthographic legality table before it reaches the candidate window. Consonant–medial–vowel triples are checked against allowed onset classes, medial rules, and vowel realizations, ensuring no malformed Burmese syllable is ever emitted.

### Viterbi Syllable Parser
Incremental composition uses a weighted finite-state / Viterbi dynamic-programming search across syllable states — not a flat longest-match table. The parser resolves ambiguous roman sequences by scoring the global best parse over the entire buffer, not syllable-by-syllable, enabling multi-syllable phrase candidates.

### Candidate Ranking Pipeline
Candidates are ranked by a four-level priority:
1. **Grammar validity** — Orthographically legal forms score highest
2. **Canonical alias cost** — Preferred romanization spellings rank above aliases
3. **Lexicon frequency** — 83,789-word corpus with log-scale unigram and bigram scores
4. **User history** — Selection count + recency boost (planned for beta)

### Digitless Candidate Disambiguation
Compose mode accepts digitless input only. Instead of typing `ky2ar:` or `thar2`, users type the base reading (`kyar`, `thar`) and choose among grammar and lexicon candidates such as `ကြား` / `ကျား` or `သာ` / `သါ`.

### Hybrid Burmese Romanization
The romanization scheme maps 33 base consonants × medial combinations × 97 vowel/final tokens = **490 total rules**. The encoding follows the pattern:

```
[h] <consonant> [w] [y|y2] <vowel_suffix>
```

| Prefix/Suffix | Myanmar Sign | Meaning |
|---|---|---|
| `h` prefix | ှ | ha-htoe medial |
| `y` suffix | ြ | ya-yit (ra) medial |
| `y2` suffix | ျ | ya-pin medial |
| `w` suffix | ွ | wa-hswe medial |

**Examples:**

| Roman input | Myanmar output | Notes |
|---|---|---|
| `thar` | သာ | onset `th` + vowel `ar` |
| `thar` → candidate | သါ | digitless input can still surface canonical `thar2` |
| `kyaw` | ကြော် | onset `k`+ya-yit + vowel `aw` |
| `min+galarpar2` | မင်္ဂလာပါ | multi-syllable with virama stack |
| `hkwy2` | ကျွှ | onset with three medials |

### 11 Medial Combinations
```
[h]  [w]  [h,w]  [y2]  [h,y2]  [w,y2]  [h,w,y2]  [y]  [h,y]  [w,y]  [h,w,y]
```

### Unicode Canonical Output
Output characters are emitted in Unicode canonical order (ျ < ြ < ွ < ှ). Leading dependent vowels are automatically prefixed with U+200C (zero-width non-joiner). No Latin characters ever appear in committed output.

### 83,789-Word SQLite Lexicon
The lexicon is compiled from a TSV source file into a bundled read-only SQLite database with:
- `entries(id, surface, canonical_reading, unigram_score)` — log-scale frequency
- `reading_index(canonical_reading, entry_id, rank_score)` — prefix lookup index
- `reading_alias_index(alias_reading, canonical_reading, entry_id, rank_score, alias_penalty)` — digitless compose lookup index
- `bigram_context(prev_surface, next_entry_id, score)` — contextual phrase ranking

### Native macOS Integration
- Built on **InputMethodKit** (`IMKInputController`)
- Uses **IMKCandidates** native panel (`kIMKSingleRowSteppingCandidatePanel`)
- Marked text via `setMarkedText`, committed text via `insertText`
- Two input modes: **Compose** (က) and **Roman** (ABC)
- 5-candidate page with `Option+1–5` selection shortcuts

---

## Architecture

```
myanmar-ime/
├── Packages/BurmeseIMECore/          # Swift Package (core library)
│   ├── Sources/
│   │   ├── BurmeseIMECore/
│   │   │   ├── BurmeseEngine.swift      # Orchestration: update(buffer:) → CompositionState
│   │   │   ├── SyllableParser.swift     # Viterbi DP parser (grammar-aware)
│   │   │   ├── Grammar.swift            # Orthographic legality tables
│   │   │   ├── Romanization.swift       # 490-rule consonant/medial/vowel mappings
│   │   │   ├── ReverseRomanizer.swift   # Myanmar → romanization (for lexicon building)
│   │   │   ├── Unicode.swift            # Myanmar block constants and char classification
│   │   │   ├── Types.swift              # Public API types
│   │   │   ├── CandidateStore.swift     # Protocol: lookup(prefix:previousSurface:)
│   │   │   └── SQLiteCandidateStore.swift  # SQLite-backed lexicon store
│   │   └── LexiconBuilder/
│   │       └── main.swift               # TSV → SQLite compilation pipeline
│   ├── Tests/BurmeseIMECoreTests/
│   │   ├── EngineTests.swift
│   │   ├── GrammarTests.swift
│   │   ├── RomanizationTests.swift
│   │   ├── ReverseRomanizerTests.swift
│   │   └── LegacyFixtureTests.swift
│   └── Data/
│       └── BurmeseLexiconSource.tsv    # 83,789 entries (surface, frequency, override?)
├── LegacyFixtures/                     # Reference: legacy JS engine + fixture data
│   ├── myangler.js                     # Original flat rule-table engine
│   └── generate_fixtures.js            # Test vector generation utility
└── IMPLEMENTATION_PLAN.md              # Full product spec and design document
```

### Architecture Layers

```
┌─────────────────────────────────────────────────────┐
│              BurmeseInputController                  │  ← InputMethodKit (IMK)
│   handleEvent → update buffer → commit/cancel        │
└────────────────────┬────────────────────────────────┘
                     │ CompositionState
┌────────────────────▼────────────────────────────────┐
│                 BurmeseEngine                        │  ← Orchestration
│   Grammar candidates + Lexicon candidates + History  │
└──────────┬──────────────────────┬───────────────────┘
           │                      │
┌──────────▼──────────┐  ┌────────▼───────────────────┐
│   SyllableParser    │  │   SQLiteCandidateStore      │
│   Viterbi DP        │  │   Prefix + bigram lookup    │
│   Grammar legality  │  │   83,789-word corpus        │
└──────────┬──────────┘  └────────────────────────────┘
           │
┌──────────▼──────────┐
│  Grammar + Romaniz. │  ← Legality tables, 490 rules
└─────────────────────┘
```

### Public API

```swift
// Input mode
enum InputMode { case compose, roman }

// Composition state (returned on every keystroke)
struct CompositionState {
    var rawBuffer: String
    var selectedCandidateIndex: Int
    var candidates: [Candidate]
    var committedContext: [String]
}

// A single candidate shown in the panel
struct Candidate {
    let surface: String          // Myanmar text
    let reading: String          // Romanization
    let source: CandidateSource  // .grammar | .lexicon | .history
    let score: Double
}

// Main engine
final class BurmeseEngine {
    func update(buffer: String, context: [String]) -> CompositionState
    func commit(state: CompositionState) -> String
}

// Lexicon protocol (swappable for testing)
protocol CandidateStore {
    func lookup(prefix: String, previousSurface: String?) -> [Candidate]
}
```

---

## Requirements

- **macOS 14 (Sonoma)** or later
- **Xcode 15+** with Command Line Tools (required for Swift 6.0 and InputMethodKit)
- No external runtime dependencies (SQLite3 is a system framework)

---

## Building

### Build the Core Library and Run Tests

```bash
cd Packages/BurmeseIMECore
swift build
swift test
```

### Build the Lexicon Database

The `LexiconBuilder` executable compiles the TSV word list into the bundled SQLite database:

```bash
cd Packages/BurmeseIMECore
swift run LexiconBuilder \
    Data/BurmeseLexiconSource.tsv \
    ../native/macos/Data/BurmeseLexicon.sqlite
```

The TSV format is:
```
surface<TAB>frequency[<TAB>override_reading]
```

- `surface` — Myanmar text (e.g. `မင်္ဂလာပါ`)
- `frequency` — Raw corpus count used to compute log-scale unigram score
- `override_reading` — Optional explicit romanization for irregular entries

### Build the Full macOS App (Xcode required)

```bash
open native/macos/BurmeseIME.xcworkspace
# Build scheme: BurmeseIMEApp (Release)
```

---

## Installation (Internal Sideload)

1. **Build** `BurmeseIMEApp` in Xcode with local code signing (no provisioning profile required for personal use).
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
   - Registration is completed by a short helper process on launch. Give macOS 5-10 seconds, then close and reopen System Settings if it was already open.
5. **Enable** the input source:
   - Open **System Settings → Keyboard → Text Input → Edit**
   - Click **+**, search for **Burmese**, and add it
6. **Switch** input modes using the macOS input menu in the menu bar:
   - **က** — Burmese Compose mode
   - **ABC** — Roman passthrough mode

---

## Key Bindings (Compose Mode)

| Key | Action |
|-----|--------|
| `a–z`, `+`, `*`, `'`, `:`, `.` | Extend the composition buffer |
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

Tests are organized into six files:

| File | Coverage |
|------|----------|
| `EngineTests.swift` | Public API: empty buffer, input, commit/cancel, normalization, mixed grammar/lexicon pages |
| `GrammarTests.swift` | Medial legality per consonant, valid/invalid syllable combinations |
| `RomanizationTests.swift` | All 33 consonants, vowel sorting, normalization, alias helpers |
| `ReverseRomanizerTests.swift` | Myanmar → roman conversion, round-trip stability |
| `LegacyFixtureTests.swift` | Known-good conversions, digitless numeric alternates, no mixed-script output, leading vowel (U+200C) |
| `SQLiteCandidateStoreTests.swift` | Alias-aware lexicon prefix lookup against the bundled database |

Run all tests:

```bash
cd Packages/BurmeseIMECore
swift test
```

**Key invariants tested:**
- All committed output contains only Myanmar Unicode (U+1000–U+109F) and U+200C — no Latin leakage
- Forward parse → reverse romanize → forward parse produces the same surface (round-trip stable)
- Illegal consonant+medial pairs never appear in committed output

---

## Lexicon

The bundled lexicon (`BurmeseLexiconSource.tsv`) contains **83,789 entries** compiled from the legacy web corpus. It provides:

- Log-scale unigram frequency scores normalized to the 0–1000 range
- Bigram context scores for phrase-level candidate ranking
- Optional explicit reading overrides for irregular or high-priority entries

The lexicon grows by appending rows to the TSV and re-running `LexiconBuilder`. The engine and schema remain unchanged as the corpus expands.

---

## Roadmap

- [x] `BurmeseIMECore` — Grammar, romanization, Viterbi parser, SQLite lexicon
- [x] `LexiconBuilder` — TSV → SQLite compilation pipeline
- [x] Unit tests — Grammar, romanization, engine, legacy fixture compatibility
- [x] `BurmeseIMEExtension` — `IMKInputController` integration and key handling
- [x] `BurmeseIMEApp` — SwiftUI settings/onboarding container app
- [x] Xcode workspace — `BurmeseIME.xcworkspace` with app + extension targets
- [ ] User history store — `UserHistory.sqlite` with selection count + recency boost

---

## Background and Design Decisions

**Why not port the web engine?** The legacy `myangler.js` engine uses a flat 490-rule table with no grammar model. It produces outputs like `par → ပာ` (legal) but also `foo → fိုို` and `kya2 → ကြ2` (mixed-script garbage). Rather than patching the table, the native engine starts from formal orthographic rules so illegal combinations are structurally impossible.

**Why Viterbi instead of longest-match?** Longest-match is ambiguous over multi-syllable buffers. Viterbi DP scores the globally best parse, enabling the engine to rank whole-word and phrase candidates rather than resolving syllables greedily left-to-right.

**Why SQLite?** The lexicon is a read-only asset bundled with the app. SQLite provides prefix-index queries and bigram lookups with zero network or server dependency, sub-millisecond latency, and a stable on-disk format that survives app updates.

**Why internal sideload?** Distributing an IME through the Mac App Store requires notarization and additional entitlements. Sideload installation to `~/Library/Input Methods/` is the standard path for all third-party macOS IMEs and requires only local signing.
