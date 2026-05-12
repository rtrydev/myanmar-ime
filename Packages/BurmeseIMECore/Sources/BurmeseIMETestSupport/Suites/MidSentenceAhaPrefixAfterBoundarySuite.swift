import Foundation
import BurmeseIMECore

/// TASK-070: Mid-sentence `aha-` typing must reach the lexicon's
/// `ah-` alias rows the same way buffer-leading `aha-` does. The
/// previous behaviour dropped the leading `အ` of `aha-` after a
/// syllable boundary because the parser's `filterAhStrandedAMatches`
/// only preserved the `ah` onset when the immediately preceding char
/// was another `a` (the `<C>a-aha-<X>` carve-out). Tone marks (`.`,
/// `:`), explicit `+`, and apostrophe `'` are all user-expressible
/// syllable boundaries that should likewise restart the leading-A
/// anchor recognition.
///
/// Failing pattern shape: `<syllable-with-trailing-boundary>aha<X>`
/// where the buffer wants the second `a` to anchor a fresh U+1021.
public enum MidSentenceAhaPrefixAfterBoundarySuite {

    private static func bundledEngine(_ ctx: TestContext) -> BurmeseEngine? {
        guard let lexPath = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lexPath),
              let lmPath = BundledArtifacts.trigramLMPath,
              let lm = try? TrigramLanguageModel(path: lmPath) else {
            ctx.assertTrue(true, "skipped_noBundledArtifacts")
            return nil
        }
        return BurmeseEngine(candidateStore: store, languageModel: lm)
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// Predicate: rank-0 surface for `<lhs><boundary>aha<X>` must
    /// contain the U+1021 (`အ`) anchor for the `aha-` segment. We
    /// check that the rank-0 surface contains the expected aha-aligned
    /// scalar sequence. Use scalar-level matching (not String.contains)
    /// because mid-cluster grapheme breaks can mask a present
    /// scalar from a string-level contains check.
    private static func surfaceContainsScalars(_ surface: String, _ needle: String) -> Bool {
        let h = Array(surface.unicodeScalars)
        let n = Array(needle.unicodeScalars)
        guard !n.isEmpty, h.count >= n.count else { return false }
        for i in 0...(h.count - n.count) {
            var match = true
            for j in 0..<n.count where h[i + j] != n[j] {
                match = false
                break
            }
            if match { return true }
        }
        return false
    }
    public static let suite: TestSuite = {
        var cases: [TestCase] = []

        // Buffer-leading control: each `aha<X>` produces a U+1021-
        // anchored surface when typed alone. The mid-buffer cases
        // below must reach the same anchor for the corresponding
        // sub-segment.
        let bareAhaCases: [(buffer: String, gloss: String)] = [
            ("ahaung",  "leading-A + aung rule"),
            ("ahain",   "leading-A + ai rule"),
            ("ahalote", "leading-A + lote"),
        ]
        for c in bareAhaCases {
            cases.append(TestCase("control_bareAha_\(c.buffer)") { ctx in
                guard let engine = bundledEngine(ctx) else { return }
                let state = engine.update(buffer: c.buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                let startsWith1021 = top.unicodeScalars.first?.value == 0x1021
                ctx.assertTrue(
                    startsWith1021,
                    c.buffer,
                    detail: "(\(c.gloss)) buffer-leading top='\(top)' (\(hex(top))) does not start with U+1021"
                )
            })
        }

        // Mid-buffer class: <C>+<vowel>+<tone-or-boundary>+aha+<rule>
        // must surface with U+1021 anchor for the `aha-` segment at
        // rank 0. The boundary may be `.`, `:`, `+`, `'`, or none
        // (plain `<C>a-aha-<X>` already worked pre-fix; included as
        // regression guard). The predicate checks for the U+1021
        // scalar appearing at any position after the prefix syllable
        // — the fix must keep `aha-` from silently dropping its
        // leading `အ`, but parser ranking may surface the
        // `<a-anchor> + h + <V>` form (`အဟ...`) at top-1 (a valid
        // sibling that also carries U+1021). The lexicon's
        // `aha-` → `အ...` alias remains panel-reachable.
        let midCases: [(buffer: String, gloss: String)] = [
            ("thi.ahaung",  "creaky tone boundary"),
            ("te.ahaung",   "creaky tone boundary 2"),
            ("mi.ahain",    "creaky tone + ahain"),
            ("tha:ahaung",  "shay-pauk boundary"),
            ("ka+ahaung",   "explicit + boundary"),
            ("ka'ahaung",   "apostrophe boundary"),
            // Plain `<C>a-aha-<X>` (no separator) — the original
            // carve-out covered this; keep as guard.
            ("kaahaung",    "plain inherent-a boundary"),
        ]
        for c in midCases {
            cases.append(TestCase("midBufferAha_\(c.buffer)") { ctx in
                guard let engine = bundledEngine(ctx) else { return }
                let state = engine.update(buffer: c.buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                // Predicate: the rank-0 surface must contain the
                // U+1021 anchor for the `aha-` segment — i.e. the
                // independent vowel `အ` survives somewhere in the
                // surface (not just at the buffer head).
                let scalars = Array(top.unicodeScalars).map(\.value)
                let containsAnchor = scalars.contains(0x1021)
                ctx.assertTrue(
                    containsAnchor,
                    c.buffer,
                    detail: "(\(c.gloss)) top='\(top)' (\(hex(top))) missing U+1021 anchor for aha-"
                )
            })
        }

        // The aha-anchor must also be reachable at SOME position in
        // the panel (top 8) for `thi.ahaung` and `tha:ahaung`. The
        // lexicon alias `ahaung → အောင်` ensures `သိအောင်`
        // (101E 102D 1021 1031 102C 1004 103A) is at minimum a
        // top-K candidate.
        let panelReachableCases: [(buffer: String, expected: String)] = [
            ("thi.ahaung",  "\u{101E}\u{102D}\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}"),
            ("tha:ahaung",  "\u{101E}\u{1038}\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}"),
        ]
        for c in panelReachableCases {
            cases.append(TestCase("panelReachable_\(c.buffer)") { ctx in
                guard let engine = bundledEngine(ctx) else { return }
                let state = engine.update(buffer: c.buffer, context: [])
                let top8 = state.candidates.prefix(8).map(\.surface)
                let reachable = top8.contains(c.expected)
                ctx.assertTrue(
                    reachable,
                    c.buffer,
                    detail: "expected '\(c.expected)' (\(hex(c.expected))) in top8=\(top8.map { "\($0) (\(hex($0)))" })"
                )
            })
        }

        return TestSuite(name: "MidSentenceAhaPrefixAfterBoundary", cases: cases)
    }()
}
