import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-053: Explicit user-typed `<C>(in|an)+<C>` shape must keep the
/// kinzi (or asat-closure) at rank 0 even when the post-stack syllable
/// carries a trailing tone marker (`.` / `:`) or digit. Pre-fix the
/// LM's no-kinzi sibling (`မည်န္ဂ့` for `min+ga.`) displaced the
/// user-respecting kinzi (`မင်္ဂ့`) past rank 0; for several buffers
/// the kinzi parse was missing from the panel entirely. This suite
/// covers the cross-product of strict-class consonants × tone-suffix
/// variants.
///
/// Suite uses the production-equivalent engine (bundled SQLite +
/// trigram LM). The bare engine ranks the kinzi/na-asat baseline at
/// rank 0 for every buffer; the displacement only manifests once the
/// LM/lexicon ranking is wired in.
public enum ExplicitKinziTonePromotionSuite {

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

    private static func containsKinzi(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 3 else { return false }
        for i in 0...(scalars.count - 3) where
            scalars[i] == 0x1004 && scalars[i + 1] == 0x103A && scalars[i + 2] == 0x1039 {
            return true
        }
        return false
    }

    private static func containsAnusvara(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value == 0x1036 }
    }

    /// True when `surface` contains a `<base> 103A` (asat-closed coda)
    /// at any position. Used for `<C>an+<C>` shapes where the closure
    /// is na+asat (`1014 103A`) rather than kinzi.
    private static func containsAsatClosure(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 2 else { return false }
        for i in 0..<(scalars.count - 1) where scalars[i + 1] == 0x103A {
            let v = scalars[i]
            if (v >= 0x1000 && v <= 0x1021) || v == 0x103F {
                return true
            }
        }
        return false
    }

    public static let suite = TestSuite(name: "ExplicitKinziTonePromotion", cases: [

        // Kinzi-class buffers: `<C>(in)+<lower>` where `<C>` ∈ {m, th}
        // and the post-stack syllable ends with inherent-`a` plus an
        // optional tone marker. The bare-engine baseline is kinzi.
        TestCase("kinziClass_in_familyAtRank0_with_tone_or_digit") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffers: [String] = [
                // Kinzi must hold at rank 0 across no-tone, creaky,
                // visarga, digit, and digit+creaky suffix variants.
                "min+ga", "min+ga.", "min+ga:", "min+ga2", "min+ga2.",
                "min+gha", "min+gha.",
                "thin+ga", "thin+ga.", "thin+ga:",
                "tin+ga", "tin+ga.",
                "in+ga", "in+ga.", "in+ga:",
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

        // Asat-closure-class buffers: `<C>an+<lower>` and `<C>en+<lower>`
        // / `<C>un+<lower>` where the bare-engine baseline is na-asat
        // (`1014 103A`) rather than kinzi. The TASK-031 bug class has
        // anusvara `1036` displacing na-asat at rank 0; the fix keeps
        // the bare-engine na-asat baseline regardless of trailing
        // tone/digit.
        TestCase("asatClass_kan_familyAtRank0_with_tone_or_digit") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffers: [String] = [
                // No-tone baseline (TASK-031 already covered these;
                // kept here so any future regression hits both
                // suites).
                "kan+ga", "ban+ga", "than+ga", "yan+gun",
                // Tone / digit suffix bug class (TASK-053).
                "kan+ga.", "kan+ga:",
                "than+ga.", "than+ga:",
                "yan+gun.",
                // Long-vowel sibling (`<C>an+<C>ar`): bare-engine
                // baseline is na-asat too.
                "than+gar.",
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

        // Concrete scalar-level assertion for the canonical `min+ga.`
        // case. The kinzi triple must appear immediately followed by
        // `1002` (ga) and then `1037` (creaky tone).
        TestCase("min+ga._kinziWithCreakyTone") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "min+ga.", context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, "min+ga.", detail: "panel empty")
                return
            }
            let scalars = Array(top.surface.unicodeScalars).map(\.value)
            ctx.assertEqual(
                scalars,
                [0x1019, 0x1004, 0x103A, 0x1039, 0x1002, 0x1037],
                "min+ga. rank-0='\(top.surface)' (\(hex(top.surface)))"
            )
        },

        // Concrete scalar-level assertion for `min+ga:` (visarga).
        TestCase("min+ga:_kinziWithVisarga") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "min+ga:", context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, "min+ga:", detail: "panel empty")
                return
            }
            let scalars = Array(top.surface.unicodeScalars).map(\.value)
            ctx.assertEqual(
                scalars,
                [0x1019, 0x1004, 0x103A, 0x1039, 0x1002, 0x1038],
                "min+ga: rank-0='\(top.surface)' (\(hex(top.surface)))"
            )
        },

        // Concrete scalar-level assertion for `min+ga2` (digit suffix).
        // The Myanmar-digit primary is `1042`.
        TestCase("min+ga2_kinziWithMyanmarDigit") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "min+ga2", context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, "min+ga2", detail: "panel empty")
                return
            }
            let scalars = Array(top.surface.unicodeScalars).map(\.value)
            ctx.assertEqual(
                scalars,
                [0x1019, 0x1004, 0x103A, 0x1039, 0x1002, 0x1042],
                "min+ga2 rank-0='\(top.surface)' (\(hex(top.surface)))"
            )
        },

        // Concrete scalar-level assertion for `than+ga.`. The bare-
        // engine baseline is `<C> 1014 103A <lower> 1037` (na-asat
        // upper + creaky tone); the TASK-031 bug pattern was anusvara
        // `1036` substitution.
        TestCase("than+ga._naAsatWithCreakyTone") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "than+ga.", context: [])
            guard let top = state.candidates.first else {
                ctx.assertTrue(false, "than+ga.", detail: "panel empty")
                return
            }
            let scalars = Array(top.surface.unicodeScalars).map(\.value)
            ctx.assertEqual(
                scalars,
                [0x101E, 0x1014, 0x103A, 0x1002, 0x1037],
                "than+ga. rank-0='\(top.surface)' (\(hex(top.surface)))"
            )
        },

        // TASK-031 regression guards: the no-tone buffers must keep
        // their existing rank-0 surfaces.
        TestCase("task031Regression_noToneBaselinesUnchanged") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(String, [UInt32])] = [
                ("min+ga",  [0x1019, 0x1004, 0x103A, 0x1039, 0x1002]),
                ("min+ka",  [0x1019, 0x1004, 0x103A, 0x1039, 0x1000]),
                ("tin+ga",  [0x1010, 0x1004, 0x103A, 0x1039, 0x1002]),
                ("ban+ga",  [0x1018, 0x1014, 0x103A, 0x1002]),
                ("kan+ga",  [0x1000, 0x1014, 0x103A, 0x1002]),
                ("than+ga", [0x101E, 0x1014, 0x103A, 0x1002]),
            ]
            for (buffer, expected) in cases {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first else {
                    ctx.assertTrue(false, buffer, detail: "panel empty")
                    continue
                }
                let scalars = Array(top.surface.unicodeScalars).map(\.value)
                ctx.assertEqual(
                    scalars, expected,
                    "\(buffer) rank-0='\(top.surface)' (\(hex(top.surface)))"
                )
            }
        },

        // Long-vowel sibling regression guards: `min+gar.`,
        // `thin+gar.` produce the kinzi+long-aa form at rank 0.
        // `than+gar.` produces the na-asat+long-aa form (bare-engine
        // baseline; not kinzi).
        TestCase("longVowelSibling_keepsItsBaselineAtRank0") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(String, [UInt32])] = [
                ("min+gar.",  [0x1019, 0x1004, 0x103A, 0x1039, 0x1002, 0x102B, 0x1037]),
                ("thin+gar.", [0x101E, 0x1004, 0x103A, 0x1039, 0x1002, 0x102B, 0x1037]),
                ("than+gar.", [0x101E, 0x1014, 0x103A, 0x1002, 0x102B, 0x1037]),
            ]
            for (buffer, expected) in cases {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first else {
                    ctx.assertTrue(false, buffer, detail: "panel empty")
                    continue
                }
                let scalars = Array(top.surface.unicodeScalars).map(\.value)
                ctx.assertEqual(
                    scalars, expected,
                    "\(buffer) rank-0='\(top.surface)' (\(hex(top.surface)))"
                )
            }
        },

        // `stripTrailingToneAndDigitMarkers` predicate sanity: the
        // helper must peel `.`/`:`/digit chains but leave the
        // pre-tone composable run intact. This is the discriminator
        // behind the explicit-`+` rank-0 promotion's tone-suffix
        // path.
        TestCase("stripTrailingToneAndDigitMarkers_sanity") { ctx in
            ctx.assertEqual(
                BurmeseEngine.stripTrailingToneAndDigitMarkers("min+ga."),
                "min+ga", "stripDot")
            ctx.assertEqual(
                BurmeseEngine.stripTrailingToneAndDigitMarkers("min+ga:"),
                "min+ga", "stripColon")
            ctx.assertEqual(
                BurmeseEngine.stripTrailingToneAndDigitMarkers("min+ga2"),
                "min+ga", "stripDigit")
            ctx.assertEqual(
                BurmeseEngine.stripTrailingToneAndDigitMarkers("min+ga2."),
                "min+ga", "stripDigitThenDot")
            ctx.assertEqual(
                BurmeseEngine.stripTrailingToneAndDigitMarkers("min+ga"),
                "min+ga", "noStrip")
            // Internal punctuation should not be peeled — only
            // trailing chars at the very end.
            ctx.assertEqual(
                BurmeseEngine.stripTrailingToneAndDigitMarkers("min:ga"),
                "min:ga", "internalColonNotStripped")
        },
    ])
}
