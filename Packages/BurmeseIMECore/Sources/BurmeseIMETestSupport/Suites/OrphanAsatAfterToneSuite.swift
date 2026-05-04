import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-057: when the user types `*` (asat) after a
/// tone-closed vowel rule (e.g. `kar:.*`, `ka:*`, `o:.*`), the engine's
/// orphan-mark anchor injector used to fabricate a phantom `1021`
/// (independent vowel `အ`) before the asat to satisfy the asat's need
/// for a consonant base, producing surfaces of shape
/// `<...>(1037|1038)? 1021 103A` — none of which has a legitimate
/// Burmese spelling.
///
/// Burmese rule reference: tone marks (U+1037 creaky / U+1038 visarga)
/// are syllable closers. Once a tone is in place, the syllable is
/// complete and may not accept additional asat or tone scalars. The
/// shape `<tone> 1021 103A` is structurally invalid — `1021 103A`
/// (independent-vowel + asat) standalone has no orthographic meaning,
/// and its appearance after a tone marker reflects an injected anchor
/// rather than a user-typed consonant.
///
/// Strict acceptance criterion: NO candidate in the panel may contain
/// the `<U+1037|U+1038> 1021 103A` adjacency. The engine must either
/// drop the redundant trailing `*`/tones from the rendered surface or
/// fall through to the literal-fallback (raw buffer verbatim).
public enum OrphanAsatAfterToneSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// True when `surface` contains a `<tone-mark> 1021 103A` triplet.
    private static func hasToneOrphanAsat(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 3 else { return false }
        for i in 2..<scalars.count {
            let preTone = scalars[i - 2]
            guard preTone == 0x1037 || preTone == 0x1038 else { continue }
            if scalars[i - 1] == 0x1021 && scalars[i] == 0x103A {
                return true
            }
        }
        return false
    }

    /// Specifically the phantom `1021 103A` cluster — independent-A
    /// followed by asat with no legitimate user-typed consonant base.
    private static func hasIndependentAAsatPair(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 2 else { return false }
        for i in 1..<scalars.count {
            if scalars[i - 1] == 0x1021 && scalars[i] == 0x103A {
                return true
            }
        }
        return false
    }

    /// Reproduction inputs from TASK-057's bug table.
    private static let bugInputs: [String] = [
        "kar:.*", "kar.:*",
        "kay:.*",
        "k+kar:.*", "ka+kar:.*",
        "ka:*", "ka.*",
        "ka:.*", "ka.:*",
        "ar:.*", "ar.:*",
        "o:.*", "i:.*", "u:.*", "ay:.*",
    ]

    /// Regression-guard cases: existing canonical surfaces that must
    /// continue to surface unchanged at rank 0.
    private static let regressionGuards: [(buffer: String, expectedTop: String)] = [
        ("kar:",  "\u{1000}\u{102C}\u{1038}"),                            // ကား
        ("kar.",  "\u{1000}\u{102C}\u{1037}"),                            // ကာ့
        ("kar:*", "\u{1000}\u{102C}\u{1038}"),                            // ကား (* dropped after tone)
        ("kar.*", "\u{1000}\u{102C}\u{1037}"),                            // ကာ့ (* dropped after tone)
    ]

    public static let suite = TestSuite(name: "OrphanAsatAfterTone", cases: [

        // No candidate at any rank may carry the `<tone> 1021 103A`
        // adjacency. The phantom-anchor injection that produced the
        // bug shape is filtered.
        TestCase("noCandidate_hasToneOrphanAsat") { ctx in
            let engine = emptyEngine()
            for buffer in bugInputs {
                let state = engine.update(buffer: buffer, context: [])
                for (rank, c) in state.candidates.enumerated() {
                    ctx.assertFalse(
                        hasToneOrphanAsat(c.surface),
                        buffer,
                        detail: "candidate #\(rank) '\(c.surface)' [\(hex(c.surface))] has <tone> 1021 103A"
                    )
                }
            }
        },

        // For the `ka:*` / `ka.*` family — bare consonant followed by
        // tone(s) followed by asat — the user did not type any `a` to
        // produce the phantom `1021 103A`. The cluster must not appear
        // at any rank.
        TestCase("noCandidate_hasInjected_1021_103A_pair") { ctx in
            let engine = emptyEngine()
            // Inputs where the user typed NO `a` letter directly before
            // the `*` — any `1021 103A` adjacency in the surface is
            // therefore an injected phantom.
            let injectedInputs = [
                "kar:.*", "kar.:*", "kay:.*",
                "k+kar:.*", "ka+kar:.*",
                "ka:*", "ka.*", "ka:.*", "ka.:*",
                "o:.*", "i:.*", "u:.*", "ay:.*",
            ]
            for buffer in injectedInputs {
                let state = engine.update(buffer: buffer, context: [])
                for (rank, c) in state.candidates.enumerated() {
                    // Skip the literal fallback (raw buffer); it has
                    // no Myanmar scalars at all.
                    if c.surface == buffer { continue }
                    ctx.assertFalse(
                        hasIndependentAAsatPair(c.surface),
                        buffer,
                        detail: "candidate #\(rank) '\(c.surface)' [\(hex(c.surface))] has injected 1021 103A"
                    )
                }
            }
        },

        // Regression: clean tone-closed inputs and the existing
        // tone-then-asat collapse continue to surface unchanged.
        TestCase("cleanToneSurfaces_unchanged") { ctx in
            let engine = emptyEngine()
            for entry in regressionGuards {
                let top = engine.update(buffer: entry.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top,
                    entry.expectedTop,
                    "\(entry.buffer)_topHex=\(hex(top))_expectedHex=\(hex(entry.expectedTop))"
                )
            }
        },

        // The `surfaceContainsToneOrphanAsat` detector must
        // correctly identify the bug shapes when called directly,
        // without false-positives on legitimate spellings.
        TestCase("surfaceContainsToneOrphanAsat_predicateAccuracy") { ctx in
            // Bug shapes (must return true).
            let bugShapes: [(label: String, scalars: [UInt32])] = [
                ("kar:.*",   [0x1000, 0x102C, 0x1038, 0x1021, 0x103A]),
                ("kar.:*",   [0x1000, 0x102C, 0x1037, 0x1021, 0x103A]),
                ("ar:.*",    [0x1021, 0x102C, 0x1038, 0x1021, 0x103A]),
                ("ka:*",     [0x1000, 0x1038, 0x1021, 0x103A]),
                ("ka.*",     [0x1000, 0x1037, 0x1021, 0x103A]),
            ]
            for c in bugShapes {
                let s = String(c.scalars.compactMap { Unicode.Scalar($0) }
                    .map(Character.init))
                ctx.assertTrue(
                    BurmeseEngine.surfaceContainsToneOrphanAsat(s),
                    c.label,
                    detail: "predicate failed to flag '\(hex(s))'"
                )
            }
            // Legitimate shapes (must return false).
            let cleanShapes: [(label: String, scalars: [UInt32])] = [
                ("kar:",     [0x1000, 0x102C, 0x1038]),
                ("kar.",     [0x1000, 0x102C, 0x1037]),
                ("kar*",     [0x1000, 0x102C, 0x103A]),
                ("kit.",     [0x1000, 0x1005, 0x1037, 0x103A]),
                ("kit:",     [0x1000, 0x1005, 0x103A, 0x1038]),
            ]
            for c in cleanShapes {
                let s = String(c.scalars.compactMap { Unicode.Scalar($0) }
                    .map(Character.init))
                ctx.assertFalse(
                    BurmeseEngine.surfaceContainsToneOrphanAsat(s),
                    c.label,
                    detail: "predicate falsely flagged '\(hex(s))'"
                )
            }
        },
    ])
}
