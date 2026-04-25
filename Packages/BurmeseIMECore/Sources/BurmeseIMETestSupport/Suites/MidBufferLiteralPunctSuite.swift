import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for task 03: literal punctuation that lands in the middle
/// of the composing buffer must NOT freeze every following letter as
/// raw ASCII. Each composable run between literal punctuation chars
/// gets composed independently and the literals stay verbatim in
/// place. Mapped punctuation is still substituted for its Myanmar
/// equivalent when `burmesePunctuationEnabled` is on; non-mapped
/// punctuation stays literal regardless.
public enum MidBufferLiteralPunctSuite {

    private static func defaultEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func mappedEngine() -> (engine: BurmeseEngine, cleanup: () -> Void) {
        let suiteName = "MidBufferLiteralPunctSuite.\(UUID().uuidString)"
        let settings = IMESettings(suiteName: suiteName)
        settings.burmesePunctuationEnabled = true
        let engine = BurmeseEngine(
            candidateStore: EmptyCandidateStore(),
            languageModel: NullLanguageModel(),
            settings: settings
        )
        return (engine, {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        })
    }

    public static let suite = TestSuite(name: "MidBufferLiteralPunct", cases: [

        // Default settings (`burmesePunctuationEnabled = false`): the
        // mid-buffer literal punctuation stays verbatim, but the
        // composable run AFTER it is still re-parsed into Myanmar.
        TestCase("midBufferLiteralPunct_recomposesTail_unmapped") { ctx in
            let engine = defaultEngine()
            let cases: [(buffer: String, expectedTop: String)] = [
                ("aung,thar",  "\u{1021}\u{1031}\u{102C}\u{1004}\u{103A},\u{101E}\u{102C}"),                              // အောင်,သာ
                ("thar;myat",  "\u{101E}\u{102C};\u{1019}\u{103C}\u{1010}\u{103A}"),                                       // သာ;မြတ်
                ("thar)myat",  "\u{101E}\u{102C})\u{1019}\u{103C}\u{1010}\u{103A}"),                                       // သာ)မြတ်
                ("(thar)myat", "(\u{101E}\u{102C})\u{1019}\u{103C}\u{1010}\u{103A}"),                                       // (သာ)မြတ်
                ("aung-thar",  "\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}-\u{101E}\u{102C}"),                              // အောင်-သာ
                ("aung_thar",  "\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}_\u{101E}\u{102C}"),                              // အောင်_သာ
                ("aung!thar",  "\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}!\u{101E}\u{102C}"),                              // အောင်!သာ
            ]
            for (buffer, expected) in cases {
                let top = engine.update(buffer: buffer, context: []).candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top == expected,
                    buffer,
                    detail: "expected top='\(expected)'; got='\(top)'"
                )
            }
        },

        // With `burmesePunctuationEnabled = true`, mapped punctuation
        // (`.`, `,`, `!`, `?`, `;`) becomes its Myanmar equivalent.
        // Non-mapped punctuation (`-`, `_`, `(`, `)`) still stays
        // literal even with the toggle on.
        TestCase("midBufferLiteralPunct_recomposesTail_mappedSubstitution") { ctx in
            let (engine, cleanup) = mappedEngine()
            defer { cleanup() }
            let cases: [(buffer: String, expectedTop: String)] = [
                ("aung,thar",  "\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}\u{104A}\u{101E}\u{102C}"),                       // အောင်၊သာ
                ("thar;myat",  "\u{101E}\u{102C}\u{104A}\u{1019}\u{103C}\u{1010}\u{103A}"),                                // သာ၊မြတ်
                ("aung!thar",  "\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}\u{104B}\u{101E}\u{102C}"),                       // အောင်။သာ
                // Non-mapped punctuation continues to stay literal.
                ("aung-thar",  "\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}-\u{101E}\u{102C}"),
                ("(thar)myat", "(\u{101E}\u{102C})\u{1019}\u{103C}\u{1010}\u{103A}"),
            ]
            for (buffer, expected) in cases {
                let top = engine.update(buffer: buffer, context: []).candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top == expected,
                    buffer,
                    detail: "expected top='\(expected)'; got='\(top)'"
                )
            }
        },

        // Pure trailing literal punctuation must NOT regress: the
        // existing behaviour for `thar.`, `thar,` (literal tail) keeps
        // working. The fix only kicks in when there's composable
        // content AFTER the literal punctuation.
        TestCase("midBufferLiteralPunct_pureTrailingLiteralPreserved") { ctx in
            let engine = defaultEngine()
            for (buffer, expected) in [
                ("thar,",  "\u{101E}\u{102C},"),    // သာ,
                ("thar;",  "\u{101E}\u{102C};"),    // သာ;
                ("aung-",  "\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}-"),                                                  // အောင်-
            ] {
                let top = engine.update(buffer: buffer, context: []).candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top == expected,
                    buffer,
                    detail: "expected top='\(expected)'; got='\(top)'"
                )
            }
        },

        // Multi-segment buffers with several literal-punct boundaries
        // must compose every segment independently.
        TestCase("midBufferLiteralPunct_multipleSegments") { ctx in
            let engine = defaultEngine()
            // a,b,c-style with three composable runs.
            let buffer = "thar,myat-aung"
            let expected = "\u{101E}\u{102C},\u{1019}\u{103C}\u{1010}\u{103A}-\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}"   // သာ,မြတ်-အောင်
            let top = engine.update(buffer: buffer, context: []).candidates.first?.surface ?? ""
            ctx.assertTrue(
                top == expected,
                buffer,
                detail: "expected top='\(expected)'; got='\(top)'"
            )
        },
    ])
}
