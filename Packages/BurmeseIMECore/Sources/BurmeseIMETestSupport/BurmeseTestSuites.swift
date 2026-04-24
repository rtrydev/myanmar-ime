import Foundation

/// Single index of every shared test suite. Both `swift run TestRunner` and
/// the XCTest driver iterate over this list; there is no other place that
/// enumerates suites.
public enum BurmeseTestSuites {
    public static let all: [TestSuite] = [
        RomanizationSuite.suite,
        GrammarSuite.suite,
        ReverseRomanizerSuite.suite,
        ClusterAliasSuite.suite,
        KinziInferenceSuite.suite,
        AnchorStabilitySuite.suite,
        LoanwordRomanizationSuite.suite,
        EngineSuite.suite,
        LexiconRankingSuite.suite,
        RankingSuite.suite,
        LanguageModelSuite.suite,
        PunctuationSuite.suite,
        MidBufferPunctuationSuite.suite,
        NumberMeasureWordsSuite.suite,
        UserHistorySuite.suite,
        IMESettingsSuite.suite,
        SQLiteCandidateStoreSuite.suite,
        PropertySuite.suite,
        FuzzSuite.suite,
        ComprehensiveRankingSuite.suite,
        LexiconLMDriftSuite.suite,
    ]
}
