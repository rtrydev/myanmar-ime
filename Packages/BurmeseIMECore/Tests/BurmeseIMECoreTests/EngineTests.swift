import XCTest
@testable import BurmeseIMECore

/// Tests for the BurmeseEngine public API.
final class EngineTests: XCTestCase {

    let engine = BurmeseEngine()

    struct PrefixCandidateStore: CandidateStore {
        func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
            guard prefix == "kyar" else { return [] }
            return [
                Candidate(surface: "ကြား", reading: "kyar:", source: .lexicon, score: 950),
                Candidate(surface: "ကျား", reading: "ky2ar:", source: .lexicon, score: 900),
            ]
        }
    }

    struct ExactAliasCandidateStore: CandidateStore {
        func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
            guard prefix == "min+galarpar" else { return [] }
            return [
                Candidate(surface: "မင်္ဂလာပါ", reading: "min+galarpar2", source: .lexicon, score: 1000),
                Candidate(surface: "မင်္ဂလာပါတော်", reading: "min+galarpartaw", source: .lexicon, score: 900),
            ]
        }
    }

    struct ComposeKeyCandidateStore: CandidateStore {
        func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
            guard prefix == "mingalarpar" else { return [] }
            return [
                Candidate(surface: "မင်္ဂလာပါ", reading: "min+galarpar2", source: .lexicon, score: 1000),
            ]
        }
    }

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

    func testCandidates_mixedGrammarAndLexicon() {
        let engine = BurmeseEngine(candidateStore: PrefixCandidateStore())
        let state = engine.update(buffer: "kyar", context: [])

        XCTAssertFalse(state.candidates.isEmpty)
        XCTAssertEqual(state.candidates.first?.source, .grammar)
        XCTAssertTrue(state.candidates.contains(where: { $0.surface == "ကြား" && $0.source == .lexicon }))
        XCTAssertTrue(state.candidates.contains(where: { $0.surface == "ကျား" && $0.source == .lexicon }))
    }

    func testCandidates_exactAliasLexiconPrioritized() {
        let engine = BurmeseEngine(candidateStore: ExactAliasCandidateStore())
        let state = engine.update(buffer: "min+galarpar", context: [])

        XCTAssertEqual(state.candidates.first?.surface, "မင်္ဂလာပါ")
        XCTAssertEqual(state.candidates.first?.source, .lexicon)
        XCTAssertTrue(state.candidates.contains(where: { $0.source == .grammar }))
    }

    func testCandidates_aaFormFilteredByGrammar() {
        // သ does not require tall aa → short aa (thar) is legal, tall aa (thar2) is not
        let state = engine.update(buffer: "thar", context: [])
        XCTAssertTrue(state.candidates.contains(where: { $0.reading == "thar" }))
        XCTAssertFalse(state.candidates.contains(where: { $0.reading == "thar2" }))

        // ပ requires tall aa → tall aa (par2) is legal, short aa (par) is not
        let state2 = engine.update(buffer: "par", context: [])
        XCTAssertTrue(state2.candidates.contains(where: { $0.reading == "par2" }))
        XCTAssertFalse(state2.candidates.contains(where: { $0.reading == "par" }))
    }

    func testCandidates_consonantFormRanksAheadOfMedialFallback() {
        let state = engine.update(buffer: "hsa", context: [])
        XCTAssertEqual(state.candidates.first?.surface, "ဆ")
    }

    func testCandidates_composeMatchPrioritizedWhenSeparatorOmitted() {
        let engine = BurmeseEngine(candidateStore: ComposeKeyCandidateStore())
        let state = engine.update(buffer: "mingalarpar", context: [])

        XCTAssertEqual(state.candidates.first?.surface, "မင်္ဂလာပါ")
        XCTAssertEqual(state.candidates.first?.source, .lexicon)
    }

    func testCandidates_longerInputKeepsTerminalNumericAlternateVisible() {
        let engine = BurmeseEngine(candidateStore: ComposeKeyCandidateStore())
        let state = engine.update(buffer: "mingalarpar", context: [])

        XCTAssertTrue(
            state.candidates.contains(where: { $0.source == .grammar && $0.reading.hasSuffix("par2") })
        )
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
