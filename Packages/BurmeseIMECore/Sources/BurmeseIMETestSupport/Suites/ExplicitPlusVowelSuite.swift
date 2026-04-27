import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-011: an explicit `+` between two vowel-bearing
/// syllables (`ka+ka`, `ta+ta`, `pa+pa`, `na+ta`, `na+da`, …) must
/// honour the user's signal and produce a virama-stacked surface
/// equivalent to the no-`+` doubled-letter form (`kakka`, `tatta`,
/// `pappa`, `natta`, `nadda`, …).
///
/// The bug class: `collapseConnectorRuns` previously stripped the
/// `+` outright when the next character was a vowel, leaving the
/// inference loop with no `+` and a `<vowel><coda><consonant>` site
/// that didn't match the inference loop's `<C>+<C>` anchor (the
/// preceding letter was the vowel `a`, not a coda letter). The fix
/// reshapes `<C><a>+<C>` → `<C>+<C><a>` so the explicit signal
/// survives and the parser's `+`-as-virama path materialises the
/// canonical conjunct.
public enum ExplicitPlusVowelSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func surfaceContainsViramaStack(
        _ surface: String,
        upper: UInt32,
        lower: UInt32
    ) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 3 else { return false }
        for i in 0..<(scalars.count - 2)
        where scalars[i] == upper && scalars[i + 1] == 0x1039 && scalars[i + 2] == lower {
            return true
        }
        return false
    }

    private static func surfaceContainsVirama(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value == 0x1039 }
    }

    public static let suite = TestSuite(name: "ExplicitPlusVowel", cases: [

        // Same-class pairs — the `+`-bearing buffer must produce the
        // same stacked-conjunct subsequence as the no-`+` doubled
        // form. Examples from TASK-011 reproduction table.
        TestCase("explicitPlusVowel_sameClassConjuncts") { ctx in
            let engine = emptyEngine()
            let cases: [(plus: String, doubled: String, upper: UInt32, lower: UInt32)] = [
                ("ka+ka", "kakka", 0x1000, 0x1000),
                ("ta+ta", "tatta", 0x1010, 0x1010),
                ("pa+pa", "pappa", 0x1015, 0x1015),
                ("ma+ma", "mamma", 0x1019, 0x1019),
                ("na+ta", "natta", 0x1014, 0x1010),
                ("na+da", "nadda", 0x1014, 0x1012),
            ]
            for c in cases {
                let plusSurface = engine.update(buffer: c.plus, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    surfaceContainsViramaStack(plusSurface, upper: c.upper, lower: c.lower),
                    c.plus,
                    detail: "expected `\(String(format: "%04X", c.upper))` 1039 `\(String(format: "%04X", c.lower))` in plus-form '\(c.plus)' surface='\(plusSurface)'"
                )
            }
        },

        // The post-`+` lower can also be a multi-letter consonant
        // (`ka+kka`, `ka+kk+a`). The inference must still produce
        // a virama somewhere in the surface.
        TestCase("explicitPlusVowel_chainedStackLower") { ctx in
            let engine = emptyEngine()
            for input in ["ka+kka", "ka+kk+a"] {
                let surface = engine.update(buffer: input, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    surfaceContainsVirama(surface),
                    input,
                    detail: "expected virama in '\(input)' surface='\(surface)'"
                )
            }
        },

        // Cross-class case (`kha+ka`): strict path produces the open
        // form `ခက` (acceptable) but the liberal path must surface a
        // stacked sibling somewhere in the panel so the user can
        // pick it.
        TestCase("explicitPlusVowel_crossClassSiblingReachable") { ctx in
            let engine = emptyEngine()
            let state = engine.update(buffer: "kha+ka", context: [])
            let stacked = state.candidates.contains {
                surfaceContainsVirama($0.surface)
            }
            ctx.assertTrue(
                stacked,
                "kha+ka",
                detail: "no stacked sibling for 'kha+ka' all=\(state.candidates.prefix(6).map(\.surface))"
            )
        },

        // Counter-examples: existing `+`-using buffers must continue
        // to render unchanged.
        TestCase("explicitPlusVowel_existingPlusBuffersUnchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(input: String, mustContainVirama: Bool)] = [
                ("k+ka", true),    // strict same-class
                ("k++ka", true),   // doubled-`+` collapse
                ("kar+u", false),  // no doubled-letter, virama not required
            ]
            for c in cases {
                let surface = engine.update(buffer: c.input, context: [])
                    .candidates.first?.surface ?? ""
                if c.mustContainVirama {
                    ctx.assertTrue(
                        surfaceContainsVirama(surface),
                        c.input,
                        detail: "expected virama in '\(c.input)' surface='\(surface)'"
                    )
                } else {
                    // Just assert non-empty.
                    ctx.assertTrue(
                        !surface.isEmpty,
                        c.input,
                        detail: "empty surface for '\(c.input)'"
                    )
                }
            }
        },
    ])
}
