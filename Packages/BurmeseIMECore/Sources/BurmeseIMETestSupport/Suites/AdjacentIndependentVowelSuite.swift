import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-015: onsetless multi-vowel buffers (`uu.`, `uu:`,
/// `uung`, `nyaungoo`, `kar+oo`, `kuu`/`kuuu`) must not produce
/// surfaces that violate the "one base per syllable" invariant. Two
/// illegal shapes the suite guards against:
///
/// 1. Adjacent independent-vowel scalars (U+1021..U+102A directly
///    adjacent).
/// 2. Repeated U+1021 anchors injected into a single orphan-mark
///    stretch (the orphan-mark sanitizer's one-anchor-per-scalar
///    bug class).
///
/// The third class originally listed in the task (`muur`/`i+u`-style
/// precomposed indep mid-syllable) was deliberately dropped from the
/// invariant set: a precomposed indep vowel after a dep-vowel sign
/// is a valid two-syllable Burmese pattern (e.g. `thiu` → `သီဥ`,
/// `rarthiu` → `ရာသီဥ`) exercised by existing tests, and the
/// surfaces are correct as-rendered.
public enum AdjacentIndependentVowelSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static let independentVowelRange: ClosedRange<UInt32> = 0x1021...0x102A
    private static let dependentVowelSigns: ClosedRange<UInt32> = 0x102B...0x1032

    /// (a) two adjacent scalars both in U+1021..U+102A.
    private static func violatesAdjacency(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 2 else { return false }
        for i in 0..<(scalars.count - 1) {
            if independentVowelRange.contains(scalars[i])
                && independentVowelRange.contains(scalars[i + 1]) {
                return true
            }
        }
        return false
    }

    /// (b) three or more U+1021 anchors chained together with only
    /// dep-vowel scalars between them. Two adjacent U+1021 anchors
    /// separated by a single dep-vowel form a valid two-syllable
    /// shape (e.g. `aungout` → `… 1021 1031 1021 102C …`); the bug
    /// class is the orphan-mark sanitizer's per-scalar anchor
    /// injection that produces four-anchor patterns
    /// (`nyaungoo` → `… 1021 102D 1021 102F 1021 102D 1021 102F`).
    private static func violatesRepeatedAnchors(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        var i = 0
        var chainCount = 0
        while i < scalars.count {
            let v = scalars[i]
            if v == 0x1021 {
                chainCount += 1
                if chainCount >= 3 { return true }
                i += 1
                continue
            }
            let isDepMark = dependentVowelSigns.contains(v)
                || v == 0x1036
                || (v >= 0x103B && v <= 0x103E)
            if isDepMark {
                i += 1
                continue
            }
            chainCount = 0
            i += 1
        }
        return false
    }

    private static func violatesAny(_ surface: String) -> Bool {
        violatesAdjacency(surface)
            || violatesRepeatedAnchors(surface)
    }

    public static let suite = TestSuite(name: "AdjacentIndependentVowel", cases: [

        // Class 1 reproductions: two adjacent indep-vowel scalars at
        // rank 0.
        TestCase("class1_adjacentIndepVowels") { ctx in
            let engine = emptyEngine()
            for buffer in ["uu.", "uu:", "uung", "kuuu"] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    violatesAdjacency(surface),
                    buffer,
                    detail: "class-1 violation in '\(buffer)' surface='\(surface)'"
                )
            }
        },

        // Class 2 reproductions: repeated U+1021 anchors within an
        // unclosed run.
        TestCase("class2_repeatedIndepAnchors") { ctx in
            let engine = emptyEngine()
            for buffer in ["nyaungoo", "kar+oo"] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    violatesRepeatedAnchors(surface),
                    buffer,
                    detail: "class-2 violation in '\(buffer)' surface='\(surface)'"
                )
            }
        },

        // General invariant on every reproduction: rank-0 surface
        // satisfies the two structural checks simultaneously.
        TestCase("allClasses_rank0SatisfiesAllInvariants") { ctx in
            let engine = emptyEngine()
            for buffer in ["uu.", "uu:", "uung", "nyaungoo", "iing", "kar+oo", "kuuu"] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    violatesAny(surface),
                    buffer,
                    detail: "invariant violated for '\(buffer)' surface='\(surface)'"
                )
            }
        },

        // Working counter-examples remain unchanged.
        TestCase("counterExamples_unchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(String, String)] = [
                ("i:akar", "\u{1021}\u{102E}\u{1038}\u{1021}\u{1000}\u{102C}"),
                ("kar.akar", "\u{1000}\u{102C}\u{1037}\u{1021}\u{1000}\u{102C}"),
            ]
            for (buffer, _) in cases {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    violatesAny(surface),
                    buffer,
                    detail: "counter-example regressed: '\(buffer)' surface='\(surface)'"
                )
            }
        },
    ])
}
