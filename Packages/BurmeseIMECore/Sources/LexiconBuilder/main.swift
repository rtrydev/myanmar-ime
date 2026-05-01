import Foundation
import BurmeseIMECore
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#endif

// Glibc declares `stderr` as a plain global var, which Swift 6 strict
// concurrency rejects when read from anywhere. FileHandle.standardError is
// Sendable and works the same on Darwin and Glibc.
private func writeStderr(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}

/// LexiconBuilder: reads BurmeseLexiconSource.tsv, reverse-romanizes each entry
/// through the grammar engine, and emits BurmeseLexicon.sqlite.
///
/// Source format: surface<TAB>frequency<TAB>override_reading?
///
/// Output tables:
///   entries(id, surface, canonical_reading, unigram_score)
///   reading_index(canonical_reading, entry_id, rank_score)
///   reading_alias_index(alias_reading, canonical_reading, entry_id, rank_score, alias_penalty)
///   reading_compose_index(compose_reading, canonical_reading, entry_id, rank_score, alias_penalty, separator_penalty)

// CLI: LexiconBuilder <input.tsv> <output.sqlite> [--lm <path>]
// `--lm` enables LM↔SQLite vocab drift checking. When provided (or when a
// default-located `BurmeseLM.bin` is found next to the sqlite output), the
// builder loads the LM after parsing the TSV and fails non-zero if any
// lexicon surface is absent from LM vocab. Missing LM file is a warning,
// not an error, so probe scripts that don't care about drift still work.
var positionalArgs: [String] = []
var lmArg: String? = nil
var argi = 1
while argi < CommandLine.arguments.count {
    let a = CommandLine.arguments[argi]
    if a == "--lm" {
        guard argi + 1 < CommandLine.arguments.count else {
            writeStderr("Error: --lm requires a path argument\n")
            exit(1)
        }
        lmArg = CommandLine.arguments[argi + 1]
        argi += 2
    } else {
        positionalArgs.append(a)
        argi += 1
    }
}

guard positionalArgs.count >= 2 else {
    writeStderr("Usage: LexiconBuilder <input.tsv> <output.sqlite> [--lm <BurmeseLM.bin>]\n")
    writeStderr("\nReads a Burmese lexicon TSV and emits a SQLite database.\n")
    writeStderr("TSV format: surface<TAB>frequency[<TAB>override_reading]\n")
    writeStderr("--lm enables LM↔SQLite drift assertion; default location is\n")
    writeStderr("     `BurmeseLM.bin` next to the output sqlite.\n")
    exit(1)
}

let inputPath = positionalArgs[0]
let outputPath = positionalArgs[1]

// Resolve the LM path for drift checking. Explicit `--lm` wins; otherwise
// try the sibling `BurmeseLM.bin` of the sqlite output. Nil means "no LM
// found — drift check skipped".
let resolvedLMPath: String? = {
    if let explicit = lmArg { return explicit }
    let sqliteURL = URL(fileURLWithPath: outputPath)
    let sibling = sqliteURL.deletingLastPathComponent()
        .appendingPathComponent("BurmeseLM.bin").path
    return FileManager.default.fileExists(atPath: sibling) ? sibling : nil
}()

// Read input TSV
guard let data = FileManager.default.contents(atPath: inputPath),
      let content = String(data: data, encoding: .utf8) else {
    writeStderr("Error: Cannot read input file: \(inputPath)\n")
    exit(1)
}

struct LexiconEntry {
    let surface: String
    let frequency: Double
    let overrideReading: String?
}

/// True when `surface` contains any scalar outside the Myanmar block
/// (U+1000–U+109F), excluding ZWNJ (U+200C) and ZWJ (U+200D) which
/// appear inside legitimate orthographic clusters. Mirrors
/// `corpus_builder.segmenter._has_non_myanmar_scalar`. Polluted rows
/// (ASCII punct suffix from corpus sentences ending in `..`/`...`,
/// curly quotes, ellipsis, emoji, …) anchor garbage entries in the
/// candidate panel; this guard keeps them out of the SQLite even if
/// the upstream corpus_builder filter regresses.
func surfaceContainsNonMyanmarScalar(_ s: String) -> Bool {
    if s.isEmpty { return true }
    for scalar in s.unicodeScalars {
        let v = scalar.value
        if v == 0x200C || v == 0x200D { continue }
        if v < 0x1000 || v > 0x109F { return true }
    }
    return false
}

/// Detect ya-pin canonical readings (e.g. `ky2aung:`, `khy2at*`,
/// `gy2ay`) — any consonant cluster ending in `y2` before a vowel.
/// Used to emit a zero-penalty alias row alongside the digit-bearing
/// canonical so lookup's penalty-ordered LIMIT does not hide ya-pin
/// surfaces under alias_penalty=0 ya-yit siblings.
func isYapinReading(_ reading: String) -> Bool {
    guard reading.contains("y2") else { return false }
    let chars = Array(reading)
    for i in 0..<chars.count - 1 where chars[i] == "y" && chars[i + 1] == "2" {
        guard i >= 1 else { continue }
        let prev = chars[i - 1]
        if prev.isLetter && prev != "y" {
            return true
        }
    }
    return false
}

// Parse TSV lines
var entries: [LexiconEntry] = []
let lines = content.components(separatedBy: .newlines)
var lineNum = 0

for line in lines {
    lineNum += 1
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

    let fields = trimmed.components(separatedBy: "\t")
    guard fields.count >= 2 else {
        writeStderr("Warning: Skipping malformed line \(lineNum): \(trimmed)\n")
        continue
    }

    let surface = fields[0]
    guard let frequency = Double(fields[1]) else {
        writeStderr("Warning: Invalid frequency on line \(lineNum): \(fields[1])\n")
        continue
    }
    if surfaceContainsNonMyanmarScalar(surface) {
        // Polluted surface — corpus_builder is the source of truth;
        // dropping here keeps a stale TSV from re-poisoning SQLite.
        continue
    }

    let overrideReading = fields.count >= 3 && !fields[2].isEmpty ? fields[2] : nil
    entries.append(LexiconEntry(surface: surface, frequency: frequency, overrideReading: overrideReading))
}

writeStderr("Parsed \(entries.count) entries from \(inputPath)\n")

// Compute max frequency for normalization
let maxFreq = entries.map(\.frequency).max() ?? 1.0

// Open SQLite database
nonisolated(unsafe) var db: OpaquePointer?
// Remove existing file
if FileManager.default.fileExists(atPath: outputPath) {
    try? FileManager.default.removeItem(atPath: outputPath)
}

guard sqlite3_open(outputPath, &db) == SQLITE_OK else {
    writeStderr("Error: Cannot create database: \(outputPath)\n")
    exit(1)
}

func exec(_ sql: String) {
    var err: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
        let msg = err.map { String(cString: $0) } ?? "unknown error"
        writeStderr("SQL Error: \(msg)\n  SQL: \(sql)\n")
        sqlite3_free(err)
        exit(1)
    }
}

// Create schema
exec("PRAGMA journal_mode = WAL")
exec("PRAGMA synchronous = OFF")
exec("""
    CREATE TABLE entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        surface TEXT NOT NULL,
        canonical_reading TEXT NOT NULL,
        unigram_score REAL NOT NULL
    )
    """)
exec("""
    CREATE TABLE reading_index (
        canonical_reading TEXT NOT NULL,
        entry_id INTEGER NOT NULL REFERENCES entries(id),
        rank_score REAL NOT NULL
    )
    """)
exec("""
    CREATE TABLE reading_alias_index (
        alias_reading TEXT NOT NULL,
        canonical_reading TEXT NOT NULL,
        entry_id INTEGER NOT NULL REFERENCES entries(id),
        rank_score REAL NOT NULL,
        alias_penalty INTEGER NOT NULL
    )
    """)
exec("""
    CREATE TABLE reading_compose_index (
        compose_reading TEXT NOT NULL,
        canonical_reading TEXT NOT NULL,
        entry_id INTEGER NOT NULL REFERENCES entries(id),
        rank_score REAL NOT NULL,
        alias_penalty INTEGER NOT NULL,
        separator_penalty INTEGER NOT NULL
    )
    """)
// Bigram context is supplied at runtime by the language model
// (see LanguageModel/FORMAT.md); no table is written here.

// Insert entries
exec("BEGIN TRANSACTION")

var insertEntryStmt: OpaquePointer?
sqlite3_prepare_v2(db, "INSERT INTO entries (surface, canonical_reading, unigram_score) VALUES (?1, ?2, ?3)", -1, &insertEntryStmt, nil)

var insertReadingStmt: OpaquePointer?
sqlite3_prepare_v2(db, "INSERT INTO reading_index (canonical_reading, entry_id, rank_score) VALUES (?1, ?2, ?3)", -1, &insertReadingStmt, nil)

var insertAliasStmt: OpaquePointer?
sqlite3_prepare_v2(
    db,
    "INSERT INTO reading_alias_index (alias_reading, canonical_reading, entry_id, rank_score, alias_penalty) VALUES (?1, ?2, ?3, ?4, ?5)",
    -1,
    &insertAliasStmt,
    nil
)

var insertComposeStmt: OpaquePointer?
sqlite3_prepare_v2(
    db,
    "INSERT INTO reading_compose_index (compose_reading, canonical_reading, entry_id, rank_score, alias_penalty, separator_penalty) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    -1,
    &insertComposeStmt,
    nil
)

var reverseFailCount = 0
var insertCount = 0
var writtenSurfaces: [String] = []

entryLoop: for entry in entries {
    // Get canonical reading: override or reverse-romanize
    let reading: String
    if let override = entry.overrideReading {
        reading = Romanization.normalize(override)
    } else {
        let reversed = ReverseRomanizer.romanize(entry.surface)
        if reversed.isEmpty {
            reverseFailCount += 1
            continue
        }
        reading = reversed
    }

    // Normalize score: log-scale frequency normalized to 0-1000
    let score = maxFreq > 0 ? (log(entry.frequency + 1) / log(maxFreq + 1)) * 1000.0 : 0.0

    // Insert into entries
    let surfaceCStr = entry.surface
    let readingCStr = reading
    sqlite3_bind_text(insertEntryStmt, 1, surfaceCStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_text(insertEntryStmt, 2, readingCStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_double(insertEntryStmt, 3, score)

    guard sqlite3_step(insertEntryStmt) == SQLITE_DONE else {
        writeStderr("Warning: Failed to insert entry: \(entry.surface)\n")
        sqlite3_reset(insertEntryStmt)
        continue
    }
    sqlite3_reset(insertEntryStmt)

    let entryId = sqlite3_last_insert_rowid(db)

    // Insert into reading_index
    sqlite3_bind_text(insertReadingStmt, 1, readingCStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_int64(insertReadingStmt, 2, entryId)
    sqlite3_bind_double(insertReadingStmt, 3, score)

    guard sqlite3_step(insertReadingStmt) == SQLITE_DONE else {
        sqlite3_reset(insertReadingStmt)
        continue
    }
    sqlite3_reset(insertReadingStmt)

    let aliasReading = Romanization.aliasReading(reading)
    for variant in Romanization.indexedAliasReadings(for: reading) {
        sqlite3_bind_text(insertAliasStmt, 1, variant.aliasReading, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(insertAliasStmt, 2, readingCStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(insertAliasStmt, 3, entryId)
        sqlite3_bind_double(insertAliasStmt, 4, score)
        sqlite3_bind_int(insertAliasStmt, 5, Int32(variant.aliasPenalty))

        guard sqlite3_step(insertAliasStmt) == SQLITE_DONE else {
            sqlite3_reset(insertAliasStmt)
            continue entryLoop
        }
        sqlite3_reset(insertAliasStmt)
    }

    // Task 03: ya-pin entries (canonical readings whose `2` digit
    // marks the ya-pin medial — `ky2`, `khy2`, `gy2`, `hsy2`, …)
    // also need a zero-penalty alias row so the lookup's
    // `ORDER BY alias_penalty ASC, rank_score DESC … LIMIT 20`
    // does not bury them under the alias_penalty=0 ya-yit siblings.
    // The penalised row above stays so other rankers still see the
    // canonical→variant cost; this extra row only changes lookup
    // reachability.
    if isYapinReading(reading) {
        sqlite3_bind_text(insertAliasStmt, 1, aliasReading, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(insertAliasStmt, 2, readingCStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(insertAliasStmt, 3, entryId)
        sqlite3_bind_double(insertAliasStmt, 4, score)
        sqlite3_bind_int(insertAliasStmt, 5, 0)
        if sqlite3_step(insertAliasStmt) != SQLITE_DONE {
            writeStderr("Warning: failed to insert ya-pin zero-penalty alias for \(entry.surface)\n")
        }
        sqlite3_reset(insertAliasStmt)
    }

    for variant in Romanization.indexedComposeReadings(for: reading) {
        sqlite3_bind_text(insertComposeStmt, 1, variant.composeReading, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(insertComposeStmt, 2, readingCStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(insertComposeStmt, 3, entryId)
        sqlite3_bind_double(insertComposeStmt, 4, score)
        sqlite3_bind_int(insertComposeStmt, 5, Int32(variant.aliasPenalty))
        sqlite3_bind_int(insertComposeStmt, 6, Int32(variant.separatorPenalty))

        guard sqlite3_step(insertComposeStmt) == SQLITE_DONE else {
            sqlite3_reset(insertComposeStmt)
            continue entryLoop
        }
        sqlite3_reset(insertComposeStmt)
    }

    insertCount += 1
    writtenSurfaces.append(entry.surface)
}

sqlite3_finalize(insertEntryStmt)
sqlite3_finalize(insertReadingStmt)
sqlite3_finalize(insertAliasStmt)
sqlite3_finalize(insertComposeStmt)

exec("COMMIT")

// Create indexes
exec("CREATE INDEX idx_reading ON reading_index (canonical_reading)")
exec("CREATE INDEX idx_reading_alias ON reading_alias_index (alias_reading)")
exec("CREATE INDEX idx_reading_compose ON reading_compose_index (compose_reading)")
exec("CREATE INDEX idx_entry_reading ON entries (canonical_reading)")

// WAL was used to speed up bulk inserts. The shipped DB is read-only at
// runtime, so checkpoint and switch to DELETE so SQLite doesn't keep the
// `-shm`/`-wal` sidecars alive — read-only opens still rewrite `-shm`
// under WAL, which churns git diffs on the bundled artifact.
exec("PRAGMA wal_checkpoint(TRUNCATE)")
exec("PRAGMA journal_mode = DELETE")

sqlite3_close(db)

writeStderr("Done: \(insertCount) entries written to \(outputPath)\n")
if reverseFailCount > 0 {
    writeStderr("Warning: \(reverseFailCount) entries failed reverse romanization\n")
}

// MARK: - LM ↔ SQLite drift assertion
//
// Any lexicon surface absent from the LM vocab is a ranker hazard: at
// runtime the missing surface gets charged the LM's `<unk>` log-prob and
// loses to any rare-but-known fallback. See tasks/audit.md §1d for the
// incident that motivated this check.
if let lmPath = resolvedLMPath {
    do {
        let lm = try TrigramLanguageModel(path: lmPath)
        var missing: [String] = []
        let maxToList = 10
        for surface in writtenSurfaces where lm.wordId(for: surface) == nil {
            missing.append(surface)
        }
        if missing.isEmpty {
            writeStderr("Drift check: \(insertCount) surfaces all present in LM vocab (\(lmPath))\n")
        } else {
            writeStderr("Drift check FAILED: \(missing.count) lexicon surfaces missing from LM vocab.\n")
            writeStderr("  LM: \(lmPath)\n")
            for surface in missing.prefix(maxToList) {
                writeStderr("    - \(surface)\n")
            }
            if missing.count > maxToList {
                writeStderr("    ... and \(missing.count - maxToList) more.\n")
            }
            writeStderr("Fix: re-run `corpus-build lm` against the current TSV so the LM vocab matches.\n")
            exit(1)
        }
    } catch {
        writeStderr("Warning: could not load LM at \(lmPath) for drift check: \(error). Skipping.\n")
    }
} else {
    writeStderr("Drift check skipped: no LM found (pass --lm <path> or place BurmeseLM.bin next to the sqlite output).\n")
}
