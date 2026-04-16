import XCTest
@testable import BurmeseIMECore

final class NumberMeasureWordsTests: XCTestCase {

    // MARK: - Pattern predicates

    func testPatternMatching_year4digit() {
        XCTAssertTrue(NumberMeasureWords.Pattern.year4digit.matches("2024"))
        XCTAssertTrue(NumberMeasureWords.Pattern.year4digit.matches("1999"))
        XCTAssertFalse(NumberMeasureWords.Pattern.year4digit.matches("0999"))
        XCTAssertFalse(NumberMeasureWords.Pattern.year4digit.matches("24"))
        XCTAssertFalse(NumberMeasureWords.Pattern.year4digit.matches("20240"))
    }

    func testPatternMatching_currencyGe100() {
        XCTAssertTrue(NumberMeasureWords.Pattern.currencyGe100.matches("100"))
        XCTAssertTrue(NumberMeasureWords.Pattern.currencyGe100.matches("1000"))
        XCTAssertFalse(NumberMeasureWords.Pattern.currencyGe100.matches("99"))
        XCTAssertFalse(NumberMeasureWords.Pattern.currencyGe100.matches("5"))
    }

    func testPatternMatching_hourRange() {
        XCTAssertTrue(NumberMeasureWords.Pattern.hourGe1Le24.matches("1"))
        XCTAssertTrue(NumberMeasureWords.Pattern.hourGe1Le24.matches("24"))
        XCTAssertFalse(NumberMeasureWords.Pattern.hourGe1Le24.matches("0"))
        XCTAssertFalse(NumberMeasureWords.Pattern.hourGe1Le24.matches("25"))
    }

    func testPatternMatching_any() {
        XCTAssertTrue(NumberMeasureWords.Pattern.any.matches("0"))
        XCTAssertTrue(NumberMeasureWords.Pattern.any.matches("999999"))
    }

    // MARK: - Loading & selection (via Bundle.module)

    func testCandidates_year_returnsYearPattern() {
        let picks = NumberMeasureWords.shared
            .candidates(forDigits: "2024", limit: 5)
            .map(\.measureWord)
        XCTAssertTrue(picks.contains("ခုနှစ်"),
                      "expected year suffix ခုနှစ် in \(picks)")
    }

    func testCandidates_smallNumber_excludesYearAndCurrency() {
        let picks = NumberMeasureWords.shared
            .candidates(forDigits: "5", limit: 5)
            .map(\.measureWord)
        XCTAssertFalse(picks.contains("ခုနှစ်"),
                       "year suffix should not apply to '5'")
        XCTAssertFalse(picks.contains("ကျပ်"),
                       "currency suffix should not apply to '5'")
        XCTAssertTrue(picks.contains("ခု"),
                      "'any' pattern entries should apply to '5'")
    }

    func testCandidates_largeNumber_includesCurrency() {
        let picks = NumberMeasureWords.shared
            .candidates(forDigits: "1000", limit: 5)
            .map(\.measureWord)
        XCTAssertTrue(picks.contains("ကျပ်"),
                      "expected currency suffix for 1000, got \(picks)")
    }

    func testCandidates_honorsLimit() {
        let picks = NumberMeasureWords.shared
            .candidates(forDigits: "2024", limit: 2)
        XCTAssertLessThanOrEqual(picks.count, 2)
    }

    func testCandidates_sortedByScoreDescending() {
        let picks = NumberMeasureWords.shared
            .candidates(forDigits: "2024", limit: 10)
        guard picks.count >= 2 else { return }
        for i in 1..<picks.count {
            XCTAssertGreaterThanOrEqual(picks[i - 1].score, picks[i].score)
        }
    }

    func testCandidates_nonDigitInput_empty() {
        XCTAssertTrue(NumberMeasureWords.shared.candidates(forDigits: "", limit: 2).isEmpty)
        XCTAssertTrue(NumberMeasureWords.shared.candidates(forDigits: "12a", limit: 2).isEmpty)
    }

    func testCandidates_zeroLimit_empty() {
        XCTAssertTrue(NumberMeasureWords.shared.candidates(forDigits: "100", limit: 0).isEmpty)
    }

    // MARK: - Missing-resource fallback

    func testCandidates_missingBundleResource_emptyList() {
        // Bundle.main has no NumberMeasureWords.tsv; loader should gracefully
        // return an empty list instead of crashing.
        let loader = NumberMeasureWords(
            bundle: .main,
            resourceName: "NumberMeasureWords-does-not-exist",
            resourceExtension: "tsv"
        )
        XCTAssertEqual(loader.candidates(forDigits: "2024", limit: 5), [])
    }
}
