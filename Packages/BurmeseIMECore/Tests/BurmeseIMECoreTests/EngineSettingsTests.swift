import XCTest
@testable import BurmeseIMECore

final class EngineSettingsTests: XCTestCase {

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "EngineSettingsTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Custom candidate page size

    func testCandidatePageSize_honoredByEngine() {
        let settings = IMESettings(suiteName: suiteName)
        settings.candidatePageSize = 3
        let engine = BurmeseEngine(settings: settings)
        let state = engine.update(buffer: "k", context: [])
        XCTAssertLessThanOrEqual(state.candidates.count, 3)
    }

    func testCandidatePageSize_exposedOnEngine() {
        let settings = IMESettings(suiteName: suiteName)
        settings.candidatePageSize = 12
        let engine = BurmeseEngine(settings: settings)
        XCTAssertEqual(engine.candidatePageSize, 12)
    }

    // MARK: - Fallback when no settings supplied

    func testSettingsNil_fallsBackToCompiledDefaults() {
        let engine = BurmeseEngine()
        XCTAssertEqual(engine.candidatePageSize, BurmeseEngine.candidatePageSizeDefault)
        // Behaviour should match the pre-refactor baseline.
        let state = engine.update(buffer: "k", context: [])
        XCTAssertLessThanOrEqual(state.candidates.count, BurmeseEngine.candidatePageSizeDefault)
    }

    // MARK: - Cluster alias toggle at engine level

    func testClusterAliasesDisabled_noJOnset() {
        let settings = IMESettings(suiteName: suiteName)
        settings.clusterAliasesEnabled = false
        let engine = BurmeseEngine(settings: settings)

        // With cluster aliases enabled, "j" parses as ka+medialYa (ကျ).
        // Disabled, "j" should not produce a cluster-onset grammar parse.
        let state = engine.update(buffer: "ja", context: [])
        let surfaces = state.candidates
            .filter { $0.source == .grammar }
            .map(\.surface)
        XCTAssertFalse(
            surfaces.contains("ကျ") || surfaces.contains("ကျာ"),
            "cluster onset leaked through with aliases disabled: \(surfaces)"
        )
    }

    func testClusterAliasesEnabled_jStillWorks() {
        let settings = IMESettings(suiteName: suiteName)
        settings.clusterAliasesEnabled = true
        let engine = BurmeseEngine(settings: settings)
        let state = engine.update(buffer: "ja", context: [])
        let surfaces = state.candidates.map(\.surface)
        XCTAssertTrue(
            surfaces.contains { $0.hasPrefix("ကျ") },
            "expected cluster parse for 'ja' to include ကျ*, got: \(surfaces)"
        )
    }

    // Locks in the lazy-rebuild contract relied on by the macOS input controller:
    // SyllableParser bakes `useClusterAliases` into its onset lookup at init time,
    // so flipping the setting on a live engine does not alter its behaviour. A
    // freshly constructed engine must observe the new value.
    func testClusterAliasesToggle_afterEngineConstruction_requiresRebuild() {
        let settings = IMESettings(suiteName: suiteName)
        settings.clusterAliasesEnabled = true
        let engine = BurmeseEngine(settings: settings)

        let before = engine.update(buffer: "ja", context: [])
        XCTAssertTrue(
            before.candidates.map(\.surface).contains { $0.hasPrefix("ကျ") },
            "precondition: enabled engine should emit ကျ*"
        )

        settings.clusterAliasesEnabled = false
        let afterToggle = engine.update(buffer: "ja", context: [])
        XCTAssertTrue(
            afterToggle.candidates.map(\.surface).contains { $0.hasPrefix("ကျ") },
            "engine should still emit cluster parses until it is rebuilt"
        )

        let rebuilt = BurmeseEngine(settings: settings)
        let afterRebuild = rebuilt.update(buffer: "ja", context: [])
        let rebuiltGrammar = afterRebuild.candidates
            .filter { $0.source == .grammar }
            .map(\.surface)
        XCTAssertFalse(
            rebuiltGrammar.contains { $0.hasPrefix("ကျ") },
            "rebuilt engine should honor the new setting: \(rebuiltGrammar)"
        )
    }
}
