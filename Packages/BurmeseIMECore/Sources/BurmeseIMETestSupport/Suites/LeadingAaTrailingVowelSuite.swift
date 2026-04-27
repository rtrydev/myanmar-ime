import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-020: leading `<C>aa<vowel>` shapes (where `<vowel>` is a
/// trailing vowel-extender like `y`, `u`, `w`, `oo`) must keep the
/// canonical dependent-vowel form at rank 0 — not the rare
/// free-standing independent-vowel sibling. Today the parser's
/// TASK-009 carve-out skips the standalone rule only when the
/// predecessor is a `vowelOnly` arc with empty emission; the carve-
/// out is widened so it also fires when the predecessor is an
/// `onsetVowel` arc whose vowel is the inherent-A (also empty
/// emission). The free-standing form remains reachable at rank ≥ 1.
public enum LeadingAaTrailingVowelSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func topSurface(_ engine: BurmeseEngine, _ buffer: String) -> String {
        engine.update(buffer: buffer, context: []).candidates.first?.surface ?? ""
    }

    /// Five representative consonant onsets — covering plain, aspirated,
    /// nasal, fricative, and approximant classes. Each must produce the
    /// same dep-vowel rank-0 shape for `<C>aaY` as for `<C>aY`.
    private static let representativeConsonants: [String] = [
        "k", "n", "t", "p", "y",
    ]

    public static let suite = TestSuite(name: "LeadingAaTrailingVowel", cases: [

        // For `<C>aay`, the rank-0 surface must use the dep-vowel
        // `1031` form (matching `<C>ay`), not the free-standing
        // `1027` form.
        TestCase("ay_rank0MatchesDepVowel") { ctx in
            let engine = emptyEngine()
            for c in representativeConsonants {
                let cAy = topSurface(engine, c + "ay")
                let cAaY = topSurface(engine, c + "aay")
                ctx.assertEqual(
                    cAaY, cAy,
                    "ay_rank0_\(c)"
                )
            }
        },

        // For `<C>aau`, the rank-0 surface must use the dep-vowel
        // `1030` (uu) form, not the free-standing `1026` form.
        TestCase("u_rank0MatchesDepVowel") { ctx in
            let engine = emptyEngine()
            for c in representativeConsonants {
                let cU = topSurface(engine, c + "u")
                let cAaU = topSurface(engine, c + "aau")
                // The rank-0 should match the dep-vowel rendering
                // produced by the bare `<C>u` reading. We allow
                // partial mismatch in the leading consonant
                // canonicalisation (e.g. `t` vs `t2`), so compare
                // by the trailing dep-vowel scalar.
                let expectedTrailingScalars = Array(cU.unicodeScalars).map(\.value)
                let actualTrailingScalars = Array(cAaU.unicodeScalars).map(\.value)
                ctx.assertTrue(
                    expectedTrailingScalars.last == actualTrailingScalars.last,
                    "u_rank0_\(c)",
                    detail: "expected trailing \(expectedTrailingScalars.last.map { String(format: "%04X", $0) } ?? "(nil)") got \(actualTrailingScalars.last.map { String(format: "%04X", $0) } ?? "(nil)") for '\(c)aau'; surface='\(cAaU)'"
                )
                // The free-standing `1026` (ဦ) should NOT be at rank 0.
                ctx.assertFalse(
                    actualTrailingScalars.contains(0x1026),
                    "u_rank0NoFreestanding_\(c)",
                    detail: "rank-0 for '\(c)aau' should not contain free-standing 1026 (ဦ); surface='\(cAaU)'"
                )
            }
        },

        // The free-standing form must remain reachable at rank ≥ 1
        // for users who explicitly want it. Verified for the `ay`
        // case via the `1027` (ဧ) scalar.
        TestCase("ay_freestandingReachable") { ctx in
            let engine = emptyEngine()
            for c in representativeConsonants {
                let state = engine.update(buffer: c + "aay", context: [])
                let hasFreestanding = state.candidates.contains { cand in
                    cand.surface.unicodeScalars.contains { $0.value == 0x1027 }
                }
                ctx.assertTrue(
                    hasFreestanding,
                    "freestanding_reachable_\(c)",
                    detail: "panel for '\(c)aay' must contain a free-standing-vowel sibling; got: \(state.candidates.map(\.surface))"
                )
            }
        },

        // Negative regression: `<C>ay` keeps its dep-vowel rendering.
        TestCase("ay_baselineUnchanged") { ctx in
            let engine = emptyEngine()
            for c in representativeConsonants {
                let surface = topSurface(engine, c + "ay")
                let scalars = Array(surface.unicodeScalars).map(\.value)
                ctx.assertTrue(
                    scalars.contains(0x1031),
                    "baseline_\(c)",
                    detail: "rank-0 for '\(c)ay' should still contain dep-vowel 1031 (ေ); surface='\(surface)'"
                )
            }
        },
    ])
}
