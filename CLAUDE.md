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
tools. This applies on Linux, macOS, and Windows. Give the exact
install command and retry after the user runs it.

Examples:

```bash
sudo apt install libsqlite3-dev pkg-config
sudo apt install libibus-1.0-dev libglib2.0-dev libjson-glib-dev meson ninja-build
swiftly install 6.3.1
```

Windows equivalents (PowerShell):

```powershell
# Visual Studio 2022 with the "Desktop development with C++" workload
# (cl, link, ATL, Windows 11 SDK 26100). Use the VS Installer GUI.
# Then install Swift 6.3+ from https://www.swift.org/install/windows/.
# SQLite via vcpkg manifest (repo ships vcpkg.json):
& "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\vcpkg\vcpkg.exe" `
    install --triplet x64-windows
# Installer tooling (optional, only for the planned WiX MSI):
dotnet tool install --global wix
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

Current local status: 1636/1636 cases and 8959/8959 assertions pass on
macOS/Linux; Windows reports 1647/1647 and 8998/8998 (extra cases from
the `os(Windows)` recognition branches added during the Phase 1 port).
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

Suite filenames describe the use case the suite protects rather than
the bug ID that originally introduced it. When adding a new suite,
follow that convention.

## Durable Behavior Rules

These are the logic decisions encoded in the current suites.

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
`hmar`. Inputs like `mhar` mean `ma + ha...` under this scheme — do not
"fix" that direction.

`y` after a consonant is structural ya-yit. Ya-pin-dominant clusters are
promoted by engine ranking and cluster shortcuts (`j`, `ch`, `gy`, `sh`)
while ya-yit siblings stay reachable. The `Cyw` / `Cwy` typing-order
asymmetry was fixed and is protected by suites; preserve it.

A narrow open alias gap remains: phonetic `y` -> spelling `r` reading
aliasing for native lemmas such as `hsayar -> ဆရာ`. This is deliberately
scoped — it is not a general fuzzy-matching or loanword-pronunciation
project.

### 6. Explicit `+`

User-typed `+` is a hard syllable / stack boundary. The LM may rank among
legal stack variants, but it should not displace the user's explicit
kinzi/stack intent with an unrelated segmentation. Explicit `+` is at
least as strong as inferred stack markers for rank-0 promotion; the
`ExplicitPlusKinziDisplacementSuite` and friends guard this.

### 7. Variants and Panel Reachability

Homophonous variants should surface in the candidate panel for the
digit-less reading. They do not have to be rank 0 or on the first page.
Reachability tests must page through results — a variant on page 2 is
not a bug.

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
purity.

### 8. Windowing and Performance

Long buffers use frozen-prefix + active-tail composition. Never split
inside an onset digraph, cluster alias, coda/stack site, or context where
a future keystroke can still change the prior syllable. Anchor stability
must not be tested with buffers whose expected prefix depends on a known
ranking bug.

Performance regressions are guarded by `BurmeseBench` and a per-platform
baseline. Cache changes should preserve parser diversity for realistic
well-formed input, not just pass pathological repeated-letter tests.

The per-keystroke hot path has several caches that must be considered
together when touching ranking, lookup, or LM code:

- `SQLiteCandidateStore` keeps bounded LRUs for both exact-match
  (`exactLookupCache`, `latticeLookupCache`) and prefix
  (`prefixLookupCache`) queries. Composite indexes
  `(alias_reading, alias_penalty, rank_score DESC)` cover the exact
  paths so the `ORDER BY` no longer spills into a temp B-tree;
  prefix-range queries still need the sort and rely on the LRU.
- `TrigramLanguageModel` pins the mmapped buffer's base pointer once
  at init and caches `surface → wordId` lookups. The `LanguageModel`
  protocol exposes `wordIdForSurface(_:)` and
  `logProb(wordId:prevId:lastId:)` so callers can skip per-call
  surface resolution; defaults keep non-vocab models working.
- `WordLatticeDecoder` keeps a decoder-level lexicon-arc cache. An
  identical buffer reuses the arcs verbatim; a strict prefix extension
  only looks up the new spans; a strict prefix truncation (backspace)
  drops trailing positions and filters arcs — no new SQL is issued.
  It also keeps a bounded LM LRU keyed on `(surfaceId, prevId, lastId)`
  `UInt32` tuples.

These caches assume the lexicon and LM are immutable once opened; if a
new feature needs to mutate either, invalidate or partition explicitly
rather than skipping the cache layer.

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

#### Windows core build

`swift build` on Windows requires the Visual Studio Developer
environment plus vcpkg's `sqlite3` paths. Always run from a shell that
loads them — agents that skip this step waste a round trip when the
manifest compile fails to find `msvcrt.lib`:

```powershell
Import-Module 'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
Enter-VsDevShell -VsInstallPath 'C:\Program Files\Microsoft Visual Studio\2022\Community' `
                 -SkipAutomaticLocation -DevCmdArguments '-arch=x64'

$vcpkg = "$env:USERPROFILE\repos\myanmar-ime\vcpkg_installed\x64-windows"
$env:INCLUDE = "$vcpkg\include;$env:INCLUDE"
$env:LIB     = "$vcpkg\lib;$env:LIB"
$env:PATH    = "$vcpkg\bin;$env:PATH"   # sqlite3.dll for runtime

cd Packages\BurmeseIMECore
swift build
swift run TestRunner
```

Windows SQLite is wired in via `Sources/CSQLite/{module.modulemap,
shim.h}` and a `.target(name: "CSQLite", condition: .when(platforms:
[.linux, .windows]))` dep in `Package.swift`. New SQLite-using targets
must keep the dual import guard
(`#if canImport(SQLite3) // #elseif canImport(CSQLite)`) and the
windowed condition; the systemLibrary itself has no pkg-config on
Windows, so the `INCLUDE` / `LIB` env vars are how clang and lld-link
find `sqlite3.h` and `sqlite3.lib`.

Two Windows-specific quirks to know before debugging:

- **SwiftPM incremental rebuild misses some edits.** On Windows, editing
  a `.swift` file occasionally doesn't bump the mtime SwiftPM's
  invalidation cache reads, so `swift build` reports "no work to do"
  even after a real source change. If a fix appears not to take, force
  it with `(Get-Item path\to\file.swift).LastWriteTime = Get-Date`
  before the next build.
- **`String.components(separatedBy: "\n")` does not split CRLF.** Swift
  treats CRLF as a single grapheme cluster, so on Windows checkouts
  (git autocrlf default) splitting on `"\n"` returns the whole file as
  one element and silently drops every TSV/text-format entry. Use
  `content.enumerateLines { line, _ in ... }` for any line-oriented
  parsing — it handles CR / LF / CRLF / U+2028 uniformly. The
  `NumberMeasureWords.tsv` loader was caught by this during the Phase
  1 port; any new line-oriented loader should follow the same pattern.

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

Scenarios come in two flavors: `bare` (parser-only engine) and `_prod`
(bundled lexicon + trigram LM + fresh user history). Prod scenarios
are the gate for production-equivalent latency claims and skip cleanly
when the bundled artifacts are absent. `ProductionBenchScenarioParitySuite`
enforces that every bare scenario name has a `_prod` peer that exists
in `baseline.json`. The truncation kind (`long_backspace_prod`,
`ain_colon_chain_backspace_prod`) feeds the engine the full buffer
off-clock then samples per-keystroke truncation cost — guards the
`WordLatticeDecoder` prefix-truncation cache path that hold-backspace
exercises.

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

`BurmeseInputController` dispatches `engine.update` to a private serial
queue rather than running it inline on the IMK keystroke. The main
queue owns `rawBuffer` and the marked text (raw Latin), so the user's
typing always renders immediately; the candidate panel updates when
each async engine result arrives. Coalescing on the main side means a
typing burst during a slow engine call produces at most two engine
runs — the in-flight one plus one for the final buffer. The committing
paths (`commitSelection`, `commitComposition`, `commitRaw`,
`reconcileClusterAliasesIfNeeded`) `engineQueue.sync` so the engine is
never accessed concurrently. When editing the controller, preserve
this rule: never call `engine.update` / `engine.commit` /
`engine.recordSelection` from the main queue without going through
`engineQueue`, and never assume an async result is still relevant —
compare against the current `rawBuffer` before applying.

The Preferences app exposes five tabs: Setup, Preferences, History
(learned entries with per-row delete and clear-all), Syntax, and
Convert. The History tab was split out so the Preferences tab stays
focused on toggles.

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

`IBusMyanglerEngine` runs `burmese_engine_update` on a per-engine
worker thread for the same reason the macOS controller uses
`engineQueue`: a slow per-keystroke parse must not block
`process_key_event`. The coordination shape is the same — the IBus
main thread owns `buffer`, `lookup_table`, `last_snapshot`, and
`last_rendered_buffer`; `update_preedit_from_buffer` echoes the raw
Latin buffer inline on every keystroke; `schedule_engine_update`
overwrites `pending_buffer` so a typing burst coalesces to at most
two worker runs; results are marshalled back via
`g_main_context_invoke` and dropped by `deliver_engine_result` if the
buffer has moved past the one the worker ran against. Commit / cancel
/ clear paths call `drain_and_wait_idle` before touching the FFI so
main and worker never reach the engine concurrently. The worker holds
a `g_object_ref` for each work cycle and a `dispose` vfunc joins the
thread before refs are released — this closes the ref-resurrection
race during engine teardown. `disable` nulls `self->handle` under
`worker_mutex` so a result still en route to the main loop is a
NULL-checked no-op. When editing `engine.c`, preserve these
invariants: never call FFI from the main thread without first
draining pending work, never assume an async snapshot is still the
user's current buffer, and never destroy state the worker thread can
still touch.

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

### Windows

There is no Windows native shell yet. Only the shared engine builds
and tests cleanly under `swift build` / `swift run TestRunner` (see
the "Windows core build" subsection above for the required Developer-
Shell + vcpkg setup). What follows is the planned architecture for the
text service, candidate window, Preferences app, and installer — a
contributor picking this up should follow the Linux template closely.

**Two-DLL layout, mirrors Linux.** Under a future `native/windows/`:

- `swift-shim/` — a Swift dynamic library that re-exports `BurmeseIMECore`
  through the same C ABI declared in `native/linux/ibus-engine/src/ffi.h`.
  The `@_cdecl` source in `native/linux/swift-shim/Sources/BurmeseIMEFFI/`
  is platform-agnostic Foundation code and ports verbatim. Output is
  `BurmeseIMEFFI.dll` + `BurmeseIMEFFI.lib`. Swift on Windows does not
  support `-static-stdlib` for distribution the way Linux does, so the
  installer must redistribute the Swift runtime DLLs from
  `%LOCALAPPDATA%\Programs\Swift\Runtimes\<version>\` next to the TIP.
- `tsf-engine/` — a non-Swift COM DLL (CMake + Ninja + MSVC C++)
  implementing the text service. Loads `BurmeseIMEFFI.dll` via
  `LoadLibraryW` + `GetProcAddress` (or the import lib) and calls the
  same FFI entry points the IBus engine uses. Reusing `ffi.h` across
  Linux and Windows is intentional — the JSON snapshot contract is the
  integration boundary.

**Use TSF, not IMM32.** New IMEs since Windows XP/Vista must be Text
Services Framework text services. IMM32 only matters for legacy app
compatibility (TSF can opt in to a shim). A TSF text service is an
**in-process COM DLL** loaded into every text-receiving process,
including browsers, Office, UWP apps, the lock screen, and protected
processes. Treat it like any other widely-loaded DLL: no process-
globals, no elevated I/O, COM apartment is STA, async work must live
on a thread the TIP creates inside each host.

**Interface map — TSF to existing concepts.** Implement these
primaries; mappings to what already exists on Linux/macOS:

| TSF interface | Maps to |
|---|---|
| `ITfTextInputProcessor[Ex]::Activate` / `Deactivate` | IMK `activateServer` / `deactivateServer`; IBus `enable` / `disable` |
| `ITfThreadMgrEventSink::OnSetFocus`, `OnInitDocumentMgr` | IBus `focus_in` / `focus_out` |
| `ITfKeyEventSink::OnTestKeyDown` / `OnKeyDown` | IMK `handle(_:client:)`; IBus `process_key_event` |
| `ITfComposition` + `ITfRange` | IMK `setMarkedText` + `insertText`; IBus `update_preedit_text` + `commit_text` |
| `ITfDisplayAttributeProvider` | Inline preedit underline / highlight |
| `ITfInputProcessorProfiles::Register*` | macOS `TISRegisterInputSource`; IBus component XML |
| `ITfLangBarItemButton` (optional) | macOS menubar Compose/Roman toggle; IBus `IBusProperty` |

**Worker-thread primitives — Linux to Win32.** The async-engine
coordination shape is identical (see `engine.c` for the source of
truth); only the primitives change:

| Linux (`engine.c`) | Win32 equivalent |
|---|---|
| `g_mutex_lock` | `SRWLOCK` (or `CRITICAL_SECTION`) |
| `g_cond_wait` / `_signal` / `_broadcast` | `SleepConditionVariableSRW` / `WakeConditionVariable[All]` |
| `g_thread_new` | `CreateThread` (or `std::jthread`) |
| `g_main_context_invoke` | `PostMessageW` to a hidden window owned by the TIP, processed in its message pump |
| `g_object_ref` / `_unref` for ref-resurrection guard | `IUnknown::AddRef` / `Release` |
| `drain_and_wait_idle` | Identical algorithm — cv on `in_flight` |

**Invariants are not negotiable — they are the same as IBus and IMK.**
Every rule already documented for the macOS controller and IBus engine
above applies verbatim to the TIP: synchronous raw preedit on the
key-event thread, coalesced async `burmese_engine_update`, stale-
buffer guard on result delivery, drain-before-commit, null-handle-on-
disable under the worker mutex, cluster-aliases reconcile rebuilds
the engine, last-3-or-4 committed-context ring for the punctuation
mapper / LM, Compose/Roman toggle bypasses the engine entirely.
Re-implementing them on top of Win32 primitives is the work — the
*shape* is fixed by what the engine assumes about its callers.

**Candidate window.** TSF does not provide one. The TIP owns a
borderless `WS_POPUP` top-level window, layered for transparency,
positioned via `ITfContextView::GetTextExt` (returns the screen
rectangle of the composition range — equivalent to the cursor rect
IMK hands `IMKCandidates`). Render with Direct2D + DirectWrite; the
shipped `Myanmar Text` font (Windows 8+) handles shaping. Keyboard
navigation (Down/Up/PageUp/PageDown/Tab/Shift-Tab) is handled inside
`OnKeyDown` — mirror the macOS keymap.

**Settings.** Store in `HKCU\Software\Myangler\BurmeseIME`. Watch with
`RegNotifyChangeKeyValue` on a worker thread; reapply via the same
per-key FFI setters Linux drives from GSettings change handlers. Same
schema and defaults as Linux/macOS (candidate page size, commit on
space, cluster aliases, LM prune margin, anchor commit threshold,
Burmese punctuation, number measure words, learning). The cluster-
aliases flip must trigger a `burmese_engine_reconcile_settings` —
`SyllableParser` bakes that flag at init time.

**Paths and data layout.**

| File | Location |
|---|---|
| `BurmeseLexicon.sqlite` | `%ProgramFiles%\Myangler\Data\BurmeseLexicon.sqlite` |
| `BurmeseLM.bin` | `%ProgramFiles%\Myangler\Data\BurmeseLM.bin` |
| `BurmeseIMEFFI.dll` + Swift runtime DLLs | `%ProgramFiles%\Myangler\` |
| `UserHistory.sqlite` | `%LOCALAPPDATA%\Myangler\UserHistory.sqlite` |

The TIP discovers `Data\` relative to its own module path via
`GetModuleFileNameW(hSelf)`. `UserHistory.sqlite` lives under
`SHGetKnownFolderPath(FOLDERID_LocalAppData)` so the TIP can write it
under Low-Integrity / AppContainer hosts (UWP, sandboxed Office).

**Preferences app.** Recommended stack is WinUI 3 (Windows App SDK) +
C# for the modern look and MSIX-friendliness. WPF is a viable fallback
if WinUI 3 friction is felt. Tabs mirror the macOS/Linux split: Setup
· Preferences · History · Convert · Diagnostics. The History tab calls
into `BurmeseIMEFFI.dll` via P/Invoke for reverse-romanize and reads
`UserHistory.sqlite` via `Microsoft.Data.Sqlite`.

**Installer.** WiX (`dotnet tool install --global wix`) builds a
per-machine MSI that:

1. Installs `MyanglerTip.dll`, `BurmeseIMEFFI.dll`, and the Swift
   runtime redistributable DLLs under `%ProgramFiles%\Myangler\`.
2. Registers the COM CLSID + ProgID via the WiX `RegistryKey` table.
3. Calls a small custom-action helper that invokes
   `ITfInputProcessorProfileMgr::RegisterProfile` (on uninstall,
   `UnregisterProfile`).
4. Drops `BurmeseLexicon.sqlite` + `BurmeseLM.bin` under
   `%ProgramFiles%\Myangler\Data\`.
5. Leaves `%LOCALAPPDATA%\Myangler\UserHistory.sqlite` intact on
   uninstall by design (matches Linux `apt purge` behaviour).

Unsigned MSI is fine for solo dev — SmartScreen warns once on
"Run anyway". A real EV cert or Microsoft Store MSIX is the path to
warning-free public distribution; not required for `swift build`,
`swift run TestRunner`, or a local dev install.

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
- Windows core change: load the VS Developer Shell, export the vcpkg
  `INCLUDE`/`LIB`/`PATH` paths, then `swift build` /
  `swift run TestRunner` from `Packages/BurmeseIMECore/`. New
  line-oriented text loaders must use `String.enumerateLines` rather
  than splitting on `"\n"` so CRLF-checkout users aren't silently
  broken. Native-shell work (TSF DLL, candidate window, MSI) follows
  the architecture in the "Native Shells → Windows" section below.
- Preferences change: macOS uses `IMESettingsViewModel` +
  `UserDefaults(suiteName:)`; Linux uses GSettings bindings in
  `native/linux/preferences/` and FFI setters.
- SQLite-backed feature: use the dual import guard and update target
  dependencies if the new code lives outside the existing SQLite-aware
  targets.
- Throwaway probes belong under `/tmp/`; anything worth preserving
  becomes a suite case. Always choose the engine layer first.
