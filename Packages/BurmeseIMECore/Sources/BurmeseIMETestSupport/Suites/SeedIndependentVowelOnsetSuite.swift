import Foundation
@_spi(Testing) import BurmeseIMECore

/// A word-initial (seed-position) independent vowel followed by a new
/// consonant syllable must render as that independent vowel, not an
/// `အ`-base dependent-vowel fallback (`အီအီပြ`) and not a raw-Latin
/// literal.
///
/// Background: the TASK-007 mid-buffer gate in `WordLatticeDecoder` /
/// `SyllableParser` suppresses standalone independent-vowel and
/// free-standing-particle arcs (Myanmar output starting U+1023..U+102A
/// or U+104C..U+104F) so they cannot land *between* consonant bases —
/// the structurally invalid `<consonant><independent-vowel>` shape that
/// `StandaloneParticleMidBufferSuite` protects against. The original
/// gate also skipped the arc whenever more buffer followed, even at the
/// seed. At the seed the scalar is surface-initial and nothing precedes
/// it, so it can never be mid-surface pollution: `ii` + `py` is the
/// legal word `ဤပြ` ("this pr…"), not `<C>ဤ`. The over-broad skip
/// forced the parser onto an `အီ…` fallback whose only competitor at
/// some prefixes was the raw Latin literal — observed as a
/// `noLatinLeak` failure on the literary word `ဤပြဿနာ` ("this problem")
/// after a lexicon/LM regeneration shifted which fallback won rank 0.
///
/// The fix keeps the off-seed skip (mid-surface pollution) and the
/// particle skip (a sentence-initial particle still has nothing to
/// attach to) but allows surface-initial independent vowels. This is a
/// parser-level property: it holds identically on the bare engine and
/// the production stack.
public enum SeedIndependentVowelOnsetSuite {

    private static func bareEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(),
                      languageModel: NullLanguageModel())
    }

    private static func topSurface(_ engine: BurmeseEngine, _ input: String) -> String {
        engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
    }

    private static func containsLatin(_ s: String) -> Bool {
        s.unicodeScalars.contains { v in
            (v.value >= 0x41 && v.value <= 0x5A) || (v.value >= 0x61 && v.value <= 0x7A)
        }
    }

    /// (buffer, expected rank-0 surface) — deterministic on the bare
    /// parser. `ii` -> ဤ (U+1024), `oo` -> ဩ (U+1029).
    private static let bareCases: [(buffer: String, expected: String)] = [
        ("ii", "ဤ"),            // 1024
        ("iipy", "ဤပြ"),        // 1024 1015 103C — the regression case
        ("iipya", "ဤပြ"),       // 1024 1015 103C
        ("iikar", "ဤကာ"),       // 1024 1000 102C — seed indep-vowel + new syllable
        ("oogar", "ဩဂါ"),       // 1029 1002 102B — generalises to ဩ
    ]

    public static let suite = TestSuite(name: "SeedIndependentVowelOnset", cases: [

        // Bare parser: the seed independent vowel survives into the
        // multi-syllable parse instead of collapsing to an `အီ…`
        // fallback.
        TestCase("bare_seedIndependentVowelRendersCorrectly") { ctx in
            let engine = bareEngine()
            for c in bareCases {
                let top = topSurface(engine, c.buffer)
                ctx.assertEqual(
                    top, c.expected,
                    "\(c.buffer) want[\(hex(c.expected))] got[\(hex(top))]"
                )
            }
        },

        // Bare parser: no raw-Latin literal at rank 0 for any of these
        // buffers (the literal only wins when every Burmese sibling is
        // illegal / mostly-unconverted, which the fix prevents here).
        TestCase("bare_noLatinLeakAtSeedIndependentVowel") { ctx in
            let engine = bareEngine()
            for c in bareCases {
                let top = topSurface(engine, c.buffer)
                ctx.assertFalse(
                    containsLatin(top), c.buffer,
                    detail: "rank-0 leaked Latin: '\(top)'"
                )
            }
        },

        // Production stack: the prefixes of the literary word
        // ဤပြဿနာ ("this problem") that previously leaked Latin now
        // produce a ဤ-initial Burmese surface. Skips cleanly when the
        // bundled artifacts are absent.
        TestCase("prod_thisProblemPrefixesNoLatinLeak") { ctx in
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath),
                  let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
            for buf in ["iipy", "iipya", "iipyassan", "iipyassana"] {
                let top = engine.update(buffer: buf, context: []).candidates.first?.surface ?? ""
                ctx.assertFalse(
                    containsLatin(top), buf,
                    detail: "rank-0 leaked Latin: '\(top)' [\(hex(top))]"
                )
                ctx.assertTrue(
                    top.unicodeScalars.first?.value == 0x1024, "\(buf)_startsWithII",
                    detail: "expected surface-initial ဤ (U+1024); got '\(top)' [\(hex(top))]"
                )
            }
        },
    ])
}
