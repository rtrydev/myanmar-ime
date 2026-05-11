import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-060: when the user types a buffer of shape
/// `<C><multi-scalar-vowel-rule><doubled-doc-punct><C>...` (e.g.
/// `kar..ka`, `thar..thar`, `kay..ka`, `ko..ka`, `kaung..ka`, …),
/// the panel must contain at least one Myanmar candidate whose
/// surface starts with a Myanmar scalar AND contains the literal
/// punct chars the user typed. Pre-fix every Myanmar parse absorbed
/// the first `.` / `:` as a tone scalar (`1037` / `1038`) and
/// stranded the second between the tone scalar and the next Myanmar
/// onset — every such candidate gets correctly rejected by the
/// TASK-055 sanitiser, leaving the panel with only the literal raw
/// buffer.
///
/// The fix lives in
/// `Engine/PunctuationHandling.swift::renderFrozenPunctSegments`:
/// when an internal `.`/`:` would normally absorb into `current` as
/// a vowel-modifier (closing a `.`/`:`-bearing vowel rule like
/// `ar.` / `ay:` / `o.`), the absorption is gated off when the
/// very next char is also a composing-punct (`./:`). Without the
/// absorption the renderer flushes the doubled-punct as literal
/// between the rendered syllables (`ကာ..က` style), producing a
/// Burmese sibling that survives the TASK-055 sanitiser.
///
/// The fix preserves single-`.`/single-`:` tone absorption
/// (`kar.kar` → `ကာ့ကာ`), tone-INELIGIBLE LHS shapes
/// (`ka..tar` → `က..တာ`, pinned by `MidBufferPunctuationSuite`),
/// and the TASK-055 leak rejection (`kar.:kar`'s tone-orphaned
/// surface still drops). It addresses the deliberately-uncovered
/// tail of TASK-055.
public enum DoubledPunctVowelRuleSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(
            candidateStore: EmptyCandidateStore(),
            languageModel: NullLanguageModel()
        )
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// Buffers from the task's Acceptance Criteria — every entry
    /// must produce a Myanmar surface in the panel. The expected
    /// surface starts with a Myanmar scalar (U+1000..U+109F) and
    /// contains the literal punct chars the user typed (so the
    /// `<tone-scalar><orphan-punct><Myanmar>` shape that TASK-055
    /// rejects is not the only candidate).
    private static let bugBuffers: [String] = [
        // Vowel-rule families covered by the validation notes:
        // `ar`, `ay`, `o`, plus a multi-letter (`aung`).
        "kar..ka",     // ar family
        "kar..thar",
        "thar..thar",
        "thar..tha",
        "myar..ka",    // medial-bearing onset
        "lar..lar",
        "kar..k",
        "tar..ka",
        // Vowel-rule families: `ay`, `o`, `aung`, `u`, `i`.
        "kay..ka",     // ay family
        "ko..ka",      // o family
        "kaung..ka",   // multi-letter aung family
        "ku..ka",      // u family (also fixes secondary dot-loss)
        "ki..ka",      // i family
        // Mixed-punct shapes (TASK-055 deliberately-uncovered tail).
        "kar:.ka",
        "kar.:ka",
        // Trailing tone after the doubled-punct sequence.
        "kar..ka:",
    ]

    /// Buffers where each `.` is a SEPARATE single-dot tone marker
    /// (not a doubled-`..` shape) — the parser correctly absorbs
    /// each `.` as a creaky tone. The rank-0 surface should not
    /// contain literal `.` chars.
    private static let multipleSingleToneBuffers: [(buffer: String, expected: [UInt32])] = [
        ("kar.k.k", [0x1000, 0x102C, 0x1037, 0x1000, 0x1037, 0x1000]),
    ]

    /// Tone-INELIGIBLE LHS controls — these `<C>a..<C>` shapes
    /// already produced literal-flushed surfaces correctly before
    /// TASK-060 (pinned by `MidBufferPunctuationSuite`) and must
    /// continue to work.
    private static let toneIneligibleControls: [(buffer: String, expected: [UInt32])] = [
        // `ka..tar` → `က..တာ` — tone-INELIGIBLE LHS.
        ("ka..tar", [0x1000, 0x002E, 0x002E, 0x1010, 0x102C]),
    ]

    /// Single-dot tone absorption controls — these must continue
    /// to absorb the `.` as a creaky tone (`1037`) onto the
    /// tone-eligible LHS, exactly as before TASK-060.
    private static let singleToneControls: [(buffer: String, expected: [UInt32])] = [
        ("kar.kar",      [0x1000, 0x102C, 0x1037, 0x1000, 0x102C]),
        ("kar.thar.kar", [0x1000, 0x102C, 0x1037, 0x101E, 0x102C, 0x1037, 0x1000, 0x102C]),
    ]

    /// Returns true when `surface` starts with a Myanmar scalar
    /// (U+1000..U+109F).
    private static func startsWithMyanmar(_ surface: String) -> Bool {
        guard let first = surface.unicodeScalars.first else { return false }
        return first.value >= 0x1000 && first.value <= 0x109F
    }

    public static let suite = TestSuite(name: "DoubledPunctVowelRule", cases: [

        // Headline: every bug buffer must surface a Myanmar
        // candidate that starts with a Myanmar scalar AND contains
        // the literal punct chars the user typed (`002E` / `003A`).
        // The literal raw buffer alone is not sufficient.
        TestCase("doubledPunctVowelRule_panelHasBurmeseCandidate") { ctx in
            let engine = emptyEngine()
            for buffer in bugBuffers {
                let cands = engine.update(buffer: buffer, context: []).candidates
                let hasBurmese = cands.contains { cand in
                    guard startsWithMyanmar(cand.surface) else { return false }
                    // The candidate's surface should also contain the
                    // user's literal punct chars (so the parser didn't
                    // silently drop them via `.skip`).
                    let userPuncts = buffer.unicodeScalars.filter {
                        $0.value == 0x002E || $0.value == 0x003A
                    }
                    let surfacePuncts = cand.surface.unicodeScalars.filter {
                        $0.value == 0x002E || $0.value == 0x003A
                    }
                    return surfacePuncts.count >= userPuncts.count
                }
                ctx.assertTrue(
                    hasBurmese,
                    buffer,
                    detail: "expected ≥1 Myanmar candidate carrying user punct chars; panel=\(cands.map { "'\($0.surface)' [\(hex($0.surface))]" })"
                )
            }
        },

        // The literal raw buffer must remain reachable in the
        // panel for every test buffer (CLAUDE.md §2 escape hatch).
        TestCase("doubledPunctVowelRule_literalReachable") { ctx in
            let engine = emptyEngine()
            for buffer in bugBuffers {
                let surfaces = engine.update(buffer: buffer, context: [])
                    .candidates.map(\.surface)
                ctx.assertTrue(
                    surfaces.contains(buffer),
                    buffer,
                    detail: "literal '\(buffer)' missing from panel; surfaces=\(surfaces)"
                )
            }
        },

        // Tone-INELIGIBLE LHS shapes (already pinned by
        // `MidBufferPunctuationSuite`) must keep their rank-0
        // scalar sequence unchanged.
        TestCase("doubledPunctVowelRule_toneIneligibleControlsUnchanged") { ctx in
            let engine = emptyEngine()
            for entry in toneIneligibleControls {
                let surface = engine.update(buffer: entry.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    actual == entry.expected,
                    entry.buffer,
                    detail: "expected=\(entry.expected.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
            }
        },

        // Single-`.`/single-`:` tone absorption on tone-eligible
        // LHS must continue to work — the TASK-060 fix only
        // disables absorption when the next char is also `./:`.
        TestCase("doubledPunctVowelRule_singleToneControlsUnchanged") { ctx in
            let engine = emptyEngine()
            for entry in singleToneControls {
                let surface = engine.update(buffer: entry.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    actual == entry.expected,
                    entry.buffer,
                    detail: "expected=\(entry.expected.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
            }
        },

        // Multiple-single-tone shapes — each `.` is its own tone
        // marker (`kar.k.k` = `kar.` + `k.` + `k`), not a doubled
        // run. The parser absorbs every `.` as a creaky tone so
        // the rank-0 surface contains only Myanmar tone scalars
        // (no literal `.`).
        TestCase("doubledPunctVowelRule_multipleSingleToneAbsorption") { ctx in
            let engine = emptyEngine()
            for entry in multipleSingleToneBuffers {
                let surface = engine.update(buffer: entry.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    actual == entry.expected,
                    entry.buffer,
                    detail: "expected=\(entry.expected.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
            }
        },

        // TASK-055 invariant: no candidate at any rank may carry
        // the tone-orphaned-leak shape (`<tone> <single-punct>
        // <Myanmar>`). The TASK-060 fix surfaces the
        // literal-`..`/`::`-flushed alternative WITHOUT
        // re-introducing the leaky tone-absorbed surface.
        TestCase("doubledPunctVowelRule_noToneOrphanedLeak") { ctx in
            let engine = emptyEngine()
            @inline(__always) func isComposingPunct(_ x: UInt32) -> Bool {
                x == 0x0027 || x == 0x002E || x == 0x003A
            }
            @inline(__always) func isMyanmarTone(_ x: UInt32) -> Bool {
                x == 0x1037 || x == 0x1038
            }
            @inline(__always) func isMyanmar(_ x: UInt32) -> Bool {
                (x >= 0x1000 && x <= 0x109F) && x != 0x104A && x != 0x104B
            }
            func hasToneOrphanedLeak(_ surface: String) -> Bool {
                let v = Array(surface.unicodeScalars).map(\.value)
                guard v.count >= 3 else { return false }
                for i in 1..<(v.count - 1) {
                    guard isComposingPunct(v[i]) else { continue }
                    if isMyanmarTone(v[i - 1]) && isMyanmar(v[i + 1]) {
                        return true
                    }
                }
                return false
            }
            for buffer in bugBuffers {
                let cands = engine.update(buffer: buffer, context: []).candidates
                for (rank, c) in cands.enumerated() {
                    ctx.assertFalse(
                        hasToneOrphanedLeak(c.surface),
                        "\(buffer)_rank\(rank)",
                        detail: "candidate '\(c.surface)' [\(hex(c.surface))] leaks ASCII punct between <tone> and Myanmar"
                    )
                }
            }
        },
    ])
}
