import XCTest
@testable import BurmeseIMECore

/// Tests for the reverse romanizer (Myanmar → roman reading).
final class ReverseRomanizerTests: XCTestCase {

    // MARK: - Consonant + Medial Combinations

    func testReverse_ky() {
        XCTAssertEqual(ReverseRomanizer.romanize("ကြ"), "kya")
    }

    func testReverse_ky2() {
        XCTAssertEqual(ReverseRomanizer.romanize("ကျ"), "ky2a")
    }

    func testReverse_kw() {
        XCTAssertEqual(ReverseRomanizer.romanize("ကွ"), "kwa")
    }

    func testReverse_hk() {
        XCTAssertEqual(ReverseRomanizer.romanize("ကှ"), "hka")
    }

    func testReverse_hkwy2() {
        XCTAssertEqual(ReverseRomanizer.romanize("ကျွှ"), "hkwy2a")
    }

    // MARK: - Consonant + Vowel

    func testReverse_par() {
        XCTAssertEqual(ReverseRomanizer.romanize("ပာ"), "par")
    }

    func testReverse_thar() {
        XCTAssertEqual(ReverseRomanizer.romanize("သာ"), "thar")
    }

    func testReverse_kyaw() {
        XCTAssertEqual(ReverseRomanizer.romanize("ကြော်"), "kyaw")
    }

    // MARK: - Independent Vowels

    func testReverse_ay2() {
        XCTAssertEqual(ReverseRomanizer.romanize("ဧ"), "ay2")
    }

    func testReverse_u2_colon() {
        XCTAssertEqual(ReverseRomanizer.romanize("ဦး"), "u2:")
    }

    // MARK: - Multi-syllable with Stacking

    func testReverse_minGalarPar2() {
        XCTAssertEqual(ReverseRomanizer.romanize("မင်္ဂလာပါ"), "min+galarpar2")
    }

    // MARK: - Round-trip Stability

    func testRoundTrip_thar() {
        let parser = SyllableParser()
        let forward = parser.parse("thar").first?.output ?? ""
        let reversed = ReverseRomanizer.romanize(forward)
        let roundTrip = parser.parse(reversed).first?.output ?? ""
        XCTAssertEqual(forward, roundTrip)
    }

    func testRoundTrip_kyaw() {
        let parser = SyllableParser()
        let forward = parser.parse("kyaw").first?.output ?? ""
        let reversed = ReverseRomanizer.romanize(forward)
        let roundTrip = parser.parse(reversed).first?.output ?? ""
        XCTAssertEqual(forward, roundTrip)
    }

    func testRoundTrip_minGalarPar2() {
        let parser = SyllableParser()
        let forward = parser.parse("min+galarpar2").first?.output ?? ""
        let reversed = ReverseRomanizer.romanize(forward)
        let roundTrip = parser.parse(reversed).first?.output ?? ""
        XCTAssertEqual(forward, roundTrip)
    }
}
