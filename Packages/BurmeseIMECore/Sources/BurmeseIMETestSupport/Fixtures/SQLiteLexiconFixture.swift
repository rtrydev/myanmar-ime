#if canImport(SQLite3)
import Foundation
import SQLite3
import BurmeseIMECore

/// Builds a throwaway on-disk SQLite lexicon matching the schema
/// `SQLiteCandidateStore` expects. Used by score-formula tests that need
/// the real store (not a Swift mock) to exercise the alias/separator
/// penalty math.
public enum SQLiteLexiconFixture {

    public struct Row: Sendable {
        public var id: Int64
        public var surface: String
        public var reading: String
        public var score: Double

        public init(id: Int64, surface: String, reading: String, score: Double) {
            self.id = id
            self.surface = surface
            self.reading = reading
            self.score = score
        }
    }

    public struct Handle {
        public let store: SQLiteCandidateStore
        public let url: URL

        public func cleanup() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public enum BuildError: Error {
        case openFailed
        case schemaFailed
        case insertFailed
        case storeOpenFailed
    }

    public static func build(
        name: String,
        rows: [Row]
    ) throws -> Handle {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lexfix_\(name)_\(UUID().uuidString).sqlite")

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            throw BuildError.openFailed
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
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw BuildError.schemaFailed
        }

        for row in rows {
            let sql = """
                INSERT INTO entries (id, surface, canonical_reading, unigram_score)
                VALUES (\(row.id), '\(row.surface)', '\(row.reading)', \(row.score));
                INSERT INTO reading_index (canonical_reading, entry_id, rank_score)
                VALUES ('\(row.reading)', \(row.id), \(row.score));
                """
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw BuildError.insertFailed
            }
        }

        guard let store = SQLiteCandidateStore(path: dbURL.path) else {
            throw BuildError.storeOpenFailed
        }
        return Handle(store: store, url: dbURL)
    }
}
#endif
