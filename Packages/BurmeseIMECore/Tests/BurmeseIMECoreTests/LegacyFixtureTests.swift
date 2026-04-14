import XCTest
@testable import BurmeseIMECore

/// Tests encoding the legacy web fixture corpus from IMPLEMENTATION_PLAN.md.
/// These verify that the native engine produces the correct Burmese output
/// for known-good inputs, and intentionally diverges from known-bad legacy behavior.
final class LegacyFixtureTests: XCTestCase {

    let parser = SyllableParser()
    let engine = BurmeseEngine()

    /// Parse input and return the best output, or empty string if no parse.
    func parse(_ input: String) -> String {
        let parses = parser.parse(input)
        return parses.first?.output ?? ""
    }

    // MARK: - Known-Good Legacy Conversions

    func testKnownGood_thar() {
        XCTAssertEqual(parse("thar"), "သာ")
    }

    func testKnownGood_thar2() {
        XCTAssertEqual(parse("thar2"), "သါ")
    }

    func testKnownGood_kyaw() {
        XCTAssertEqual(parse("kyaw"), "ကြော်")
    }

    func testKnownGood_kyaw2() {
        XCTAssertEqual(parse("kyaw2"), "ကြေါ်")
    }

    func testKnownGood_minGalarPar2() {
        XCTAssertEqual(parse("min+galarpar2"), "မင်္ဂလာပါ")
    }

    func testKnownGood_ahinGar2GyoHStar() {
        XCTAssertEqual(parse("ahin+gar2gyoh*"), "အင်္ဂါဂြိုဟ်")
    }

    func testKnownGood_shanNoodles() {
        XCTAssertEqual(parse("hran2:khout2hswe:"), "ရှမ်းခေါက်ဆွဲ")
    }

    func testKnownGood_choose() {
        XCTAssertEqual(parse("rway:khy2e"), "ရွေးချယ်")
    }

    func testParseCandidates_thar_includesNumericAlternate() {
        let parses = parser.parseCandidates("thar")
        XCTAssertTrue(parses.contains(where: { $0.output == "သာ" && $0.reading == "thar" }))
        XCTAssertTrue(parses.contains(where: { $0.output == "သါ" && $0.reading == "thar2" }))
    }

    func testParseCandidates_kyar_includesNumericAlternate() {
        let parses = parser.parseCandidates("kyar")
        XCTAssertTrue(parses.contains(where: { $0.reading == "kyar" }))
        XCTAssertTrue(parses.contains(where: { $0.reading == "ky2ar" }))
    }

    // MARK: - Additional Legacy Fixtures

    func testMingalarpar2_noLatinLeakage() {
        // Without explicit '+', common phrase parses differently — verify no Latin leakage
        let result = parse("mingalarpar2")
        for scalar in result.unicodeScalars {
            XCTAssertTrue(
                Myanmar.isMyanmar(scalar) || scalar.value == 0x200C,
                "Output should not contain non-Myanmar characters, found: U+\(String(scalar.value, radix: 16))"
            )
        }
    }

    func testNay2_noLatinLeakage() {
        // Legacy engine produces "နဧ" — numeric alternate over-applies
        let result = parse("nay2")
        for scalar in result.unicodeScalars {
            XCTAssertTrue(
                Myanmar.isMyanmar(scalar) || scalar.value == 0x200C,
                "Output should not contain non-Myanmar characters, found: U+\(String(scalar.value, radix: 16))"
            )
        }
    }

    // MARK: - Known-Bad Legacy Conversions (Divergence)
    // The native engine must never produce mixed-script output.

    func testKnownBad_par_noIllegalMixedScript() {
        let result = parse("par")
        for scalar in result.unicodeScalars {
            XCTAssertTrue(
                Myanmar.isMyanmar(scalar) || scalar.value == 0x200C,
                "Output should not contain non-Myanmar characters, found: U+\(String(scalar.value, radix: 16))"
            )
        }
    }

    func testKnownBad_kya2_noLatinLeakage() {
        let result = parse("kya2")
        for scalar in result.unicodeScalars {
            let isOk = Myanmar.isMyanmar(scalar) || scalar.value == 0x200C
            XCTAssertTrue(isOk, "Output should not contain latin characters, found: U+\(String(scalar.value, radix: 16))")
        }
    }

    func testKnownBad_foo_noMixedScript() {
        let result = parse("foo")
        let hasMyanmarChar = result.unicodeScalars.contains { Myanmar.isMyanmar($0) }
        let hasLatinChar = result.unicodeScalars.contains { (0x41...0x7A).contains($0.value) }
        XCTAssertFalse(
            hasMyanmarChar && hasLatinChar,
            "Mixed script output is illegal: \(result)"
        )
    }

    func testKnownBad_abc_noMixedScript() {
        let result = parse("abc")
        let hasMyanmarChar = result.unicodeScalars.contains { Myanmar.isMyanmar($0) }
        let hasLatinChar = result.unicodeScalars.contains { (0x41...0x7A).contains($0.value) }
        XCTAssertFalse(
            hasMyanmarChar && hasLatinChar,
            "Mixed script output is illegal: \(result)"
        )
    }

    // MARK: - Leading-Vowel / U+200C Fixtures

    func testLeadingVowel_u() {
        XCTAssertEqual(parse("u"), "\u{200C}\u{1030}")
    }

    func testLeadingVowel_ay() {
        XCTAssertEqual(parse("ay"), "\u{200C}\u{1031}")
    }

    func testLeadingVowel_aw() {
        XCTAssertEqual(parse("aw"), "\u{200C}\u{1031}\u{102C}\u{103A}")
    }

    func testLeadingVowel_aw2() {
        XCTAssertEqual(parse("aw2"), "\u{200C}\u{1031}\u{102B}\u{103A}")
    }

    func testLeadingVowel_aw_colon() {
        XCTAssertEqual(parse("aw:"), "\u{200C}\u{1031}\u{102C}")
    }

    func testLeadingVowel_aw2_colon() {
        XCTAssertEqual(parse("aw2:"), "\u{200C}\u{1031}\u{102B}")
    }

    func testLeadingVowel_own() {
        XCTAssertEqual(parse("own"), "\u{200C}\u{102F}\u{1014}\u{103A}")
    }

    func testLeadingVowel_own2() {
        XCTAssertEqual(parse("own2"), "\u{200C}\u{102F}\u{1019}\u{103A}")
    }

    func testLeadingVowel_own3() {
        XCTAssertEqual(parse("own3"), "\u{200C}\u{102F}\u{1036}")
    }

    // MARK: - Cluster-Sound Shortcuts

    func testCluster_j()        { XCTAssertEqual(parse("j"),       "ကျ") }
    func testCluster_ja()       { XCTAssertEqual(parse("ja"),      "ကျ") }
    func testCluster_jw()       { XCTAssertEqual(parse("jw"),      "ကျွ") }
    func testCluster_jwantaw()  { XCTAssertEqual(parse("jwantaw"), "ကျွန်တော်") }
    func testCluster_ch()       { XCTAssertEqual(parse("ch"),      "ချ") }
    func testCluster_chit()     { XCTAssertEqual(parse("chit"),    "ချစ်") }
    func testCluster_sha()      { XCTAssertEqual(parse("sha"),     "ရှ") }
    func testCluster_shar()     { XCTAssertEqual(parse("shar"),    "ရှာ") }

    func testCluster_gyw_hasJwaCandidate() {
        let outputs = parser.parseCandidates("gyw", maxResults: 4).map(\.output)
        XCTAssertTrue(outputs.contains("ဂျွ"), "candidates: \(outputs)")
    }

    // Aspirated sonorants continue to work via the existing h-prefix scheme.
    func testAspirated_hnga() { XCTAssertEqual(parse("hnga"), "ငှ") }
    func testAspirated_hma()  { XCTAssertEqual(parse("hma"),  "မှ") }
    func testAspirated_hla()  { XCTAssertEqual(parse("hla"),  "လှ") }
    func testAspirated_hna()  { XCTAssertEqual(parse("hna"),  "နှ") }

    // Canonical (digit-free) regressions.
    func testCanonical_hr()              { XCTAssertEqual(parse("hr"),  "ရှ") }
    func testCanonical_gy_isYaYit()      { XCTAssertEqual(parse("gy"),  "ဂြ") }
    func testCanonical_kya_isYaYit()     { XCTAssertEqual(parse("kya"), "ကြ") }
}
