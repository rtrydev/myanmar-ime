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

    func testCandidates_aaShapeMatchesOnsetDescender() {
        // Grammar filtering: each candidate's aa sign is auto-corrected to
        // match the preceding consonant's descender requirement. Descender
        // onsets (ပ, ခ, ဂ, င, ဒ, ဝ) take tall ါ (U+102B); others take
        // short ာ (U+102C). Wrong-shape siblings are never emitted.
        let par = engine.update(buffer: "par", context: [])
        XCTAssertTrue(par.candidates.contains { $0.surface.contains("\u{102B}") })
        XCTAssertFalse(par.candidates.contains { $0.surface.contains("\u{102C}") })

        let thar = engine.update(buffer: "thar", context: [])
        XCTAssertTrue(thar.candidates.contains { $0.surface.contains("\u{102C}") })
        XCTAssertFalse(thar.candidates.contains { $0.surface.contains("\u{102B}") })
    }

    // MARK: - Grammar Filtering

    func testGrammarFilter_retroflexDiphthongRejected() {
        // Retroflex Pali onset ဋ (t2) never combines with native-Burmese
        // "ote" final in real orthography; the illegal parse must not win.
        let state = engine.update(buffer: "t2ote", context: [])
        XCTAssertFalse(state.candidates.contains { $0.surface == "ဋောက်" || $0.surface.contains("\u{1031}\u{102C}\u{1000}\u{103A}") && $0.surface.hasPrefix("ဋ") })
    }

    func testGrammarFilter_medialHaPlusLongI_rejected() {
        // Medial ha-htoe (ှ) + long-i (ီ) is not used in modern orthography.
        // Parse falls back to a shorter legal prefix + literal tail.
        let state = engine.update(buffer: "hki:", context: [])
        XCTAssertFalse(state.candidates.contains { $0.surface.contains("\u{103E}") && $0.surface.contains("\u{102E}") })
    }

    func testCommit_digitIsLiteral() {
        // Digits are never consumed as vowel-variant disambiguators; "thar2"
        // commits as သာ followed by the literal "2".
        let state = engine.update(buffer: "thar2", context: [])
        XCTAssertEqual(engine.commit(state: state), "သာ2")
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

    func testCandidates_longerInputPreservesTallAaAfterDescender() {
        // "mingalarpar" ends on ပ (descender → requires tall ါ). After
        // grammar filtering, the visible surface must carry ါ, not ာ, even
        // though the buffer uses the no-digit "ar" form.
        let engine = BurmeseEngine(candidateStore: ComposeKeyCandidateStore())
        let state = engine.update(buffer: "mingalarpar", context: [])

        XCTAssertTrue(
            state.candidates.contains(where: { $0.source == .grammar && $0.surface.hasSuffix("ပါ") })
        )
        XCTAssertFalse(
            state.candidates.contains(where: { $0.surface.hasSuffix("ပာ") })
        )
    }

    // MARK: - Unconvertible Tail Preservation

    func testCommit_preservesTrailingDigits() {
        let state = engine.update(buffer: "min:123", context: [])
        let committed = engine.commit(state: state)
        XCTAssertTrue(committed.hasSuffix("123"), "Expected '123' to be preserved, got '\(committed)'")
        XCTAssertTrue(committed.hasPrefix("မင်း"), "Expected မင်း prefix, got '\(committed)'")
    }

    func testUpdate_candidatesIncludeTrailingDigits() {
        let state = engine.update(buffer: "thar123", context: [])
        XCTAssertFalse(state.candidates.isEmpty)
        for candidate in state.candidates {
            XCTAssertTrue(
                candidate.surface.hasSuffix("123"),
                "Candidate '\(candidate.surface)' should end with literal tail '123'"
            )
        }
    }

    func testCommit_preservesNonComposingTail() {
        // Punctuation outside the composing set is split off by the existing
        // literalTail path; verify the combined behavior still works.
        let state = engine.update(buffer: "thar!", context: [])
        let committed = engine.commit(state: state)
        XCTAssertTrue(committed.hasSuffix("!"), "Expected '!' preserved, got '\(committed)'")
    }

    func testCommit_preservesMixedDigitAndPunctuationTail() {
        let state = engine.update(buffer: "min:123!", context: [])
        let committed = engine.commit(state: state)
        XCTAssertTrue(committed.hasSuffix("123!"), "Expected '123!' preserved, got '\(committed)'")
    }

    func testCommit_standaloneTallAa_splitsAsLiteralTail() {
        let state = engine.update(buffer: "ar2", context: [])
        let committed = engine.commit(state: state)
        XCTAssertTrue(committed.hasSuffix("2"), "Expected '2' suffix, got '\(committed)'")
        XCTAssertFalse(committed.contains("\u{102B}"), "Should not contain ါ, got '\(committed)'")
        XCTAssertTrue(committed.contains("\u{102C}"), "Should contain ာ, got '\(committed)'")
    }

    func testUpdate_pureUnconvertibleBuffer_yieldsRawCommit() {
        let state = engine.update(buffer: "123", context: [])
        XCTAssertTrue(state.isActive)
        XCTAssertTrue(state.candidates.isEmpty)
        XCTAssertEqual(engine.commit(state: state), "123")
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
