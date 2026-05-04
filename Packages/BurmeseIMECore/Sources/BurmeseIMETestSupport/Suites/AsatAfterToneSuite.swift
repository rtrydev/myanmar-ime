import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-048: an asat (`U+103A`) that lands directly after a
/// tone marker (`U+1037` creaky / `U+1038` visarga) is orthographically
/// invalid — the tone closes the syllable cluster and nothing, including
/// asat, may legitimately follow it.
///
/// Burmese rule reference (Unicode TUS §16.3, "Visual order vs storage
/// order in Myanmar"):
///
///   `<base> (<asat-virama-stack>)? (<medial>)* (<dep-vowel>)* (<asat-coda>)? (<tone>)?`
///
/// The asat coda occupies the slot **before** the tone. A surface
/// containing the scalar adjacency `(1037 | 1038) 103A` is therefore
/// malformed, has no orthographic interpretation, and must not pass the
/// parser's `scanOutputLegality` predicate.
///
/// The reproduction set covers tone-vowel rules over single-consonant
/// onsets (`kar:*`, `ki:*`, `ku:*`, `ko:*`, `kay:*`), independent-vowel
/// onsets (`ar:*`, `ar.*`), and virama-stack onsets (`k+kar:*`,
/// `k+kar.*`) so the fix cannot be a per-input patch.
public enum AsatAfterToneSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// True when `surface` contains a malformed asat-after-tone
    /// adjacency:
    ///
    ///   - `1038 103A` (visarga before asat) — never legal; visarga
    ///     always sits AFTER the asat (`<C> 103A 1038`, TASK-023).
    ///   - `1037 103A` (creaky before asat) where the scalar
    ///     immediately before the creaky is NOT a consonant base.
    ///     The legal shape `<C-base> 1037 103A` (stop-coda creaky,
    ///     TASK-023) is allowed; `<dep-vowel> 1037 103A` /
    ///     `<medial> 1037 103A` are not.
    private static func surfaceHasAsatAfterTone(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        guard scalars.count >= 2 else { return false }
        @inline(__always) func isConsonantBase(_ v: UInt32) -> Bool {
            return (v >= 0x1000 && v <= 0x1021) || v == 0x103F
        }
        for i in 1..<scalars.count {
            let prev = scalars[i - 1].value
            let curr = scalars[i].value
            guard curr == 0x103A else { continue }
            if prev == 0x1038 {
                return true
            }
            if prev == 0x1037 {
                // Legal creaky-before-asat requires a consonant base
                // immediately before the creaky.
                if i < 2 { return true }
                let preTone = scalars[i - 2].value
                if !isConsonantBase(preTone) { return true }
            }
        }
        return false
    }

    /// Reproduction inputs spanning every variant of the bug class:
    /// single-consonant + tone-vowel rule + asat (`*`), virama-stacked
    /// onset, independent-vowel onset, both creaky (`.`) and visarga
    /// (`:`) tones.
    private static let bugInputs: [String] = [
        "kar:*", "kar.*",
        "ki:*",  "ki.*",
        "ku:*",  "ku.*",
        "ko:*",  "ko.*",
        "kay:*", "kay.*",
        "ar:*",  "ar.*",
        "k+kar:*", "k+kar.*",
    ]

    public static let suite = TestSuite(name: "AsatAfterTone", cases: [

        // Rank-0 surface must NEVER contain the malformed
        // `(1037 | 1038) 103A` adjacency — either a clean Myanmar
        // sibling wins, or the literal-fallback Class A trigger lifts
        // the user's typed buffer to rank 0.
        TestCase("rank0Surface_hasNoAsatAfterToneAdjacency") { ctx in
            let engine = emptyEngine()
            for buffer in bugInputs {
                let state = engine.update(buffer: buffer, context: [])
                let topSurface = state.candidates.first?.surface ?? ""
                ctx.assertFalse(
                    surfaceHasAsatAfterTone(topSurface),
                    buffer,
                    detail: "rank-0 surface contains (1037|1038) 103A; got '\(topSurface)' [\(hex(topSurface))]"
                )
            }
        },

        // Stronger guard: the malformed adjacency must not appear in
        // ANY candidate surface — once `scanOutputLegality` rejects
        // these shapes, the DP cannot admit them and the engine should
        // surface either a clean sibling or the literal fallback.
        TestCase("noCandidateSurface_carriesAsatAfterTone") { ctx in
            let engine = emptyEngine()
            for buffer in bugInputs {
                let state = engine.update(buffer: buffer, context: [])
                for c in state.candidates {
                    ctx.assertFalse(
                        surfaceHasAsatAfterTone(c.surface),
                        buffer,
                        detail: "candidate surface '\(c.surface)' [\(hex(c.surface))] contains (1037|1038) 103A"
                    )
                }
            }
        },

        // Direct legality-scan predicate test: scalar sequences that
        // place an asat directly after a tone marker must be rejected
        // by `SyllableParser.scanOutputLegality`. The scan operates
        // on rendered scalar sequences without going through the
        // engine pipeline, so this is the narrowest possible check.
        TestCase("scanOutputLegality_rejectsAsatAfterTone") { ctx in
            let cases: [(label: String, scalars: [UInt32])] = [
                ("ka:*",     [0x1000, 0x102C, 0x1038, 0x103A]),                  // ကား်
                ("ka.*",     [0x1000, 0x102C, 0x1037, 0x103A]),                  // ကာ့်
                ("ki:*",     [0x1000, 0x102E, 0x1038, 0x103A]),                  // ကီး်
                ("ku:*",     [0x1000, 0x1030, 0x1038, 0x103A]),                  // ကူး်
                ("ko:*",     [0x1000, 0x102D, 0x102F, 0x1038, 0x103A]),          // ကိုး်
                ("kay:*",    [0x1000, 0x1031, 0x1038, 0x103A]),                  // ကေး်
                ("kay.*",    [0x1000, 0x1031, 0x1037, 0x103A]),                  // ကေ့်
                ("ar:*",     [0x1021, 0x102C, 0x1038, 0x103A]),                  // အား်
                ("ar.*",     [0x1021, 0x102C, 0x1037, 0x103A]),                  // အာ့်
                ("k+kar:*",  [0x1000, 0x1039, 0x1000, 0x102C, 0x1038, 0x103A]),  // က္ကား်
                ("k+kar.*",  [0x1000, 0x1039, 0x1000, 0x102C, 0x1037, 0x103A]),  // က္ကာ့်
            ]
            for c in cases {
                let s = String(c.scalars.compactMap { Unicode.Scalar($0) }.map(Character.init))
                let legal = SyllableParser.scanOutputLegality(s)
                ctx.assertFalse(
                    legal,
                    c.label,
                    detail: "scanOutputLegality returned true for malformed scalars '\(hex(s))'"
                )
            }
        },

        // Counter-examples that must REMAIN legal — clean tone
        // placements where the asat sits BEFORE the tone (the
        // documented coda+tone order). These already work; this
        // case exists as a regression guard so the fix does not
        // tighten too aggressively.
        TestCase("scanOutputLegality_acceptsAsatBeforeTone") { ctx in
            let cases: [(label: String, scalars: [UInt32])] = [
                // <C> 103A 1038 — visarga after asat coda. (TASK-023)
                ("kit:",  [0x1000, 0x1005, 0x103A, 0x1038]),
                ("let:",  [0x101C, 0x1000, 0x103A, 0x1038]),
                // <C> 1037 103A — creaky before asat coda. (TASK-023)
                ("kit.",  [0x1000, 0x1005, 0x1037, 0x103A]),
                ("let.",  [0x101C, 0x1000, 0x1037, 0x103A]),
            ]
            for c in cases {
                let s = String(c.scalars.compactMap { Unicode.Scalar($0) }.map(Character.init))
                let legal = SyllableParser.scanOutputLegality(s)
                ctx.assertTrue(
                    legal,
                    c.label,
                    detail: "scanOutputLegality wrongly rejected legal scalars '\(hex(s))'"
                )
            }
        },
    ])
}
