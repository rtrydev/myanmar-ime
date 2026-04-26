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

        // Affixes path: digit prefix, digit suffix, and literal-tail
        // affixes are concatenated onto candidate surfaces but the
        // inner parser only saw the composable middle. Every
        // candidate `reading` must equal the full display buffer so
        // `recordSelection` doesn't store the spliced surface under
        // a truncated key. Covers the original task's reproduction
        // entry `123abc456` (which takes the digit-prefix/suffix
        // path, not the punct-split recursion paths).
        TestCase("affixesBuffer_topReadingEqualsDisplayBuffer") { ctx in
            let engine = emptyEngine()
            let cases = [
                "123abc456", "123abc", "abc456", "12abc", "abc12",
                "min:123", "123min:", "kar:5", "5kar:", "min:la3",
                "min:3la",
            ]
            for buffer in cases {
                let state = engine.update(buffer: buffer, context: [])
                guard let topReading = state.candidates.first?.reading else {
                    ctx.assertTrue(false, buffer, detail: "no candidate")
                    continue
                }
                ctx.assertTrue(
                    topReading == buffer,
                    buffer,
                    detail: "topReading='\(topReading)' expected '\(buffer)'"
                )
            }
        },

        // Mid-buffer digit splice path (letter-digit-letter): the
        // inner update strips digits and parses the cleaned letters.
        // `spliceMidBufferDigits` re-attaches the digits to the
        // surface; the candidate `reading` must reflect the user's
        // full digit-bearing buffer, not just the cleaned letters.
        TestCase("midBufferDigitSplice_topReadingEqualsDisplayBuffer") { ctx in
            let engine = emptyEngine()
            let cases = [
                "t1ote", "k1ya", "min2gala", "t2ote", "h1ma",
            ]
            for buffer in cases {
                let state = engine.update(buffer: buffer, context: [])
                guard let topReading = state.candidates.first?.reading else {
                    ctx.assertTrue(false, buffer, detail: "no candidate")
                    continue
                }
                ctx.assertTrue(
                    topReading == buffer,
                    buffer,
                    detail: "topReading='\(topReading)' expected '\(buffer)'"
                )
            }
        },

        // History pollution sibling: commit a digit-affixed buffer
        // (`123abc`) and assert its surface does not leak into a
        // later short-prefix lookup (`a`). Same shape as the
        // existing punct-split test but covers the affixes path.
        // The stored key passes through `Romanization.aliasReading`
        // which strips `2`/`3` (internal variant markers), so the
        // exact key for `123abc` is `1abc` — but the assertion is
        // about *not* being the truncated `a` and about covering
        // the letter portion, mirroring the punct-split test.
        TestCase("historyPollution_affixesPath_keyCoversFullBuffer") { ctx in
            let store = PrefixOnlyHistoryStore()
            let engine = BurmeseEngine(
                candidateStore: EmptyCandidateStore(),
                historyStore: store,
                languageModel: NullLanguageModel()
            )
            var state = engine.update(buffer: "123abc", context: [])
            engine.recordSelection(state: state)
            let storedReading = store.rows.first?.reading ?? ""
            ctx.assertFalse(
                storedReading == "a" || storedReading == "abc",
                "stored_reading_not_truncated",
                detail: "history was keyed on truncated active suffix: stored='\(storedReading)'"
            )
            ctx.assertTrue(
                storedReading.contains("1") && storedReading.contains("abc"),
                "stored_reading_includes_affixes",
                detail: "stored='\(storedReading)' missing digit-prefix or letter content"
            )
            // Type only `a`. The recorded long surface must not
            // surface under that short reading — it was keyed on the
            // full buffer's alias, not on `a`.
            state = engine.update(buffer: "a", context: [])
            let polluted = state.candidates.contains { $0.surface == "၁၂၃အဘc" }
            ctx.assertFalse(
                polluted,
                "no_pollution_for_a",
                detail: "long surface leaked into 'a' panel"
            )
        },
    ])
}
