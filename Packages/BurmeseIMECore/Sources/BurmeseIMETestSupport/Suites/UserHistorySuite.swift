import Foundation
import BurmeseIMECore

public enum UserHistorySuite {

    private static func makeStore() -> (SQLiteUserHistoryStore, URL)? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BurmeseIMEHistoryTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("UserHistory.sqlite").path
        guard let store = SQLiteUserHistoryStore(path: path) else { return nil }
        return (store, dir)
    }

    private static func teardown(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private struct StaticHistoryStore: UserHistoryStore {
        let surface: String
        let reading: String
        let score: Double
        func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
            guard prefix == reading else { return [] }
            return [Candidate(surface: surface, reading: reading,
                              source: .history, score: score)]
        }
        func record(reading: String, surface: String) {}
        func remove(reading: String, surface: String) {}
        func listAll() -> [HistoryEntry] { [] }
        func clearAll() {}
    }

    private struct LexiconMock: CandidateStore {
        func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
            guard prefix == "kyar" else { return [] }
            return [
                Candidate(surface: "ကြား", reading: "kyar:", source: .lexicon, score: 950),
            ]
        }
    }

    private final class CapturingStore: UserHistoryStore, @unchecked Sendable {
        var recorded: [(String, String)] = []
        func lookup(prefix: String, previousSurface: String?) -> [Candidate] { [] }
        func record(reading: String, surface: String) { recorded.append((reading, surface)) }
        func remove(reading: String, surface: String) {
            recorded.removeAll { $0.0 == reading && $0.1 == surface }
        }
        func listAll() -> [HistoryEntry] { [] }
        func clearAll() { recorded.removeAll() }
    }

    /// Returns a canned history candidate whenever the stored reading
    /// starts with the query prefix, and captures every `record` call so
    /// tests can assert what key the engine wrote.
    private final class PrefixHistoryMock: UserHistoryStore, @unchecked Sendable {
        let storedReading: String
        let storedSurface: String
        var recorded: [(String, String)] = []
        init(reading: String, surface: String) {
            self.storedReading = reading
            self.storedSurface = surface
        }
        func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
            guard storedReading.hasPrefix(prefix) else { return [] }
            return [Candidate(surface: storedSurface, reading: storedReading,
                              source: .history, score: 10.0)]
        }
        func record(reading: String, surface: String) { recorded.append((reading, surface)) }
        func remove(reading: String, surface: String) {}
        func listAll() -> [HistoryEntry] { [] }
        func clearAll() { recorded.removeAll() }
    }

    public static let suite = TestSuite(name: "UserHistory", cases: [

        TestCase("recordThenLookup_returnsCandidate") { ctx in
            guard let (store, dir) = makeStore() else {
                ctx.fail("setup", detail: "cannot open temp history store")
                return
            }
            defer { teardown(dir) }
            store.record(reading: "kyar", surface: "ကြား")
            store.record(reading: "kyar", surface: "ကြား")
            let results = store.lookup(prefix: "kyar", previousSurface: nil)
            ctx.assertEqual(results.count, 1, "count")
            ctx.assertEqual(results.first?.surface, "ကြား", "surface")
            ctx.assertTrue(results.first?.source == .history, "sourceIsHistory")
            ctx.assertTrue((results.first?.score ?? 0) > 0, "positiveScore")
        },

        TestCase("recordMultipleSurfaces_ordersByCount") { ctx in
            guard let (store, dir) = makeStore() else {
                ctx.fail("setup", detail: "cannot open temp history store")
                return
            }
            defer { teardown(dir) }
            store.record(reading: "kyar", surface: "ကြား")
            store.record(reading: "kyar", surface: "ကျား")
            store.record(reading: "kyar", surface: "ကျား")
            store.record(reading: "kyar", surface: "ကျား")
            let results = store.lookup(prefix: "kyar", previousSurface: nil)
            ctx.assertEqual(results.count, 2, "count")
            ctx.assertEqual(results.first?.surface, "ကျား", "higherCountLeads")
        },

        TestCase("prefixLookup_returnsExtendedReadings") { ctx in
            guard let (store, dir) = makeStore() else {
                ctx.fail("setup", detail: "cannot open temp history store")
                return
            }
            defer { teardown(dir) }
            store.record(reading: "kyar:", surface: "ကြား")
            let results = store.lookup(prefix: "kya", previousSurface: nil)
            ctx.assertTrue(results.contains(where: { $0.surface == "ကြား" }),
                           "extendedMatch")
        },

        TestCase("recencyDecay_halvesEveryThirtyDays") { ctx in
            #if DEBUG
            guard let (store, dir) = makeStore() else {
                ctx.fail("setup", detail: "cannot open temp history store")
                return
            }
            defer { teardown(dir) }
            store.record(reading: "old", surface: "A")
            store.record(reading: "old", surface: "B")
            let sixtyDaysAgo = Date().timeIntervalSince1970 - 60 * 86_400
            store.forceLastPickedAt(reading: "old", surface: "A", to: sixtyDaysAgo)
            let results = store.lookup(prefix: "old", previousSurface: nil)
            let a = results.first(where: { $0.surface == "A" })?.score ?? 0
            let b = results.first(where: { $0.surface == "B" })?.score ?? 0
            ctx.assertTrue(b > a, "freshOutranksOld", detail: "a=\(a) b=\(b)")
            ctx.assertTrue(b / max(a, 0.0001) > 3.5, "ratio>3.5",
                           detail: "ratio=\(b / max(a, 0.0001))")
            #else
            ctx.assertTrue(true, "skipped_releaseBuild")
            #endif
        },

        TestCase("lookup_requiresHalfOfStoredReading") { ctx in
            guard let (store, dir) = makeStore() else {
                ctx.fail("setup", detail: "cannot open temp history store")
                return
            }
            defer { teardown(dir) }
            store.record(reading: "kwyantaw", surface: "ကျွန်တော်")
            ctx.assertTrue(store.lookup(prefix: "kw", previousSurface: nil).isEmpty,
                           "hiddenBelowHalf")
            ctx.assertTrue(store.lookup(prefix: "kwy", previousSurface: nil).isEmpty,
                           "stillHiddenAtThreeOfEight")
            ctx.assertFalse(store.lookup(prefix: "kwya", previousSurface: nil).isEmpty,
                            "visibleAtHalf")
            ctx.assertFalse(store.lookup(prefix: "kwyantaw", previousSurface: nil).isEmpty,
                            "visibleAtFullMatch")
        },

        TestCase("engine_historySelection_recordsStoredReadingNotPrefix") { ctx in
            let store = PrefixHistoryMock(reading: "kwyantaw", surface: "ကျွန်တော်")
            let engine = BurmeseEngine(historyStore: store)
            var state = engine.update(buffer: "kw", context: [])
            guard let idx = state.candidates.firstIndex(where: { $0.source == .history }) else {
                ctx.fail("setup", detail: "history candidate not present")
                return
            }
            state.selectedCandidateIndex = idx
            engine.recordSelection(state: state)
            ctx.assertEqual(store.recorded.count, 1, "oneWrite")
            ctx.assertEqual(store.recorded.first?.0, "kwyantaw",
                            "readingIsStoredNotPrefix")
            ctx.assertEqual(store.recorded.first?.1, "ကျွန်တော်", "surface")
        },

        TestCase("remove_deletesOnlyTargetedRow") { ctx in
            guard let (store, dir) = makeStore() else {
                ctx.fail("setup", detail: "cannot open temp history store")
                return
            }
            defer { teardown(dir) }
            store.record(reading: "kyar", surface: "ကြား")
            store.record(reading: "kyar", surface: "ကျား")
            store.remove(reading: "kyar", surface: "ကြား")
            let results = store.lookup(prefix: "kyar", previousSurface: nil)
            ctx.assertEqual(results.count, 1, "oneLeft")
            ctx.assertEqual(results.first?.surface, "ကျား", "otherRemains")
        },

        TestCase("remove_missingRowIsNoOp") { ctx in
            guard let (store, dir) = makeStore() else {
                ctx.fail("setup", detail: "cannot open temp history store")
                return
            }
            defer { teardown(dir) }
            store.record(reading: "kyar", surface: "ကြား")
            store.remove(reading: "doesnotexist", surface: "X")
            let results = store.lookup(prefix: "kyar", previousSurface: nil)
            ctx.assertEqual(results.count, 1, "intactAfterNoOp")
        },

        TestCase("listAll_returnsEntriesNewestFirst") { ctx in
            #if DEBUG
            guard let (store, dir) = makeStore() else {
                ctx.fail("setup", detail: "cannot open temp history store")
                return
            }
            defer { teardown(dir) }
            store.record(reading: "old", surface: "A")
            store.record(reading: "mid", surface: "B")
            store.record(reading: "new", surface: "C")
            let now = Date().timeIntervalSince1970
            store.forceLastPickedAt(reading: "old", surface: "A", to: now - 3000)
            store.forceLastPickedAt(reading: "mid", surface: "B", to: now - 1500)
            store.forceLastPickedAt(reading: "new", surface: "C", to: now)
            let entries = store.listAll()
            ctx.assertEqual(entries.count, 3, "count")
            ctx.assertEqual(entries[0].surface, "C", "newestFirst")
            ctx.assertEqual(entries[1].surface, "B", "midSecond")
            ctx.assertEqual(entries[2].surface, "A", "oldestLast")
            #else
            ctx.assertTrue(true, "skipped_releaseBuild")
            #endif
        },

        TestCase("listAll_reflectsRemovals") { ctx in
            guard let (store, dir) = makeStore() else {
                ctx.fail("setup", detail: "cannot open temp history store")
                return
            }
            defer { teardown(dir) }
            store.record(reading: "kyar", surface: "ကြား")
            store.record(reading: "kyar", surface: "ကျား")
            ctx.assertEqual(store.listAll().count, 2, "beforeRemove")
            store.remove(reading: "kyar", surface: "ကြား")
            let after = store.listAll()
            ctx.assertEqual(after.count, 1, "afterRemove")
            ctx.assertEqual(after.first?.surface, "ကျား", "survivorSurface")
            ctx.assertEqual(after.first?.reading, "kyar", "survivorReading")
        },

        TestCase("clearAll_removesRows") { ctx in
            guard let (store, dir) = makeStore() else {
                ctx.fail("setup", detail: "cannot open temp history store")
                return
            }
            defer { teardown(dir) }
            store.record(reading: "kyar", surface: "ကြား")
            ctx.assertFalse(store.lookup(prefix: "kyar", previousSurface: nil).isEmpty,
                            "hasRowsBeforeClear")
            store.clearAll()
            ctx.assertTrue(store.lookup(prefix: "kyar", previousSurface: nil).isEmpty,
                           "emptyAfterClear")
        },

        TestCase("historyScoreFormula_isLogTimesDecay") { ctx in
            let now: TimeInterval = 1_000_000_000
            let score1 = SQLiteUserHistoryStore.historyScore(count: 1, lastPickedAt: now, now: now)
            let score2 = SQLiteUserHistoryStore.historyScore(count: 3, lastPickedAt: now, now: now)
            ctx.assertTrue(abs(score1 - log1p(1)) < 1e-9, "score1", detail: "\(score1)")
            ctx.assertTrue(abs(score2 - log1p(3)) < 1e-9, "score2", detail: "\(score2)")
            let oldTime = now - 30 * 86_400
            let decayed = SQLiteUserHistoryStore.historyScore(
                count: 1, lastPickedAt: oldTime, now: now
            )
            ctx.assertTrue(abs(decayed - log1p(1) * 0.5) < 1e-9,
                           "thirtyDayHalf", detail: "\(decayed)")
        },

        TestCase("engine_historyCandidatePromotedToTop") { ctx in
            let engine = BurmeseEngine(
                candidateStore: LexiconMock(),
                historyStore: StaticHistoryStore(surface: "ကျား",
                                                 reading: "kyar", score: 1.0)
            )
            let state = engine.update(buffer: "kyar", context: [])
            ctx.assertEqual(state.candidates.first?.surface, "ကျား",
                            "historyAtTop")
        },

        TestCase("engine_historyBypassedWhenLearningDisabled") { ctx in
            let suiteName = "UserHistorySuite.\(UUID().uuidString)"
            defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
            let settings = IMESettings(suiteName: suiteName)
            settings.learningEnabled = false
            let engine = BurmeseEngine(
                historyStore: StaticHistoryStore(surface: "ကျား",
                                                 reading: "kyar", score: 1.0),
                settings: settings
            )
            let state = engine.update(buffer: "kyar", context: [])
            ctx.assertTrue(state.candidates.first?.surface != "ကျား",
                           "historyNotAtTop",
                           detail: "first=\(state.candidates.first?.surface ?? "nil")")
        },

        TestCase("engine_recordSelection_writesWhenEnabled") { ctx in
            let store = CapturingStore()
            let engine = BurmeseEngine(historyStore: store)
            var state = engine.update(buffer: "kyar", context: [])
            ctx.assertFalse(state.candidates.isEmpty, "hasCandidates")
            state.selectedCandidateIndex = 0
            engine.recordSelection(state: state)
            ctx.assertEqual(store.recorded.count, 1, "recordedOnce")
            ctx.assertEqual(store.recorded.first?.0, "kyar", "recordedReading")
        },

        TestCase("engine_recordSelection_skippedWhenLearningDisabled") { ctx in
            let suiteName = "UserHistorySuite.\(UUID().uuidString)"
            defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
            let settings = IMESettings(suiteName: suiteName)
            settings.learningEnabled = false
            let store = CapturingStore()
            let engine = BurmeseEngine(historyStore: store, settings: settings)
            var state = engine.update(buffer: "kyar", context: [])
            state.selectedCandidateIndex = 0
            engine.recordSelection(state: state)
            ctx.assertTrue(store.recorded.isEmpty, "nothingRecorded")
        },
    ])
}
