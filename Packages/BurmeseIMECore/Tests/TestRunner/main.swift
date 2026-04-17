/// Standalone test runner for BurmeseIMECore. Usable with Command Line Tools
/// only — iterates the shared `BurmeseTestSuites.all` index and routes
/// assertions through `CLITestReporter`.

import Foundation
import BurmeseIMECore
import BurmeseIMETestSupport

final class CLITestReporter: TestReporter {
    private var totalAssertions = 0
    private var totalFailures = 0
    private var casesWithFailures: Set<String> = []
    private var runningCase: String = ""
    private var lastCaseFailed: Bool = false

    func startCase(_ name: String) {
        runningCase = name
        lastCaseFailed = false
    }

    func finishCase() {
        print(lastCaseFailed ? "FAIL" : "PASS")
    }

    func recordPass(case caseName: String, label: String) {
        totalAssertions += 1
    }

    func recordFailure(
        case caseName: String,
        label: String,
        detail: String,
        file: StaticString,
        line: UInt
    ) {
        totalAssertions += 1
        totalFailures += 1
        casesWithFailures.insert(caseName)
        lastCaseFailed = true
        print("")
        print("    ✗ \(label): \(detail)")
        print("      at \(file):\(line)")
    }

    func printSummary(totalCases: Int) {
        let passedCases = totalCases - casesWithFailures.count
        print("")
        print("=== Summary ===")
        print("  Cases: \(passedCases)/\(totalCases) passed")
        print("  Assertions: \(totalAssertions - totalFailures)/\(totalAssertions) passed")
        if totalFailures == 0 {
            print("ALL \(totalAssertions) TESTS PASSED")
        } else {
            print("\(totalFailures) ASSERTION(S) FAILED across \(casesWithFailures.count) case(s)")
        }
    }

    var exitCode: Int32 { totalFailures == 0 ? 0 : 1 }
}

let reporter = CLITestReporter()
var totalCases = 0
for suite in BurmeseTestSuites.all {
    print("=== \(suite.name) ===")
    for testCase in suite.cases {
        totalCases += 1
        print("  \(testCase.name) ... ", terminator: "")
        reporter.startCase(testCase.name)
        let ctx = TestContext(caseName: testCase.name, reporter: reporter)
        testCase.body(ctx)
        reporter.finishCase()
    }
}
reporter.printSummary(totalCases: totalCases)
exit(reporter.exitCode)
