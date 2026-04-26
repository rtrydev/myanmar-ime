import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for task 05: when the engine recurses through
/// `splitAtLastEmbeddedComposingPunct` /
/// `splitAtLastEmbeddedLiteralPunct`, the candidate `reading` must
/// reflect the *full* user buffer, not just the active suffix; and
/// `recordSelection` must write a key derived from the full buffer
/// rather than the truncated suffix. Otherwise a commit on `ka.la`
/// stores the surface `က.လ` keyed on `la`, polluting future lookups
/// for unrelated short readings.
public enum LiteralPunctRecursionReadingSuite {

    private final class CapturingHistoryStore: UserHistoryStore, @unchecked Sendable {
        var recorded: [(reading: String, surface: String)] = []
        func lookup(prefix: String, previousSurface: String?) -> [Candidate] { [] }
        func record(reading: String, surface: String) {
            recorded.append((reading, surface))
        }
        func remove(reading: String, surface: String) {}
        func listAll() -> [HistoryEntry] { [] }
        func clearAll() { recorded.removeAll() }
    }

    /// Stores one entry. Returns it whenever the lookup prefix is a
    /// prefix of the stored reading — exactly the SQLite path's
    /// behaviour, so polluted writes become visible at lookup time.
    private final class PrefixOnlyHistoryStore: UserHistoryStore, @unchecked Sendable {
        var rows: [(reading: String, surface: String)] = []
        func record(reading: String, surface: String) {
            rows.append((reading, surface))
        }
        func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
            rows.compactMap { row in
                guard row.reading.hasPrefix(prefix) else { return nil }
                return Candidate(surface: row.surface, reading: row.reading,
                                 source: .history, score: 10.0)
            }
        }
        func remove(reading: String, surface: String) {}
        func listAll() -> [HistoryEntry] { [] }
        func clearAll() { rows.removeAll() }
    }

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    public static let suite = TestSuite(name: "LiteralPunctRecursionReading", cases: [

        // Reading symmetry: every recursing buffer's top reading must
        // equal the full normalized buffer (or at minimum cover the
        // pre-punct prefix). The active-suffix-only reading is the
        // bug.
        TestCase("recursingBuffer_topReadingCoversPrefix") { ctx in
            let engine = emptyEngine()
            let cases = [
                "ka.la", "ka:la", "ka.la.", "ka:.la", "ka..la",
                "ka,la", "ka 'la", "thar 'ka", "thar,ka",
            ]
            for buffer in cases {
                let state = engine.update(buffer: buffer, context: [])
                let topReading = state.candidates.first?.reading ?? ""
                // The reading must include the pre-punct portion
                // (`ka` for ka.la, `thar` for thar,ka). The truncated
                // form would be just `la` / `ka`.
                let prefix = String(buffer.prefix(while: { $0 != "." && $0 != ":" && $0 != "," && $0 != " " && $0 != "'" }))
                ctx.assertTrue(
                    topReading.hasPrefix(prefix),
                    buffer,
                    detail: "topReading='\(topReading)' does not start with full buffer's prefix '\(prefix)'"
                )
            }
        },

        // History pollution: commit a candidate from a punct-split
        // buffer; then call `update` with just the active suffix and
        // assert the long-surface candidate does NOT appear at top —
        // its history-aliased key was full-buffer-keyed and is not
        // reachable from the suffix alone.
        TestCase("historyPollution_truncatedKeyIsNotReachable") { ctx in
            let store = PrefixOnlyHistoryStore()
            let engine = BurmeseEngine(
                candidateStore: EmptyCandidateStore(),
                historyStore: store,
                languageModel: NullLanguageModel()
            )
            // Commit `ka.la` and check what reading was stored.
            var state = engine.update(buffer: "ka.la", context: [])
            engine.recordSelection(state: state)
            let storedReading = store.rows.first?.reading ?? ""
            ctx.assertFalse(
                storedReading == "la",
                "stored_reading_not_truncated",
                detail: "history was keyed on truncated 'la': stored='\(storedReading)'"
            )
            // The longer recorded reading must include `ka` somewhere.
            ctx.assertTrue(
                storedReading.contains("ka"),
                "stored_reading_includes_prefix",
                detail: "stored='\(storedReading)' does not contain 'ka'"
            )
            // Now type only the active suffix `la`. The committed
            // long surface `က.လ` must NOT appear (it would be a
            // pollution leak).
            state = engine.update(buffer: "la", context: [])
            let panelHasLongSurface = state.candidates.contains { $0.surface == "က.လ" }
            ctx.assertFalse(
                panelHasLongSurface,
                "no_pollution_for_la",
                detail: "က.လ leaked into the panel for the unrelated 'la' input"
            )
        },

        // Regression: non-recursing siblings (`kar:`, `thar.`,
        // `thar.la`, `thar:la`, `hma'la`) must keep their full
        // readings — the fix must not regress them.
        TestCase("nonRecursingBuffers_readingsUnchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expectedReadingHasPrefix: String)] = [
                ("kar:",    "kar:"),
                ("thar.",   "thar."),
                ("thar.la", "thar.la"),
                ("thar:la", "thar:la"),
                ("hma'la",  "hma'la"),
            ]
            for entry in cases {
                let state = engine.update(buffer: entry.buffer, context: [])
                let topReading = state.candidates.first?.reading ?? ""
                ctx.assertTrue(
                    topReading.hasPrefix(entry.expectedReadingHasPrefix)
                        || entry.expectedReadingHasPrefix.hasPrefix(topReading),
                    entry.buffer,
                    detail: "topReading='\(topReading)' does not align with expected prefix '\(entry.expectedReadingHasPrefix)'"
                )
            }
        },
    ])
}
