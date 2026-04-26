import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-002: when the cleaned full-buffer parse merges the
/// prefix's tail letter with the suffix's head letter (re-segmenting the
/// prefix), the mid-buffer digit splice computed from a separate
/// prefix-only parse lands inside the wrong syllable. The fix routes the
/// splice through the cleaned-buffer parse's per-arc char-to-scalar
/// provenance so the digit always sits at the user's intended boundary,
/// and promotes the structurally clean candidate (one whose char
/// segmentation has a boundary at the digit position) to rank 0.
///
/// Examples: `tar1ar` should produce `တာ၁အာ` (rank 1 today, rank 0 after
/// the fix) instead of `တရ၁ာ` (rank 0 today; the prefix's `တာ` becomes
/// stranded `တ` + `ရ` and the suffix's `အာ` becomes a base-less `ာ`).
public enum MidBufferDigitVowelSplitSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func scalars(_ surface: String) -> [UInt32] {
        surface.unicodeScalars.map(\.value)
    }

    /// Returns true if the surface contains a `<digit><dep-vowel>`
    /// adjacency where the dep-vowel scalar is in U+102B–U+1032 — the
    /// signature of a splice that landed mid-cluster, detaching the
    /// dep-vowel from its consonant base.
    private static func hasDigitBeforeDepVowel(_ surface: String) -> Bool {
        let s = scalars(surface)
        for i in 1..<s.count {
            let prev = s[i - 1]
            let isAsciiDigit = prev >= 0x30 && prev <= 0x39
            let isMyanmarDigit = prev >= 0x1040 && prev <= 0x1049
            guard isAsciiDigit || isMyanmarDigit else { continue }
            let cur = s[i]
            if cur >= 0x102B && cur <= 0x1032 { return true }
        }
        return false
    }

    public static let suite = TestSuite(name: "MidBufferDigitVowelSplit", cases: [

        // Top-1 must place the digit at the user-intended syllable
        // boundary. For `tar1ar`-style inputs, the prefix syllable
        // `<C>+<dep-vowel>` must remain intact, the digit sits after
        // it, and the suffix's bare-vowel rule re-anchors with an
        // implicit `အ`.
        TestCase("rePrefixSegmentation_topPlacesDigitAtIntendedBoundary") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expectedHex: [UInt32])] = [
                // tar + 1 + ar → တာ၁အာ
                ("tar1ar",   [0x1010, 0x102C, 0x1041, 0x1021, 0x102C]),
                // kar + 1 + ar → ကာ၁အာ
                ("kar1ar",   [0x1000, 0x102C, 0x1041, 0x1021, 0x102C]),
                // thar + 1 + ar → သာ၁အာ
                ("thar1ar",  [0x101E, 0x102C, 0x1041, 0x1021, 0x102C]),
                // lar + 1 + ar → လာ၁အာ
                ("lar1ar",   [0x101C, 0x102C, 0x1041, 0x1021, 0x102C]),
                // mar + 1 + ar → မာ၁အာ
                ("mar1ar",   [0x1019, 0x102C, 0x1041, 0x1021, 0x102C]),
            ]
            for entry in cases {
                let top = engine.update(buffer: entry.buffer, context: []).candidates.first?.surface ?? ""
                let topHex = scalars(top)
                ctx.assertTrue(
                    topHex == entry.expectedHex,
                    entry.buffer,
                    detail: "top '\(top)' hex=\(topHex.map { String(format: "%04X", $0) }) expected=\(entry.expectedHex.map { String(format: "%04X", $0) })"
                )
            }
        },

        // Stronger: no candidate at any rank may carry a
        // `<digit><dep-vowel>` adjacency for the bug-class inputs. The
        // structurally clean sibling exists at rank 1 today — keep the
        // panel free of broken alternatives.
        TestCase("rePrefixSegmentation_noCandidateHasDigitBeforeDepVowel") { ctx in
            let engine = emptyEngine()
            let inputs = [
                "tar1ar", "kar1ar", "thar1ar", "lar1ar", "mar1ar",
                "kyar1ar", "phyar1ar",
            ]
            for input in inputs {
                let cands = engine.update(buffer: input, context: []).candidates
                for (rank, cand) in cands.enumerated() {
                    ctx.assertFalse(
                        hasDigitBeforeDepVowel(cand.surface),
                        input,
                        detail: "candidate #\(rank) '\(cand.surface)' has digit-before-depVowel adjacency"
                    )
                }
            }
        },

        // Regression guard: counter-examples that already work today
        // must continue to render as `<C+aa>+digit+<C+aa>`, with the
        // digit at the same boundary the user typed.
        TestCase("nonRePrefixSegmentation_remainsClean") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expectedHex: [UInt32])] = [
                // kar + 1 + kar → ကာ၁ကာ
                ("kar1kar", [0x1000, 0x102C, 0x1041, 0x1000, 0x102C]),
                // tar + 1 + tar → တာ၁တာ
                ("tar1tar", [0x1010, 0x102C, 0x1041, 0x1010, 0x102C]),
            ]
            for entry in cases {
                let top = engine.update(buffer: entry.buffer, context: []).candidates.first?.surface ?? ""
                let topHex = scalars(top)
                ctx.assertTrue(
                    topHex == entry.expectedHex,
                    entry.buffer,
                    detail: "top '\(top)' hex=\(topHex.map { String(format: "%04X", $0) }) expected=\(entry.expectedHex.map { String(format: "%04X", $0) })"
                )
            }
        },
    ])
}
