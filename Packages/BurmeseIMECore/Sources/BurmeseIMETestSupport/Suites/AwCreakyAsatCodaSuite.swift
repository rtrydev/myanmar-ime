import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-079: the creaky-tone aw vowel closed with asat
/// (`ော့်` / `ေါ့်`, storage shape `<C> 1031 102B|102C 1037 103A`) is
/// regular Burmese orthography — the productive creaky possessive /
/// emphatic of every `ော်` word (`ကျွန်တော့်`, `တော့်`, `နော့်`,
/// `မော့်`, …). The legality scan must accept the dot-first canonical
/// order (U+1037 ccc=7 before U+103A ccc=9 — the order the
/// romanization tables and the shipped lexicon use uniformly), while
/// the genuinely illegal asat-after-tone shapes (tone-closed non-aw
/// vowels, visarga + asat, digit-anchored asat) stay rejected.
public enum AwCreakyAsatCodaSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func bundledEngine(_ ctx: TestContext) -> BurmeseEngine? {
        guard let lexPath = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lexPath),
              let lmPath = BundledArtifacts.trigramLMPath,
              let lm = try? TrigramLanguageModel(path: lmPath) else {
            ctx.assertTrue(true, "skipped_noBundledArtifacts")
            return nil
        }
        return BurmeseEngine(candidateStore: store, languageModel: lm)
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    private static func str(_ scalars: [UInt32]) -> String {
        String(scalars.compactMap { Unicode.Scalar($0) }.map(Character.init))
    }

    public static let suite = TestSuite(name: "AwCreakyAsatCoda", cases: [

        // The dot-first aw-family creaky-asat coda is legal — on a
        // plain consonant base, a medial-bearing onset cluster, the
        // tall-aa (`102B`) sibling, and inside a multi-syllable word.
        TestCase("scanOutputLegality_acceptsAwCreakyAsatCoda") { ctx in
            let cases: [(label: String, scalars: [UInt32])] = [
                // တော့် — <C> 1031 102C 1037 103A
                ("taw.*",  [0x1010, 0x1031, 0x102C, 0x1037, 0x103A]),
                // နော့်
                ("naw.*",  [0x1014, 0x1031, 0x102C, 0x1037, 0x103A]),
                // မော့်
                ("maw.*",  [0x1019, 0x1031, 0x102C, 0x1037, 0x103A]),
                // ခေါ့် — tall-aa sibling <C> 1031 102B 1037 103A
                ("khaw2.*", [0x1001, 0x1031, 0x102B, 0x1037, 0x103A]),
                // ကျော့် — medial-bearing onset cluster
                ("kyaw.*", [0x1000, 0x103B, 0x1031, 0x102C, 0x1037, 0x103A]),
                // ကြော့် — ya-yit sibling
                ("kraw.*", [0x1000, 0x103C, 0x1031, 0x102C, 0x1037, 0x103A]),
                // ကျွန်တော့် — multi-syllable lexicon storage shape
                ("kwyantaw.*",
                 [0x1000, 0x103B, 0x103D, 0x1014, 0x103A, 0x1010, 0x1031, 0x102C, 0x1037, 0x103A]),
            ]
            for c in cases {
                let s = str(c.scalars)
                ctx.assertTrue(
                    SyllableParser.scanOutputLegality(s),
                    c.label,
                    detail: "scanOutputLegality wrongly rejected regular creaky-asat coda '\(s)' [\(hex(s))]"
                )
            }
        },

        // The genuinely illegal asat-after-tone shapes stay rejected:
        // the carve-out is exactly `1031 102B|102C 1037 103A` and
        // nothing wider.
        TestCase("scanOutputLegality_keepsRejectingIllegalAsatAfterTone") { ctx in
            let cases: [(label: String, scalars: [UInt32])] = [
                // ကာ့် — aa WITHOUT the leading 1031 cannot take creaky+asat
                ("kar.*",  [0x1000, 0x102C, 0x1037, 0x103A]),
                // ကါ့် — tall-aa without 1031
                ("kar2.*", [0x1000, 0x102B, 0x1037, 0x103A]),
                // ကေ့် — lone e-kar (no aa) + creaky + asat
                ("kay.*",  [0x1000, 0x1031, 0x1037, 0x103A]),
                // ကိ့် — i-vowel + creaky + asat
                ("ki..*",  [0x1000, 0x102D, 0x1037, 0x103A]),
                // ကို့် — o-cluster + creaky + asat
                ("ko.*",   [0x1000, 0x102D, 0x102F, 0x1037, 0x103A]),
                // ကား် — visarga before asat is never legal
                ("kar:*",  [0x1000, 0x102C, 0x1038, 0x103A]),
                // ကေား် — visarga after the aw cluster + asat
                ("kaw:*",  [0x1000, 0x1031, 0x102C, 0x1038, 0x103A]),
                // ၅် — digit-anchored asat
                ("digit*", [0x1045, 0x103A]),
                // ော့် with no consonant base at all
                ("orphan", [0x1031, 0x102C, 0x1037, 0x103A]),
            ]
            for c in cases {
                let s = str(c.scalars)
                ctx.assertFalse(
                    SyllableParser.scanOutputLegality(s),
                    c.label,
                    detail: "scanOutputLegality wrongly accepted malformed '\(s)' [\(hex(s))]"
                )
            }
        },

        // Forward composition: `<…>aw.` + `*` composes the `ော့်`
        // coda at rank 0 on the bare engine — the parse already
        // exists; only the legality verdict was suppressing it.
        TestCase("bareEngine_composesCreakyAsatCoda") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                ("taw.*",  [0x1010, 0x1031, 0x102C, 0x1037, 0x103A]),
                ("naw.*",  [0x1014, 0x1031, 0x102C, 0x1037, 0x103A]),
                ("maw.*",  [0x1019, 0x1031, 0x102C, 0x1037, 0x103A]),
                // kh takes the tall-aa shape automatically: ခေါ့်
                ("khaw.*", [0x1001, 0x1031, 0x102B, 0x1037, 0x103A]),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    Array(surface.unicodeScalars.map(\.value)) == c.expected,
                    c.buffer,
                    detail: "expected '\(str(c.expected))' [\(hex(str(c.expected)))] got '\(surface)' [\(hex(surface))]"
                )
            }
        },

        // Non-regression: the asat-less creaky forms keep composing
        // unchanged when no `*` is typed.
        TestCase("bareEngine_asatlessCreakyUnchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                ("taw.", [0x1010, 0x1031, 0x102C, 0x1037]),   // တော့
                ("naw.", [0x1014, 0x1031, 0x102C, 0x1037]),   // နော့
                ("taw",  [0x1010, 0x1031, 0x102C, 0x103A]),   // တော်
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    Array(surface.unicodeScalars.map(\.value)) == c.expected,
                    c.buffer,
                    detail: "expected '\(str(c.expected))' got '\(surface)' [\(hex(surface))]"
                )
            }
        },

        // Production: the exact alias-index hits must reach the panel
        // once the scan stops marking the stored surfaces malformed.
        // `ကျွန်တော့်` and `နော့်` are penalty-0 alias rows in the
        // shipped lexicon; top-3 is the bar for exact penalty-0 hits.
        TestCase("production_exactAliasHitsReachPanel") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, expected: String)] = [
                ("kwyantaw.*", "ကျွန်တော့်"),
                ("naw.*",      "နော့်"),
                ("taw.*",      "တော့်"),
            ]
            for c in cases {
                let candidates = engine.update(buffer: c.buffer, context: []).candidates
                let rank = candidates.firstIndex { $0.surface == c.expected }
                ctx.assertTrue(
                    rank != nil && rank! < 3,
                    c.buffer,
                    detail: "expected '\(c.expected)' in top 3; got \(candidates.prefix(5).map(\.surface)) (rank=\(rank.map(String.init) ?? "absent"))"
                )
            }
        },

        // Production: the multi-word compound `kwyantaw.*ko` must
        // surface the lexicon entry `ကျွန်တော့်ကို` with a non-empty
        // Myanmar panel (today it collapses to a literal-only panel).
        TestCase("production_creakyAsatCompoundReachable") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let candidates = engine.update(buffer: "kwyantaw.*ko", context: []).candidates
            let found = candidates.contains { $0.surface == "ကျွန်တော့်ကို" }
            ctx.assertTrue(
                found,
                "kwyantaw.*ko",
                detail: "expected 'ကျွန်တော့်ကို' in panel; got \(candidates.prefix(6).map(\.surface))"
            )
        },
    ])
}
