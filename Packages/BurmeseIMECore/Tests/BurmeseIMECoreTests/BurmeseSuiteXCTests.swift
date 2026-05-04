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

final class LexiconLMDriftXCTests: XCTestCase {
    func testAll() { runSuite(LexiconLMDriftSuite.suite, xctest: self) }
}

final class MidBufferStackInferenceXCTests: XCTestCase {
    func testAll() { runSuite(MidBufferStackInferenceSuite.suite, xctest: self) }
}

final class ExplicitViramaXCTests: XCTestCase {
    func testAll() { runSuite(ExplicitViramaSuite.suite, xctest: self) }
}

final class RepeatedDepVowelXCTests: XCTestCase {
    func testAll() { runSuite(RepeatedDepVowelSuite.suite, xctest: self) }
}

final class MidBufferLiteralPunctXCTests: XCTestCase {
    func testAll() { runSuite(MidBufferLiteralPunctSuite.suite, xctest: self) }
}

final class LoneComposingPunctXCTests: XCTestCase {
    func testAll() { runSuite(LoneComposingPunctSuite.suite, xctest: self) }
}

final class LongBufferWindowingXCTests: XCTestCase {
    func testAll() { runSuite(LongBufferWindowingSuite.suite, xctest: self) }
}

final class ConsonantDigraphIntegrityXCTests: XCTestCase {
    func testAll() { runSuite(ConsonantDigraphIntegritySuite.suite, xctest: self) }
}

final class PaliStackOverrideXCTests: XCTestCase {
    func testAll() { runSuite(PaliStackOverrideSuite.suite, xctest: self) }
}

final class BareVowelRepetitionXCTests: XCTestCase {
    func testAll() { runSuite(BareVowelRepetitionSuite.suite, xctest: self) }
}

final class MedialHaForbiddenBasesXCTests: XCTestCase {
    func testAll() { runSuite(MedialHaForbiddenBasesSuite.suite, xctest: self) }
}

final class MedialYaForbiddenBasesXCTests: XCTestCase {
    func testAll() { runSuite(MedialYaForbiddenBasesSuite.suite, xctest: self) }
}

final class KinziTallAaXCTests: XCTestCase {
    func testAll() { runSuite(KinziTallAaSuite.suite, xctest: self) }
}

final class ClusterMedialPreferenceXCTests: XCTestCase {
    func testAll() { runSuite(ClusterMedialPreferenceSuite.suite, xctest: self) }
}

final class OrphanLeadingVowelXCTests: XCTestCase {
    func testAll() { runSuite(OrphanLeadingVowelSuite.suite, xctest: self) }
}

final class BareAingDiphthongXCTests: XCTestCase {
    func testAll() { runSuite(BareAingDiphthongSuite.suite, xctest: self) }
}

final class UnparseableTailFallbackXCTests: XCTestCase {
    func testAll() { runSuite(UnparseableTailFallbackSuite.suite, xctest: self) }
}

final class LiteralFallbackCandidateXCTests: XCTestCase {
    func testAll() { runSuite(LiteralFallbackCandidateSuite.suite, xctest: self) }
}

final class StandaloneCodaVowelXCTests: XCTestCase {
    func testAll() { runSuite(StandaloneCodaVowelSuite.suite, xctest: self) }
}

final class MidBufferDigitMedialSplitXCTests: XCTestCase {
    func testAll() { runSuite(MidBufferDigitMedialSplitSuite.suite, xctest: self) }
}

final class MidBufferDigitAsatSplitXCTests: XCTestCase {
    func testAll() { runSuite(MidBufferDigitAsatSplitSuite.suite, xctest: self) }
}

final class MidBufferDigitOrderXCTests: XCTestCase {
    func testAll() { runSuite(MidBufferDigitOrderSuite.suite, xctest: self) }
}

final class MidBufferDigitVowelSplitXCTests: XCTestCase {
    func testAll() { runSuite(MidBufferDigitVowelSplitSuite.suite, xctest: self) }
}

final class TrailingDigitPunctXCTests: XCTestCase {
    func testAll() { runSuite(TrailingDigitPunctSuite.suite, xctest: self) }
}

final class WindowingClusterIntegrityXCTests: XCTestCase {
    func testAll() { runSuite(WindowingClusterIntegritySuite.suite, xctest: self) }
}


final class LiteralPunctRecursionReadingXCTests: XCTestCase {
    func testAll() { runSuite(LiteralPunctRecursionReadingSuite.suite, xctest: self) }
}

final class HeavyToneAwXCTests: XCTestCase {
    func testAll() { runSuite(HeavyToneAwSuite.suite, xctest: self) }
}

final class WindowingKinziPromotionXCTests: XCTestCase {
    func testAll() { runSuite(WindowingKinziPromotionSuite.suite, xctest: self) }
}

final class CrossClassNTStackRankingXCTests: XCTestCase {
    func testAll() { runSuite(CrossClassNTStackRankingSuite.suite, xctest: self) }
}

final class WindowingKinziAcrossThresholdXCTests: XCTestCase {
    func testAll() { runSuite(WindowingKinziAcrossThresholdSuite.suite, xctest: self) }
}

final class IncrementalParityXCTests: XCTestCase {
    func testAll() { runSuite(IncrementalParitySuite.suite, xctest: self) }
}

final class VisargaInherentAXCTests: XCTestCase {
    func testAll() { runSuite(VisargaInherentASuite.suite, xctest: self) }
}

final class RedundantExplicitAsatXCTests: XCTestCase {
    func testAll() { runSuite(RedundantExplicitAsatSuite.suite, xctest: self) }
}

final class StandaloneParticleMidBufferXCTests: XCTestCase {
    func testAll() { runSuite(StandaloneParticleMidBufferSuite.suite, xctest: self) }
}

final class BareVowelPaliStackXCTests: XCTestCase {
    func testAll() { runSuite(BareVowelPaliStackSuite.suite, xctest: self) }
}

final class ExplicitPlusVowelXCTests: XCTestCase {
    func testAll() { runSuite(ExplicitPlusVowelSuite.suite, xctest: self) }
}

final class WindowedIndepVowelViramaInvariantXCTests: XCTestCase {
    func testAll() { runSuite(WindowedIndepVowelViramaInvariantSuite.suite, xctest: self) }
}

final class RepeatedLetterPerfXCTests: XCTestCase {
    func testAll() { runSuite(RepeatedLetterPerfSuite.suite, xctest: self) }
}

final class BareConsonantToneXCTests: XCTestCase {
    func testAll() { runSuite(BareConsonantToneSuite.suite, xctest: self) }
}

final class AdjacentIndependentVowelXCTests: XCTestCase {
    func testAll() { runSuite(AdjacentIndependentVowelSuite.suite, xctest: self) }
}

final class RepeatedVowelLetterXCTests: XCTestCase {
    func testAll() { runSuite(RepeatedVowelLetterSuite.suite, xctest: self) }
}

final class ApostropheContractionXCTests: XCTestCase {
    func testAll() { runSuite(ApostropheContractionSuite.suite, xctest: self) }
}

final class InherentAChainOverflowXCTests: XCTestCase {
    func testAll() { runSuite(InherentAChainOverflowSuite.suite, xctest: self) }
}

final class OrphanMarkClusterAnchorXCTests: XCTestCase {
    func testAll() { runSuite(OrphanMarkClusterAnchorSuite.suite, xctest: self) }
}

final class LeadingAaTrailingVowelXCTests: XCTestCase {
    func testAll() { runSuite(LeadingAaTrailingVowelSuite.suite, xctest: self) }
}

final class OoSuffixOrphanChainXCTests: XCTestCase {
    func testAll() { runSuite(OoSuffixOrphanChainSuite.suite, xctest: self) }
}

final class DoubledLetterKinziXCTests: XCTestCase {
    func testAll() { runSuite(DoubledLetterKinziSuite.suite, xctest: self) }
}

final class CrossCategoryDepVowelLegalityXCTests: XCTestCase {
    func testAll() { runSuite(CrossCategoryDepVowelLegalitySuite.suite, xctest: self) }
}

final class BareDoubledVowelToneXCTests: XCTestCase {
    func testAll() { runSuite(BareDoubledVowelToneSuite.suite, xctest: self) }
}

final class AhConsonantBoundaryHXCTests: XCTestCase {
    func testAll() { runSuite(AhConsonantBoundaryHSuite.suite, xctest: self) }
}

final class LiteralFallbackIllegalSurfaceXCTests: XCTestCase {
    func testAll() { runSuite(LiteralFallbackIllegalSurfaceSuite.suite, xctest: self) }
}

final class AsatAfterToneXCTests: XCTestCase {
    func testAll() { runSuite(AsatAfterToneSuite.suite, xctest: self) }
}
#endif
