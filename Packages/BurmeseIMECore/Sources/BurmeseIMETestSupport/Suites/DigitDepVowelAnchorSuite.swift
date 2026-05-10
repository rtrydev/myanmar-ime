import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-051: a mid-buffer digit immediately followed by a dep-vowel,
/// medial, anusvara, or e-kar scalar must NEVER appear in any panel
/// candidate. The class is `<C>(<medial>?)<digit><U+102B..U+1032 |
/// U+1036 | U+103B..U+103E>` where the dep-vowel / medial / anusvara
/// is left dangling on a digit (which never anchors marks per
/// CLAUDE.md §3 and Unicode TUS storage order). The expected
/// rank-0 surface carries an injected `U+1021` independent-vowel
/// anchor between the digit and the orphan'd cluster, mirroring the
/// already-working `kar2aung` / `tar2aing` shapes.
///
/// The bare engine reproduces the bug — it does not depend on the
/// LM/lexicon — so this suite uses an empty-store engine for
/// determinism (matching `MidBufferDigitVowelSplitSuite`).
public enum DigitDepVowelAnchorSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func scalars(_ surface: String) -> [UInt32] {
        surface.unicodeScalars.map(\.value)
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
    }

    /// True when the surface contains a `<digit><dep-vowel | medial |
    /// anusvara | e-kar>` adjacency. The dep-vowel range is
    /// U+102B..U+1032; medials are U+103B..U+103E; anusvara is
    /// U+1036. e-kar U+1031 is included in the dep-vowel range.
    /// Asat U+103A is intentionally excluded — it is covered by the
    /// pre-existing `surfaceContainsDigitOrphanAsat` predicate
    /// (TASK-052 sanitiser) and folded into the broader check
    /// below.
    private static func hasDigitOrphanAttachableMark(_ surface: String) -> Bool {
        let s = scalars(surface)
        guard s.count >= 2 else { return false }
        for i in 1..<s.count {
            let prev = s[i - 1]
            let isAsciiDigit = prev >= 0x30 && prev <= 0x39
            let isMyanmarDigit = prev >= 0x1040 && prev <= 0x1049
            guard isAsciiDigit || isMyanmarDigit else { continue }
            let cur = s[i]
            // dep-vowels (incl. e-kar)
            if cur >= 0x102B && cur <= 0x1032 { return true }
            // anusvara
            if cur == 0x1036 { return true }
            // medials
            if cur >= 0x103B && cur <= 0x103E { return true }
            // asat — TASK-052 also forbids this adjacency. A pre-existing
            // sanitiser exists for `<digit>103A` and `<digit>1021 103A`.
            if cur == 0x103A { return true }
        }
        return false
    }

    public static let suite = TestSuite(name: "DigitDepVowelAnchor", cases: [

        // The headline bug-class buffers from TASK-051. None of these
        // candidates may carry a `<digit><dep-vowel/medial/anusvara/
        // e-kar>` adjacency at any rank.
        TestCase("noCandidateCarriesDigitOrphanMarkAdjacency") { ctx in
            let engine = emptyEngine()
            let buffers: [String] = [
                "ka2aung", "ka2ar", "ka2i", "ka2u", "ka2y", "ka2aing", "ka2o",
                "kya2aung", "kya2y", "kya2ar",
                "ky2aung", "khy2et",
                "ka2yar",
                "t2ote",
                // Digit before medial (medial-after-digit is also
                // illegal; see TASK-051 example `khy2et` table row).
                "ka2yar", "ka2war",
            ]
            for buffer in buffers {
                let cands = engine.update(buffer: buffer, context: []).candidates
                ctx.assertFalse(cands.isEmpty, "\(buffer)_panelNonEmpty")
                for (rank, cand) in cands.enumerated() {
                    ctx.assertFalse(
                        hasDigitOrphanAttachableMark(cand.surface),
                        "\(buffer)_rank\(rank)",
                        detail: "candidate '\(cand.surface)' (\(hex(cand.surface))) carries <digit><orphan-mark>"
                    )
                }
            }
        },

        // Concrete rank-0 expectations for the headline cases. The
        // `1021` anchor must be injected between the digit and the
        // orphan'd cluster, producing the same shape as `kar2aung`
        // / `tar2aing`.
        TestCase("rank0InjectsAnchorBetweenDigitAndOrphanCluster") { ctx in
            let engine = emptyEngine()
            // The Myanmar-digit primary uses U+1042 for `2`. Each
            // cluster gets its own U+1021 anchor injected.
            let cases: [(buffer: String, expectedHex: [UInt32])] = [
                // ka + 2 + aung → က၂အောင်
                ("ka2aung", [0x1000, 0x1042, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
                // ka + 2 + ar → က၂အာ
                ("ka2ar",   [0x1000, 0x1042, 0x1021, 0x102C]),
                // ka + 2 + i → က၂အီ
                ("ka2i",    [0x1000, 0x1042, 0x1021, 0x102E]),
                // ka + 2 + u → က၂အူ
                ("ka2u",    [0x1000, 0x1042, 0x1021, 0x1030]),
                // ka + 2 + y (e-kar)  → က၂အေ
                ("ka2y",    [0x1000, 0x1042, 0x1021, 0x1031]),
                // ka + 2 + aing → က၂အိုင်
                ("ka2aing", [0x1000, 0x1042, 0x1021, 0x102D, 0x102F, 0x1004, 0x103A]),
                // kya + 2 + aung → ကျ၂အောင်
                ("kya2aung",
                    [0x1000, 0x103B, 0x1042, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
            ]
            for entry in cases {
                let cands = engine.update(buffer: entry.buffer, context: []).candidates
                guard let top = cands.first else {
                    ctx.assertTrue(false, entry.buffer, detail: "panel empty")
                    continue
                }
                let topHex = scalars(top.surface)
                ctx.assertTrue(
                    topHex == entry.expectedHex,
                    entry.buffer,
                    detail: "rank-0 '\(top.surface)' hex=\(topHex.map { String(format: "%04X", $0) }) expected=\(entry.expectedHex.map { String(format: "%04X", $0) })"
                )
            }
        },

        // Counter-example regression guard: buffers where the digit
        // does NOT precede a dep-vowel / medial / anusvara must keep
        // their existing rank-0 surface. These already work today
        // and must not regress.
        TestCase("counterExamplesUnchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expectedHex: [UInt32])] = [
                // kar + 2 + aung → ကာ၂အောင် (digit follows full
                // dep-vowel cluster; existing `1021` injection works).
                ("kar2aung",
                    [0x1000, 0x102C, 0x1042, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
                // tar + 2 + aing → တာ၂အိုင်
                ("tar2aing",
                    [0x1010, 0x102C, 0x1042, 0x1021, 0x102D, 0x102F, 0x1004, 0x103A]),
                // kar + 2 + na → ကာ၂န (digit followed by consonant
                // base — no orphan-mark adjacency possible).
                ("kar2na",
                    [0x1000, 0x102C, 0x1042, 0x1014]),
            ]
            for entry in cases {
                let cands = engine.update(buffer: entry.buffer, context: []).candidates
                guard let top = cands.first else {
                    ctx.assertTrue(false, entry.buffer, detail: "panel empty")
                    continue
                }
                let topHex = scalars(top.surface)
                ctx.assertTrue(
                    topHex == entry.expectedHex,
                    entry.buffer,
                    detail: "rank-0 '\(top.surface)' hex=\(topHex.map { String(format: "%04X", $0) }) expected=\(entry.expectedHex.map { String(format: "%04X", $0) })"
                )
            }
        },

        // Sanitiser predicate sanity. The
        // `surfaceContainsDigitOrphanAsat` predicate already covers
        // `<digit>103A` and `<digit>1021 103A`. The TASK-051 fix
        // widens the orphan-cluster repair / sanitiser surface to
        // also cover `<digit><dep-vowel/medial/anusvara/e-kar>`.
        // This case asserts the underlying predicate fires for the
        // wider class.
        TestCase("surfaceContainsDigitOrphanAttachableMark_predicate") { ctx in
            // dep-vowel
            ctx.assertTrue(BurmeseEngine.surfaceContainsDigitOrphanAttachableMark(
                "\u{1000}\u{1042}\u{102C}"), "digit_aa")
            ctx.assertTrue(BurmeseEngine.surfaceContainsDigitOrphanAttachableMark(
                "\u{1000}\u{1042}\u{1031}"), "digit_eKar")
            ctx.assertTrue(BurmeseEngine.surfaceContainsDigitOrphanAttachableMark(
                "\u{1000}\u{1042}\u{102E}"), "digit_longI")
            ctx.assertTrue(BurmeseEngine.surfaceContainsDigitOrphanAttachableMark(
                "\u{1000}\u{1042}\u{1030}"), "digit_longU")
            // anusvara
            ctx.assertTrue(BurmeseEngine.surfaceContainsDigitOrphanAttachableMark(
                "\u{1000}\u{1042}\u{1036}"), "digit_anusvara")
            // medial
            ctx.assertTrue(BurmeseEngine.surfaceContainsDigitOrphanAttachableMark(
                "\u{1000}\u{1042}\u{103B}"), "digit_yaPin")
            // ASCII digit
            ctx.assertTrue(BurmeseEngine.surfaceContainsDigitOrphanAttachableMark(
                "\u{1000}\u{0032}\u{102C}"), "asciiDigit_aa")
            // Counter-examples: no adjacency
            ctx.assertFalse(BurmeseEngine.surfaceContainsDigitOrphanAttachableMark(
                "\u{1000}\u{102C}\u{1042}"), "digit_trailing_isFine")
            ctx.assertFalse(BurmeseEngine.surfaceContainsDigitOrphanAttachableMark(
                "\u{1000}\u{102C}\u{1042}\u{1014}"), "digit_followedByConsonant")
            ctx.assertFalse(BurmeseEngine.surfaceContainsDigitOrphanAttachableMark(
                "\u{1000}\u{102C}\u{1042}\u{1021}\u{1031}\u{102C}"),
                "digit_followedByAnchorThenCluster")
        },
    ])
}
