import XCTest
@testable import BurmeseIMECore

/// Tests for romanization mappings and normalization.
final class RomanizationTests: XCTestCase {

    // MARK: - Consonant Mappings

    func testConsonantCount() {
        XCTAssertEqual(Romanization.consonants.count, 33)
    }

    func testConsonantRoundTrip() {
        let romans = Romanization.consonants.map(\.roman)
        let uniqueRomans = Set(romans)
        XCTAssertEqual(romans.count, uniqueRomans.count, "Duplicate roman keys in consonant table")
    }

    func testConsonantLookup_ka() {
        XCTAssertEqual(Romanization.romanToConsonant["k"], Myanmar.ka)
    }

    func testConsonantLookup_tha() {
        XCTAssertEqual(Romanization.romanToConsonant["th"], Myanmar.sa)  // သ
    }

    func testConsonantReverse_ka() {
        XCTAssertEqual(Romanization.consonantToRoman[Myanmar.ka], "k")
    }

    // MARK: - Vowel Mappings

    func testVowelKeysSortedByLength() {
        let keys = Romanization.vowelKeysByLength
        XCTAssertGreaterThan(keys.count, 0)
        for i in 1..<keys.count {
            XCTAssertGreaterThanOrEqual(keys[i-1].count, keys[i].count,
                    "Keys should be sorted by descending length")
        }
    }

    func testVowelLookup_ar() {
        let entry = Romanization.romanToVowel["ar"]
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.myanmar, "\u{102C}")  // ာ
    }

    func testVowelLookup_virama() {
        let entry = Romanization.romanToVowel["+"]
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.myanmar, "\u{1039}")  // ္
    }

    // MARK: - Normalization

    func testNormalize_lowercase() {
        XCTAssertEqual(Romanization.normalize("ABC"), "abc")
    }

    func testNormalize_keepsDigits() {
        XCTAssertEqual(Romanization.normalize("thar2"), "thar2")
    }

    func testNormalize_keepsSpecials() {
        XCTAssertEqual(Romanization.normalize("min+galar"), "min+galar")
    }

    func testNormalize_stripsInvalid() {
        XCTAssertEqual(Romanization.normalize("hello!@#"), "hello")
    }

    func testAliasReading_stripsNumericMarkers() {
        XCTAssertEqual(Romanization.aliasReading("ky2ar3"), "kyar")
    }

    func testAliasReading_keepsOtherCharacters() {
        XCTAssertEqual(Romanization.aliasReading("u2:+"), "u:+")
    }

    func testComposeLookupKey_stripsDigitsAndSeparators() {
        XCTAssertEqual(Romanization.composeLookupKey("min+galarpar2"), "mingalarpar")
    }

    func testComposeSeparatorPenaltyCount_countsOptionalSeparators() {
        XCTAssertEqual(Romanization.composeSeparatorPenaltyCount(for: "min+'galar"), 2)
    }

    // MARK: - Composing Characters

    func testComposingCharacters_containsExpected() {
        let expected: [Character] = Array("abcdefghijklmnopqrstuvwxyz0123456789+*':.")
        for ch in expected {
            XCTAssertTrue(Romanization.composingCharacters.contains(ch), "Missing composing character: \(ch)")
        }
    }

    func testComposingCharacters_excludesSpecials() {
        let excluded: [Character] = ["!", "@", "#", "$", "%", " ", "\n"]
        for ch in excluded {
            XCTAssertFalse(Romanization.composingCharacters.contains(ch), "Should not be a composing character: \(ch)")
        }
    }
}
