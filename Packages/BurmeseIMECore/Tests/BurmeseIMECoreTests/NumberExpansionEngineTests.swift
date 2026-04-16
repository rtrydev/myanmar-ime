import XCTest
@testable import BurmeseIMECore

/// Engine-level tests for the measure-word expansion feature. Exercises
/// `BurmeseEngine.update` with the `numberMeasureWordsEnabled` setting
/// flipped via an isolated `UserDefaults` suite.
final class NumberExpansionEngineTests: XCTestCase {

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "NumberExpansionEngineTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    func testYearExpansion_addsYearSuffixCandidate_whenEnabled() {
        let settings = IMESettings(suiteName: suiteName)
        settings.numberMeasureWordsEnabled = true
        let engine = BurmeseEngine(settings: settings)

        let state = engine.update(buffer: "2024", context: [])
        let surfaces = state.candidates.map(\.surface)
        XCTAssertTrue(surfaces.contains("၂၀၂၄"),
                      "baseline digit candidate missing: \(surfaces)")
        XCTAssertTrue(surfaces.contains("၂၀၂၄ ခုနှစ်"),
                      "year suffix candidate missing: \(surfaces)")
    }

    func testDigitOnlyCandidates_unchanged_whenDisabled() {
        let settings = IMESettings(suiteName: suiteName)
        settings.numberMeasureWordsEnabled = false
        let engine = BurmeseEngine(settings: settings)

        let state = engine.update(buffer: "2024", context: [])
        let surfaces = state.candidates.map(\.surface)
        XCTAssertEqual(Set(surfaces), Set(["၂၀၂၄", "2024"]),
                       "with feature off, only baseline digits should appear: \(surfaces)")
    }

    func testCurrencyExpansion_addsCurrencySuffix() {
        let settings = IMESettings(suiteName: suiteName)
        settings.numberMeasureWordsEnabled = true
        let engine = BurmeseEngine(settings: settings)

        let state = engine.update(buffer: "1000", context: [])
        let surfaces = state.candidates.map(\.surface)
        XCTAssertTrue(surfaces.contains("၁၀၀၀ ကျပ်"),
                      "currency suffix candidate missing: \(surfaces)")
    }

    func testLimit_capsAtTwoExpansions() {
        let settings = IMESettings(suiteName: suiteName)
        settings.numberMeasureWordsEnabled = true
        let engine = BurmeseEngine(settings: settings)

        let state = engine.update(buffer: "2024", context: [])
        // Candidates: baseline Burmese + up to 2 expansions + baseline ASCII.
        XCTAssertLessThanOrEqual(state.candidates.count, 4)
    }
}
