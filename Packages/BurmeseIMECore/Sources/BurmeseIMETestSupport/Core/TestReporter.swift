import Foundation

/// Receives per-assertion results from `TestContext`. Implemented by each
/// runner (CLI, XCTest) to adapt assertions to its native reporting.
public protocol TestReporter: AnyObject {
    func recordPass(case caseName: String, label: String)
    func recordFailure(
        case caseName: String,
        label: String,
        detail: String,
        file: StaticString,
        line: UInt
    )
}

/// Bundle of assertion helpers handed to every `TestCase` body. Calls route
/// through `reporter` so the same case runs under both the CLI runner and
/// XCTest without knowing which.
public struct TestContext {
    public let caseName: String
    public let reporter: any TestReporter

    public init(caseName: String, reporter: any TestReporter) {
        self.caseName = caseName
        self.reporter = reporter
    }

    public func assertEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let tag = label.isEmpty ? caseName : label
        if actual == expected {
            reporter.recordPass(case: caseName, label: tag)
        } else {
            reporter.recordFailure(
                case: caseName,
                label: tag,
                detail: "Expected '\(expected)', got '\(actual)'",
                file: file,
                line: line
            )
        }
    }

    public func assertTrue(
        _ condition: Bool,
        _ label: String = "",
        detail: String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let tag = label.isEmpty ? caseName : label
        if condition {
            reporter.recordPass(case: caseName, label: tag)
        } else {
            reporter.recordFailure(
                case: caseName,
                label: tag,
                detail: detail.isEmpty ? "Condition was false" : detail,
                file: file,
                line: line
            )
        }
    }

    public func assertFalse(
        _ condition: Bool,
        _ label: String = "",
        detail: String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        assertTrue(!condition, label, detail: detail, file: file, line: line)
    }

    public func assertGreaterThan(
        _ a: Int,
        _ b: Int,
        _ label: String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let tag = label.isEmpty ? caseName : label
        if a > b {
            reporter.recordPass(case: caseName, label: tag)
        } else {
            reporter.recordFailure(
                case: caseName,
                label: tag,
                detail: "Expected \(a) > \(b)",
                file: file,
                line: line
            )
        }
    }

    public func assertGreaterThan(
        _ a: Double,
        _ b: Double,
        _ label: String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let tag = label.isEmpty ? caseName : label
        if a > b {
            reporter.recordPass(case: caseName, label: tag)
        } else {
            reporter.recordFailure(
                case: caseName,
                label: tag,
                detail: "Expected \(a) > \(b)",
                file: file,
                line: line
            )
        }
    }

    public func fail(
        _ label: String,
        detail: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        reporter.recordFailure(
            case: caseName,
            label: label.isEmpty ? caseName : label,
            detail: detail,
            file: file,
            line: line
        )
    }
}
