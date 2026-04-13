import Foundation
import BurmeseIMECore
#if canImport(SQLite3)
import SQLite3
#endif

/// LexiconBuilder: reads BurmeseLexiconSource.tsv, reverse-romanizes each entry
/// through the grammar engine, and emits BurmeseLexicon.sqlite.
///
/// Source format: surface<TAB>frequency<TAB>override_reading?
///
/// Output tables:
///   entries(id, surface, canonical_reading, unigram_score)
///   reading_index(canonical_reading, entry_id, rank_score)
///   bigram_context(prev_surface, next_entry_id, score)

guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: LexiconBuilder <input.tsv> <output.sqlite>\n", stderr)
    fputs("\nReads a Burmese lexicon TSV and emits a SQLite database.\n", stderr)
    fputs("TSV format: surface<TAB>frequency[<TAB>override_reading]\n", stderr)
    exit(1)
}

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

// Read input TSV
guard let data = FileManager.default.contents(atPath: inputPath),
      let content = String(data: data, encoding: .utf8) else {
    fputs("Error: Cannot read input file: \(inputPath)\n", stderr)
    exit(1)
}

struct LexiconEntry {
    let surface: String
    let frequency: Double
    let overrideReading: String?
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
        fputs("Warning: Skipping malformed line \(lineNum): \(trimmed)\n", stderr)
        continue
    }

    let surface = fields[0]
    guard let frequency = Double(fields[1]) else {
        fputs("Warning: Invalid frequency on line \(lineNum): \(fields[1])\n", stderr)
        continue
    }

    let overrideReading = fields.count >= 3 && !fields[2].isEmpty ? fields[2] : nil
    entries.append(LexiconEntry(surface: surface, frequency: frequency, overrideReading: overrideReading))
}

fputs("Parsed \(entries.count) entries from \(inputPath)\n", stderr)

// Compute max frequency for normalization
let maxFreq = entries.map(\.frequency).max() ?? 1.0

// Open SQLite database
nonisolated(unsafe) var db: OpaquePointer?
// Remove existing file
if FileManager.default.fileExists(atPath: outputPath) {
    try? FileManager.default.removeItem(atPath: outputPath)
}

guard sqlite3_open(outputPath, &db) == SQLITE_OK else {
    fputs("Error: Cannot create database: \(outputPath)\n", stderr)
    exit(1)
}

func exec(_ sql: String) {
    var err: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
        let msg = err.map { String(cString: $0) } ?? "unknown error"
        fputs("SQL Error: \(msg)\n  SQL: \(sql)\n", stderr)
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
    CREATE TABLE bigram_context (
        prev_surface TEXT NOT NULL,
        next_entry_id INTEGER NOT NULL REFERENCES entries(id),
        score REAL NOT NULL
    )
    """)

// Insert entries
exec("BEGIN TRANSACTION")

var insertEntryStmt: OpaquePointer?
sqlite3_prepare_v2(db, "INSERT INTO entries (surface, canonical_reading, unigram_score) VALUES (?1, ?2, ?3)", -1, &insertEntryStmt, nil)

var insertReadingStmt: OpaquePointer?
sqlite3_prepare_v2(db, "INSERT INTO reading_index (canonical_reading, entry_id, rank_score) VALUES (?1, ?2, ?3)", -1, &insertReadingStmt, nil)

var reverseFailCount = 0
var insertCount = 0

for entry in entries {
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
        fputs("Warning: Failed to insert entry: \(entry.surface)\n", stderr)
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

    insertCount += 1
}

sqlite3_finalize(insertEntryStmt)
sqlite3_finalize(insertReadingStmt)

exec("COMMIT")

// Create indexes
exec("CREATE INDEX idx_reading ON reading_index (canonical_reading)")
exec("CREATE INDEX idx_bigram ON bigram_context (prev_surface)")
exec("CREATE INDEX idx_entry_reading ON entries (canonical_reading)")

sqlite3_close(db)

fputs("Done: \(insertCount) entries written to \(outputPath)\n", stderr)
if reverseFailCount > 0 {
    fputs("Warning: \(reverseFailCount) entries failed reverse romanization\n", stderr)
}
