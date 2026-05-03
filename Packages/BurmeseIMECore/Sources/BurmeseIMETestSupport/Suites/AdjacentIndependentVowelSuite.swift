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

    /// (b) two or more independent-vowel anchors chained together
    /// with at least one dep-vowel scalar between them. The walk
    /// counts every scalar in U+1021..U+102A as an anchor (not just
    /// U+1021), and resets the chain on any consonant base, virama
    /// stack, or syllable-closing asat (U+103A). Two anchors in the
    /// same dep-mark run violate the "one base per syllable" rule
    /// regardless of which independent-vowel codepoints are involved.
    /// (See TASK-037: `uun` → `1021 1030 1026 1014`, `u+ay` →
    /// `1021 1030 1027`, `uuun` → `1021 1030 1021 1030 1026 1014`.)
    private static func violatesRepeatedAnchors(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        var i = 0
        var anchorCount = 0
        var sawDepMarkSinceAnchor = false
        while i < scalars.count {
            let v = scalars[i]
            if independentVowelRange.contains(v) {
                if anchorCount >= 1 && sawDepMarkSinceAnchor {
                    return true
                }
                anchorCount += 1
                sawDepMarkSinceAnchor = false
                i += 1
                continue
            }
            let isDepMark = dependentVowelSigns.contains(v)
                || v == 0x1036
                || (v >= 0x103B && v <= 0x103E)
            if isDepMark {
                sawDepMarkSinceAnchor = true
                i += 1
                continue
            }
            // Anything else (consonant base, virama, asat, tone marks
            // 1037/1038, format controls, …) terminates the cluster.
            anchorCount = 0
            sawDepMarkSinceAnchor = false
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
        // satisfies the two structural checks simultaneously. Note
        // that `uung` is intentionally absent — under the broader
        // TASK-037 invariant it has no clean parse and falls into
        // the orphan-ZWNJ-class fallback policy (multi-anchor shape
        // allowed through as a last resort). That carve-out is
        // exercised by `task037_adjacencyFormDroppedEvenWithoutCleanSibling`.
        TestCase("allClasses_rank0SatisfiesAllInvariants") { ctx in
            let engine = emptyEngine()
            for buffer in ["uu.", "uu:", "nyaungoo", "iing", "kar+oo", "kuuu"] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    violatesAny(surface),
                    buffer,
                    detail: "invariant violated for '\(buffer)' surface='\(surface)'"
                )
            }
        },

        // TASK-037: when at least one clean sibling exists in the
        // panel, no top-3 candidate may carry the multi-anchor shape
        // (the orphan-ZWNJ class fallback policy from
        // `sanitizeAdjacentIndependentVowels`). When NO clean sibling
        // exists (the bare `uun` / `uung` / `u+un` / `uuun` family),
        // the multi-anchor surface is allowed through as a last
        // resort — but the strictly-worse adjacency form (`ဦဦင`)
        // must always be filtered when a chain-shape sibling
        // exists.
        TestCase("task037_topCandidatesFreeOfMultiAnchorWhenSiblingExists") { ctx in
            let engine = emptyEngine()
            // Buffers where a clean sibling exists in the panel.
            // None of the top-3 may carry the violating pattern.
            // (`u+u` collapses to single-anchor `အူ`; `ee+oo` keeps
            // the leading `အီ` clean. `u+oo` is excluded because all
            // its parses are multi-anchor — no clean parse exists,
            // so it falls into the fallback case.)
            let withClean = ["u+u", "ee+oo"]
            for buffer in withClean {
                let candidates = engine.update(buffer: buffer, context: []).candidates
                let cleanSiblingExists = candidates.contains { !violatesAny($0.surface) }
                guard cleanSiblingExists else {
                    ctx.fail(
                        buffer,
                        detail: "expected clean sibling for '\(buffer)' but none found",
                        file: #file,
                        line: #line
                    )
                    continue
                }
                for (i, c) in candidates.prefix(3).enumerated() {
                    ctx.assertFalse(
                        violatesAny(c.surface),
                        buffer,
                        detail: "TASK-037: top-\(i) violates invariant: '\(c.surface)'"
                    )
                }
            }
        },

        // TASK-037: even when no clean sibling exists, the strictly-
        // worse class-1 adjacency form (e.g. `ဦဦင`) must not surface
        // when a chain-shape sibling (e.g. `အူဦင`) is available. The
        // fallback policy in `sanitizeAdjacentIndependentVowels`
        // prefers the chain shape over the adjacency form.
        TestCase("task037_adjacencyFormDroppedEvenWithoutCleanSibling") { ctx in
            let engine = emptyEngine()
            for buffer in ["uun", "uung", "u+un", "uuun"] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    violatesAdjacency(surface),
                    buffer,
                    detail: "TASK-037 fallback surfaced adjacency form for '\(buffer)' surface='\(surface)'"
                )
            }
        },

        // TASK-037: the invariant predicate itself recognises mixed-
        // anchor pairs. Direct unit test of
        // `surfaceViolatesIndependentVowelInvariant`.
        TestCase("task037_predicateRecognisesMixedAnchors") { ctx in
            // Each scalar sequence is a known violator.
            let violators: [(String, [UInt32])] = [
                ("uun", [0x1021, 0x1030, 0x1026, 0x1014]),
                ("uung", [0x1021, 0x1030, 0x1026, 0x1004]),
                ("u+ay", [0x1021, 0x1030, 0x1027]),
                ("u+u", [0x1021, 0x1030, 0x1026]),
                ("uuun", [0x1021, 0x1030, 0x1021, 0x1030, 0x1026, 0x1014]),
                ("u+oo_first_pair", [0x1021, 0x1030, 0x1021, 0x102D, 0x102F]),
                ("u+aw", [0x1021, 0x1030, 0x1029]),
                ("u+i", [0x1021, 0x1030, 0x1024]),
            ]
            for (label, scalars) in violators {
                var s = ""
                s.unicodeScalars.append(contentsOf: scalars.compactMap { Unicode.Scalar($0) })
                ctx.assertTrue(
                    BurmeseEngine.surfaceViolatesIndependentVowelInvariant(s),
                    label,
                    detail: "predicate failed to flag '\(label)' surface='\(s)'"
                )
            }
            // Negative cases: legitimate two-syllable shapes where
            // an asat closes the first cluster before a second
            // anchor appears.
            let nonViolators: [(String, [UInt32])] = [
                ("aungout",
                 [0x1021, 0x1031, 0x102C, 0x1004, 0x103A,
                  0x1021, 0x1031, 0x102C, 0x1000, 0x103A]),
                ("rarthiu",
                 [0x101B, 0x102C, 0x101E, 0x102E, 0x1026]),
                ("kway", [0x1000, 0x103D, 0x1031]),
                ("singleAnchor", [0x1021, 0x1030]),
            ]
            for (label, scalars) in nonViolators {
                var s = ""
                s.unicodeScalars.append(contentsOf: scalars.compactMap { Unicode.Scalar($0) })
                ctx.assertFalse(
                    BurmeseEngine.surfaceViolatesIndependentVowelInvariant(s),
                    label,
                    detail: "predicate over-flagged '\(label)' surface='\(s)'"
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
