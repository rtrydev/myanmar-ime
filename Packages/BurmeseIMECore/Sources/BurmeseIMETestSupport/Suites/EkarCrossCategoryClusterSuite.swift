import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-053: `<base> [medials] 1031 <other-cat-dep-vowel>` chains on a
/// single anchor must be rejected by `scanOutputLegality`. The leading
/// e-kar (U+1031) is the start of exactly two legal multi-scalar dep-
/// vowel shapes: `1031 102B` (`aw`-tall) and `1031 102C` (`aw`-short
/// → the `aw` / `aung` family). Every other dep-vowel scalar after
/// `1031` on the same anchor (i, ii, u, uu, ai, the `o` cluster
/// `102D 102F`) is malformed.
///
/// The mirror predicate in `Engine/SurfaceSanitizers.swift::
/// attachableMarkHasAnchor` must be tightened in lockstep so that the
/// orphan-mark injector flags the trailing `<C> 1031 <other>` cluster
/// and produces a multi-anchor sibling that anchors the second vowel
/// rule on a fresh `1021`.
public enum EkarCrossCategoryClusterSuite {

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

    /// Detect any `<base-or-indep-vowel> [medials/marks] 1031 <other-
    /// cat dep-vowel>` adjacency on a single anchor. The walk skips
    /// medials and tone marks but stops at asat / virama / fresh
    /// anchor (these legitimately break the cluster).
    private static func surfaceContainsIllegalEkarChain(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        var i = 0
        while i < scalars.count {
            let v = scalars[i]
            let isAnchor = (v >= 0x1000 && v <= 0x102A) || v == 0x103F
            if !isAnchor { i += 1; continue }
            // Walk forward collecting dep-vowel scalars belonging to
            // this anchor's cluster. Stop on asat / virama / fresh
            // anchor.
            var depVowels: [UInt32] = []
            var j = i + 1
            walk: while j < scalars.count {
                let w = scalars[j]
                if w >= 0x102B && w <= 0x1032 {
                    depVowels.append(w)
                    j += 1
                } else if (w >= 0x1036 && w <= 0x1038) || (w >= 0x103B && w <= 0x103E) {
                    j += 1
                } else {
                    break walk
                }
            }
            // Look for `1031` followed by any non-aa dep-vowel within
            // this cluster.
            for k in 0..<(depVowels.count) {
                if depVowels[k] != 0x1031 { continue }
                if k + 1 < depVowels.count {
                    let next = depVowels[k + 1]
                    if next != 0x102B && next != 0x102C {
                        return true
                    }
                }
            }
            i = j
        }
        return false
    }

    public static let suite = TestSuite(name: "EkarCrossCategoryCluster", cases: [

        // Parser-level: every `<base> 1031 <other-cat-dep-vowel>`
        // adjacency on a single anchor must lose its legal status.
        TestCase("scanOutputLegality_rejectsEkarThenOther") { ctx in
            let illegalShapes: [(label: String, scalars: [UInt32])] = [
                ("ka + e + i",       [0x1000, 0x1031, 0x102D]),
                ("ka + e + ii",      [0x1000, 0x1031, 0x102E]),
                ("ka + e + u",       [0x1000, 0x1031, 0x102F]),
                ("ka + e + uu",      [0x1000, 0x1031, 0x1030]),
                ("ka + e + i + u",   [0x1000, 0x1031, 0x102D, 0x102F]),
                ("ka + e + ai",      [0x1000, 0x1031, 0x1032]),
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

        // Parser-level carve-outs: the legal `aw` / `aw-tall` shapes
        // must remain accepted.
        TestCase("scanOutputLegality_acceptsLegalEkarShapes") { ctx in
            let legalShapes: [(label: String, scalars: [UInt32])] = [
                ("ka + e + tall-aa (aw-tall)", [0x1000, 0x1031, 0x102B]),
                ("ka + e + aa (aw-short)",     [0x1000, 0x1031, 0x102C]),
                ("ka + e + aa + asat (aung)",  [0x1000, 0x1031, 0x102C, 0x103A]),
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

        // Engine-level: rank-0 surface for every TASK-053 buffer must
        // not contain a `<C> 1031 <other-cat-dep-vowel>` cluster on a
        // single anchor.
        TestCase("rank0_noEkarCrossCategoryChain") { ctx in
            let engine = emptyEngine()
            let buffers = [
                "kayoo", "tayoo", "payoo", "thayoo",
                "myayoo", "kyayoo", "khwayoo",
                "thrayoo", "mrayoo", "shwayoo",
                "ayoo", "ayooar",
                "kayooar", "kayoopar",
            ]
            for buffer in buffers {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    surfaceContainsIllegalEkarChain(surface),
                    buffer,
                    detail: "rank-0 has illegal e-kar cluster: '\(hex(surface))'"
                )
            }
        },

        // Engine-level: legitimate aw-family inputs must be
        // unchanged. Regression guard for the legal carve-out.
        TestCase("rank0_legitimateAwFamilyUnchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, mustContain: [UInt32])] = [
                ("kaw",     [0x1031, 0x102C]),       // aw short
                ("kaung",   [0x1031, 0x102C]),       // aung
                ("aung",    [0x1031, 0x102C]),       // bare aung
                ("kyaung",  [0x1031, 0x102C]),       // kyaung
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
                    detail: "rank-0 lost legal aw-family shape '\(c.mustContain.map { String(format: "%04X", $0) })' surface='\(hex(surface))'"
                )
            }
        },
    ])
}
