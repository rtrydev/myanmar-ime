import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-025: a virama-stacked Pali-style cluster that
/// terminates in a bare lower consonant (no following vowel) followed
/// by a tone marker (`.` or `:`) must produce a candidate whose surface
/// contains the tone scalar — currently the trailing `.`/`:` is
/// silently absorbed by the parser via the `hasOnlyCleanViramaStacks`
/// carve-out in `isAcceptableParse`, leaving neither the literal nor
/// the tone in any panel candidate.
///
/// Burmese rule reference:
///   `<C> U+1039 <C>` (clean virama stack) takes tone scalars exactly
///   like a bare consonant: creaky `U+1037` / visarga `U+1038` appended
///   after the stack's lower consonant.
public enum ViramaStackToneSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    private static let creakyCases: [(buffer: String, expected: [UInt32])] = [
        ("k+ka.",     [0x1000, 0x1039, 0x1000, 0x1037]),                 // က္က့
        ("p+pa.",     [0x1015, 0x1039, 0x1015, 0x1037]),                 // ပ္ပ့
        ("k+kakha.",  [0x1000, 0x1039, 0x1000, 0x1001, 0x1037]),         // က္ကခ့
    ]

    private static let visargaCases: [(buffer: String, expected: [UInt32])] = [
        ("k+ka:",     [0x1000, 0x1039, 0x1000, 0x1038]),                 // က္ကး
        ("p+pa:",     [0x1015, 0x1039, 0x1015, 0x1038]),                 // ပ္ပး
        ("k+kakha:",  [0x1000, 0x1039, 0x1000, 0x1001, 0x1038]),         // က္ကခး
    ]

    public static let suite = TestSuite(name: "ViramaStackTone", cases: [

        // Creaky tone after a bare lower-stack consonant must reach
        // rank 0.
        TestCase("viramaStackBareLower_creakyAtRank0") { ctx in
            let engine = emptyEngine()
            for c in creakyCases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    actual == c.expected,
                    c.buffer,
                    detail: "expected scalars=\(c.expected.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
            }
        },

        // Visarga tone after a bare lower-stack consonant must reach
        // rank 0.
        TestCase("viramaStackBareLower_visargaAtRank0") { ctx in
            let engine = emptyEngine()
            for c in visargaCases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    actual == c.expected,
                    c.buffer,
                    detail: "expected scalars=\(c.expected.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
            }
        },

        // The tone scalar must NEVER be silently dropped — every
        // reproduction must yield at least one candidate that contains
        // either the tone scalar or the literal `.` / `:` ASCII byte.
        TestCase("viramaStackTone_neverSilentlyDropped") { ctx in
            let engine = emptyEngine()
            let cases = creakyCases.map { $0.buffer } + visargaCases.map { $0.buffer }
            for buffer in cases {
                let cands = engine.update(buffer: buffer, context: []).candidates
                let toneScalar: UInt32 = buffer.hasSuffix(":") ? 0x1038 : 0x1037
                let asciiScalar: UInt32 = buffer.hasSuffix(":") ? 0x003A : 0x002E
                let reachable = cands.contains { c in
                    c.surface.unicodeScalars.contains { v in
                        v.value == toneScalar || v.value == asciiScalar
                    }
                }
                ctx.assertTrue(
                    reachable,
                    buffer,
                    detail: "no candidate carries tone scalar or literal punct for '\(buffer)' — silent drop. all=\(cands.prefix(6).map(\.surface))"
                )
            }
        },

        // Counter-examples — clean virama stack + vowel + tone must
        // continue to render correctly (the carve-out is needed for
        // the no-tone form `k+ka` → `က္က`).
        TestCase("viramaStackPlusVowelPlusTone_unchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                ("k+kar.",    [0x1000, 0x1039, 0x1000, 0x102C, 0x1037]),
                ("k+kar:",    [0x1000, 0x1039, 0x1000, 0x102C, 0x1038]),
                ("k+kan.",    [0x1000, 0x1039, 0x1000, 0x1014, 0x1037, 0x103A]),
                ("k+kakhan.", [0x1000, 0x1039, 0x1000, 0x1001, 0x1014, 0x1037, 0x103A]),
                ("k+kakhan:", [0x1000, 0x1039, 0x1000, 0x1001, 0x1014, 0x103A, 0x1038]),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    actual == c.expected,
                    c.buffer,
                    detail: "regression: expected scalars=\(c.expected.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
            }
        },

        // Bare stack with no tone must keep working — `k+ka` → `က္က`.
        TestCase("viramaStackNoTone_unchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                ("k+ka",     [0x1000, 0x1039, 0x1000]),
                ("p+pa",     [0x1015, 0x1039, 0x1015]),
                ("k+kakha",  [0x1000, 0x1039, 0x1000, 0x1001]),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    actual == c.expected,
                    c.buffer,
                    detail: "regression: expected scalars=\(c.expected.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
            }
        },
    ])
}
