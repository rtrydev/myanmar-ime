import XCTest
@testable import BurmeseIMECore
#if canImport(SQLite3)
import SQLite3
#endif

final class SQLiteCandidateStoreTests: XCTestCase {

    func testLookup_aliasPrefixMatchesDigitVariants() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dbURL = repoRoot.appendingPathComponent("native/macos/Data/BurmeseLexicon.sqlite")

        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw XCTSkip("Bundled lexicon database is not available at \(dbURL.path)")
        }

        guard let store = SQLiteCandidateStore(path: dbURL.path) else {
            XCTFail("Expected SQLiteCandidateStore to open bundled lexicon")
            return
        }

        let candidates = store.lookup(prefix: "u:", previousSurface: nil)

        XCTAssertTrue(candidates.contains(where: { $0.reading.hasPrefix("u2:") }))
    }

    func testLookup_composePrefixMatchesSeparatorVariants() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dbURL = repoRoot.appendingPathComponent("native/macos/Data/BurmeseLexicon.sqlite")

        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw XCTSkip("Bundled lexicon database is not available at \(dbURL.path)")
        }

        guard let store = SQLiteCandidateStore(path: dbURL.path) else {
            XCTFail("Expected SQLiteCandidateStore to open bundled lexicon")
            return
        }

        let candidates = store.lookup(prefix: "mingalarpar", previousSurface: nil)

        XCTAssertTrue(candidates.contains(where: { $0.surface == "မင်္ဂလာပါ" }))
    }

    func testLookup_legacySchemaBuildsDerivedIndexes() throws {
#if canImport(SQLite3)
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            XCTFail("Expected temporary SQLite database to open")
            return
        }
        defer { sqlite3_close(db) }

        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE entries (
                id INTEGER PRIMARY KEY,
                surface TEXT NOT NULL,
                canonical_reading TEXT NOT NULL,
                unigram_score REAL NOT NULL
            );
            CREATE TABLE reading_index (
                canonical_reading TEXT NOT NULL,
                entry_id INTEGER NOT NULL REFERENCES entries(id),
                rank_score REAL NOT NULL
            );
            CREATE TABLE bigram_context (
                prev_surface TEXT NOT NULL,
                next_entry_id INTEGER NOT NULL REFERENCES entries(id),
                score REAL NOT NULL
            );
            INSERT INTO entries (id, surface, canonical_reading, unigram_score) VALUES
                (1, 'မင်္ဂလာပါ', 'min+galarpar2', 1000.0),
                (2, 'ဦး', 'u2:', 900.0);
            INSERT INTO reading_index (canonical_reading, entry_id, rank_score) VALUES
                ('min+galarpar2', 1, 1000.0),
                ('u2:', 2, 900.0);
            """, nil, nil, nil), SQLITE_OK)

        guard let store = SQLiteCandidateStore(path: dbURL.path) else {
            XCTFail("Expected SQLiteCandidateStore to open legacy-schema database")
            return
        }

        let composeCandidates = store.lookup(prefix: "mingalarpar", previousSurface: nil)
        XCTAssertTrue(composeCandidates.contains(where: { $0.surface == "မင်္ဂလာပါ" }))

        let aliasCandidates = store.lookup(prefix: "u:", previousSurface: nil)
        XCTAssertTrue(aliasCandidates.contains(where: { $0.reading == "u2:" }))
#else
        throw XCTSkip("SQLite3 is unavailable in this environment")
#endif
    }
}
