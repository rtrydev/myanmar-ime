import XCTest
@testable import BurmeseIMECore

final class PunctuationMapperTests: XCTestCase {

    func testMapped_sentenceTerminators_foldToU104B() {
        XCTAssertEqual(PunctuationMapper.mapped("."), "\u{104B}")
        XCTAssertEqual(PunctuationMapper.mapped("!"), "\u{104B}")
        XCTAssertEqual(PunctuationMapper.mapped("?"), "\u{104B}")
    }

    func testMapped_phraseSeparators_foldToU104A() {
        XCTAssertEqual(PunctuationMapper.mapped(","), "\u{104A}")
        XCTAssertEqual(PunctuationMapper.mapped(";"), "\u{104A}")
    }

    func testMapped_unmappedCharsReturnNil() {
        XCTAssertNil(PunctuationMapper.mapped(":"))
        XCTAssertNil(PunctuationMapper.mapped("a"))
        XCTAssertNil(PunctuationMapper.mapped("1"))
        XCTAssertNil(PunctuationMapper.mapped(" "))
    }

    func testIsMappable_matchesMappedSet() {
        for c in [".", "!", "?", ",", ";"] as [Character] {
            XCTAssertTrue(PunctuationMapper.isMappable(c), "\(c) should be mappable")
        }
        XCTAssertFalse(PunctuationMapper.isMappable(":"))
        XCTAssertFalse(PunctuationMapper.isMappable("a"))
    }

    func testIsMyanmar_detectsMyanmarScript() {
        XCTAssertTrue(PunctuationMapper.isMyanmar("ဟယ်လို"))
        XCTAssertTrue(PunctuationMapper.isMyanmar("hello ဟယ်လို"))
        XCTAssertTrue(PunctuationMapper.isMyanmar("\u{1040}")) // ၀ Myanmar digit
    }

    func testIsMyanmar_rejectsAsciiAndEmpty() {
        XCTAssertFalse(PunctuationMapper.isMyanmar(""))
        XCTAssertFalse(PunctuationMapper.isMyanmar("hello"))
        XCTAssertFalse(PunctuationMapper.isMyanmar("e.g."))
        XCTAssertFalse(PunctuationMapper.isMyanmar("1234"))
    }
}
