import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-018: long inherent-A chains followed by more letters past
/// the 6-character dropped-tail gate must not leak raw ASCII INTO
/// THE MYANMAR PORTION of the rank-0 candidate surface. The right-
/// shrink probe peels the trailing letters into the literal tail;
/// without this fix `composeLetterRunsInTail` is gated off and the
/// user sees a Myanmar+ASCII mixed surface (`ကaaaakaa` for
/// `kaaaaakaa`).
///
/// The acceptance invariant: no rank-0 surface for these buffers
/// is a Myanmar-then-ASCII mix. With TASK-047's literal-fallback
/// promotion in place, rank-0 may legitimately be the pure-ASCII
/// literal (Class B "extreme right-shrink collapse") for
/// repetition-heavy buffers like `kaaaaaaaaa`; the test uses a
/// per-candidate scan to distinguish "no Myanmar surface anywhere"
/// (invariant violation, regression) from "rank-0 is the pure-
/// ASCII literal because the buffer collapsed too far" (acceptable
/// post-TASK-047).
public enum InherentAChainOverflowSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    /// True when `surface` contains an ASCII letter (U+0041..U+005A
    /// or U+0061..U+007A). The TASK-018 invariant rejects any rank-0
    /// surface where this is true and the input was a pure-ASCII
    /// Roman composing buffer.
    private static func surfaceHasAsciiLetter(_ surface: String) -> Bool {
        surface.unicodeScalars.contains {
            (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
        }
    }

    /// True when `surface` mixes Myanmar-block scalars (U+1000..
    /// U+109F) with ASCII letters. The post-TASK-047 invariant: a
    /// candidate may be the pure-ASCII literal OR pure Myanmar,
    /// but never a mix of the two. The original TASK-018 bug shape
    /// produced exactly the mixed form (`ကaaaakaa`); guarding
    /// against it via this stricter predicate.
    private static func surfaceMixesMyanmarAndAscii(_ surface: String) -> Bool {
        var hasMyanmar = false
        var hasAscii = false
        for scalar in surface.unicodeScalars {
            let v = scalar.value
            if v >= 0x1000 && v <= 0x109F {
                hasMyanmar = true
            } else if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) {
                hasAscii = true
            }
            if hasMyanmar && hasAscii { return true }
        }
        return false
    }

    /// Onsets that should not collide with the inherent-A chain
    /// (excludes medial-bearing keys / cluster aliases / digit-bearing
    /// variants — those interact with the parser's other special
    /// paths).
    private static let onsets: [String] = [
        "k", "g", "n", "p", "h", "m", "y", "r", "l", "w", "s", "z",
        "th", "ny", "ng", "ph", "kh",
    ]

    public static let suite = TestSuite(name: "InherentAChainOverflow", cases: [

        // Specific reproductions documented in TASK-018. The
        // invariant is "no candidate is a Myanmar+ASCII mix" — the
        // original bug shape (`ကaaaakaa`). Post-TASK-047, rank-0
        // may be the pure-ASCII literal candidate for Class B
        // "extreme right-shrink collapse" buffers; this is a
        // legitimate user-facing escape hatch, not the bug being
        // guarded against here.
        TestCase("repro_kaaaaakaa_isMyanmarOnly") { ctx in
            let engine = emptyEngine()
            let inputs = ["kaaaaakaa", "kaaaaaakaa", "kaaaaakaaa",
                          "naaaaakaa", "thaaaaakaa", "phaaaaakaa"]
            for buffer in inputs {
                let panel = engine.update(buffer: buffer, context: [])
                    .candidates
                ctx.assertFalse(
                    panel.isEmpty,
                    "\(buffer)_nonEmpty",
                    detail: "panel must not be empty for '\(buffer)'"
                )
                for cand in panel {
                    ctx.assertFalse(
                        surfaceMixesMyanmarAndAscii(cand.surface),
                        buffer,
                        detail: "candidate mixes Myanmar+ASCII for '\(buffer)' surface='\(cand.surface)'"
                    )
                }
                let panelHasMyanmar = panel.contains { cand in
                    cand.surface.unicodeScalars.contains {
                        $0.value >= 0x1000 && $0.value <= 0x109F
                    }
                }
                ctx.assertTrue(
                    panelHasMyanmar,
                    "\(buffer)_panelHasMyanmar",
                    detail: "panel must contain a Myanmar candidate for '\(buffer)'"
                )
            }
        },

        // Pathological auto-repeat: 16 trailing `a`s. With
        // TASK-047's Class B promotion, rank-0 is the literal;
        // the panel must still contain a Myanmar candidate.
        TestCase("repro_extremeChain_isMyanmarOnly") { ctx in
            let engine = emptyEngine()
            let buffer = "kaaaaaaaaaaaaaaaaa"
            let panel = engine.update(buffer: buffer, context: [])
                .candidates
            for cand in panel {
                ctx.assertFalse(
                    surfaceMixesMyanmarAndAscii(cand.surface),
                    buffer,
                    detail: "candidate mixes Myanmar+ASCII for '\(buffer)' surface='\(cand.surface)'"
                )
            }
            let panelHasMyanmar = panel.contains { cand in
                cand.surface.unicodeScalars.contains {
                    $0.value >= 0x1000 && $0.value <= 0x109F
                }
            }
            ctx.assertTrue(
                panelHasMyanmar,
                buffer,
                detail: "panel must contain a Myanmar candidate for '\(buffer)'"
            )
        },

        // Sweep across every plain consonant onset and chain length.
        // Same relaxed invariant: no candidate mixes Myanmar+ASCII;
        // the panel always carries a Myanmar candidate.
        TestCase("sweep_consonantsAndChainLengths_areMyanmarOnly") { ctx in
            let engine = emptyEngine()
            for onset in onsets {
                for chainLen in 5...10 {
                    let chain = String(repeating: "a", count: chainLen)
                    for tail in ["kaa", "ka", "kaaa"] {
                        let buffer = onset + chain + tail
                        let panel = engine.update(buffer: buffer, context: [])
                            .candidates
                        for cand in panel {
                            ctx.assertFalse(
                                surfaceMixesMyanmarAndAscii(cand.surface),
                                buffer,
                                detail: "candidate mixes Myanmar+ASCII for '\(buffer)' surface='\(cand.surface)'"
                            )
                        }
                    }
                }
            }
        },

        // Counter-example: short chains (≤8 chars or with the
        // Class B threshold not firing) continue to render cleanly
        // at rank 0. With TASK-047 Class B's conservative
        // `3 * scalar < buffer` ratio, these specific 6-8 char
        // buffers do not trigger the literal-fallback promotion.
        TestCase("counter_shortChain_unchanged") { ctx in
            let engine = emptyEngine()
            for buffer in ["kaakaa", "kaaakaa", "kaaaakaa"] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    surfaceHasAsciiLetter(surface),
                    buffer,
                    detail: "regressed short-chain behaviour for '\(buffer)' surface='\(surface)'"
                )
            }
        },
    ])
}
