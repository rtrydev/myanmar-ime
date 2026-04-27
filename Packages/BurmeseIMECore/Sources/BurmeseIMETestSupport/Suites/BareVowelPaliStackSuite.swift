import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-010: implicit Pali/Sanskrit stack inference must
/// fire on every onsetless leading independent-vowel romanization key
/// (`a`, `e`, `i`, `o`, `u`, `ay`, `aw`, `oo`, `ii`, plus the numeric
/// disambiguators `u2`, `oo2`, `ay2`), not just on bare `a`.
///
/// The reference shape is `akka` → `အက္က` (`1021 1000 1039 1000`):
/// every `<bare-vowel-rom><stack-pair>a` buffer must produce a rank-0
/// surface that contains the canonical virama-separated stack
/// `<upper> 1039 <lower>` in the same position the bare-`a` form does.
public enum BareVowelPaliStackSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    /// Returns true if `surface`'s scalar sequence contains `<upper>
    /// 1039 <lower>` somewhere — the canonical signal that the
    /// inferred stack fired.
    private static func containsStackedPair(
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

    /// Build a `<bare-vowel><stack-pair>a` buffer and assert the rank-0
    /// surface contains the inferred virama between the doubled-letter
    /// upper/lower. The bare-`a` sibling is asserted as the reference.
    private static func runStackPair(
        ctx: TestContext,
        upperLetter: String,
        upperScalar: UInt32,
        // List of (vowel-prefix, descriptive-name) pairs to verify.
        vowels: [(rom: String, name: String)]
    ) {
        let engine = emptyEngine()
        // Reference: `<a><up><up>a` must always inferring-stack.
        let aBuffer = "a" + upperLetter + upperLetter + "a"
        let aSurface = engine.update(buffer: aBuffer, context: []).candidates.first?.surface ?? ""
        ctx.assertTrue(
            containsStackedPair(aSurface, upper: upperScalar, lower: upperScalar),
            "reference_\(aBuffer)",
            detail: "bare-`a` reference '\(aBuffer)' missing virama stack — surface='\(aSurface)'"
        )
        for v in vowels {
            let buffer = v.rom + upperLetter + upperLetter + "a"
            let surface = engine.update(buffer: buffer, context: []).candidates.first?.surface ?? ""
            ctx.assertTrue(
                containsStackedPair(surface, upper: upperScalar, lower: upperScalar),
                "\(v.name)_\(buffer)",
                detail: "expected virama stack in '\(buffer)' surface='\(surface)'"
            )
        }
    }

    public static let suite = TestSuite(name: "BareVowelPaliStack", cases: [

        // The headline reproduction table from TASK-010 paired with
        // its bare-`a` sibling. For each consonant pair (kk, pp, tt,
        // mm, dd, …) the parallel non-`a` openers (e/i/o/u/ay/aw)
        // must produce the same stacked surface as `akka`/`atta`/...
        TestCase("nonALeadingPaliStack_kkFamily") { ctx in
            runStackPair(
                ctx: ctx,
                upperLetter: "k",
                upperScalar: 0x1000,
                vowels: [
                    ("e", "e"),
                    ("i", "i"),
                    ("o", "o"),
                    ("u", "u"),
                    ("ay", "ay"),
                    ("aw", "aw"),
                ]
            )
        },

        TestCase("nonALeadingPaliStack_ppFamily") { ctx in
            runStackPair(
                ctx: ctx,
                upperLetter: "p",
                upperScalar: 0x1015,
                vowels: [
                    ("e", "e"),
                    ("i", "i"),
                    ("o", "o"),
                    ("u", "u"),
                ]
            )
        },

        TestCase("nonALeadingPaliStack_ttFamily") { ctx in
            // `e` / `i` are excluded for the `tt` pair because `et`
            // and `it` are vowel rules in their own right (က်/စ်)
            // and consume the first letter of the doubled-`t`,
            // so the bug class doesn't apply for those vowels here.
            runStackPair(
                ctx: ctx,
                upperLetter: "t",
                upperScalar: 0x1010,
                vowels: [
                    ("o", "o"),
                    ("u", "u"),
                ]
            )
        },

        TestCase("nonALeadingPaliStack_mmFamily") { ctx in
            runStackPair(
                ctx: ctx,
                upperLetter: "m",
                upperScalar: 0x1019,
                vowels: [
                    ("e", "e"),
                    ("i", "i"),
                    ("u", "u"),
                ]
            )
        },

        // Cross-class stacks reproduction table: `iddha` → `အီဒ္ဓ`.
        // The upper here is `da` (1012), lower is `dha` (1013).
        TestCase("nonALeadingPaliStack_iddha") { ctx in
            let engine = emptyEngine()
            let surface = engine.update(buffer: "iddha", context: [])
                .candidates.first?.surface ?? ""
            ctx.assertTrue(
                containsStackedPair(surface, upper: 0x1012, lower: 0x1013),
                "iddha",
                detail: "expected `da` 1039 `dha` stack — surface='\(surface)'"
            )
        },

        TestCase("nonALeadingPaliStack_enta") { ctx in
            // `enta` → expected `na` 1039 `ta`.
            let engine = emptyEngine()
            let surface = engine.update(buffer: "enta", context: [])
                .candidates.first?.surface ?? ""
            ctx.assertTrue(
                containsStackedPair(surface, upper: 0x1014, lower: 0x1010),
                "enta",
                detail: "expected `na` 1039 `ta` stack — surface='\(surface)'"
            )
        },

        // Reference: bare-`a` family must still produce stacked
        // surface unchanged after the fix.
        TestCase("aLeadingPaliStack_unchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(input: String, upper: UInt32, lower: UInt32)] = [
                ("akka", 0x1000, 0x1000),
                ("atta", 0x1010, 0x1010),
                ("appa", 0x1015, 0x1015),
                ("amma", 0x1019, 0x1019),
                ("anta", 0x1014, 0x1010),
                ("assa", 0x1005, 0x1005),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.input, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    containsStackedPair(surface, upper: c.upper, lower: c.lower),
                    c.input,
                    detail: "regressed bare-`a` reference '\(c.input)' surface='\(surface)'"
                )
            }
        },

        // Onset+vowel forms (consonant-led — control set) must continue
        // to infer the stack unchanged.
        TestCase("onsetLedPaliStack_unchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(input: String, upper: UInt32, lower: UInt32)] = [
                ("thatta", 0x1010, 0x1010),
                ("thakka", 0x1000, 0x1000),
                ("dhamma", 0x1019, 0x1019),
                ("kappa", 0x1015, 0x1015),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.input, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    containsStackedPair(surface, upper: c.upper, lower: c.lower),
                    c.input,
                    detail: "regressed onset-led reference '\(c.input)' surface='\(surface)'"
                )
            }
        },
    ])
}
