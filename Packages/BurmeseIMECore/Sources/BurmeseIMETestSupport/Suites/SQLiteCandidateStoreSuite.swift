import Foundation
import BurmeseIMECore
#if canImport(SQLite3)
import SQLite3
#endif

public enum SQLiteCandidateStoreSuite {

    public static let suite = TestSuite(name: "SQLiteCandidateStore", cases: [

        TestCase("lookup_aliasPrefixMatchesDigitVariants") { ctx in
            guard let path = BundledArtifacts.lexiconPath else {
                ctx.assertTrue(true, "skipped_noBundledLexicon")
                return
            }
            guard let store = SQLiteCandidateStore(path: path) else {
                ctx.fail("openStore", detail: "could not open \(path)")
                return
            }
            let candidates = store.lookup(prefix: "u:", previousSurface: nil)
            ctx.assertTrue(candidates.contains(where: { $0.reading.hasPrefix("u2:") }),
                           "u:_matches_u2:")
        },

        TestCase("lookup_composePrefixMatchesSeparatorVariants") { ctx in
            guard let path = BundledArtifacts.lexiconPath else {
                ctx.assertTrue(true, "skipped_noBundledLexicon")
                return
            }
            guard let store = SQLiteCandidateStore(path: path) else {
                ctx.fail("openStore", detail: "could not open \(path)")
                return
            }
            let candidates = store.lookup(prefix: "mingalarpar", previousSurface: nil)
            ctx.assertTrue(candidates.contains(where: { $0.surface == "မင်္ဂလာပါ" }),
                           "mingalarpar_surface")
        },

        TestCase("lookup_legacySchemaBuildsDerivedIndexes") { ctx in
            #if canImport(SQLite3)
            let dbURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".sqlite")
            defer { try? FileManager.default.removeItem(at: dbURL) }
            var db: OpaquePointer?
            guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
                ctx.fail("openTempDB", detail: "sqlite3_open failed")
                return
            }
            defer { sqlite3_close(db) }
            let schema = """
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
                INSERT INTO entries (id, surface, canonical_reading, unigram_score) VALUES
                    (1, 'မင်္ဂလာပါ', 'min+galarpar2', 1000.0),
                    (2, 'ဦး', 'u2:', 900.0);
                INSERT INTO reading_index (canonical_reading, entry_id, rank_score) VALUES
                    ('min+galarpar2', 1, 1000.0),
                    ('u2:', 2, 900.0);
                """
            guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
                ctx.fail("schema", detail: "sqlite3_exec failed")
                return
            }
            guard let store = SQLiteCandidateStore(path: dbURL.path) else {
                ctx.fail("openStore", detail: "legacy-schema open failed")
                return
            }
            let composeCandidates = store.lookup(prefix: "mingalarpar", previousSurface: nil)
            ctx.assertTrue(composeCandidates.contains(where: { $0.surface == "မင်္ဂလာပါ" }),
                           "composePrefix")
            let aliasCandidates = store.lookup(prefix: "u:", previousSurface: nil)
            ctx.assertTrue(aliasCandidates.contains(where: { $0.reading == "u2:" }),
                           "aliasPrefix")
            #else
            ctx.assertTrue(true, "skipped_noSQLite3")
            #endif
        },
    ])
}
