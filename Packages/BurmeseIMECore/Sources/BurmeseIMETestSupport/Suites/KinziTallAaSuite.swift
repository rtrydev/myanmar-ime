import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for task 01: `correctAaShape` must keep the orthographically
/// dominant tall ါ (U+102B) on descender consonants regardless of whether
/// the consonant sits as the lower of a virama stack or below a kinzi
/// superscript. Lexicon evidence (`အင်္ဂါ`, `မဂ္ဂါဝပ်`, `အဓိပ္ပါယ်`)
/// shows the previous "if preceded by virama, fall back to short ာ"
/// carve-out was wrong: tall is the only attested form for kinzi+ga+aa
/// and ဂ_+aa, and it dominates by frequency for ပ္ပ_+aa.
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

        // Pali virama stacks where the lower is a descender (ပ_, ဂ_,
        // ဒ_) take the tall hook in the dominant lexicon spelling.
        TestCase("paliStack_descenderLower_aa_isTall") { ctx in
            let engine = BurmeseEngine()
            for input in ["pap+par", "ag+gar", "ad+dar"] {
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

        // Direct unit on `correctAaShape` with synthetic surfaces so
        // the rule is asserted outside the engine pipeline. Each entry
        // is the raw scalar list a parser/lexicon path could emit; the
        // sanitizer must rewrite the closing aa to U+102B.
        TestCase("correctAaShape_rewritesStackedDescender") { ctx in
            let cases: [(String, String)] = [
                // မင်္ဂာ → မင်္ဂါ
                ("\u{1019}\u{1004}\u{103A}\u{1039}\u{1002}\u{102C}",
                 "\u{1019}\u{1004}\u{103A}\u{1039}\u{1002}\u{102B}"),
                // ပပ္ပာ → ပပ္ပါ
                ("\u{1015}\u{1015}\u{1039}\u{1015}\u{102C}",
                 "\u{1015}\u{1015}\u{1039}\u{1015}\u{102B}"),
                // အဂ္ဂာ → အဂ္ဂါ
                ("\u{1021}\u{1002}\u{1039}\u{1002}\u{102C}",
                 "\u{1021}\u{1002}\u{1039}\u{1002}\u{102B}"),
                // အဒ္ဒာ → အဒ္ဒါ
                ("\u{1021}\u{1012}\u{1039}\u{1012}\u{102C}",
                 "\u{1021}\u{1012}\u{1039}\u{1012}\u{102B}"),
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
