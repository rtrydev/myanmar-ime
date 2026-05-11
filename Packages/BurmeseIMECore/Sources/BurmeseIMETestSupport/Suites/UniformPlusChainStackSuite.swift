import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-057: chains of five or more identical bare-`<C>a`
/// syllables joined by explicit `+` (`ka+ka+ka+ka+ka`,
/// `ka+ka+ka+ka+ka+ka`, …) must produce a Myanmar surface that covers
/// the entire input chain. Pre-fix the parser only enumerated the
/// triple-virama-stack form (`<C> 1039 <C> 1039 <C>`) which fails
/// `scanOutputLegality`; the right-shrink probe then collapsed the
/// buffer to a tiny prefix and the literal-fallback wrapper put the
/// raw ASCII at rank 0.
///
/// The fix lives in `Parser/NBestDP.swift::softBoundaryContext`:
/// when the previous arc is a bare `onsetOnly(C)` whose parent ended
/// on a virama vowel (the lower of an already-formed virama stack),
/// the soft-`+` arc is admitted unconditionally. This produces an
/// alternative parse where the user's next `+` opens a fresh stack
/// rather than deepening the existing one (which would form an
/// orthographically illegal triple stack).
///
/// `Parser/Finalization.swift` and
/// `Parser/SyllableParser.swift::parseLongestAcceptablePrefix` carry
/// matching widening / fallback gates so the alternative parse
/// reaches the materialise / sort path despite its higher
/// `syllableCount`.
///
/// CLAUDE.md §6 ("Explicit `+`"): "User-typed `+` is a hard syllable
/// / stack boundary." Honoring the user's intent on uniform chains
/// requires producing a Burmese surface that pairs adjacent stacks
/// rather than silently flushing to literal.
public enum UniformPlusChainStackSuite {

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

    /// Count base-consonant scalars (U+1000..U+1021) in `surface`.
    /// TASK-057 acceptance criterion: this count must be at least
    /// the number of `+`-separated syllables in the input.
    private static func baseConsonantCount(_ surface: String) -> Int {
        var count = 0
        for scalar in surface.unicodeScalars {
            let v = scalar.value
            if (v >= 0x1000 && v <= 0x1021) || v == 0x103F {
                count += 1
            }
        }
        return count
    }

    /// Count the `+`-separated bare-syllable segments in the user's
    /// input buffer.
    private static func plusSegmentCount(_ buffer: String) -> Int {
        var count = 1
        for c in buffer where c == "+" {
            count += 1
        }
        return count
    }

    public static let suite = TestSuite(name: "UniformPlusChainStack", cases: [

        // Headline acceptance: rank 0 (or any candidate in the panel)
        // must cover the full input chain — the count of base-
        // consonant scalars in some Myanmar candidate's surface must
        // equal or exceed the number of `+`-separated bare-`<C>a`
        // syllables in the buffer.
        TestCase("uniformPlusChain_panelHasFullChainSurface") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, minBaseConsonants: Int)] = [
                // 4-stack uniform chains continue to work (control).
                ("ka+ka+ka+ka",          4),
                // 5+ stacks are the bug class.
                ("ka+ka+ka+ka+ka",       5),
                ("ka+ka+ka+ka+ka+ka",    6),
                ("ka+ka+ka+ka+ka+ka+ka", 7),
                // Different consonant.
                ("pa+pa+pa+pa+pa",       5),
                ("ta+ta+ta+ta+ta",       5),
                // Trailing tone marker — the 4-stack case is pinned
                // by `MultiStackTrailingToneSuite`; the ≥5 cases are
                // the new TASK-057 ground.
                ("ka+ka+ka+ka.",         4),
                ("ka+ka+ka+ka:",         4),
                ("ka+ka+ka+ka+ka.",      5),
                ("ka+ka+ka+ka+ka:",      5),
            ]
            for c in cases {
                let state = engine.update(buffer: c.buffer, context: [])
                let panel = state.candidates
                let hasFullChain = panel.contains {
                    baseConsonantCount($0.surface) >= c.minBaseConsonants
                }
                ctx.assertTrue(
                    hasFullChain,
                    c.buffer,
                    detail: "expected ≥\(c.minBaseConsonants) base-consonants in some candidate; panel=\(panel.map { "'\($0.surface)' [\(hex($0.surface))]" })"
                )
            }
        },

        // Stronger assertion (preferred per task): rank 0 carries the
        // full-chain Myanmar surface, not the literal raw buffer.
        TestCase("uniformPlusChain_rank0IsFullChainOrLiteral") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, minBaseConsonants: Int)] = [
                ("ka+ka+ka+ka+ka",       5),
                ("ka+ka+ka+ka+ka+ka",    6),
                ("ka+ka+ka+ka+ka+ka+ka", 7),
                ("pa+pa+pa+pa+pa",       5),
            ]
            for c in cases {
                let state = engine.update(buffer: c.buffer, context: [])
                guard let top = state.candidates.first else {
                    ctx.assertTrue(false, c.buffer, detail: "panel empty")
                    continue
                }
                let isLiteral = top.surface == c.buffer
                let isFullChain = baseConsonantCount(top.surface) >= c.minBaseConsonants
                ctx.assertTrue(
                    isLiteral || isFullChain,
                    c.buffer,
                    detail: "rank-0='\(top.surface)' [\(hex(top.surface))]; expected literal or ≥\(c.minBaseConsonants)-consonant Myanmar"
                )
            }
        },

        // The literal raw buffer must remain reachable in the panel
        // for every test buffer (CLAUDE.md §2 escape hatch).
        TestCase("uniformPlusChain_literalReachable") { ctx in
            let engine = emptyEngine()
            for buffer in [
                "ka+ka+ka+ka+ka",
                "ka+ka+ka+ka+ka+ka",
                "ka+ka+ka+ka+ka+ka+ka",
                "ka+ka+ka+ka+ka.",
                "ka+ka+ka+ka+ka:",
            ] {
                let state = engine.update(buffer: buffer, context: [])
                let surfaces = state.candidates.map(\.surface)
                ctx.assertTrue(
                    surfaces.contains(buffer),
                    buffer,
                    detail: "literal '\(buffer)' missing from panel; surfaces=\(surfaces)"
                )
            }
        },

        // Heterogeneous chains must continue to work — mixing one
        // different letter into the chain breaks the bug class via
        // a different DP path that pre-existed the TASK-057 fix.
        TestCase("heterogeneousPlusChain_unchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expectedScalars: [UInt32])] = [
                ("ka+ka+pa+ka+ka", [0x1000, 0x1039, 0x1000, 0x1015, 0x1000, 0x1039, 0x1000]),
                ("ka+ta+ka+ta+ka", [0x1000, 0x1010, 0x1000, 0x1010, 0x1000]),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    actual == c.expectedScalars,
                    c.buffer,
                    detail: "expected=\(c.expectedScalars.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
            }
        },

        // Trailing tone marker must reach the rank-0 surface for
        // ≥5-stack chains (extends `MultiStackTrailingToneSuite`'s
        // 4-stack ceiling). The tone scalar (1037 creaky / 1038
        // visarga) attaches to the trailing loose syllable.
        TestCase("uniformPlusChain_trailingToneAtRank0") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, lastScalar: UInt32)] = [
                ("ka+ka+ka+ka+ka.", 0x1037),
                ("ka+ka+ka+ka+ka:", 0x1038),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    scalars.last == c.lastScalar,
                    c.buffer,
                    detail: "expected trailing scalar \(String(format: "%04X", c.lastScalar)); got '\(hex(surface))'"
                )
            }
        },

        // Pre-existing 4-stack control buffers from
        // `MultiStackTrailingToneSuite` must keep producing the
        // same rank-0 scalar sequence (no regression on the
        // earlier coverage ceiling).
        TestCase("uniformPlusChain_4StackControlUnchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                ("ka+ka",       [0x1000, 0x1039, 0x1000]),
                ("ka+ka+ka",    [0x1000, 0x1039, 0x1000, 0x1000]),
                ("ka+ka+ka+ka", [0x1000, 0x1039, 0x1000, 0x1000, 0x1039, 0x1000]),
                ("ka+ka+ka+ka.", [0x1000, 0x1039, 0x1000, 0x1000, 0x1039, 0x1000, 0x1037]),
                ("ka+ka+ka+ka:", [0x1000, 0x1039, 0x1000, 0x1000, 0x1039, 0x1000, 0x1038]),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    actual == c.expected,
                    c.buffer,
                    detail: "expected=\(c.expected.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
            }
        },

        // The triple-virama-stack scalar shape (`<C> 1039 <C> 1039
        // <C>`) must NEVER appear at rank 0 for any uniform chain
        // — the parser's break-the-chain alternative replaces it.
        TestCase("uniformPlusChain_noTripleViramaStackAtRank0") { ctx in
            let engine = emptyEngine()
            for buffer in [
                "ka+ka+ka",
                "ka+ka+ka+ka",
                "ka+ka+ka+ka+ka",
                "ka+ka+ka+ka+ka+ka",
                "ka+ka+ka+ka+ka+ka+ka",
                "pa+pa+pa+pa",
                "pa+pa+pa+pa+pa",
            ] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars.map(\.value))
                var hasTripleStack = false
                if scalars.count >= 5 {
                    for i in 0..<(scalars.count - 4) {
                        if scalars[i + 1] == 0x1039 && scalars[i + 3] == 0x1039 {
                            hasTripleStack = true
                            break
                        }
                    }
                }
                ctx.assertFalse(
                    hasTripleStack,
                    buffer,
                    detail: "rank-0='\(surface)' [\(hex(surface))] contains triple-virama-stack `<C> 1039 <C> 1039 <C>`"
                )
            }
        },
    ])
}
