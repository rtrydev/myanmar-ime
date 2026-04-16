import XCTest
@testable import BurmeseIMECore

/// Engine-level tests for in-composition punctuation mapping. When the
/// `burmesePunctuationEnabled` setting is on, trailing ASCII punctuation
/// is substituted inside each candidate's surface rather than committing
/// the selection early and appending the glyph outside the composition.
final class PunctuationTailEngineTests: XCTestCase {

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PunctuationTailEngineTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    func testTrailingDot_mappedInsideCandidateSurface_whenEnabled() {
        let settings = IMESettings(suiteName: suiteName)
        settings.burmesePunctuationEnabled = true
        let engine = BurmeseEngine(settings: settings)

        let state = engine.update(buffer: "thar.", context: [])
        let surfaces = state.candidates.map(\.surface)
        XCTAssertTrue(surfaces.contains("သာ\u{104B}"),
                      "expected ‘သာ။’ candidate, got \(surfaces)")
        XCTAssertFalse(surfaces.contains(where: { $0.hasSuffix(".") }),
                       "raw ASCII dot leaked into surface: \(surfaces)")
    }

    func testTrailingComma_mapsToU104A() {
        let settings = IMESettings(suiteName: suiteName)
        settings.burmesePunctuationEnabled = true
        let engine = BurmeseEngine(settings: settings)

        let state = engine.update(buffer: "thar,", context: [])
        let surfaces = state.candidates.map(\.surface)
        XCTAssertTrue(surfaces.contains("သာ\u{104A}"),
                      "expected ‘သာ၊’ candidate, got \(surfaces)")
    }

    func testTrailingDot_stayLiteral_whenDisabled() {
        let settings = IMESettings(suiteName: suiteName)
        settings.burmesePunctuationEnabled = false
        let engine = BurmeseEngine(settings: settings)

        let state = engine.update(buffer: "thar.", context: [])
        let surfaces = state.candidates.map(\.surface)
        XCTAssertTrue(surfaces.contains(where: { $0.hasSuffix(".") }),
                      "expected a candidate ending in literal '.', got \(surfaces)")
        XCTAssertFalse(surfaces.contains(where: { $0.hasSuffix("\u{104B}") }),
                       "burmese punct leaked through with feature off: \(surfaces)")
    }

    func testRawBuffer_unchanged_evenWhenMappingApplied() {
        let settings = IMESettings(suiteName: suiteName)
        settings.burmesePunctuationEnabled = true
        let engine = BurmeseEngine(settings: settings)

        let state = engine.update(buffer: "thar.", context: [])
        XCTAssertEqual(state.rawBuffer, "thar.",
                       "raw buffer should reflect the user's keystrokes verbatim")
    }

    func testDigitsWithTrailingDot_mapTailWhenEnabled() {
        let settings = IMESettings(suiteName: suiteName)
        settings.burmesePunctuationEnabled = true
        let engine = BurmeseEngine(settings: settings)

        let state = engine.update(buffer: "123.", context: [])
        let surfaces = state.candidates.map(\.surface)
        XCTAssertTrue(surfaces.contains("၁၂၃\u{104B}"),
                      "expected ‘၁၂၃။’ for digit buffer with trailing dot, got \(surfaces)")
    }

    /// Regression: when mapped punctuation is *embedded* in the buffer,
    /// composable characters on the far side still need to be converted.
    /// Before this fix everything past the first non-composing char was
    /// treated as inert literal tail, so `thar,myat` produced `သာ၊myat`.
    func testComposableAfterComma_getsParsed() {
        let settings = IMESettings(suiteName: suiteName)
        settings.burmesePunctuationEnabled = true
        let engine = BurmeseEngine(settings: settings)

        let state = engine.update(buffer: "thar,myat", context: [])
        let surfaces = state.candidates.map(\.surface)
        XCTAssertTrue(surfaces.contains("သာ\u{104A}မြတ်"),
                      "expected ‘သာ၊မြတ်’ (both segments converted), got \(surfaces)")
        XCTAssertFalse(surfaces.contains(where: { $0.contains("myat") }),
                       "raw roman should not leak into any candidate surface: \(surfaces)")
    }

    func testComposableAfterDot_getsParsed() {
        let settings = IMESettings(suiteName: suiteName)
        settings.burmesePunctuationEnabled = true
        let engine = BurmeseEngine(settings: settings)

        let state = engine.update(buffer: "thar.myat", context: [])
        let surfaces = state.candidates.map(\.surface)
        XCTAssertTrue(surfaces.contains("သာ\u{104B}မြတ်"),
                      "expected ‘သာ။မြတ်’, got \(surfaces)")
    }

    func testComposableBetweenTwoPuncts_getsParsed() {
        let settings = IMESettings(suiteName: suiteName)
        settings.burmesePunctuationEnabled = true
        let engine = BurmeseEngine(settings: settings)

        let state = engine.update(buffer: "thar,myat.", context: [])
        let surfaces = state.candidates.map(\.surface)
        XCTAssertTrue(surfaces.contains("သာ\u{104A}မြတ်\u{104B}"),
                      "expected three-segment render ‘သာ၊မြတ်။’, got \(surfaces)")
    }
}
