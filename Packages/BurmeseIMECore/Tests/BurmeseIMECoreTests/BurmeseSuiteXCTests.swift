#if canImport(XCTest)
import XCTest
import BurmeseIMECore
import BurmeseIMETestSupport

/// Adapter that forwards `TestReporter` callbacks to XCTest. Each case is
/// wrapped in `XCTContext.runActivity` so Xcode's test navigator groups
/// assertions under the case name.
private final class XCTReporter: TestReporter {
    let xctest: XCTestCase

    init(xctest: XCTestCase) { self.xctest = xctest }

    func recordPass(case caseName: String, label: String) {
        // XCTest has no "pass" event; silence.
    }

    func recordFailure(
        case caseName: String,
        label: String,
        detail: String,
        file: StaticString,
        line: UInt
    ) {
        XCTFail("[\(caseName)] \(label): \(detail)", file: file, line: line)
    }
}

private func runSuite(_ suite: TestSuite, xctest: XCTestCase) {
    let reporter = XCTReporter(xctest: xctest)
    for testCase in suite.cases {
        let ctx = TestContext(caseName: testCase.name, reporter: reporter)
        testCase.body(ctx)
    }
}

final class RomanizationXCTests: XCTestCase {
    func testAll() { runSuite(RomanizationSuite.suite, xctest: self) }
}

final class GrammarXCTests: XCTestCase {
    func testAll() { runSuite(GrammarSuite.suite, xctest: self) }
}

final class ReverseRomanizerXCTests: XCTestCase {
    func testAll() { runSuite(ReverseRomanizerSuite.suite, xctest: self) }
}

final class ClusterAliasXCTests: XCTestCase {
    func testAll() { runSuite(ClusterAliasSuite.suite, xctest: self) }
}

final class EngineXCTests: XCTestCase {
    func testAll() { runSuite(EngineSuite.suite, xctest: self) }
}

final class LexiconRankingXCTests: XCTestCase {
    func testAll() { runSuite(LexiconRankingSuite.suite, xctest: self) }
}

final class RankingXCTests: XCTestCase {
    func testAll() { runSuite(RankingSuite.suite, xctest: self) }
}

final class LanguageModelXCTests: XCTestCase {
    func testAll() { runSuite(LanguageModelSuite.suite, xctest: self) }
}

final class PunctuationXCTests: XCTestCase {
    func testAll() { runSuite(PunctuationSuite.suite, xctest: self) }
}

final class NumberMeasureWordsXCTests: XCTestCase {
    func testAll() { runSuite(NumberMeasureWordsSuite.suite, xctest: self) }
}

final class UserHistoryXCTests: XCTestCase {
    func testAll() { runSuite(UserHistorySuite.suite, xctest: self) }
}

final class IMESettingsXCTests: XCTestCase {
    func testAll() { runSuite(IMESettingsSuite.suite, xctest: self) }
}

final class SQLiteCandidateStoreXCTests: XCTestCase {
    func testAll() { runSuite(SQLiteCandidateStoreSuite.suite, xctest: self) }
}

final class PropertyXCTests: XCTestCase {
    func testAll() { runSuite(PropertySuite.suite, xctest: self) }
}

final class FuzzXCTests: XCTestCase {
    func testAll() { runSuite(FuzzSuite.suite, xctest: self) }
}

final class ComprehensiveRankingXCTests: XCTestCase {
    func testAll() { runSuite(ComprehensiveRankingSuite.suite, xctest: self) }
}
#endif
