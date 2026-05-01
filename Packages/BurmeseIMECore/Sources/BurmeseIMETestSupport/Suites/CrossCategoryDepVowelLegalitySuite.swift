import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-028: cross-category dependent-vowel chains on a single
/// consonant anchor must be rejected by `scanOutputLegality`. Burmese
/// orthography permits exactly these multi-scalar dep-vowel shapes on
/// one base:
///
/// - `102D 102F` ("o" / "ou" cluster — i + u, the canonical exception).
/// - `1031 102B` / `1031 102C` (leading e-kar Unicode storage order
///   for the `aw`/`aung`/`aing` family).
///
/// Every other dep-vowel-on-dep-vowel pairing on the same anchor
/// (`aa + i`, `aa + u`, `i + uu`, `ii + u`, `aa + ai`, …) is malformed
/// and must lose its positive `legalityScore` so clean siblings outrank
/// it at the engine level.
public enum CrossCategoryDepVowelLegalitySuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    private static func makeSurface(_ values: [UInt32]) -> String {
        var s = ""
        s.unicodeScalars.reserveCapacity(values.count)
        for v in values { s.unicodeScalars.append(Unicode.Scalar(v)!) }
        return s
    }

    /// Detect any "base + cross-category dep-vowel chain" on a single
    /// consonant anchor that is NOT one of the canonical legal shapes.
    /// Walks the surface scalar-by-scalar; whenever a consonant base
    /// (U+1000..U+1021, U+103F) carries two or more dep-vowel scalars
    /// before the next anchor, allow only `102D 102F` (o-cluster) or
    /// `1031` followed by `102B`/`102C` (aung Unicode order).
    private static func hasIllegalCrossCategoryChain(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        var i = 0
        while i < scalars.count {
            let v = scalars[i]
            let isBase = (v >= 0x1000 && v <= 0x1021) || v == 0x103F
            if !isBase { i += 1; continue }
            var depVowels: [UInt32] = []
            var j = i + 1
            while j < scalars.count {
                let w = scalars[j]
                if w >= 0x102B && w <= 0x1032 {
                    depVowels.append(w)
                    j += 1
                } else if (w >= 0x1036 && w <= 0x103A) || (w >= 0x103B && w <= 0x103E) {
                    j += 1
                } else {
                    break
                }
            }
            // Allow the canonical multi-scalar shapes; reject anything else.
            if depVowels.count >= 2 {
                let isOCluster = depVowels == [0x102D, 0x102F]
                let isAungOrder = depVowels.count == 2
                    && depVowels[0] == 0x1031
                    && (depVowels[1] == 0x102B || depVowels[1] == 0x102C)
                if !(isOCluster || isAungOrder) {
                    return true
                }
            }
            i = j
        }
        return false
    }

    public static let suite = TestSuite(name: "CrossCategoryDepVowelLegality", cases: [

        // Parser-level: the scalar-level legality scan must reject
        // every cross-category dep-vowel pair on a single anchor that
        // is not one of the canonical legal shapes.
        TestCase("scanOutputLegality_rejectsIllegalCrossCategory") { ctx in
            let illegalShapes: [(label: String, scalars: [UInt32])] = [
                ("ka + aa + i",   [0x1000, 0x102C, 0x102D]),
                ("ka + aa + ii",  [0x1000, 0x102C, 0x102E]),
                ("ka + aa + u",   [0x1000, 0x102C, 0x102F]),
                ("ka + aa + uu",  [0x1000, 0x102C, 0x1030]),
                ("ka + i + uu",   [0x1000, 0x102D, 0x1030]),
                ("ka + ii + u",   [0x1000, 0x102E, 0x102F]),
                ("ka + aa + ai",  [0x1000, 0x102C, 0x1032]),
                ("ka + tall-aa+i",[0x1000, 0x102B, 0x102D]),
                ("ka + i + ii",   [0x1000, 0x102D, 0x102E]),  // same-cat already, retained
                ("ka + u + uu",   [0x1000, 0x102F, 0x1030]),
                ("ka + aa + i + u", [0x1000, 0x102C, 0x102D, 0x102F]),
            ]
            for shape in illegalShapes {
                let surface = makeSurface(shape.scalars)
                ctx.assertFalse(
                    SyllableParser.scanOutputLegality(surface),
                    shape.label,
                    detail: "expected ILLEGAL but scan accepted '\(hex(surface))'"
                )
            }
        },

        // Parser-level: the canonical multi-scalar dep-vowel shapes
        // must remain legal.
        TestCase("scanOutputLegality_acceptsCanonicalShapes") { ctx in
            let legalShapes: [(label: String, scalars: [UInt32])] = [
                ("ka + i + u (o-cluster)", [0x1000, 0x102D, 0x102F]),
                ("ka + e + tall-aa",       [0x1000, 0x1031, 0x102B]),
                ("ka + e + aa",            [0x1000, 0x1031, 0x102C]),
                ("ka + e + aa + asat",     [0x1000, 0x1031, 0x102C, 0x103A]),
                ("ka alone",               [0x1000]),
                ("ka + aa",                [0x1000, 0x102C]),
                ("ka + i",                 [0x1000, 0x102D]),
                ("u-tone (1026 1038)",     [0x1026, 0x1038]),
                ("ဦ + visarga",            [0x1029, 0x1038]),
            ]
            for shape in legalShapes {
                let surface = makeSurface(shape.scalars)
                ctx.assertTrue(
                    SyllableParser.scanOutputLegality(surface),
                    shape.label,
                    detail: "expected LEGAL but scan rejected '\(hex(surface))'"
                )
            }
        },

        // Engine-level: the rank-0 surface for the bug-class buffers
        // must not contain any anchor with an illegal cross-category
        // dep-vowel chain. The exact target surfaces vary by parser
        // arc choice; the load-bearing invariant is the scalar-shape
        // rule.
        TestCase("rank0_noCrossCategoryDepVowelChain") { ctx in
            let engine = emptyEngine()
            let buffers = [
                "karoo", "karii", "karuu", "karee",
                "paroo", "parii", "paruu",
                "haroo", "harii", "haruu",
                "aroo", "arii", "aruu", "aree",
                "kaau", "kaai",
            ]
            for buffer in buffers {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    hasIllegalCrossCategoryChain(surface),
                    buffer,
                    detail: "rank-0 has illegal cross-category dep-vowel chain: '\(hex(surface))'"
                )
            }
        },

        // Engine-level: legal multi-scalar shapes (`koo` → o-cluster,
        // `kaung` → aung order) must continue to surface cleanly.
        // Regression guard for the canonical exceptions.
        TestCase("rank0_legalMultiScalarShapesUnchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, mustContain: [UInt32])] = [
                ("ko",     [0x102D, 0x102F]),       // o-cluster
                ("kaung",  [0x1031, 0x102C]),       // aung Unicode order
                ("kaw",    [0x1031, 0x102C]),       // aw Unicode order
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars).map(\.value)
                var found = false
                if scalars.count >= c.mustContain.count {
                    for i in 0...(scalars.count - c.mustContain.count) {
                        if Array(scalars[i..<(i + c.mustContain.count)]) == c.mustContain {
                            found = true
                            break
                        }
                    }
                }
                ctx.assertTrue(
                    found,
                    c.buffer,
                    detail: "rank-0 lost canonical legal multi-scalar shape '\(c.mustContain.map { String(format: "%04X", $0) })' surface='\(hex(surface))'"
                )
            }
        },
    ])
}
