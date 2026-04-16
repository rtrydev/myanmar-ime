import XCTest
@testable import BurmeseIMECore

final class IMESettingsTests: XCTestCase {

    private var suiteName: String!
    private var store: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "IMESettingsTests.\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        store = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Seeding / defaults

    func testDefaults_seedOnFirstInit() {
        let settings = IMESettings(suiteName: suiteName)
        XCTAssertEqual(settings.candidatePageSize, 9)
        XCTAssertEqual(settings.commitOnSpace, false)
        XCTAssertEqual(settings.clusterAliasesEnabled, true)
        XCTAssertEqual(settings.lmPruneMargin, 8.0, accuracy: 1e-9)
        XCTAssertEqual(settings.anchorCommitThreshold, 8)
        XCTAssertEqual(settings.burmesePunctuationEnabled, false)
        XCTAssertEqual(settings.numberMeasureWordsEnabled, false)
        XCTAssertEqual(settings.learningEnabled, true)
    }

    func testDefaults_existingValuesSurviveInit() {
        store.set(3, forKey: IMESettings.Key.candidatePageSize.rawValue)
        store.set(false, forKey: IMESettings.Key.learningEnabled.rawValue)

        let settings = IMESettings(suiteName: suiteName)
        XCTAssertEqual(settings.candidatePageSize, 3)
        XCTAssertEqual(settings.learningEnabled, false)
    }

    // MARK: - Round-trip

    func testRoundTrip_allKeys() {
        let settings = IMESettings(suiteName: suiteName)
        settings.candidatePageSize = 12
        settings.commitOnSpace = true
        settings.clusterAliasesEnabled = false
        settings.lmPruneMargin = 3.5
        settings.anchorCommitThreshold = 14
        settings.burmesePunctuationEnabled = true
        settings.numberMeasureWordsEnabled = true
        settings.learningEnabled = false

        // A fresh instance backed by the same suite reads through the writes.
        let reread = IMESettings(suiteName: suiteName)
        XCTAssertEqual(reread.candidatePageSize, 12)
        XCTAssertEqual(reread.commitOnSpace, true)
        XCTAssertEqual(reread.clusterAliasesEnabled, false)
        XCTAssertEqual(reread.lmPruneMargin, 3.5, accuracy: 1e-9)
        XCTAssertEqual(reread.anchorCommitThreshold, 14)
        XCTAssertEqual(reread.burmesePunctuationEnabled, true)
        XCTAssertEqual(reread.numberMeasureWordsEnabled, true)
        XCTAssertEqual(reread.learningEnabled, false)
    }

    // MARK: - Restore defaults

    func testRestoreDefaults_onlyAffectsSection() {
        let settings = IMESettings(suiteName: suiteName)
        settings.candidatePageSize = 3
        settings.commitOnSpace = true
        settings.lmPruneMargin = 0.5
        settings.learningEnabled = false

        settings.restoreDefaults(section: .candidateRanking)

        // Candidate-ranking keys reset, others untouched.
        XCTAssertEqual(settings.lmPruneMargin, 8.0, accuracy: 1e-9)
        XCTAssertEqual(settings.anchorCommitThreshold, 8)
        XCTAssertEqual(settings.candidatePageSize, 3)
        XCTAssertEqual(settings.commitOnSpace, true)
        XCTAssertEqual(settings.learningEnabled, false)
    }

    // MARK: - Notifications

    func testChangeNotification_firesWithKey() {
        let settings = IMESettings(suiteName: suiteName)
        let expectation = XCTestExpectation(description: "notification fires")
        var capturedKey: String?

        let observer = NotificationCenter.default.addObserver(
            forName: IMESettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { note in
            capturedKey = note.userInfo?[IMESettings.changedKeyUserInfoKey] as? String
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        settings.commitOnSpace = true
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(capturedKey, IMESettings.Key.commitOnSpace.rawValue)
    }

    // MARK: - Key → Section mapping (guards against drift as we add keys)

    func testKeySectionMapping_matchesExpectedGroupings() {
        XCTAssertEqual(IMESettings.Key.candidatePageSize.section, .inputBehavior)
        XCTAssertEqual(IMESettings.Key.commitOnSpace.section, .inputBehavior)
        XCTAssertEqual(IMESettings.Key.clusterAliasesEnabled.section, .inputBehavior)
        XCTAssertEqual(IMESettings.Key.lmPruneMargin.section, .candidateRanking)
        XCTAssertEqual(IMESettings.Key.anchorCommitThreshold.section, .candidateRanking)
        XCTAssertEqual(IMESettings.Key.burmesePunctuationEnabled.section, .textOutput)
        XCTAssertEqual(IMESettings.Key.numberMeasureWordsEnabled.section, .textOutput)
        XCTAssertEqual(IMESettings.Key.learningEnabled.section, .learning)
    }
}
