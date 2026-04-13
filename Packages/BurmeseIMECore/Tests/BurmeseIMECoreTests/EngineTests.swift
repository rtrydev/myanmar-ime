import XCTest
@testable import BurmeseIMECore

/// Tests for the BurmeseEngine public API.
final class EngineTests: XCTestCase {

    let engine = BurmeseEngine()

    // MARK: - Basic Update/Commit Cycle

    func testUpdate_emptyBuffer_returnsInactive() {
        let state = engine.update(buffer: "", context: [])
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.candidates.isEmpty)
    }

    func testUpdate_singleConsonant_returnsCandidates() {
        let state = engine.update(buffer: "k", context: [])
        XCTAssertTrue(state.isActive)
        XCTAssertFalse(state.candidates.isEmpty)
    }

    func testCommit_returnsSelectedSurface() {
        let state = engine.update(buffer: "thar", context: [])
        let committed = engine.commit(state: state)
        XCTAssertEqual(committed, "သာ")
    }

    func testCancel_returnsRawBuffer() {
        let state = engine.update(buffer: "thar", context: [])
        let cancelled = engine.cancel(state: state)
        XCTAssertEqual(cancelled, "thar")
    }

    func testUpdate_normalizes_uppercase() {
        let state = engine.update(buffer: "THAR", context: [])
        XCTAssertEqual(state.rawBuffer, "thar")
    }

    // MARK: - Candidate Ranking

    func testCandidates_grammarFirst() {
        let state = engine.update(buffer: "thar", context: [])
        guard let first = state.candidates.first else {
            XCTFail("Expected at least one candidate")
            return
        }
        XCTAssertEqual(first.source, .grammar)
    }

    func testCandidates_maxPageSize() {
        let state = engine.update(buffer: "k", context: [])
        XCTAssertLessThanOrEqual(state.candidates.count, BurmeseEngine.candidatePageSize)
    }

    // MARK: - Composition State Properties

    func testCompositionState_selectedIndex_startsAtZero() {
        let state = engine.update(buffer: "thar", context: [])
        XCTAssertEqual(state.selectedCandidateIndex, 0)
    }

    func testCompositionState_rawBuffer_normalized() {
        let state = engine.update(buffer: "TH+ar", context: [])
        XCTAssertEqual(state.rawBuffer, "th+ar")
    }
}
