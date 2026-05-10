import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-055: an asat (`U+103A`) that lands directly after a
/// dependent vowel (other than the legal `aw`-cluster `1031 102B/C`)
/// is orthographically invalid — the dep-vowel either does not take a
/// stop coda at all, or it forms a tone-closed syllable that has no
/// legal trailing asat. The parser used to accept the malformed surface
/// (`ki*` → `1000 102E 103A` / `ကီ်`, `kar*` → `1000 102C 103A` / `ကာ်`,
/// `kywar*` → `1000 103B 103D 102C 103A` / `ကျွာ်`) at rank 0 with a
/// positive grammar score because `scanOutputLegality` walked freely
/// through every dep-vowel scalar before the asat.
///
/// Burmese rule reference: closed-syllable shapes admitting a trailing
/// asat are limited to —
///
/// 1. `<C>(<medial>)*<103A>` — pure stop coda with optional medials.
/// 2. `<C><1031><102B/C><103A>` — the `aw`-vowel cluster.
/// 3. `<C><1037><103A>` — creaky-then-asat (TASK-048 carve-out, only
///    when the scalar immediately before the creaky is a consonant base).
///
/// Every other `<C><dep-vowel><103A>` shape is malformed.
public enum AsatAfterDepVowelSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// True when `surface` has any `<dep-vowel><103A>` adjacency that
    /// is not part of the legal `aw`-cluster shape `<1031><102B/C><103A>`.
    private static func hasIllegalAsatAfterDepVowel(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 2 else { return false }
        for i in 1..<scalars.count {
            guard scalars[i] == 0x103A else { continue }
            let prev = scalars[i - 1]
            // No dep-vowel before the asat at all → not the bug shape.
            guard prev >= 0x102B && prev <= 0x1032 else { continue }
            // Legal aw-cluster: `1031 102B/C 103A`. Walk back further
            // to confirm `1031` precedes the aa scalar.
            if (prev == 0x102B || prev == 0x102C),
               i >= 2,
               scalars[i - 2] == 0x1031 {
                continue
            }
            return true
        }
        return false
    }

    /// Reproduction inputs from TASK-055's bug table — every shape
    /// reaches the malformed `<C><dep-vowel><103A>` rank-0 surface
    /// against the un-fixed engine.
    private static let bugInputs: [String] = [
        "ki*", "ko*", "ku*",
        "ki.*", "ku.*",
        "kar*", "kar2*",
        "ke:*",
        "kywar*", "kywi*", "kywu*", "kywo*",
        "i*", "u*", "o*",
        "kar*ka", "ki*ka", "ko*ka",
        "k+kar*",
    ]

    /// Inputs where a legitimate Myanmar sibling exists in the panel —
    /// once the malformed surface is filtered, the legitimate sibling
    /// must be promoted to rank 0 (or the literal-fallback can win).
    private static let bugInputsWithLegitimateSibling: [(buffer: String, legitimateSurface: String)] = [
        ("kar*",   "\u{1000}\u{101B}\u{103A}"),                          // ကရ် (kar* → kar with asat coda)
        ("k+kar*", "\u{1000}\u{1039}\u{1000}\u{101B}\u{103A}"),          // က္ကရ်
    ]

    /// Inputs that have NO legitimate Myanmar `<C><consonant><103A>`
    /// stop-coda parse — the rank-0 surface must either drop the
    /// trailing asat / dep-vowel content from the user's `*` typing,
    /// or fall through to the literal-fallback (raw buffer).
    /// Either resolution clears the bug-class invariant; the
    /// `rank0Surface_hasNoIllegalAsatAfterDepVowel` case already
    /// asserts the predicate. This list documents the inputs in the
    /// reproduction table that lack a clean `<C><consonant><103A>`
    /// sibling.
    private static let bugInputsLiteralOnly: [String] = [
        "ki*", "ko*", "ku*",
        "ki.*", "ku.*",
        "ke:*",
        "i*", "u*", "o*",
    ]

    /// Regression-guard: legal asat-bearing surfaces that must continue
    /// to surface unchanged at rank 0. NOTE: TASK-049 removed `kya*`
    /// and `kw*` from this list — `<C><medial>103A` is malformed and
    /// is now asserted in `MedialPlusAsatRejectionSuite`.
    private static let regressionGuards: [(buffer: String, expectedTop: String)] = [
        ("k*",    "\u{1000}\u{103A}"),                                   // က်
        ("kaw*",  "\u{1000}\u{1031}\u{102C}\u{103A}"),                   // ကော် (aw cluster)
        ("kar:",  "\u{1000}\u{102C}\u{1038}"),                           // ကား (tone, no asat)
        ("kan*",  "\u{1000}\u{1014}\u{103A}"),                           // ကန်
        ("kin*",  "\u{1000}\u{1004}\u{103A}"),                           // ကင်
        ("khaung*", "\u{1001}\u{1031}\u{102B}\u{1004}\u{103A}"),         // ခေါင် (tall-aa, descender ခ)
    ]

    public static let suite = TestSuite(name: "AsatAfterDepVowel", cases: [

        // Rank-0 surface must NEVER carry the malformed
        // `<dep-vowel> 103A` adjacency (outside the legal aw-cluster).
        TestCase("rank0Surface_hasNoIllegalAsatAfterDepVowel") { ctx in
            let engine = emptyEngine()
            for buffer in bugInputs {
                let state = engine.update(buffer: buffer, context: [])
                let topSurface = state.candidates.first?.surface ?? ""
                ctx.assertFalse(
                    hasIllegalAsatAfterDepVowel(topSurface),
                    buffer,
                    detail: "rank-0 '\(topSurface)' [\(hex(topSurface))] contains <dep-vowel> 103A adjacency"
                )
            }
        },

        // Stronger guard: the malformed adjacency must not appear in
        // the top Myanmar (non-fallback) candidate.
        TestCase("topMyanmarCandidate_hasNoIllegalAsatAfterDepVowel") { ctx in
            let engine = emptyEngine()
            for buffer in bugInputs {
                let state = engine.update(buffer: buffer, context: [])
                // Find the first candidate whose surface differs from the
                // raw literal (i.e., a Myanmar candidate, not the
                // literal fallback).
                let firstMyanmar = state.candidates.first { $0.surface != buffer }
                guard let candidate = firstMyanmar else { continue }
                ctx.assertFalse(
                    hasIllegalAsatAfterDepVowel(candidate.surface),
                    buffer,
                    detail: "first non-literal '\(candidate.surface)' [\(hex(candidate.surface))] contains <dep-vowel> 103A"
                )
            }
        },

        // Legitimate sibling promotion. Inputs that have a legal Myanmar
        // form (`kar*` has `ကရ်` at rank 1 pre-fix) must ranks the
        // legitimate sibling at rank 0 once the malformed surface is
        // filtered.
        TestCase("legitimateSibling_promotedToRank0") { ctx in
            let engine = emptyEngine()
            for entry in bugInputsWithLegitimateSibling {
                let top = engine.update(buffer: entry.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top,
                    entry.legitimateSurface,
                    "\(entry.buffer)_topHex=\(hex(top))_expectedHex=\(hex(entry.legitimateSurface))"
                )
            }
        },

        // No-legitimate-sibling inputs: the rank-0 surface must clear
        // the bug-class invariant. Either the trailing asat is dropped
        // entirely (`ki*` → `ကီ`) or the literal-fallback wins
        // (`ki*` → `ki*`). This case is a redundant guard alongside
        // `rank0Surface_hasNoIllegalAsatAfterDepVowel`, but it
        // documents the inputs that have no clean
        // `<C><consonant><103A>` sibling.
        TestCase("noLegitimateSibling_rank0_clearsBugInvariant") { ctx in
            let engine = emptyEngine()
            for buffer in bugInputsLiteralOnly {
                let top = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    hasIllegalAsatAfterDepVowel(top),
                    buffer,
                    detail: "rank-0 '\(top)' [\(hex(top))] still contains <dep-vowel> 103A"
                )
            }
        },

        // Direct legality-scan predicate: scalar sequences with
        // `<dep-vowel> 103A` (outside the aw-cluster) must be rejected.
        TestCase("scanOutputLegality_rejectsAsatAfterDepVowel") { ctx in
            let cases: [(label: String, scalars: [UInt32])] = [
                ("ki*",   [0x1000, 0x102E, 0x103A]),                      // ကီ်
                ("ko*",   [0x1000, 0x102D, 0x102F, 0x103A]),              // ကို်
                ("ku*",   [0x1000, 0x1030, 0x103A]),                      // ကူ်
                ("ki.*",  [0x1000, 0x102D, 0x103A]),                      // ကိ်
                ("ku.*",  [0x1000, 0x102F, 0x103A]),                      // ကု်
                ("kar*",  [0x1000, 0x102C, 0x103A]),                      // ကာ်
                ("kar2*", [0x1000, 0x102B, 0x103A]),                      // ကါ်
                ("ke:*",  [0x1000, 0x1032, 0x103A]),                      // ကဲ်
                ("kywar*", [0x1000, 0x103B, 0x103D, 0x102C, 0x103A]),     // ကျွာ်
                ("kywi*",  [0x1000, 0x103B, 0x103D, 0x102E, 0x103A]),     // ကျွီ်
                ("kywu*",  [0x1000, 0x103B, 0x103D, 0x1030, 0x103A]),     // ကျွူ်
                ("kywo*",  [0x1000, 0x103B, 0x103D, 0x102D, 0x102F, 0x103A]), // ကျွို်
                ("i*",    [0x1021, 0x102E, 0x103A]),                      // အီ်
                ("u*",    [0x1021, 0x1030, 0x103A]),                      // အူ်
                ("o*",    [0x1021, 0x102D, 0x102F, 0x103A]),              // အို်
                ("k+kar*", [0x1000, 0x1039, 0x1000, 0x102C, 0x103A]),     // က္ကာ်
            ]
            for c in cases {
                let s = String(c.scalars.compactMap { Unicode.Scalar($0) }
                    .map(Character.init))
                let legal = SyllableParser.scanOutputLegality(s)
                ctx.assertFalse(
                    legal,
                    c.label,
                    detail: "scanOutputLegality returned true for malformed scalars '\(hex(s))'"
                )
            }
        },

        // Counter-examples — legal asat-bearing shapes must REMAIN legal.
        //
        // NOTE: TASK-049 reclassified `<C><medial>103A` (`kya*` →
        // `1000 103B 103A`, `kw*` → `1000 103D 103A`) from "legal"
        // to "malformed". A medial belongs to the onset cluster;
        // closing it with asat produces a syllable with no inherent
        // vowel and no coda consonant. The legitimate medial-bearing
        // closure adds a coda consonant before the asat (`kyan*` →
        // `1000 103B 1014 103A`). The medial-only cases were removed
        // from this list and are now asserted as REJECTED in
        // `MedialPlusAsatRejectionSuite`.
        TestCase("scanOutputLegality_acceptsLegalAsatShapes") { ctx in
            let cases: [(label: String, scalars: [UInt32])] = [
                // <C> 103A — pure stop coda
                ("k*",   [0x1000, 0x103A]),
                // <C> <medial> <coda-C> 103A — medial + coda + asat
                ("kyan*", [0x1000, 0x103B, 0x1014, 0x103A]),
                ("kwan*", [0x1000, 0x103D, 0x1014, 0x103A]),
                // <C> 1031 102C 103A — aw cluster
                ("kaw*", [0x1000, 0x1031, 0x102C, 0x103A]),
                // <C> 1037 103A — TASK-048 creaky carve-out
                ("kit.", [0x1000, 0x1005, 0x1037, 0x103A]),
                // <C> 1014 103A — kan*-style
                ("kan*", [0x1000, 0x1014, 0x103A]),
                // Internal rule emissions: aing/aung/ein clusters
                ("khaung*", [0x1001, 0x1031, 0x102C, 0x1004, 0x103A]),
            ]
            for c in cases {
                let s = String(c.scalars.compactMap { Unicode.Scalar($0) }
                    .map(Character.init))
                let legal = SyllableParser.scanOutputLegality(s)
                ctx.assertTrue(
                    legal,
                    c.label,
                    detail: "scanOutputLegality wrongly rejected legal scalars '\(hex(s))'"
                )
            }
        },

        // Engine-end regression: existing legal asat-bearing rank-0
        // surfaces must continue to surface unchanged.
        TestCase("legalAsatSurfaces_remainAtRank0") { ctx in
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
    ])
}
