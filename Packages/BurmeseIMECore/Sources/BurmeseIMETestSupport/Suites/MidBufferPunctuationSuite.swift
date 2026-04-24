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
            for (input, expected) in [
                ("ka.tar", "က.တာ"),
                ("ka:tar", "က:တာ"),
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
            for (input, expected) in [
                ("ka.tar", "က\u{104B}တာ"),
                ("ka..tar", "က\u{104B}\u{104B}တာ"),
                ("ka:tar", "က:တာ"),
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
