import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-031: explicit user-typed `+` between `<C>(in|an|en|...)` and a
/// stack lower must keep the kinzi or native virama-stack surface at
/// production rank 0. The bug: the LM-driven composite ranking can
/// flip an LM-favoured cross-class re-segmentation
/// (`မည်န္ဂ` for `min+ga`, `သည်န္ဂ` for `thin+ga`) or an anusvara
/// closure (`ကံဂ` for `kan+ga`, `ယံဂူန` for `yan+gun`) above the
/// user's clearly-intended kinzi/asat-closure form. The user-typed
/// `+` is the strongest possible "stack here" signal — overriding
/// it forces the user to navigate past multiple wrong panels to
/// find the surface they typed for.
///
/// Suite uses the production-equivalent engine (bundled SQLite
/// lexicon + trigram LM). The bare engine ranks the kinzi at top-1
/// for every bug-class buffer; the displacement only manifests once
/// the LM/lexicon ranking is wired in.
public enum ExplicitPlusKinziDisplacementSuite {

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
        s.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
    }

    /// True when `surface` contains the kinzi triple `1004 103A 1039`.
    private static func containsKinzi(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 3 else { return false }
        for i in 0...(scalars.count - 3) where
            scalars[i] == 0x1004 && scalars[i + 1] == 0x103A && scalars[i + 2] == 0x1039 {
            return true
        }
        return false
    }

    /// True when `surface` contains a `<base> 103A` (asat-closed coda)
    /// at any position. Used for `<C>an+<C>` shapes where the closure
    /// is na+asat (`1014 103A`) rather than kinzi.
    private static func containsAsatClosure(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        for i in 0..<(scalars.count - 1) where scalars[i + 1] == 0x103A {
            let v = scalars[i]
            if (v >= 0x1000 && v <= 0x1021) || v == 0x103F {
                return true
            }
        }
        return false
    }

    /// True when `surface` contains anusvara (`1036`).
    private static func containsAnusvara(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value == 0x1036 }
    }

    /// Bug-class buffers from TASK-031 *Current State*. Each shipping
    /// production rank-0 displaces the user-respecting kinzi / native-
    /// virama-stack form to rank ≥ 1.
    public static let suite = TestSuite(name: "ExplicitPlusKinziDisplacement", cases: [

        // Kinzi-closure bug class. The user typed `<C>in+<C>` (or
        // `<C>en+<C>`/`<C>on+<C>` with a velar-class lower); the
        // expected rank-0 surface contains the kinzi triple
        // `1004 103A 1039` immediately followed by the lower
        // consonant.
        TestCase("kinziClosure_min+ga_familyAtRank0") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffers: [String] = [
                "min+ga",
                "min+ka",
                "min+galarpar",
                "thin+ga",
                "thin+gala",
                "thin+ga+thin",
                "thin+kun",
                "tin+ga",
                "tin+ga+min",
                "min+ga+min",
            ]
            for buffer in buffers {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first else {
                    ctx.assertTrue(false, buffer, detail: "panel empty")
                    continue
                }
                ctx.assertTrue(
                    containsKinzi(top.surface),
                    buffer,
                    detail: "rank-0='\(top.surface)' (\(hex(top.surface))) lacks kinzi 1004 103A 1039"
                )
            }
        },

        // Native virama-stack / na-asat-closure bug class. The user
        // typed `<C>an+<C>` (or `<C>en+<C>` with non-velar lower);
        // the expected rank-0 surface contains `<base> 103A` (asat-
        // closed coda) at the user-typed `+` position. Anusvara
        // `1036` substitution is the bug pattern that this guards
        // against.
        TestCase("asatClosure_kan+ga_familyAtRank0") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffers: [String] = [
                "kan+ga",
                "ran+ga",
                "nan+ga",
                "than+ga",
                "ban+ga",
                "yan+gun",
                "yan+kun",
            ]
            for buffer in buffers {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first else {
                    ctx.assertTrue(false, buffer, detail: "panel empty")
                    continue
                }
                ctx.assertTrue(
                    containsAsatClosure(top.surface),
                    "\(buffer)_hasAsatClosure",
                    detail: "rank-0='\(top.surface)' (\(hex(top.surface))) lacks <base> 103A asat-closure"
                )
                ctx.assertFalse(
                    containsAnusvara(top.surface),
                    "\(buffer)_noAnusvara",
                    detail: "rank-0='\(top.surface)' (\(hex(top.surface))) used anusvara 1036 instead of asat closure"
                )
            }
        },

        // Concrete scalar-level assertion for the canonical `min+ga`
        // case. The kinzi triple must appear immediately followed by
        // `1002` (ga, the lower).
        TestCase("min+ga_kinziImmediatelyBeforeLower") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "min+ga", context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, "min+ga", detail: "panel empty")
                return
            }
            let scalars = Array(top.surface.unicodeScalars).map(\.value)
            ctx.assertEqual(
                scalars,
                [0x1019, 0x1004, 0x103A, 0x1039, 0x1002],
                "min+ga rank-0='\(top.surface)' (\(hex(top.surface)))"
            )
        },

        // Concrete scalar-level assertion for the canonical `kan+ga`
        // case. `<C> 1014 103A <lower>` (na+asat closure) is the
        // user-respecting shape; anusvara substitution is the bug.
        TestCase("kan+ga_naAsatImmediatelyBeforeLower") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "kan+ga", context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, "kan+ga", detail: "panel empty")
                return
            }
            let scalars = Array(top.surface.unicodeScalars).map(\.value)
            ctx.assertEqual(
                scalars,
                [0x1000, 0x1014, 0x103A, 0x1002],
                "kan+ga rank-0='\(top.surface)' (\(hex(top.surface)))"
            )
        },

        // Discriminator helper sanity. The reading-match-modulo-
        // inherent-vowel-`a` predicate must accept inverse-of-TASK-011
        // shapes (parser-inserted `a` immediately before a `+`) and
        // trailing inherent-vowel appends, but reject mid-syllable
        // `a` insertions and `2`/`3` disambiguators.
        TestCase("readingMatchPredicate_acceptsInherentVowelInsertions") { ctx in
            // Exact match.
            ctx.assertTrue(BurmeseEngine.readingMatchesUserLiteralAcrossInherentVowels(
                parseReading: "min+ga",
                userInput: "min+ga"
            ), "exactMatch")
            // Trailing-`a` (parser appended inherent vowel after
            // bare trailing consonant).
            ctx.assertTrue(BurmeseEngine.readingMatchesUserLiteralAcrossInherentVowels(
                parseReading: "yan+guna",
                userInput: "yan+gun"
            ), "trailingInherentA")
            ctx.assertTrue(BurmeseEngine.readingMatchesUserLiteralAcrossInherentVowels(
                parseReading: "thin+kuna",
                userInput: "thin+kun"
            ), "trailingInherentA_thinKun")
            // Inverse-of-TASK-011 reshape: parser inserted `a` before
            // a `+`. User originally typed `thin+ga+thin`, the
            // `collapseConnectorRuns` reshape stripped the middle `a`
            // before `+`, and the parser rebuilt it.
            ctx.assertTrue(BurmeseEngine.readingMatchesUserLiteralAcrossInherentVowels(
                parseReading: "thin+ga+thin",
                userInput: "thin+ga+thin"
            ), "inverseTask011")
            ctx.assertTrue(BurmeseEngine.readingMatchesUserLiteralAcrossInherentVowels(
                parseReading: "thin+ga+thin",
                userInput: "thin+g+thin"
            ), "inverseTask011_post-reshape")
        },

        TestCase("readingMatchPredicate_rejectsSegmentationChanges") { ctx in
            // `2` disambiguator means the parser picked a variant
            // that the user didn't type.
            ctx.assertFalse(BurmeseEngine.readingMatchesUserLiteralAcrossInherentVowels(
                parseReading: "mi2n+ga",
                userInput: "min+ga"
            ), "rejectsTwo")
            ctx.assertFalse(BurmeseEngine.readingMatchesUserLiteralAcrossInherentVowels(
                parseReading: "kan2+ga",
                userInput: "kan+ga"
            ), "rejectsTwo_kanGa")
            // Mid-syllable `a` insertion (between two onset
            // consonants). For user `brah+ma`, parser reading
            // `barah+ma` represents segmenting `b` as a separate
            // syllable `ba` instead of an onset cluster `bra` —
            // that's a segmentation change, not an inherent-vowel
            // fill.
            ctx.assertFalse(BurmeseEngine.readingMatchesUserLiteralAcrossInherentVowels(
                parseReading: "barah+ma",
                userInput: "brah+ma"
            ), "rejectsMidSyllableA")
            // Different reading altogether.
            ctx.assertFalse(BurmeseEngine.readingMatchesUserLiteralAcrossInherentVowels(
                parseReading: "tahin+ga+thin",
                userInput: "thin+ga+thin"
            ), "rejectsExtraOnset")
        },

        // Baseline preservation: the cases the task explicitly lists
        // as "currently correct" must continue to surface their
        // existing rank-0 surfaces. This guards against an over-
        // aggressive promotion that flips shapes the LM was already
        // ranking correctly.
        TestCase("baseline_correctCasesAreUnchanged") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(String, [UInt32])] = [
                ("min+ka", [0x1019, 0x1004, 0x103A, 0x1039, 0x1000]),     // မင်္က
                ("tin+ga", [0x1010, 0x1004, 0x103A, 0x1039, 0x1002]),     // တင်္ဂ
                ("ban+ga", [0x1018, 0x1014, 0x103A, 0x1002]),             // ဘန်ဂ
                ("min+ga+min", [0x1019, 0x1004, 0x103A, 0x1039, 0x1002,
                                0x1019, 0x1004, 0x103A]),                  // မင်္ဂမင်
                ("tin+ga+min", [0x1010, 0x1004, 0x103A, 0x1039, 0x1002,
                                0x1019, 0x1004, 0x103A]),                  // တင်္ဂမင်
            ]
            for (buffer, expected) in cases {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first else {
                    ctx.assertTrue(false, buffer, detail: "panel empty")
                    continue
                }
                let scalars = Array(top.surface.unicodeScalars).map(\.value)
                ctx.assertEqual(
                    scalars,
                    expected,
                    "\(buffer) rank-0='\(top.surface)' (\(hex(top.surface)))"
                )
            }
        },

        // Cross-class explicit-`+` (TASK-031 must not regress the
        // existing `ExplicitVirama` invariants). The `pad+ma` /
        // `brah+ma` family — non-Burmese cross-class loanword shapes
        // — must keep their virama-stacked rank-0 surface, matching
        // the no-`+` sibling.
        TestCase("crossClassPlus_keepsViramaAtRank0") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffers: [String] = ["pad+ma", "brah+ma", "nag+ma", "yag+na"]
            for buffer in buffers {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first else {
                    ctx.assertTrue(false, buffer, detail: "panel empty")
                    continue
                }
                let hasVirama = top.surface.unicodeScalars.contains { $0.value == 0x1039 }
                ctx.assertTrue(
                    hasVirama,
                    buffer,
                    detail: "rank-0='\(top.surface)' (\(hex(top.surface))) lost the virama"
                )
            }
        },
    ])
}
