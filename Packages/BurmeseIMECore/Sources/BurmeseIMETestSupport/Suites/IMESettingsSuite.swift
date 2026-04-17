import Foundation
import BurmeseIMECore

public enum IMESettingsSuite {

    private static func makeSuite() -> (String, UserDefaults) {
        let suiteName = "IMESettingsSuite.\(UUID().uuidString)"
        return (suiteName, UserDefaults(suiteName: suiteName)!)
    }

    private static func cleanup(_ suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    public static let suite = TestSuite(name: "IMESettings", cases: [

        TestCase("defaults_seedOnFirstInit") { ctx in
            let (suiteName, _) = makeSuite()
            defer { cleanup(suiteName) }
            let settings = IMESettings(suiteName: suiteName)
            ctx.assertEqual(settings.candidatePageSize, 9, "pageSize")
            ctx.assertEqual(settings.commitOnSpace, false, "commitOnSpace")
            ctx.assertEqual(settings.clusterAliasesEnabled, true, "clusterAliases")
            ctx.assertTrue(abs(settings.lmPruneMargin - 8.0) < 1e-9, "lmPruneMargin")
            ctx.assertEqual(settings.anchorCommitThreshold, 8, "anchorCommit")
            ctx.assertEqual(settings.burmesePunctuationEnabled, false, "punct")
            ctx.assertEqual(settings.numberMeasureWordsEnabled, false, "numExpand")
            ctx.assertEqual(settings.learningEnabled, true, "learning")
        },

        TestCase("defaults_existingValuesSurviveInit") { ctx in
            let (suiteName, store) = makeSuite()
            defer { cleanup(suiteName) }
            store.set(3, forKey: IMESettings.Key.candidatePageSize.rawValue)
            store.set(false, forKey: IMESettings.Key.learningEnabled.rawValue)
            let settings = IMESettings(suiteName: suiteName)
            ctx.assertEqual(settings.candidatePageSize, 3, "pageSize")
            ctx.assertEqual(settings.learningEnabled, false, "learning")
        },

        TestCase("roundTrip_allKeys") { ctx in
            let (suiteName, _) = makeSuite()
            defer { cleanup(suiteName) }
            let settings = IMESettings(suiteName: suiteName)
            settings.candidatePageSize = 12
            settings.commitOnSpace = true
            settings.clusterAliasesEnabled = false
            settings.lmPruneMargin = 3.5
            settings.anchorCommitThreshold = 14
            settings.burmesePunctuationEnabled = true
            settings.numberMeasureWordsEnabled = true
            settings.learningEnabled = false
            let reread = IMESettings(suiteName: suiteName)
            ctx.assertEqual(reread.candidatePageSize, 12, "pageSize")
            ctx.assertEqual(reread.commitOnSpace, true, "commitOnSpace")
            ctx.assertEqual(reread.clusterAliasesEnabled, false, "clusterAliases")
            ctx.assertTrue(abs(reread.lmPruneMargin - 3.5) < 1e-9, "lmPruneMargin")
            ctx.assertEqual(reread.anchorCommitThreshold, 14, "anchorCommit")
            ctx.assertEqual(reread.burmesePunctuationEnabled, true, "punct")
            ctx.assertEqual(reread.numberMeasureWordsEnabled, true, "numExpand")
            ctx.assertEqual(reread.learningEnabled, false, "learning")
        },

        TestCase("restoreDefaults_onlyAffectsSection") { ctx in
            let (suiteName, _) = makeSuite()
            defer { cleanup(suiteName) }
            let settings = IMESettings(suiteName: suiteName)
            settings.candidatePageSize = 3
            settings.commitOnSpace = true
            settings.lmPruneMargin = 0.5
            settings.learningEnabled = false
            settings.restoreDefaults(section: .candidateRanking)
            ctx.assertTrue(abs(settings.lmPruneMargin - 8.0) < 1e-9, "lmPruneMarginReset")
            ctx.assertEqual(settings.anchorCommitThreshold, 8, "anchorCommitReset")
            ctx.assertEqual(settings.candidatePageSize, 3, "pageSizeUntouched")
            ctx.assertEqual(settings.commitOnSpace, true, "commitOnSpaceUntouched")
            ctx.assertEqual(settings.learningEnabled, false, "learningUntouched")
        },

        TestCase("changeNotification_firesWithKey") { ctx in
            let (suiteName, _) = makeSuite()
            defer { cleanup(suiteName) }
            let settings = IMESettings(suiteName: suiteName)
            final class Box: @unchecked Sendable { var value: String? }
            let box = Box()
            let sem = DispatchSemaphore(value: 0)
            let observer = NotificationCenter.default.addObserver(
                forName: IMESettings.didChangeNotification,
                object: nil,
                queue: nil
            ) { note in
                box.value = note.userInfo?[IMESettings.changedKeyUserInfoKey] as? String
                sem.signal()
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            settings.commitOnSpace = true
            _ = sem.wait(timeout: .now() + 1.0)
            ctx.assertEqual(box.value, IMESettings.Key.commitOnSpace.rawValue,
                            "capturedKey")
        },

        TestCase("keySectionMapping_matchesExpectedGroupings") { ctx in
            ctx.assertTrue(IMESettings.Key.candidatePageSize.section == .inputBehavior,
                           "pageSize")
            ctx.assertTrue(IMESettings.Key.commitOnSpace.section == .inputBehavior,
                           "commitOnSpace")
            ctx.assertTrue(IMESettings.Key.clusterAliasesEnabled.section == .inputBehavior,
                           "clusterAliases")
            ctx.assertTrue(IMESettings.Key.lmPruneMargin.section == .candidateRanking,
                           "lmPruneMargin")
            ctx.assertTrue(IMESettings.Key.anchorCommitThreshold.section == .candidateRanking,
                           "anchorCommit")
            ctx.assertTrue(IMESettings.Key.burmesePunctuationEnabled.section == .textOutput,
                           "punct")
            ctx.assertTrue(IMESettings.Key.numberMeasureWordsEnabled.section == .textOutput,
                           "numExpand")
            ctx.assertTrue(IMESettings.Key.learningEnabled.section == .learning,
                           "learning")
        },

        TestCase("engine_candidatePageSize_honoredByEngine") { ctx in
            let (suiteName, _) = makeSuite()
            defer { cleanup(suiteName) }
            let settings = IMESettings(suiteName: suiteName)
            settings.candidatePageSize = 3
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "k", context: [])
            ctx.assertTrue(state.candidates.count <= 3,
                           "capped", detail: "count=\(state.candidates.count)")
        },

        TestCase("engine_candidatePageSize_exposedOnEngine") { ctx in
            let (suiteName, _) = makeSuite()
            defer { cleanup(suiteName) }
            let settings = IMESettings(suiteName: suiteName)
            settings.candidatePageSize = 12
            let engine = BurmeseEngine(settings: settings)
            ctx.assertEqual(engine.candidatePageSize, 12, "pageSize")
        },

        TestCase("engine_settingsNil_fallsBackToCompiledDefaults") { ctx in
            let engine = BurmeseEngine()
            ctx.assertEqual(engine.candidatePageSize,
                            BurmeseEngine.candidatePageSizeDefault,
                            "pageSizeDefault")
            let state = engine.update(buffer: "k", context: [])
            ctx.assertTrue(state.candidates.count <= BurmeseEngine.candidatePageSizeDefault,
                           "capAtDefault",
                           detail: "count=\(state.candidates.count)")
        },

        TestCase("engine_clusterAliasesDisabled_noJOnset") { ctx in
            let (suiteName, _) = makeSuite()
            defer { cleanup(suiteName) }
            let settings = IMESettings(suiteName: suiteName)
            settings.clusterAliasesEnabled = false
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "ja", context: [])
            let surfaces = state.candidates
                .filter { $0.source == .grammar }
                .map(\.surface)
            ctx.assertFalse(
                surfaces.contains("ကျ") || surfaces.contains("ကျာ"),
                "noClusterLeakage",
                detail: "surfaces=\(surfaces)"
            )
        },

        TestCase("engine_clusterAliasesEnabled_jStillWorks") { ctx in
            let (suiteName, _) = makeSuite()
            defer { cleanup(suiteName) }
            let settings = IMESettings(suiteName: suiteName)
            settings.clusterAliasesEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let state = engine.update(buffer: "ja", context: [])
            let surfaces = state.candidates.map(\.surface)
            ctx.assertTrue(
                surfaces.contains { $0.hasPrefix("ကျ") },
                "clusterParse",
                detail: "surfaces=\(surfaces)"
            )
        },

        TestCase("engine_clusterAliasesToggle_afterConstruction_requiresRebuild") { ctx in
            let (suiteName, _) = makeSuite()
            defer { cleanup(suiteName) }
            let settings = IMESettings(suiteName: suiteName)
            settings.clusterAliasesEnabled = true
            let engine = BurmeseEngine(settings: settings)
            let before = engine.update(buffer: "ja", context: [])
            ctx.assertTrue(
                before.candidates.map(\.surface).contains { $0.hasPrefix("ကျ") },
                "precondition_enabledEngine"
            )
            settings.clusterAliasesEnabled = false
            let afterToggle = engine.update(buffer: "ja", context: [])
            ctx.assertTrue(
                afterToggle.candidates.map(\.surface).contains { $0.hasPrefix("ကျ") },
                "stillProducesClusterUntilRebuild"
            )
            let rebuilt = BurmeseEngine(settings: settings)
            let afterRebuild = rebuilt.update(buffer: "ja", context: [])
            let rebuiltGrammar = afterRebuild.candidates
                .filter { $0.source == .grammar }
                .map(\.surface)
            ctx.assertFalse(
                rebuiltGrammar.contains { $0.hasPrefix("ကျ") },
                "rebuiltHonorsNewSetting",
                detail: "surfaces=\(rebuiltGrammar)"
            )
        },
    ])
}
