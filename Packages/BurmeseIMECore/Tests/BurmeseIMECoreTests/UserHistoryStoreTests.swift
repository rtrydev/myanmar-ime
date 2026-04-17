import XCTest
@testable import BurmeseIMECore

final class UserHistoryStoreTests: XCTestCase {

    private func makeStore() -> (SQLiteUserHistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BurmeseIMEHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("UserHistory.sqlite").path
        guard let store = SQLiteUserHistoryStore(path: path) else {
            fatalError("Failed to open temp history store at \(path)")
        }
        return (store, dir)
    }

    private func teardown(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRecordThenLookupReturnsCandidate() throws {
        let (store, dir) = makeStore()
        defer { teardown(dir) }

        store.record(reading: "kyar", surface: "ကြား")
        store.record(reading: "kyar", surface: "ကြား")
        // Record is async; force a sync point by calling clearAll semantics
        // via a lookup — lookup uses `queue.sync`, flushing prior async work.
        let results = store.lookup(prefix: "kyar", previousSurface: nil)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.surface, "ကြား")
        XCTAssertEqual(results.first?.source, .history)
        XCTAssertGreaterThan(results.first?.score ?? 0, 0)
    }

    func testRecordMultipleSurfacesOrdersByCount() throws {
        let (store, dir) = makeStore()
        defer { teardown(dir) }

        store.record(reading: "kyar", surface: "ကြား")
        store.record(reading: "kyar", surface: "ကျား")
        store.record(reading: "kyar", surface: "ကျား")
        store.record(reading: "kyar", surface: "ကျား")

        let results = store.lookup(prefix: "kyar", previousSurface: nil)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.surface, "ကျား", "Higher count should lead")
    }

    func testPrefixLookupReturnsExtendedReadings() throws {
        let (store, dir) = makeStore()
        defer { teardown(dir) }

        store.record(reading: "kyar:", surface: "ကြား")
        let results = store.lookup(prefix: "kya", previousSurface: nil)
        XCTAssertTrue(results.contains(where: { $0.surface == "ကြား" }))
    }

    func testRecencyDecayHalvesEveryThirtyDays() throws {
        let (store, dir) = makeStore()
        defer { teardown(dir) }

        store.record(reading: "old", surface: "A")
        store.record(reading: "old", surface: "B")
        // Force the A row to ~60 days old.
        let sixtyDaysAgo = Date().timeIntervalSince1970 - 60 * 86_400
        store.forceLastPickedAt(reading: "old", surface: "A", to: sixtyDaysAgo)

        let results = store.lookup(prefix: "old", previousSurface: nil)
        let a = results.first(where: { $0.surface == "A" })?.score ?? 0
        let b = results.first(where: { $0.surface == "B" })?.score ?? 0
        XCTAssertGreaterThan(b, a, "Fresh entry must outrank a 60-day-old entry")
        // 60d halving twice → fresh should be ~4× older.
        XCTAssertGreaterThan(b / max(a, 0.0001), 3.5)
    }

    func testClearAllRemovesRows() throws {
        let (store, dir) = makeStore()
        defer { teardown(dir) }

        store.record(reading: "kyar", surface: "ကြား")
        XCTAssertFalse(store.lookup(prefix: "kyar", previousSurface: nil).isEmpty)

        store.clearAll()
        XCTAssertTrue(store.lookup(prefix: "kyar", previousSurface: nil).isEmpty)
    }

    func testHistoryScoreFormulaIsLogTimesDecay() {
        let now: TimeInterval = 1_000_000_000
        let score1 = SQLiteUserHistoryStore.historyScore(count: 1, lastPickedAt: now, now: now)
        let score2 = SQLiteUserHistoryStore.historyScore(count: 3, lastPickedAt: now, now: now)
        XCTAssertEqual(score1, log1p(1), accuracy: 1e-9)
        XCTAssertEqual(score2, log1p(3), accuracy: 1e-9)
        // 30 days ago with count=1 should equal 0.5 * score1.
        let oldTime = now - 30 * 86_400
        let decayed = SQLiteUserHistoryStore.historyScore(count: 1, lastPickedAt: oldTime, now: now)
        XCTAssertEqual(decayed, log1p(1) * 0.5, accuracy: 1e-9)
    }
}

final class EngineHistoryIntegrationTests: XCTestCase {

    struct MockHistoryStore: UserHistoryStore {
        let surface: String
        let reading: String
        let score: Double
        func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
            guard prefix == reading else { return [] }
            return [Candidate(surface: surface, reading: reading, source: .history, score: score)]
        }
        func record(reading: String, surface: String) {}
        func clearAll() {}
    }

    func testHistoryCandidatePromotedToTop() {
        // The lexicon mock returns a surface, but history returns a *different*
        // surface for the same reading. History should win position 0.
        struct LexiconMock: CandidateStore {
            func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
                guard prefix == "kyar" else { return [] }
                return [
                    Candidate(surface: "ကြား", reading: "kyar:", source: .lexicon, score: 950),
                ]
            }
        }
        let engine = BurmeseEngine(
            candidateStore: LexiconMock(),
            historyStore: MockHistoryStore(surface: "ကျား", reading: "kyar", score: 1.0)
        )
        let state = engine.update(buffer: "kyar", context: [])
        XCTAssertEqual(state.candidates.first?.surface, "ကျား")
    }

    func testHistoryBypassedWhenLearningDisabled() {
        let suiteName = "BurmeseIMEHistoryTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let settings = IMESettings(suiteName: suiteName)
        settings.learningEnabled = false

        let engine = BurmeseEngine(
            historyStore: MockHistoryStore(surface: "ကျား", reading: "kyar", score: 1.0),
            settings: settings
        )
        let state = engine.update(buffer: "kyar", context: [])
        // When disabled, history shouldn't inject "ကျား" at position 0.
        XCTAssertNotEqual(state.candidates.first?.surface, "ကျား")
    }

    func testRecordSelectionWritesThroughWhenEnabled() {
        final class CapturingStore: UserHistoryStore, @unchecked Sendable {
            var recorded: [(String, String)] = []
            func lookup(prefix: String, previousSurface: String?) -> [Candidate] { [] }
            func record(reading: String, surface: String) { recorded.append((reading, surface)) }
            func clearAll() { recorded.removeAll() }
        }
        let store = CapturingStore()
        let engine = BurmeseEngine(historyStore: store)
        var state = engine.update(buffer: "kyar", context: [])
        XCTAssertFalse(state.candidates.isEmpty)
        state.selectedCandidateIndex = 0
        engine.recordSelection(state: state)
        XCTAssertEqual(store.recorded.count, 1)
        XCTAssertEqual(store.recorded.first?.0, "kyar")
    }

    func testRecordSelectionSkippedWhenLearningDisabled() {
        final class CapturingStore: UserHistoryStore, @unchecked Sendable {
            var recorded: [(String, String)] = []
            func lookup(prefix: String, previousSurface: String?) -> [Candidate] { [] }
            func record(reading: String, surface: String) { recorded.append((reading, surface)) }
            func clearAll() { recorded.removeAll() }
        }
        let suiteName = "BurmeseIMEHistoryTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let settings = IMESettings(suiteName: suiteName)
        settings.learningEnabled = false

        let store = CapturingStore()
        let engine = BurmeseEngine(historyStore: store, settings: settings)
        var state = engine.update(buffer: "kyar", context: [])
        state.selectedCandidateIndex = 0
        engine.recordSelection(state: state)
        XCTAssertTrue(store.recorded.isEmpty)
    }
}
