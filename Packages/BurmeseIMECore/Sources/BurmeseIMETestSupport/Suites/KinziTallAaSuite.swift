import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for task 01 (amended by TASK-087): `correctAaShape` keeps the
/// orthographically dominant tall ါ (U+102B) on descender consonants at
/// plain-onset positions and below a kinzi superscript — tall is the only
/// attested form for kinzi+ga+aa (`အင်္ဂါ`, `ဘင်္ဂါလီ`).
///
/// TASK-087 narrowed the original task-01 rule: when the aa's base is the
/// lower of a PLAIN Pali virama stack (`<C> 1039 <C>`, kinzi excluded),
/// the shape is a per-word lexical convention (`သိက္ခာ`, `စန္ဒာ`, `နန္ဒာ`
/// round vs `သဒ္ဓါ`, `မဂ္ဂါ…` tall — 153 curated store spellings
/// contradict the structural prediction), so the rewrite is skipped and
/// the typed/authored shape passes through. The bare engine renders the
/// typed round `ar`; curated tall spellings stay reachable through
/// lexicon hits, which now pass through verbatim
/// (StackLowerAaShapeFidelitySuite pins the production behavior).
public enum KinziTallAaSuite {

    private static let tallAa: UInt32 = 0x102B
    private static let shortAa: UInt32 = 0x102C

    private static func endsWithTallAa(_ surface: String) -> Bool {
        surface.unicodeScalars.last?.value == tallAa
    }

    private static func endsWithShortAa(_ surface: String) -> Bool {
        surface.unicodeScalars.last?.value == shortAa
    }

    private static func containsAa(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value == tallAa || $0.value == shortAa }
    }

    public static let suite = TestSuite(name: "KinziTallAa", cases: [

        // Kinzi + ga + aa always renders with the tall hook in the
        // lexicon (`အင်္ဂါ`, `ဘင်္ဂါလီ`, `မင်္ဂလာပါ`); the short form
        // does not appear. Top candidate must follow.
        TestCase("kinzi_ga_aa_isTall") { ctx in
            let engine = BurmeseEngine()
            for input in ["min+gar", "ahin+gar", "thin+gar", "pin+gar"] {
                let state = engine.update(buffer: input, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(input, detail: "no candidates")
                    continue
                }
                ctx.assertTrue(
                    endsWithTallAa(top),
                    input,
                    detail: "expected tall ါ on top candidate, got '\(top)'"
                )
            }
        },

        // TASK-087: Pali virama stacks where the lower is a descender
        // (ပ_, ဂ_, ဒ_) keep the TYPED shape on the bare engine — the
        // aa shape after a plain stack lower is a per-word lexical
        // convention the structural rule cannot express (`စန္ဒာ`,
        // `နန္ဒာ` round vs `မဂ္ဂါ…` tall), so the rewrite is skipped
        // and the parser's round `ar` materialization passes through.
        // Curated tall spellings are served verbatim by lexicon hits
        // on the production engine (StackLowerAaShapeFidelitySuite).
        TestCase("paliStack_lowerAa_keepsTypedShape") { ctx in
            let engine = BurmeseEngine()
            for input in ["pap+par", "ag+gar", "ad+dar"] {
                let state = engine.update(buffer: input, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(input, detail: "no candidates")
                    continue
                }
                ctx.assertTrue(
                    endsWithShortAa(top),
                    input,
                    detail: "expected typed round ာ on top candidate, got '\(top)'"
                )
            }
        },

        // Direct unit on `correctAaShape` with synthetic surfaces so
        // the rule is asserted outside the engine pipeline. The kinzi
        // base (`103A 1039 <C>`) is still rewritten to U+102B; plain
        // stack lowers (`<C> 1039 <C>`) keep their authored shape in
        // BOTH directions (TASK-087).
        TestCase("correctAaShape_rewritesKinziKeepsStackLower") { ctx in
            let cases: [(String, String)] = [
                // Kinzi stays structural: မင်္ဂာ → မင်္ဂါ
                ("\u{1019}\u{1004}\u{103A}\u{1039}\u{1002}\u{102C}",
                 "\u{1019}\u{1004}\u{103A}\u{1039}\u{1002}\u{102B}"),
                // Plain stack lowers pass through verbatim:
                // ပပ္ပာ stays round
                ("\u{1015}\u{1015}\u{1039}\u{1015}\u{102C}",
                 "\u{1015}\u{1015}\u{1039}\u{1015}\u{102C}"),
                // အဂ္ဂာ stays round
                ("\u{1021}\u{1002}\u{1039}\u{1002}\u{102C}",
                 "\u{1021}\u{1002}\u{1039}\u{1002}\u{102C}"),
                // အဒ္ဒာ stays round
                ("\u{1021}\u{1012}\u{1039}\u{1012}\u{102C}",
                 "\u{1021}\u{1012}\u{1039}\u{1012}\u{102C}"),
                // …and authored tall is preserved too: သဒ္ဓါ stays tall
                ("\u{101E}\u{1012}\u{1039}\u{1013}\u{102B}",
                 "\u{101E}\u{1012}\u{1039}\u{1013}\u{102B}"),
            ]
            for (input, expected) in cases {
                let actual = BurmeseEngine.correctAaShape(input)
                ctx.assertEqual(actual, expected, input)
            }
        },

        // The rule must only rewrite aa scalars — never inject one.
        // Stacks without an aa terminal stay byte-identical.
        TestCase("correctAaShape_doesNotInjectAa") { ctx in
            let engine = BurmeseEngine()
            let state = engine.update(buffer: "pap+pa", context: [])
            guard let top = state.candidates.first?.surface else {
                ctx.fail("pap+pa", detail: "no candidates")
                return
            }
            ctx.assertFalse(
                containsAa(top),
                "pap+pa",
                detail: "no aa expected, got '\(top)'"
            )
        },

        // Control: a non-descender consonant (ka) keeps the short ာ.
        // The rule remains gated on `Grammar.requiresTallAa`, not on
        // "always tall".
        TestCase("nonDescender_aa_staysShort") { ctx in
            let engine = BurmeseEngine()
            for input in ["kar", "ka+kar"] {
                let state = engine.update(buffer: input, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(input, detail: "no candidates")
                    continue
                }
                ctx.assertTrue(
                    endsWithShortAa(top),
                    input,
                    detail: "expected short ာ on top candidate, got '\(top)'"
                )
            }
        },
    ])
}
