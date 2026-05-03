import Foundation
import BurmeseIMECore

/// TASK-043: when an ASCII letter run produces no Burmese candidate
/// — or only partial Myanmar candidates with no lexicon hit — the
/// engine must always synthesize a literal-text candidate equal to
/// the user's raw buffer. The literal lets the user commit what they
/// typed (English words, brand names, etc.) without being stranded by
/// an empty panel.
///
/// Resolved policy (2026-05-03):
///
/// 1. Synthesize `Candidate(surface: rawBuffer, reading: rawBuffer,
///    source: .grammar, score: 0)`.
/// 2. Compute `unconvertibleRatio = (rawBuffer.count -
///    parser.parseLongestAcceptablePrefix(normalized)) / rawBuffer.count`.
/// 3. Position by threshold:
///    - empty panel → literal is the only candidate.
///    - ratio ≥ 0.5  → insert at rank 0 (Myanmar follows).
///    - ratio < 0.5  → append at the bottom.
/// 4. Skip entirely when the rank-0 candidate (before injection) has
///    `source == .lexicon` — a lexicon hit signals intentional
///    Burmese composition, so don't clutter the panel.
/// 5. De-dup: skip if any existing candidate already has
///    `surface == rawBuffer`.
public enum LiteralFallbackCandidateSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    /// Engine fixture with a minimal lexicon mock — used for the
    /// "lexicon-hit carve-out" branches where we must observe a
    /// `.lexicon` source candidate at rank 0.
    private static func engine(withLexicon entries: [String: [Candidate]]) -> BurmeseEngine {
        BurmeseEngine(
            candidateStore: FixedCandidateStore(byPrefix: entries),
            languageModel: NullLanguageModel()
        )
    }

    private static func surfaceContainsMyanmar(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value >= 0x1000 && $0.value <= 0x109F }
    }

    private static func surfaces(_ candidates: [Candidate]) -> [String] {
        candidates.map(\.surface)
    }

    public static let suite = TestSuite(name: "LiteralFallbackCandidate", cases: [

        // Ratio == 1.0: the buffer has no acceptable Myanmar parse at
        // all. The literal is the only candidate, equal to the raw
        // buffer character-for-character.
        TestCase("noMyanmarParse_literalIsOnlyCandidate") { ctx in
            let engine = emptyEngine()
            for buffer in ["c", "co", "comp", "compute", "computer",
                           "facebook", "face", "fac", "fb"] {
                let state = engine.update(buffer: buffer, context: [])
                ctx.assertTrue(
                    state.candidates.count == 1,
                    buffer,
                    detail: "expected exactly 1 candidate; got \(surfaces(state.candidates))"
                )
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top == buffer,
                    buffer,
                    detail: "expected literal '\(buffer)'; got '\(top)'"
                )
            }
        },

        // Ratio == 0.0 (parser fully consumes input, no lexicon hit):
        // Myanmar candidate stays at rank 0; literal is appended at
        // the bottom of the panel.
        TestCase("fullParseNoLexicon_literalAppendedAtBottom") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expectedTopHasMyanmar: Bool)] = [
                ("tablet", true),
                ("phone", true),
            ]
            for entry in cases {
                let state = engine.update(buffer: entry.buffer, context: [])
                ctx.assertTrue(
                    state.candidates.count >= 2,
                    entry.buffer,
                    detail: "expected ≥2 candidates; got \(surfaces(state.candidates))"
                )
                if entry.expectedTopHasMyanmar {
                    let topSurface = state.candidates.first?.surface ?? ""
                    ctx.assertTrue(
                        surfaceContainsMyanmar(topSurface),
                        entry.buffer,
                        detail: "top='\(topSurface)' should be Myanmar"
                    )
                }
                ctx.assertTrue(
                    state.candidates.last?.surface == entry.buffer,
                    entry.buffer,
                    detail: "expected last candidate to be literal '\(entry.buffer)'; got '\(state.candidates.last?.surface ?? "")'"
                )
            }
        },

        // Ratio < 0.5: Myanmar leads, literal appended at bottom.
        // `aungc` (1/5 = 0.2 unconvertible), `kac` (1/3 ≈ 0.33).
        TestCase("partialParseLowRatio_literalAppendedAtBottom") { ctx in
            let engine = emptyEngine()
            for buffer in ["aungc", "kac"] {
                let state = engine.update(buffer: buffer, context: [])
                ctx.assertTrue(
                    state.candidates.count >= 2,
                    buffer,
                    detail: "expected ≥2 candidates; got \(surfaces(state.candidates))"
                )
                let topSurface = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    surfaceContainsMyanmar(topSurface),
                    buffer,
                    detail: "top='\(topSurface)' should contain Myanmar"
                )
                ctx.assertTrue(
                    state.candidates.last?.surface == buffer,
                    buffer,
                    detail: "expected last candidate to be literal '\(buffer)'; got '\(state.candidates.last?.surface ?? "")'"
                )
            }
        },

        // Engine renders `google` as `ဂိုဂလယ်` even though the
        // strict-acceptable-prefix length is only 2: the rank-0
        // surface is Myanmar, and the literal is appended at the
        // bottom (the rank-0 surface carries no raw ASCII letters,
        // so the engine-side signal vetoes a rank-0 literal even
        // though the parser-side signal would push for one).
        TestCase("partialParseEngineRendersMyanmar_literalAppended") { ctx in
            let engine = emptyEngine()
            let state = engine.update(buffer: "google", context: [])
            ctx.assertTrue(
                state.candidates.count >= 2,
                "google",
                detail: "expected ≥2 candidates; got \(surfaces(state.candidates))"
            )
            let topSurface = state.candidates.first?.surface ?? ""
            ctx.assertTrue(
                surfaceContainsMyanmar(topSurface),
                "google",
                detail: "expected rank-0 Myanmar; got '\(topSurface)'"
            )
            ctx.assertTrue(
                state.candidates.last?.surface == "google",
                "google",
                detail: "expected literal 'google' at bottom; got '\(state.candidates.last?.surface ?? "")'"
            )
        },

        // Lexicon-hit carve-out: when the rank-0 candidate has source
        // `.lexicon`, the user is composing intentional Burmese — do
        // not synthesize a literal. The candidate panel matches what
        // it would have without the fallback step.
        TestCase("lexiconHitAtRankZero_noLiteralSynthesized") { ctx in
            let engine = engine(withLexicon: [
                "mingalarpar": [Candidate(
                    surface: "မင်္ဂလာပါ",
                    reading: "min+galarpar",
                    source: .lexicon,
                    score: 1000
                )],
            ])
            for buffer in ["mingalarpar"] {
                let state = engine.update(buffer: buffer, context: [])
                ctx.assertFalse(
                    state.candidates.isEmpty,
                    buffer,
                    detail: "expected non-empty panel"
                )
                let top = state.candidates.first
                ctx.assertTrue(
                    top?.source == .lexicon,
                    buffer,
                    detail: "expected lexicon top; got source=\(String(describing: top?.source))"
                )
                ctx.assertFalse(
                    state.candidates.contains { $0.surface == buffer },
                    buffer,
                    detail: "literal '\(buffer)' should NOT appear when lexicon hits at rank 0; got \(surfaces(state.candidates))"
                )
            }
        },

        // De-dup: the literal must appear at most once even when the
        // engine has multiple paths that could each emit it. Calling
        // `update` repeatedly with the same buffer must not accumulate
        // duplicate literal candidates. (Dedup is enforced by checking
        // that no existing candidate already has `surface == rawBuffer`
        // before inserting.)
        TestCase("repeatedUpdates_literalAppearsAtMostOnce") { ctx in
            let engine = emptyEngine()
            for _ in 0..<3 {
                let state = engine.update(buffer: "comp", context: [])
                let literalCount = state.candidates.filter { $0.surface == "comp" }.count
                ctx.assertTrue(
                    literalCount == 1,
                    "comp",
                    detail: "expected exactly one 'comp' candidate; got \(literalCount)"
                )
            }
        },

        // Literal must be the raw buffer verbatim — ASCII digits stay
        // ASCII, never Myanmar numerals, no alias folding, no
        // displayBuffer mapping.
        TestCase("digitsInBufferStayAscii") { ctx in
            let engine = emptyEngine()
            let state = engine.update(buffer: "comp2", context: [])
            ctx.assertTrue(
                state.candidates.contains { $0.surface == "comp2" },
                "comp2",
                detail: "expected literal 'comp2' verbatim (not 'comp၂'); got \(surfaces(state.candidates))"
            )
        },

        // The synthesized literal candidate has source `.grammar`,
        // score 0, and reading equal to the raw buffer.
        TestCase("literalCandidateProperties") { ctx in
            let engine = emptyEngine()
            let state = engine.update(buffer: "facebook", context: [])
            let literal = state.candidates.first { $0.surface == "facebook" }
            ctx.assertTrue(literal != nil, "facebook", detail: "literal not present")
            ctx.assertTrue(
                literal?.source == .grammar,
                "facebook",
                detail: "expected source=.grammar; got \(String(describing: literal?.source))"
            )
            ctx.assertTrue(
                literal?.score == 0.0,
                "facebook",
                detail: "expected score=0; got \(String(describing: literal?.score))"
            )
            ctx.assertTrue(
                literal?.reading == "facebook",
                "facebook",
                detail: "expected reading='facebook'; got '\(literal?.reading ?? "")'"
            )
        },

        // Mixed-buffer inputs (buffer with composable + literal tail
        // affixes) still get the literal injected when no lexicon
        // hit takes rank 0. `kar:bc` → Myanmar `ကား` + literal tail
        // `:bc` at rank 0; literal `kar:bc` appended at bottom
        // (ratio = 1/6 ≈ 0.17, < 0.5).
        TestCase("mixedBuffer_partialMyanmar_literalAppendedAtBottom") { ctx in
            let engine = emptyEngine()
            let state = engine.update(buffer: "kar:bc", context: [])
            ctx.assertTrue(
                state.candidates.count >= 2,
                "kar:bc",
                detail: "expected ≥2 candidates; got \(surfaces(state.candidates))"
            )
            ctx.assertTrue(
                state.candidates.last?.surface == "kar:bc",
                "kar:bc",
                detail: "expected literal 'kar:bc' at bottom; got '\(state.candidates.last?.surface ?? "")'"
            )
        },

        // The literal candidate equals the raw buffer (lowercased
        // equivalent, since the engine lowercases internally). All
        // letters preserved as typed.
        TestCase("literalEqualsRawBufferVerbatim") { ctx in
            let engine = emptyEngine()
            for buffer in ["c", "comp", "computer", "facebook", "fb"] {
                let state = engine.update(buffer: buffer, context: [])
                let literal = state.candidates.first { $0.surface == buffer }
                ctx.assertTrue(
                    literal != nil,
                    buffer,
                    detail: "literal '\(buffer)' missing from panel; got \(surfaces(state.candidates))"
                )
            }
        },

        // Sanity: empty buffer still produces no candidates (the
        // wrapper does not synthesize a literal for empty input).
        TestCase("emptyBuffer_noLiteralSynthesized") { ctx in
            let engine = emptyEngine()
            let state = engine.update(buffer: "", context: [])
            ctx.assertTrue(
                state.candidates.isEmpty,
                "empty",
                detail: "expected empty panel for empty input"
            )
        },

        // Property: for any non-empty composable ASCII letter run
        // (length 1–6), the panel is never empty. Either a Myanmar
        // candidate composed, or a literal was synthesized.
        TestCase("nonEmptyAsciiLetterRun_panelNeverEmpty") { ctx in
            let engine = emptyEngine()
            // Hand-picked ASCII letter runs (no `'`, `+`, `*`, `.`,
            // `:` — those are exercised by LoneComposingPunctSuite).
            let buffers = [
                "c", "f", "q", "v", "x", "z",
                "cc", "ccc", "fc", "qq", "xq", "zz",
                "facebook", "comp", "google",
                "abc", "kac", "aungc", "tablet", "phone",
            ]
            for buffer in buffers {
                let state = engine.update(buffer: buffer, context: [])
                ctx.assertFalse(
                    state.candidates.isEmpty,
                    buffer,
                    detail: "panel empty for '\(buffer)'"
                )
            }
        },
    ])
}
