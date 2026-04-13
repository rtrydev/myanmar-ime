import XCTest
@testable import BurmeseIMECore

/// Tests for the Burmese grammar legality tables.
final class GrammarTests: XCTestCase {

    // MARK: - Medial Legality

    func testMedialRa_ka_isLegal() {
        XCTAssertTrue(Grammar.canConsonantTakeMedial(Myanmar.ka, Myanmar.medialRa))
    }

    func testMedialYa_ka_isLegal() {
        XCTAssertTrue(Grammar.canConsonantTakeMedial(Myanmar.ka, Myanmar.medialYa))
    }

    func testMedialWa_ka_isLegal() {
        XCTAssertTrue(Grammar.canConsonantTakeMedial(Myanmar.ka, Myanmar.medialWa))
    }

    func testMedialHa_ka_isLegal() {
        XCTAssertTrue(Grammar.canConsonantTakeMedial(Myanmar.ka, Myanmar.medialHa))
    }

    func testMedialRa_nga_isIllegal() {
        XCTAssertFalse(Grammar.canConsonantTakeMedial(Myanmar.nga, Myanmar.medialRa))
    }

    func testMedialCombination_count() {
        XCTAssertEqual(Grammar.medialCombinations.count, 11)
    }

    // MARK: - Syllable Validation

    func testValidateSyllable_ka_noMedials_ar() {
        let score = Grammar.validateSyllable(onset: Myanmar.ka, medials: [], vowelRoman: "ar")
        XCTAssertGreaterThan(score, 0)
    }

    func testValidateSyllable_noOnset_standalone() {
        let score = Grammar.validateSyllable(onset: nil, medials: [], vowelRoman: "ay2")
        XCTAssertGreaterThan(score, 0)
    }

    func testValidateSyllable_noOnset_nonStandalone_lowPriority() {
        // Dependent vowels without onset are legal but low-priority (score=10)
        // so they work standalone with U+200C prefix but lose to onset+vowel paths
        let score = Grammar.validateSyllable(onset: nil, medials: [], vowelRoman: "ar")
        XCTAssertGreaterThan(score, 0)
        XCTAssertLessThan(score, 100)
    }
}
