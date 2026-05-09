import Foundation
import BurmeseIMECore

public enum MidBufferPunctuationSuite {

    private static func makeEngine(mapped: Bool) -> (BurmeseEngine, String) {
        let suiteName = "MidBufferPunctuation.\(UUID().uuidString)"
        let settings = IMESettings(suiteName: suiteName)
        settings.burmesePunctuationEnabled = mapped
        return (BurmeseEngine(settings: settings), suiteName)
    }

    private static func cleanup(_ suiteName: String) {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private static func assertTop(
        _ ctx: TestContext,
        engine: BurmeseEngine,
        input: String,
        expected: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let state = engine.update(buffer: input, context: [])
        let top = state.candidates.first?.surface ?? ""
        ctx.assertEqual(
            top,
            expected,
            input,
            file: file,
            line: line
        )
    }

    public static let suite = TestSuite(name: "MidBufferPunctuation", cases: [

        TestCase("asciiMidBufferPunctuationStaysLiteral") { ctx in
            let (engine, suiteName) = makeEngine(mapped: false)
            defer { cleanup(suiteName) }
            // TASK-032: a SINGLE `.` / `:` between a tone-eligible
            // bare-`<C>a` syllable and a Burmese-composable
            // continuation is unambiguously a Burmese tone marker
            // (creaky / visarga) and gets absorbed onto the preceding
            // syllable, NOT preserved as a literal between scripts.
            // Doubled / mixed punct runs (`..`, `::`, `.:`) and runs
            // that include `*` / `'` continue to flush as literal
            // because they cannot all act as a single tone marker.
            for (input, expected) in [
                ("ka.tar", "က့တာ"),       // creaky absorbed (TASK-032)
                ("ka:tar", "ကးတာ"),       // visarga absorbed (TASK-032)
                ("ka*.tar", "က*.တာ"),
                ("ka'.tar", "က'.တာ"),
                ("ka..tar", "က..တာ"),
                ("ka::tar", "က::တာ"),
                ("ka.:tar", "က.:တာ"),
            ] {
                assertTop(ctx, engine: engine, input: input, expected: expected)
            }
        },

        TestCase("mappedMidBufferPunctuationMapsOnlyMappedCharacters") { ctx in
            let (engine, suiteName) = makeEngine(mapped: true)
            defer { cleanup(suiteName) }
            // TASK-032: with Burmese-punctuation mapping ON, a single
            // `.` between two Burmese syllables maps to U+104B
            // (Myanmar full stop), but only when the prefix is NOT a
            // tone-eligible bare-`<C>a` shape. For `ka.tar` and
            // `ka:tar` (bare-`<C>a` + tone + Burmese), the tone
            // absorption takes precedence over the punct mapping —
            // the user's `.` after `ka` is a Burmese tone marker, not
            // a section-end-mark.
            for (input, expected) in [
                ("ka.tar", "က့တာ"),                        // creaky absorbed (TASK-032)
                ("ka..tar", "က\u{104B}\u{104B}တာ"),
                ("ka:tar", "ကးတာ"),                        // visarga absorbed (TASK-032)
                ("ka'.tar", "က'\u{104B}တာ"),
                ("ka*.tar", "က*\u{104B}တာ"),
            ] {
                assertTop(ctx, engine: engine, input: input, expected: expected)
            }
        },

        TestCase("creakyToneDotStillAttachesBeforeNextRun") { ctx in
            for mapped in [false, true] {
                let (engine, suiteName) = makeEngine(mapped: mapped)
                defer { cleanup(suiteName) }
                assertTop(ctx, engine: engine, input: "mi.ka", expected: "မိက")
            }
        },
    ])
}
