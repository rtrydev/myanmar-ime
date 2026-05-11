import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-054: when the user types a tone marker (`.` for creaky / `:`
/// for visarga) between a Myanmar-digit-converted syllable and a
/// following Burmese syllable, the rank-0 candidate must preserve the
/// `.` / `:` as a literal character in the surface. Silently dropping
/// it (the pre-fix behavior — `kar2.kar` → `ကာ၂ကာ`, `.` vanished) is
/// not a legal outcome: a digit cannot anchor a tone, so the marker
/// must surface as literal punctuation between the digit and the next
/// syllable, matching the working `kar2.` (terminal `.`) and
/// `kar3.kar` (digit-as-ASCII) shapes.
///
/// The bug reproduces on the bare engine (no LM/lexicon dependency)
/// — `composeLetterRunsInTail` consumes the leading `.` / `:` of a
/// post-digit letter run via the parser's `.skip` arc and silently
/// drops it. The fix peels leading tone-class punct chars off the
/// run as literal preserved characters, mirroring the existing
/// leading-`*` preservation for the same `<digit><...>` shape.
public enum MidBufferDigitTonePunctSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(
            candidateStore: EmptyCandidateStore(),
            languageModel: NullLanguageModel()
        )
    }

    private static func scalars(_ surface: String) -> [UInt32] {
        surface.unicodeScalars.map(\.value)
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
    }

    /// True when `s` contains a digit (ASCII 0x30–0x39 or Myanmar
    /// 0x1040–0x1049) followed by a Myanmar scalar in U+1000–U+109F
    /// with NO `.` / `:` / `'` (or other ASCII tone-class punct)
    /// scalar between them. Used to assert that the user-typed
    /// `.` / `:` is preserved between a digit and the next Burmese
    /// syllable.
    private static func digitDirectlyFollowedByMyanmar(_ s: String) -> Bool {
        let v = scalars(s)
        guard v.count >= 2 else { return false }
        for i in 1..<v.count {
            let prev = v[i - 1]
            let isDigit = (prev >= 0x30 && prev <= 0x39)
                || (prev >= 0x1040 && prev <= 0x1049)
            guard isDigit else { continue }
            let cur = v[i]
            if cur >= 0x1000 && cur <= 0x109F { return true }
        }
        return false
    }

    public static let suite = TestSuite(name: "MidBufferDigitTonePunct", cases: [

        // Headline bug class (TASK-054 table). The user's typed `.`
        // / `:` between a Myanmar-digit-converted syllable and a
        // following Burmese onset must appear in the rank-0 surface.
        // Each rank-0 surface must NOT have a digit directly adjacent
        // to a Myanmar scalar — the user-typed punct sits between
        // them.
        TestCase("rank0PreservesDotBetweenDigitAndNextSyllable") { ctx in
            let engine = emptyEngine()
            let buffers: [String] = [
                "kar2.kar", "tar2.tar", "thar2.thar",
                "kar2.aung", "kar2.thar",
                "myar2.kar", "lar2.lar", "phar2.phar",
            ]
            for buffer in buffers {
                let cands = engine.update(buffer: buffer, context: []).candidates
                guard let top = cands.first else {
                    ctx.assertTrue(false, buffer, detail: "panel empty")
                    continue
                }
                ctx.assertFalse(
                    digitDirectlyFollowedByMyanmar(top.surface),
                    buffer,
                    detail: "rank-0='\(top.surface)' (\(hex(top.surface))) has digit directly adjacent to Myanmar scalar; user-typed `.` was dropped"
                )
                // The preserved scalar may be ASCII `.` (0x002E) or
                // mapped Myanmar `။` (0x104B) when burmese-punct is
                // on, but here punct mapping is off (default).
                ctx.assertTrue(
                    top.surface.contains("."),
                    "\(buffer)_dotInSurface",
                    detail: "rank-0='\(top.surface)' (\(hex(top.surface))) missing literal `.`"
                )
            }
        },

        TestCase("rank0PreservesColonBetweenDigitAndNextSyllable") { ctx in
            let engine = emptyEngine()
            let buffers: [String] = [
                "kar2:kar", "tar2:tar", "thar2:thar",
                "myar2:kar", "lar2:lar",
            ]
            for buffer in buffers {
                let cands = engine.update(buffer: buffer, context: []).candidates
                guard let top = cands.first else {
                    ctx.assertTrue(false, buffer, detail: "panel empty")
                    continue
                }
                ctx.assertFalse(
                    digitDirectlyFollowedByMyanmar(top.surface),
                    buffer,
                    detail: "rank-0='\(top.surface)' (\(hex(top.surface))) has digit directly adjacent to Myanmar scalar; user-typed `:` was dropped"
                )
                ctx.assertTrue(
                    top.surface.contains(":"),
                    "\(buffer)_colonInSurface",
                    detail: "rank-0='\(top.surface)' (\(hex(top.surface))) missing literal `:`"
                )
            }
        },

        // Concrete scalar-level rank-0 expectations from the task
        // table. Note: the bare engine produces variant siblings
        // (e.g. `myar` → ya-pin vs ya-yit) before the LM disambiguates
        // them; tests here pin the digit-tone-preservation invariant
        // (digit, then `.`/`:`, then next syllable) without locking
        // in the medial choice. For the scalar-equality cases we use
        // single-onset shapes that do not have medial siblings.
        TestCase("rank0ScalarHexForCanonicalShapes") { ctx in
            let engine = emptyEngine()
            // Pre-digit syllable, U+1042 (Myanmar 2), U+002E or
            // U+003A (literal punct), post-digit syllable.
            let cases: [(buffer: String, expectedHex: [UInt32])] = [
                // tar + 2 + . + tar → တာ၂.တာ
                ("tar2.tar", [0x1010, 0x102C, 0x1042, 0x002E, 0x1010, 0x102C]),
                ("tar2:tar", [0x1010, 0x102C, 0x1042, 0x003A, 0x1010, 0x102C]),
                // kar + 2 + . + kar → ကာ၂.ကာ
                ("kar2.kar", [0x1000, 0x102C, 0x1042, 0x002E, 0x1000, 0x102C]),
                ("kar2:kar", [0x1000, 0x102C, 0x1042, 0x003A, 0x1000, 0x102C]),
                // thar + 2 + . + thar → သာ၂.သာ
                ("thar2.thar", [0x101E, 0x102C, 0x1042, 0x002E, 0x101E, 0x102C]),
                // lar + 2 + . + lar → လာ၂.လာ
                ("lar2.lar", [0x101C, 0x102C, 0x1042, 0x002E, 0x101C, 0x102C]),
                // phar + 2 + . + phar → ဖာ၂.ဖာ
                ("phar2.phar", [0x1016, 0x102C, 0x1042, 0x002E, 0x1016, 0x102C]),
            ]
            for entry in cases {
                let cands = engine.update(buffer: entry.buffer, context: []).candidates
                guard let top = cands.first else {
                    ctx.assertTrue(false, entry.buffer, detail: "panel empty")
                    continue
                }
                let topHex = scalars(top.surface)
                ctx.assertEqual(
                    topHex,
                    entry.expectedHex,
                    "\(entry.buffer)_actual=\(topHex.map { String(format: "%04X", $0) })"
                )
            }
        },

        // Carve-outs that must remain unchanged.
        TestCase("carveOutsUnchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expectedHex: [UInt32])] = [
                // Terminal `.` — already kept correctly.
                ("kar2.", [0x1000, 0x102C, 0x1042, 0x002E]),
                // Single `.` between bare-`<C>a` and next syllable —
                // creaky tone absorption (TASK-032). No digit
                // involved.
                ("ka.kar", [0x1000, 0x1037, 0x1000, 0x102C]),
                // Single `.` between `<C>ar` and next syllable —
                // creaky tone (TASK-049 / TASK-053). No digit.
                ("thar.kar", [0x101E, 0x102C, 0x1037, 0x1000, 0x102C]),
            ]
            for entry in cases {
                let cands = engine.update(buffer: entry.buffer, context: []).candidates
                guard let top = cands.first else {
                    ctx.assertTrue(false, entry.buffer, detail: "panel empty")
                    continue
                }
                let topHex = scalars(top.surface)
                ctx.assertEqual(
                    topHex,
                    entry.expectedHex,
                    "\(entry.buffer)_actual=\(topHex.map { String(format: "%04X", $0) })"
                )
            }
        },

        // ASCII-digit-secondary variants must also preserve the
        // user-typed `.` / `:`. The surface uses ASCII `2` instead
        // of Myanmar `၂`, but the punct must still survive.
        TestCase("asciiDigitSecondaryPreservesTonePunct") { ctx in
            let engine = emptyEngine()
            let buffers: [String] = [
                "kar2.kar", "tar2.tar", "kar2:kar",
            ]
            for buffer in buffers {
                let cands = engine.update(buffer: buffer, context: []).candidates
                let surfaces = cands.map(\.surface)
                let asciiVariant = surfaces.first { surface -> Bool in
                    let v = surface.unicodeScalars.map(\.value)
                    return v.contains(where: { $0 == 0x0032 })
                        && !v.contains(where: { $0 == 0x1042 })
                }
                guard let asciiVariant else {
                    // Acceptable: not every buffer has an ASCII
                    // sibling at production-level ranking — but
                    // when it does exist, it must carry the punct.
                    continue
                }
                ctx.assertFalse(
                    digitDirectlyFollowedByMyanmar(asciiVariant),
                    "\(buffer)_asciiVariant",
                    detail: "ASCII-digit variant '\(asciiVariant)' (\(hex(asciiVariant))) lost the user-typed punct"
                )
            }
        },

        // Literal-fallback presence guard. The literal candidate
        // (raw user buffer) must remain reachable in the panel.
        TestCase("literalFallbackReachable") { ctx in
            let engine = emptyEngine()
            let buffers: [String] = [
                "kar2.kar", "tar2.tar", "kar2:kar", "myar2.kar",
            ]
            for buffer in buffers {
                let cands = engine.update(buffer: buffer, context: []).candidates
                let surfaces = cands.map(\.surface)
                ctx.assertTrue(
                    surfaces.contains(buffer),
                    buffer,
                    detail: "literal '\(buffer)' not reachable in panel surfaces=\(surfaces)"
                )
            }
        },
    ])
}
