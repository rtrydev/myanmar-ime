import Foundation
import BurmeseIMECore

public enum PunctuationSuite {

    private static func makeSettings() -> (IMESettings, String) {
        let suiteName = "PunctuationSuite.\(UUID().uuidString)"
        return (IMESettings(suiteName: suiteName), suiteName)
    }

    private static func cleanup(_ suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    public static let suite = TestSuite(name: "Punctuation", cases: [

        TestCase("mapper_sentenceTerminators_foldToU104B") { ctx in
            ctx.assertEqual(PunctuationMapper.mapped("."), "\u{104B}", "dot")
            ctx.assertEqual(PunctuationMapper.mapped("!"), "\u{104B}", "bang")
            ctx.assertEqual(PunctuationMapper.mapped("?"), "\u{104B}", "qmark")
        },

        TestCase("mapper_phraseSeparators_foldToU104A") { ctx in
            ctx.assertEqual(PunctuationMapper.mapped(","), "\u{104A}", "comma")
            ctx.assertEqual(PunctuationMapper.mapped(";"), "\u{104A}", "semi")
        },

        TestCase("mapper_unmappedCharsReturnNil") { ctx in
            ctx.assertTrue(PunctuationMapper.mapped(":") == nil, "colon")
            ctx.assertTrue(PunctuationMapper.mapped("a") == nil, "letter")
            ctx.assertTrue(PunctuationMapper.mapped("1") == nil, "digit")
            ctx.assertTrue(PunctuationMapper.mapped(" ") == nil, "space")
        },

        TestCase("mapper_isMappable_matchesMappedSet") { ctx in
            for c in [".", "!", "?", ",", ";"] as [Character] {
                ctx.assertTrue(PunctuationMapper.isMappable(c), "mappable", detail: "\(c)")
            }
            ctx.assertFalse(PunctuationMapper.isMappable(":"), "colon_notMappable")
            ctx.assertFalse(PunctuationMapper.isMappable("a"), "letter_notMappable")
        },

        TestCase("mapper_isMyanmar_detectsMyanmarScript") { ctx in
            ctx.assertTrue(PunctuationMapper.isMyanmar("ဟယ်လို"), "pureMyanmar")
            ctx.assertTrue(PunctuationMapper.isMyanmar("hello ဟယ်လို"), "mixed")
            ctx.assertTrue(PunctuationMapper.isMyanmar("\u{1040}"), "myanmarDigit")
        },

        TestCase("mapper_isMyanmar_rejectsAsciiAndEmpty") { ctx in
            ctx.assertFalse(PunctuationMapper.isMyanmar(""), "empty")
            ctx.assertFalse(PunctuationMapper.isMyanmar("hello"), "ascii")
            ctx.assertFalse(PunctuationMapper.isMyanmar("e.g."), "asciiDot")
            ctx.assertFalse(PunctuationMapper.isMyanmar("1234"), "asciiDigits")
        },

        TestCase("engine_trailingDot_mappedInsideSurface_whenEnabled") { ctx in
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "thar.", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("သာ\u{104B}"),
                           "mappedDot", detail: "surfaces=\(surfaces)")
            ctx.assertFalse(surfaces.contains(where: { $0.hasSuffix(".") }),
                            "noAsciiLeak", detail: "surfaces=\(surfaces)")
        },

        TestCase("engine_trailingComma_mapsToU104A") { ctx in
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "thar,", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("သာ\u{104A}"),
                           "mappedComma", detail: "surfaces=\(surfaces)")
        },

        TestCase("engine_trailingDot_stayLiteral_whenDisabled") { ctx in
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = false
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "thar.", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains(where: { $0.hasSuffix(".") }),
                           "literalDot", detail: "surfaces=\(surfaces)")
            ctx.assertFalse(surfaces.contains(where: { $0.hasSuffix("\u{104B}") }),
                            "noMyanmarPunct", detail: "surfaces=\(surfaces)")
        },

        TestCase("engine_rawBuffer_unchanged_evenWhenMappingApplied") { ctx in
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "thar.", context: [])
            ctx.assertEqual(state.rawBuffer, "thar.", "rawBufferPreserved")
        },

        TestCase("engine_digitsWithTrailingDot_mapTail_whenEnabled") { ctx in
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "123.", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("၁၂၃\u{104B}"),
                           "mappedDigitsWithDot", detail: "surfaces=\(surfaces)")
        },

        TestCase("engine_composableAfterComma_getsParsed") { ctx in
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "thar,myat", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("သာ\u{104A}မြတ်"),
                           "bothSegmentsConverted", detail: "surfaces=\(surfaces)")
            ctx.assertFalse(surfaces.contains(where: { $0.contains("myat") }),
                            "noRawRomanLeak", detail: "surfaces=\(surfaces)")
        },

        TestCase("engine_composableAfterDot_getsParsed") { ctx in
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "thar.myat", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("သာ\u{104B}မြတ်"),
                           "dotThenComposable", detail: "surfaces=\(surfaces)")
        },

        TestCase("engine_composableBetweenTwoPuncts_getsParsed") { ctx in
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "thar,myat.", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("သာ\u{104A}မြတ်\u{104B}"),
                           "threeSegmentRender", detail: "surfaces=\(surfaces)")
        },

        TestCase("engine_trailingDot_creakyTone_whenEnabled") { ctx in
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "tu.", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("\u{1010}\u{102F}"),
                           "creakyTone", detail: "surfaces=\(surfaces)")
            ctx.assertFalse(surfaces.contains(where: { $0.hasSuffix("\u{104B}") }),
                            "noTrailingPunct", detail: "surfaces=\(surfaces)")
        },

        TestCase("engine_doubleTrailingDot_modifierPlusPunct_whenEnabled") { ctx in
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "tu..", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("\u{1010}\u{102F}\u{104B}"),
                           "creakyPlusPunct", detail: "surfaces=\(surfaces)")
        },

        TestCase("engine_trailingDot_onNonModifierOnset_stillMapsToPunct_whenEnabled") { ctx in
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "thar.", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("သာ\u{104B}"),
                           "mappedDot", detail: "surfaces=\(surfaces)")
            ctx.assertFalse(surfaces.contains(where: { $0.hasSuffix(".") }),
                            "noAsciiLeak", detail: "surfaces=\(surfaces)")
        },

        TestCase("engine_mixedTrailingDotBang_bothMapToPunct_whenEnabled") { ctx in
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "thar.!", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("သာ\u{104B}\u{104B}"),
                           "dotBangMapped", detail: "surfaces=\(surfaces)")
            ctx.assertFalse(surfaces.contains(where: { $0.contains(".") }),
                            "noRawDot", detail: "surfaces=\(surfaces)")
        },

        TestCase("engine_thiuDot_producesStandaloneBu_whenEnabled") { ctx in
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "thiu.", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("\u{101E}\u{102E}\u{1025}"),
                           "thiuDotStandalone", detail: "surfaces=\(surfaces)")
        },
    ])
}
