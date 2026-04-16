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

    // MARK: - Prefix Stability

    func testUpdate_longerBufferPreservesPreviouslyRenderedPrefix() {
        // Screenshot bug: after the user typed `kwyantaw` and saw the top
        // candidate ကျွန်တော်, typing more characters ("kwyantawkahtamin")
        // re-parsed the whole buffer and changed the rendering of the
        // already-typed portion to ကွျန်တော်. Once a prefix has been
        // rendered and seen by the user, it must stay stable as they
        // extend the buffer forward.
        let engine = BurmeseEngine()
        let short = engine.update(buffer: "kwyantaw", context: [])
        guard let shortTop = short.candidates.first?.surface else {
            XCTFail("no candidate for 'kwyantaw'")
            return
        }
        let longer = engine.update(buffer: "kwyantawkahtamin", context: [])
        guard let longerTop = longer.candidates.first?.surface else {
            XCTFail("no candidate for longer buffer")
            return
        }
        XCTAssertTrue(
            longerTop.hasPrefix(shortTop),
            "prefix drift: longer-buffer top '\(longerTop)' should start with '\(shortTop)'"
        )
    }

    // MARK: - Progressive Typing Correctness

    func testProgressiveTyping_mingalarpar_producesCorrectOutput() {
        // Bug: typing "min+galarpar" letter by letter, the anchor mechanism
        // commits "min+gala" (8 chars) as မင်္ဂလ, then "r" is parsed as
        // standalone onset ရ instead of vowel suffix "ar" → ာ on the
        // previous syllable. Expected: မင်္ဂလာပါ (with tall aa on pa).
        let engine = BurmeseEngine()
        let keystrokes = Array("min+galarpar")
        var buffer = ""
        for ch in keystrokes {
            buffer.append(ch)
            _ = engine.update(buffer: buffer, context: [])
        }
        let finalState = engine.update(buffer: "min+galarpar", context: [])
        let top = finalState.candidates.first?.surface ?? ""
        // Strip ZWSP/ZWNJ for comparison
        let stripped = String(top.unicodeScalars.filter {
            $0.value != 0x200B && $0.value != 0x200C
        })
        XCTAssertEqual(stripped, "မင်္ဂလာပါ",
            "Progressive typing 'min+galarpar' should produce မင်္ဂလာပါ, got \(top)")
    }

    func testProgressiveTyping_kwyantawkahtamin_producesCorrectSuffix() {
        // Bug: typing "kwyantawkahtamin" letter by letter, the anchor locks
        // in wrong syllable boundaries. "kah" gets committed as ကဟ (ka+ha)
        // when it should later become ka + hta (ကထ). "mi" gets locked as
        // မီ when it should become min (မင်).
        // The suffix "kahtamin" must parse as ကထမင် regardless of the
        // ya-pin/ya-yit choice in the prefix (LM-dependent).
        let engine = BurmeseEngine()
        let keystrokes = Array("kwyantawkahtamin")
        var buffer = ""
        for ch in keystrokes {
            buffer.append(ch)
            _ = engine.update(buffer: buffer, context: [])
        }
        let finalState = engine.update(buffer: "kwyantawkahtamin", context: [])
        let top = finalState.candidates.first?.surface ?? ""
        let stripped = String(top.unicodeScalars.filter {
            $0.value != 0x200B && $0.value != 0x200C
        })
        XCTAssertTrue(stripped.hasSuffix("ကထမင်"),
            "Progressive typing suffix should be ကထမင်, got \(top)")
    }

    // MARK: - Long Input Multi-Character Onset

    func testProgressiveTyping_longInput_thaNotSplitAsTaHa() {
        // Bug: in long progressive inputs, "tha" (which should produce သ)
        // was split as ta+ha (တ+ဟ) because the anchor boundary cut the
        // multi-character onset "th" across the frozen prefix and the tail.
        let engine = BurmeseEngine()
        let input = "kwyantawkahtamin:masar:rathar"
        var buffer = ""
        for ch in Array(input) {
            buffer.append(ch)
            _ = engine.update(buffer: buffer, context: [])
        }
        let state = engine.update(buffer: input, context: [])
        let top = state.candidates.first?.surface ?? ""
        let stripped = String(top.unicodeScalars.filter {
            $0.value != 0x200B && $0.value != 0x200C
        })
        XCTAssertFalse(stripped.contains("တဟ"),
            "Found တဟ (ta+ha) split, expected သ (tha). Got: \(stripped)")
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
