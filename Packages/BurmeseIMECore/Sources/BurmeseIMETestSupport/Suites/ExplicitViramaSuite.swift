import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for task 01: a user-typed `+` between two consonants must
/// surface a virama-stacked candidate, even when the two consonants are
/// in different orthographic classes (the strict-stack rule rejects
/// them on principle). The explicit `+` is the user's signal that they
/// want a stack, so the result of typing `pad+ma` must never be
/// strictly worse than typing `padma`.
public enum ExplicitViramaSuite {

    private static func defaultEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func surfaceContainsVirama(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value == 0x1039 }
    }

    public static let suite = TestSuite(name: "ExplicitVirama", cases: [

        // The same buffer with and without `+` must yield top-level
        // candidates of comparable strength. Specifically: when the
        // no-`+` form surfaces a virama-stacked candidate at top (via
        // override or implicit inference), the explicit-`+` form must
        // also surface a virama-stacked candidate at top — the user
        // explicitly asked for it.
        TestCase("explicitPlus_topMatchesNoPlusTop") { ctx in
            let engine = defaultEngine()
            // Pairs of (with-plus, without-plus) buffers. Each has
            // cross-class consonants around the `+`.
            let pairs: [(plus: String, plain: String)] = [
                ("pad+ma", "padma"),
                ("brah+ma", "brahma"),
            ]
            for (plus, plain) in pairs {
                let plusTop = engine.update(buffer: plus, context: []).candidates.first?.surface ?? ""
                let plainTop = engine.update(buffer: plain, context: []).candidates.first?.surface ?? ""
                ctx.assertTrue(
                    plusTop == plainTop,
                    plus,
                    detail: "explicit-`+` top='\(plusTop)' does not match no-`+` top='\(plainTop)'"
                )
            }
        },

        // Cross-class explicit `+` must surface a virama-stacked
        // candidate at top. The strict same-class predicate currently
        // gates the only path that can produce this stack — the fix
        // routes the buffer through a liberal-stack parse when the
        // user types `+` so the stack reaches the panel.
        TestCase("crossClassPlus_topHasVirama") { ctx in
            let engine = defaultEngine()
            for input in [
                "pad+ma",
                "brah+ma",
                "nag+ma",
                "yag+na",
            ] {
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    surfaceContainsVirama(top),
                    input,
                    detail: "top='\(top)' lacks virama (U+1039); cands=\(state.candidates.prefix(4).map(\.surface))"
                )
            }
        },

        // Cross-class explicit `+` must NEVER produce a top candidate
        // that is strictly worse than the no-`+` sibling. "Worse" here
        // means: the no-`+` sibling has a virama, but the `+` form
        // doesn't. This is the user-facing acceptance criterion.
        TestCase("explicitPlus_neverDropsViramaWhenPlainHasIt") { ctx in
            let engine = defaultEngine()
            for input in [
                "pad+ma",
                "brah+ma",
                "nag+ma",
                "yag+na",
            ] {
                let plain = input.replacingOccurrences(of: "+", with: "")
                let plainTop = engine.update(buffer: plain, context: []).candidates.first?.surface ?? ""
                let plusTop = engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
                if surfaceContainsVirama(plainTop) {
                    ctx.assertTrue(
                        surfaceContainsVirama(plusTop),
                        input,
                        detail: "plain='\(plainTop)' has virama; plus='\(plusTop)' lost it"
                    )
                }
            }
        },

        // Same-class explicit `+` continues to work. Regression guard
        // for the strict path: the fix must not change behaviour when
        // strict same-class stacking already yields the right surface.
        TestCase("sameClassPlus_topUnchanged") { ctx in
            let engine = defaultEngine()
            let cases: [(buffer: String, expectedTop: String)] = [
                ("pak+ka",  "\u{1015}\u{1000}\u{1039}\u{1000}"),  // ပက္က
                ("p+m",     "\u{1015}\u{1039}\u{1019}"),          // ပ္မ
                ("dham+ma", "\u{1013}\u{1019}\u{1039}\u{1019}"),  // ဓမ္မ
            ]
            for (buffer, expected) in cases {
                let state = defaultEngine().update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top == expected,
                    buffer,
                    detail: "expected '\(expected)'; got top='\(top)'"
                )
                _ = engine // keep reference to silence unused-warnings if any
            }
        },

        // The implicit (no-`+`) inference path must keep its existing
        // demotion of liberal-stack siblings on plain Burmese
        // compounds — adding the explicit-`+` path must not poison
        // this regression. `takmaung` has no `+`, no `r`, and is a
        // native compound; the top must remain unstacked.
        TestCase("implicitPath_noPlus_noVirama_forNativeCompounds") { ctx in
            let engine = defaultEngine()
            for input in ["takmaung", "pakta", "satka", "sapna"] {
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertFalse(
                    surfaceContainsVirama(top),
                    input,
                    detail: "implicit (no-`+`) path top='\(top)' acquired a cross-class virama"
                )
            }
        },
    ])
}
