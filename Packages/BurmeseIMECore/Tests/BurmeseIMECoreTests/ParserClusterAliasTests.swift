import XCTest
@testable import BurmeseIMECore

final class ParserClusterAliasTests: XCTestCase {

    func testClusterAliasesEnabled_jMatchesKaMedialYa() {
        let parser = SyllableParser(useClusterAliases: true)
        let parses = parser.parseCandidates("j", maxResults: 8)
        let surfaces = parses.map(\.output)
        XCTAssertTrue(
            surfaces.contains("ကျ"),
            "expected 'j' to parse as ကျ with cluster aliases on, got: \(surfaces)"
        )
    }

    func testClusterAliasesDisabled_jHasNoClusterOnset() {
        let parser = SyllableParser(useClusterAliases: false)
        let parses = parser.parseCandidates("j", maxResults: 8)
        let surfaces = parses.map(\.output)
        // Without the alias, 'j' is not a registered onset; any parse that
        // materializes must be a fallback rather than a ka+medial cluster.
        XCTAssertFalse(
            surfaces.contains("ကျ"),
            "cluster parse leaked through with aliases disabled: \(surfaces)"
        )
    }

    func testClusterAliasesDisabled_doesNotBreakOtherOnsets() {
        let parser = SyllableParser(useClusterAliases: false)
        let parses = parser.parseCandidates("ka", maxResults: 4)
        XCTAssertFalse(
            parses.isEmpty,
            "disabling cluster aliases should not break standard onsets"
        )
    }
}
