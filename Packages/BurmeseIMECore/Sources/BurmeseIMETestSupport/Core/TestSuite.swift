import Foundation

/// A single named test case. Body runs with a `TestContext` that routes
/// assertions to whichever reporter the active runner installed.
public struct TestCase: Sendable {
    public let name: String
    public let body: @Sendable (TestContext) -> Void

    public init(_ name: String, _ body: @Sendable @escaping (TestContext) -> Void) {
        self.name = name
        self.body = body
    }
}

/// A named collection of `TestCase`s. One suite maps to one XCTestCase class
/// and to one section header in the CLI runner.
public struct TestSuite: Sendable {
    public let name: String
    public let cases: [TestCase]

    public init(name: String, cases: [TestCase]) {
        self.name = name
        self.cases = cases
    }
}
