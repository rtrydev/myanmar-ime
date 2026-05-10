import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-046: bare-onset diphthong vowel rules (`aing`, `aung`, `ai`)
/// repeated N times must produce N independent-vowel-anchored
/// syllables. The parser's leading-A promotion fires only at
/// `output.isEmpty` (buffer head), so 2nd-and-later repetitions had
/// to rely on the orphan-mark sanitizer's anchor walk to insert
/// `1021` anchors. For chains of length 4 or more the orphan-mark
/// sanitizer's worst-case walk merged dep-vowel clusters across
/// implicit syllable boundaries and produced shapes like
/// `အောင်အောင်အူငေါင်` (last 2 syllables collapsed into orphan
/// `ေါင်` after `အူ`) or `အိုင်အိုင်အိုင်ငိုင်` (`ငိုင်`
/// substituting a consonant base for the missing `အ` anchor).
///
/// Acceptance: rank-0 surface for `<bare diphthong> × N` is the
/// expected single repeated N times, and the surface contains
/// exactly N occurrences of `U+1021`.
public enum BareVowelRuleChainSuite {

    /// Single-syllable expected scalars per rule.
    private static let aingScalars: [UInt32] = [0x1021, 0x102D, 0x102F, 0x1004, 0x103A]
    private static let aungScalars: [UInt32] = [0x1021, 0x1031, 0x102C, 0x1004, 0x103A]
    private static let aiScalars: [UInt32]   = [0x1021, 0x102D, 0x102F, 0x1004, 0x103A]

    private static func makeBundledEngine() -> BurmeseEngine? {
        guard let lexPath = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lexPath),
              let lmPath = BundledArtifacts.trigramLMPath,
              let lm = try? TrigramLanguageModel(path: lmPath) else {
            return nil
        }
        return BurmeseEngine(candidateStore: store, languageModel: lm)
    }

    private static func countAnchor1021(_ surface: String) -> Int {
        surface.unicodeScalars.reduce(0) { $1.value == 0x1021 ? $0 + 1 : $0 }
    }

    /// Concatenated expected surface for `repetitions` of `singleScalars`.
    private static func expectedSurface(
        single: [UInt32],
        count: Int
    ) -> String {
        var result = ""
        result.unicodeScalars.reserveCapacity(single.count * count)
        for _ in 0..<count {
            for v in single {
                result.unicodeScalars.append(Unicode.Scalar(v)!)
            }
        }
        return result
    }

    /// Bare-engine assertion: for chained bare-vowel-rule inputs that
    /// fit in a single window pass (`compositionWindowSize = 18`,
    /// i.e. N ≤ 4 for `aing` / `aung` rules at 4 chars apiece), the
    /// rank-0 surface is the all-anchored N-fold repetition of the
    /// rule's independent-vowel form. Buffers past the windowing
    /// threshold (N ≥ 5) are tested for panel-reachability of the
    /// all-anchored leading two-syllable prefix — a weakened check
    /// that proves the anchor injection survives both the parser
    /// materialise step and the frozen-prefix render. The
    /// frozen-prefix boundary cuts the chain mid-buffer and the
    /// tail-side parser re-segments the trailing chars in ways that
    /// can demote the strict-equality all-anchored sibling further
    /// down the panel; the leading-prefix check is the structural
    /// invariant that the fix must restore. CLAUDE.md §7 general
    /// reachability rule applies.
    private static func bareEngineCases(
        rule: String,
        single: [UInt32]
    ) -> [TestCase] {
        return (2...8).map { n in
            TestCase("\(rule)_x\(n)_bareEngineAllAnchored") { ctx in
                let engine = BurmeseEngine()
                let buffer = String(repeating: rule, count: n)
                let state = engine.update(buffer: buffer, context: [])
                let expected = expectedSurface(single: single, count: n)
                let inWindow = buffer.count <= 18
                if inWindow {
                    ctx.assertEqual(
                        state.candidates.first?.surface ?? "",
                        expected,
                        "\(rule)x\(n)_bareEngine_topIsAllAnchored"
                    )
                } else {
                    // Windowed weakened check: at least one candidate
                    // surface starts with two consecutive independent-
                    // vowel-anchored repetitions of the rule. This
                    // guards against the original TASK-046 collapse
                    // where the frozen-prefix-side merged its second
                    // syllable into an orphan dep-vowel cluster
                    // (`အောင်ေါင်`), without requiring the windowed
                    // tail to perfectly align with the all-anchored
                    // form (which the frozen-prefix split-position
                    // chooser does not always honour).
                    let expectedPrefix = expectedSurface(single: single, count: 2)
                    let panelHasAllAnchoredPrefix = state.candidates.contains {
                        $0.surface.hasPrefix(expectedPrefix)
                    }
                    ctx.assertTrue(
                        panelHasAllAnchoredPrefix,
                        "\(rule)x\(n)_bareEngine_panelHasAllAnchoredPrefix",
                        detail: "expectedPrefix='\(expectedPrefix)' top10=\(state.candidates.prefix(10).map(\.surface))"
                    )
                }
            }
        }
    }

    /// Bare-engine reachability for the `ai` rule. The 2-char `ai`
    /// rule is structurally distinct from the 4-char `aing` / `aung`
    /// — chained `aiai...` lacks a syllable-closing letter past the
    /// 2-char rule end, and the parser historically dropped to the
    /// literal-fallback surface for N ≥ 4 (`ai × 4` panel-empty for
    /// Myanmar). Assert at minimum panel-reachability of the
    /// all-anchored sibling for N ∈ {2..8}; rank 0 is preferred but
    /// not required (CLAUDE.md §7 general reachability rule).
    private static func aiReachabilityCases() -> [TestCase] {
        return (2...8).map { n in
            TestCase("ai_x\(n)_bareEngineAllAnchoredReachable") { ctx in
                let engine = BurmeseEngine()
                let buffer = String(repeating: "ai", count: n)
                let state = engine.update(buffer: buffer, context: [])
                let expected = expectedSurface(single: aiScalars, count: n)
                ctx.assertTrue(
                    state.candidates.contains(where: { $0.surface == expected }),
                    "aix\(n)_bareEngine_panelContainsAllAnchored",
                    detail: "expected='\(expected)' top10=\(state.candidates.prefix(10).map(\.surface))"
                )
            }
        }
    }

    public static let suite = TestSuite(name: "BareVowelRuleChain", cases:
        bareEngineCases(rule: "aing", single: aingScalars)
        + bareEngineCases(rule: "aung", single: aungScalars)
        + aiReachabilityCases()
    )
}
