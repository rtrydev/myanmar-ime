import Foundation
import BurmeseIMECore

/// Step 4 / Tier 2 — C29 (literal pass-through).
///
/// Real Burmese text mixes scripts — Latin brand names, English
/// words, technical terms appear inline. The engine must not
/// force-convert ASCII letter runs that have no legal Burmese
/// parse: those runs commit verbatim. The literal-fallback policy
/// (CLAUDE.md) gates this:
/// - empty Myanmar panel → literal is the only candidate.
/// - ratio ≥ 0.5 unconvertible → literal at rank 0.
/// - ratio < 0.5 → literal appended at the bottom.
public enum LangLiteralPassthroughSuite {

    private static func bareEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func surfaces(_ buffer: String) -> [String] {
        bareEngine().update(buffer: buffer, context: []).candidates.map(\.surface)
    }

    public static let suite = TestSuite(name: "LangLiteralPassthrough", cases: [

        // Fully unconvertible ASCII → literal is rank-0.
        TestCase("c_literal_only") { ctx in
            let s = surfaces("c")
            ctx.assertTrue(s.first == "c", "c_top",
                           detail: "expected rank-0 == 'c'; got \(s)")
        },
        TestCase("comp_literal_only") { ctx in
            let s = surfaces("comp")
            ctx.assertTrue(s.first == "comp", "comp_top",
                           detail: "got \(s)")
        },
        TestCase("iphone_panel_includesLiteral") { ctx in
            // `iphone` is partially parseable (`i` + `ph` + `o` + `ne`),
            // so the literal goes to the bottom of the panel rather
            // than rank 0. Test panel-inclusion, not rank-0.
            let s = surfaces("iphone")
            ctx.assertTrue(s.contains("iphone"), "iphone_in_panel",
                           detail: "got \(s)")
        },
        TestCase("facebook_literal_only") { ctx in
            let s = surfaces("facebook")
            ctx.assertTrue(s.first == "facebook", "facebook_top",
                           detail: "got \(s)")
        },

        // Fully parseable input → literal appended at the bottom of
        // the panel (since rank-0 is Myanmar, not lexicon).
        TestCase("tablet_literalAppended") { ctx in
            let s = surfaces("tablet")
            ctx.assertTrue(s.contains("tablet"), "tablet_in_panel",
                           detail: "expected 'tablet' candidate in panel; got \(s)")
            // Top should be Myanmar (or at least not the literal).
            let topIsMyanmar = s.first?.unicodeScalars.contains { $0.value >= 0x1000 && $0.value <= 0x109F } ?? false
            ctx.assertTrue(topIsMyanmar, "tablet_topMyanmar",
                           detail: "expected Myanmar at rank-0; got \(s)")
        },

        // Non-empty buffer must always have a candidate panel
        // (literal-fallback guarantees this).
        TestCase("nonEmptyBuffer_alwaysHasCandidates") { ctx in
            for input in ["c", "co", "tablet", "kar", "u", "min+"] {
                let candidates = bareEngine().update(buffer: input, context: []).candidates
                ctx.assertTrue(!candidates.isEmpty, input,
                               detail: "empty panel for non-empty input '\(input)'")
            }
        },
    ])
}
