/// Standalone test runner for BurmeseIMECore. Usable with Command Line Tools
/// only — iterates the shared `BurmeseTestSuites.all` index and routes
/// assertions through a per-case reporter.
///
/// Every case runs concurrently via `DispatchQueue.concurrentPerform`. The
/// suites only share read-only static configuration; per-case state lives
/// in fresh `BurmeseEngine` / `IMESettings(suiteName:)` instances backed by
/// UUID-distinct `UserDefaults` suites and tmp directories.
///
/// Streaming output emits `.` for each passing case and `F` for each
/// failing case as they complete. At the end the runner prints full
/// failure details grouped by qualified case name, followed by a summary.

import Foundation
import BurmeseIMECore
import BurmeseIMETestSupport

final class CaseReporter: TestReporter, @unchecked Sendable {
    let qualifiedName: String
    private let lock = NSLock()
    private var passes = 0
    private var failures: [String] = []

    init(_ qualifiedName: String) { self.qualifiedName = qualifiedName }

    func recordPass(case caseName: String, label: String) {
        lock.lock(); passes += 1; lock.unlock()
    }

    func recordFailure(
        case caseName: String,
        label: String,
        detail: String,
        file: StaticString,
        line: UInt
    ) {
        let entry = "    ✗ \(label): \(detail)\n      at \(file):\(line)"
        lock.lock(); failures.append(entry); lock.unlock()
    }

    func snapshot() -> (passes: Int, failures: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (passes, failures)
    }
}

struct CaseResult: Sendable {
    let qualifiedName: String
    let passes: Int
    let failures: [String]
}

final class RunCollector: @unchecked Sendable {
    private let lock = NSLock()
    var results: [CaseResult?]

    init(caseCount: Int) {
        self.results = [CaseResult?](repeating: nil, count: caseCount)
    }

    func set(_ result: CaseResult, at index: Int) {
        lock.lock(); results[index] = result; lock.unlock()
    }
}

final class StreamWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle = FileHandle.standardOutput
    private let dot = Data(".".utf8)
    private let fmark = Data("F".utf8)

    func writePass() {
        lock.lock(); handle.write(dot); lock.unlock()
    }

    func writeFail() {
        lock.lock(); handle.write(fmark); lock.unlock()
    }
}

struct FlatEntry: Sendable {
    let qualifiedName: String
    let body: @Sendable (TestContext) -> Void
}

let suites = BurmeseTestSuites.all
let flat: [FlatEntry] = suites.flatMap { suite in
    suite.cases.map { c in
        FlatEntry(qualifiedName: "\(suite.name).\(c.name)", body: c.body)
    }
}
let totalCases = flat.count
let collector = RunCollector(caseCount: totalCases)
let stream = StreamWriter()

DispatchQueue.concurrentPerform(iterations: totalCases) { i in
    let entry = flat[i]
    let cr = CaseReporter(entry.qualifiedName)
    let ctx = TestContext(caseName: entry.qualifiedName, reporter: cr)
    entry.body(ctx)
    let snap = cr.snapshot()
    collector.set(
        CaseResult(qualifiedName: entry.qualifiedName,
                   passes: snap.passes,
                   failures: snap.failures),
        at: i
    )
    if snap.failures.isEmpty { stream.writePass() } else { stream.writeFail() }
}
print("")

var totalAssertions = 0
var totalFailures = 0
var failingCases: [CaseResult] = []
for r in collector.results.compactMap({ $0 }) {
    totalAssertions += r.passes + r.failures.count
    totalFailures += r.failures.count
    if !r.failures.isEmpty { failingCases.append(r) }
}

if !failingCases.isEmpty {
    print("")
    print("=== Failures ===")
    for c in failingCases.sorted(by: { $0.qualifiedName < $1.qualifiedName }) {
        print("✗ \(c.qualifiedName)")
        for entry in c.failures {
            print(entry)
        }
    }
}

print("")
print("=== Summary ===")
let passedCases = totalCases - failingCases.count
print("  Cases: \(passedCases)/\(totalCases) passed")
print("  Assertions: \(totalAssertions - totalFailures)/\(totalAssertions) passed")
if totalFailures == 0 {
    print("ALL \(totalAssertions) TESTS PASSED")
} else {
    print("\(totalFailures) ASSERTION(S) FAILED across \(failingCases.count) case(s)")
}
exit(totalFailures == 0 ? 0 : 1)
