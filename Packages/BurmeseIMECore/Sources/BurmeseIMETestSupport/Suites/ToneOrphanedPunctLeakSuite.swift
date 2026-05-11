import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-055: when a buffer contains the shape
/// `<C><open-vowel-rule><punct1><punct2><C><V>` and `<punct1>` is
/// absorbable as a tone (`.` → creaky `1037`, `:` → visarga `1038`)
/// on the open-vowel syllable, the tone consumption fires correctly
/// but `<punct2>` must NOT be left as raw ASCII (`002E`, `003A`, or
/// `0027`) directly between the tone scalar and the next Myanmar
/// onset. That adjacency violates CLAUDE.md §1's script-purity
/// invariant — composing punctuation wedged between Myanmar scalars
/// is a rejected shape.
///
/// This is the deliberately-uncovered tail of archived TASK-056
/// (doubled-asterisk-apostrophe leak): the existing
/// `surfaceContainsInterleavedComposingPunct` predicate requires the
/// punct run to contain `*` OR have ≥2 strict-consume chars (`''`).
/// After tone absorption peels one of the two punct chars onto the
/// preceding syllable as a `1037`/`1038` tone scalar, only ONE punct
/// survives in the surface — and that single survivor falls below
/// the predicate's threshold even though it now sits between two
/// Myanmar scalars (the tone scalar IS Myanmar, and so is the next
/// onset). The fix extends the predicate to flag a single composing-
/// punct sitting between a tone scalar (1037 / 1038) and a Myanmar
/// onset.
///
/// The fix MUST preserve the deliberate carve-out from
/// `MidBufferPunctuationSuite` (lines 49-59 of the suite): doubled /
/// mixed punct runs in the `<C>(a)<punct><punct><C><V>` shape (tone-
/// INELIGIBLE LHS) flush as literal — `ka'.tar` → `က'.တာ` etc.
public enum ToneOrphanedPunctLeakSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(
            candidateStore: EmptyCandidateStore(),
            languageModel: NullLanguageModel()
        )
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
    }

    /// True when `surface` contains a single ASCII composing-punct
    /// scalar (`'`, `.`, `:`) sitting immediately AFTER a Myanmar
    /// tone scalar (1037 creaky / 1038 visarga) with a Myanmar
    /// onset directly to its right. This is the bug pattern the
    /// task forbids — a tone-orphaned punct leak.
    private static func hasToneOrphanedPunctLeak(_ surface: String) -> Bool {
        let v = Array(surface.unicodeScalars).map(\.value)
        guard v.count >= 3 else { return false }
        @inline(__always) func isComposingPunct(_ x: UInt32) -> Bool {
            x == 0x0027 || x == 0x002E || x == 0x003A
        }
        @inline(__always) func isMyanmarTone(_ x: UInt32) -> Bool {
            x == 0x1037 || x == 0x1038
        }
        @inline(__always) func isMyanmar(_ x: UInt32) -> Bool {
            (x >= 0x1000 && x <= 0x109F) && x != 0x104A && x != 0x104B
        }
        for i in 1..<(v.count - 1) {
            guard isComposingPunct(v[i]) else { continue }
            // The leak shape: <tone> <punct> <Myanmar onset>
            if isMyanmarTone(v[i - 1]) && isMyanmar(v[i + 1]) {
                return true
            }
        }
        return false
    }

    /// Bug-class buffers from the TASK-055 table. Each rank-0 surface
    /// before the fix contains ONE composing-punct between a tone
    /// scalar and the next Myanmar onset.
    private static let bugBuffers: [String] = [
        // Tone-eligible LHS with mixed punct chars
        "thar.:kar", "thar.'kar", "thar:.kar", "thar:'kar",
        "kar.:kar", "kar:.kar", "kar.'kar", "kar:'kar",
        // Medial-bearing onset
        "myar.:kar",
        // Different consonant
        "lar.:lar",
    ]

    /// Tone-INELIGIBLE LHS buffers from `MidBufferPunctuationSuite`
    /// (lines 49-59) that must keep their literal-flush rank-0
    /// surface unchanged. These are deliberately pinned and represent
    /// product-decision behavior; the TASK-055 fix MUST NOT regress
    /// them.
    private static let toneIneligiblePinned: [(buffer: String, expectedHex: [UInt32])] = [
        ("ka'.tar", [0x1000, 0x0027, 0x002E, 0x1010, 0x102C]),  // က'.တာ
        ("ka..tar", [0x1000, 0x002E, 0x002E, 0x1010, 0x102C]),  // က..တာ
        ("ka::tar", [0x1000, 0x003A, 0x003A, 0x1010, 0x102C]),  // က::တာ
        ("ka.:tar", [0x1000, 0x002E, 0x003A, 0x1010, 0x102C]),  // က.:တာ
        ("ka*.tar", [0x1000, 0x002A, 0x002E, 0x1010, 0x102C]),  // က*.တာ
    ]

    public static let suite = TestSuite(name: "ToneOrphanedPunctLeak", cases: [

        // Headline: rank-0 surface for every bug buffer must NOT
        // contain a single composing-punct directly between a tone
        // scalar and the next Myanmar onset.
        TestCase("rank0NoToneOrphanedPunctLeak") { ctx in
            let engine = emptyEngine()
            for buffer in bugBuffers {
                let cands = engine.update(buffer: buffer, context: []).candidates
                guard let top = cands.first else {
                    ctx.assertTrue(false, buffer, detail: "panel empty")
                    continue
                }
                ctx.assertFalse(
                    hasToneOrphanedPunctLeak(top.surface),
                    buffer,
                    detail: "rank-0='\(top.surface)' (\(hex(top.surface))) leaks ASCII punct between <tone> and Myanmar onset"
                )
            }
        },

        // Stronger assertion: NO candidate at ANY rank may carry the
        // bug shape (the literal-fallback raw buffer is not Myanmar
        // at all, so it doesn't trigger the predicate).
        TestCase("noCandidateAtAnyRankCarriesToneOrphanedLeak") { ctx in
            let engine = emptyEngine()
            for buffer in bugBuffers {
                let cands = engine.update(buffer: buffer, context: []).candidates
                for (rank, c) in cands.enumerated() {
                    ctx.assertFalse(
                        hasToneOrphanedPunctLeak(c.surface),
                        "\(buffer)_rank\(rank)",
                        detail: "candidate '\(c.surface)' (\(hex(c.surface))) leaks ASCII punct between <tone> and Myanmar onset"
                    )
                }
            }
        },

        // The literal fallback (raw user buffer) must remain
        // reachable in the panel for every test buffer.
        TestCase("literalFallbackReachable") { ctx in
            let engine = emptyEngine()
            for buffer in bugBuffers {
                let surfaces = engine.update(buffer: buffer, context: []).candidates
                    .map(\.surface)
                ctx.assertTrue(
                    surfaces.contains(buffer),
                    buffer,
                    detail: "literal '\(buffer)' missing from panel surfaces=\(surfaces)"
                )
            }
        },

        // Tone-ineligible LHS (MidBufferPunctuationSuite invariants)
        // must remain rank-0 unchanged. These are the deliberately-
        // pinned product decisions distinguishing this task's bug
        // shape from the tone-INELIGIBLE class (which legitimately
        // flushes mixed/doubled punct as literal).
        TestCase("toneIneligibleLHSStaysLiteral") { ctx in
            let engine = emptyEngine()
            for entry in toneIneligiblePinned {
                let cands = engine.update(buffer: entry.buffer, context: []).candidates
                guard let top = cands.first else {
                    ctx.assertTrue(false, entry.buffer, detail: "panel empty")
                    continue
                }
                let topHex = top.surface.unicodeScalars.map(\.value)
                ctx.assertEqual(
                    Array(topHex),
                    entry.expectedHex,
                    "\(entry.buffer)_actualHex=\(topHex.map { String(format: "%04X", $0) })"
                )
            }
        },

        // Predicate sanity (the suite's own bug-shape detector).
        TestCase("hasToneOrphanedPunctLeak_predicate") { ctx in
            // True cases: <tone> <punct> <Myanmar>
            ctx.assertTrue(
                hasToneOrphanedPunctLeak("\u{101E}\u{102C}\u{1037}\u{003A}\u{1000}\u{102C}"),
                "creaky_then_colon_then_ka",
                detail: "သာ့:ကာ should be flagged"
            )
            ctx.assertTrue(
                hasToneOrphanedPunctLeak("\u{1000}\u{102C}\u{1038}\u{002E}\u{1000}\u{102C}"),
                "visarga_then_dot_then_ka",
                detail: "ကား.ကာ should be flagged"
            )
            ctx.assertTrue(
                hasToneOrphanedPunctLeak("\u{1000}\u{102C}\u{1037}\u{0027}\u{1000}\u{102C}"),
                "creaky_then_apostrophe_then_ka",
                detail: "ကာ့'ကာ should be flagged"
            )
            // False cases: tone-ineligible LHS pinned shapes
            ctx.assertFalse(
                hasToneOrphanedPunctLeak("\u{1000}\u{0027}\u{002E}\u{1010}\u{102C}"),
                "ka_apostrophe_dot_tar",
                detail: "က'.တာ has no <tone> predecessor — should NOT be flagged"
            )
            ctx.assertFalse(
                hasToneOrphanedPunctLeak("\u{1000}\u{002E}\u{002E}\u{1010}\u{102C}"),
                "ka_dot_dot_tar",
                detail: "က..တာ has no <tone> predecessor — should NOT be flagged"
            )
            // Single tone with no following content (no leak shape)
            ctx.assertFalse(
                hasToneOrphanedPunctLeak("\u{101E}\u{102C}\u{1037}"),
                "thar_creaky_only",
                detail: "သာ့ with no following punct should NOT be flagged"
            )
        },
    ])
}
