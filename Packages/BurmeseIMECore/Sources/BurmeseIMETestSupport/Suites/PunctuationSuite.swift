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
            // Use `ka.` (no `a.` creaky rule) so the `.` falls through to
            // the punctuation-mapping path. `thar.` now consumes the `.`
            // as the `ar.` creaky-tone vowel modifier (task 01).
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let buffer = "ka."
            let state = engine.update(buffer: buffer, context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("က\u{104B}"),
                           "mappedDot", detail: "surfaces=\(surfaces)")
            // TASK-043: skip the raw-buffer literal when checking that
            // converted candidates have no ASCII leak.
            ctx.assertFalse(
                surfaces.contains(where: { $0 != buffer && $0.hasSuffix(".") }),
                "noAsciiLeak",
                detail: "surfaces=\(surfaces)"
            )
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
            // `ka.` retains literal `.` since there is no `a.` creaky rule.
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = false
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "ka.", context: [])
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
            let buffer = "thar,myat"
            let state = engine.update(buffer: buffer, context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("သာ\u{104A}မြတ်"),
                           "bothSegmentsConverted", detail: "surfaces=\(surfaces)")
            // TASK-043: the literal-fallback candidate carries the raw
            // buffer verbatim as a commit-as-typed escape hatch; skip
            // it when checking that the converted candidates dropped
            // the romanization tail.
            ctx.assertFalse(
                surfaces.contains(where: { $0 != buffer && $0.contains("myat") }),
                "noRawRomanLeak",
                detail: "surfaces=\(surfaces)"
            )
        },

        TestCase("engine_composableAfterDot_getsParsed") { ctx in
            // TASK-032: `ka.myat` is bare-`<C>a` + `.` + Burmese-
            // composable. The `.` is unambiguously a creaky tone
            // marker on the `ka` syllable, not a punctuation
            // terminator. The expected top is `က့မြတ်` (creaky
            // absorbed).
            //
            // Pre-fix this case was used to assert the literal-
            // mapped behaviour (`က။မြတ်`), but that contradicted
            // TASK-014's invariant for trailing-position `<C>a:` /
            // `<C>a.`; TASK-032 unifies those by always absorbing
            // when the continuation is itself Burmese.
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "ka.myat", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("က\u{1037}မြတ်"),
                           "dotAbsorbedAsCreaky", detail: "surfaces=\(surfaces)")
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
            // `padma.` ends in `<consonant>.` with no `X.` rule on the
            // tail consonant, so the `.` falls through to punct mapping.
            // `thar.` would now consume the `.` via `ar.` (task 01).
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let buffer = "padma."
            let state = engine.update(buffer: buffer, context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains(where: { $0.hasSuffix("\u{104B}") }),
                           "mappedDot", detail: "surfaces=\(surfaces)")
            // TASK-043: literal-fallback candidate is the raw buffer
            // verbatim — exclude it from the no-ASCII-leak guard.
            ctx.assertFalse(
                surfaces.contains(where: { $0 != buffer && $0.hasSuffix(".") }),
                "noAsciiLeak",
                detail: "surfaces=\(surfaces)"
            )
        },

        TestCase("engine_mixedTrailingDotBang_bothMapToPunct_whenEnabled") { ctx in
            // Use `ka.!` so both `.` and `!` are non-modifier punct.
            // `thar.!` would now bind the `.` into `သာ့` (task 01).
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let buffer = "ka.!"
            let state = engine.update(buffer: buffer, context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(surfaces.contains("က\u{104B}\u{104B}"),
                           "dotBangMapped", detail: "surfaces=\(surfaces)")
            // TASK-043: literal-fallback candidate is the raw buffer
            // verbatim — exclude it from the no-raw-dot guard.
            ctx.assertFalse(
                surfaces.contains(where: { $0 != buffer && $0.contains(".") }),
                "noRawDot",
                detail: "surfaces=\(surfaces)"
            )
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

        TestCase("engine_embeddedDot_asVowelModifier_notSplitAsPunctuation") { ctx in
            // `rarthiu.tu.` should parse as rar + thi + u. + tu. with a
            // trailing punctuation `.` → ။. The first `.` is part of the
            // `u.` creaky-tone vowel modifier and must not be split out
            // as a Myanmar full stop, which would freeze `rarthiu.` as
            // `ရာသီ<something>။` and leave the user with a broken render.
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "rarthiu.tu.", context: [])
            let surfaces = state.candidates.map(\.surface)
            // No candidate should contain a Myanmar full stop followed by
            // a consonant — that would mean the embedded `.` was misread
            // as punctuation rather than a vowel modifier.
            ctx.assertFalse(
                surfaces.contains(where: { surface in
                    guard let punctIdx = surface.firstIndex(of: "\u{104B}") else { return false }
                    let after = surface.index(after: punctIdx)
                    return after != surface.endIndex
                }),
                "noEmbeddedFullStop",
                detail: "surfaces=\(surfaces)"
            )
        },

        TestCase("engine_embeddedDot_mixedRealAndModifier_splitsOnlyRealPunct") { ctx in
            // `padma..rarthiu.tu.` — the doubled `..` between `padma`
            // and `rarthiu` cannot be a single-tone marker (TASK-032
            // absorbs only single `.` when it sits between Burmese-
            // composable runs); the first single `.` from the doubled
            // pair stays as punctuation and maps to ။. Second `.`
            // follows `u`, closing `u.` (modifier). Trailing `.` is
            // absorbed as creaky-tone of `tu.`.
            //
            // Switched from `thar.…` since task 01 made the `ar.`
            // creaky rule absorb that leading `.`. Switched from
            // `padma.…` to `padma..…` since TASK-032 now absorbs the
            // bare-`ma` + single-`.` shape as creaky too.
            let (settings, suiteName) = makeSettings()
            defer { cleanup(suiteName) }
            settings.burmesePunctuationEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "padma..rarthiu.tu.", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(
                surfaces.contains(where: { $0.contains("\u{104B}") }),
                "realPunctMapped",
                detail: "surfaces=\(surfaces)"
            )
            // The trailing `.` and the inner modifier `u.` must not
            // become ။ — no surface should have more than two ။
            // glyphs (the doubled real punct between `padma` and
            // `rarthiu` produces two ။).
            ctx.assertFalse(
                surfaces.contains(where: {
                    $0.filter({ $0 == "\u{104B}" }).count > 2
                }),
                "noTripleFullStop",
                detail: "surfaces=\(surfaces)"
            )
        },
    ])
}
