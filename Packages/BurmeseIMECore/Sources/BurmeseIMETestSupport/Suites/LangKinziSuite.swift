import Foundation
import BurmeseIMECore

/// Step 4 / Tier 3 — C16 (kinzi shape).
///
/// Kinzi is the canonical 3-codepoint sequence `1004 103A 1039`
/// rendering as a superscript ng over the next consonant. It
/// appears in the highest-frequency native words (မင်္ဂလာ "blessing",
/// အင်္ဂါ "Tuesday", အင်္ကျီ "shirt", သင်္ဘော "ship") and must
/// surface at rank 0 for the canonical user-typed inputs.
public enum LangKinziSuite {

    private static let kinziScalars: [UInt32] = [0x1004, 0x103A, 0x1039]

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

    private static func surfaceContainsKinzi(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        for i in 0..<max(0, scalars.count - 2) {
            if scalars[i].value == 0x1004
                && scalars[i+1].value == 0x103A
                && scalars[i+2].value == 0x1039 {
                return true
            }
        }
        return false
    }

    private static func assertRank0HasKinzi(
        _ ctx: TestContext,
        input: String,
        expectedSurface: String? = nil
    ) {
        guard let engine = bundledEngine(ctx) else { return }
        let state = engine.update(buffer: input, context: [])
        let top = state.candidates.first?.surface ?? ""
        ctx.assertTrue(
            surfaceContainsKinzi(top),
            input,
            detail: "rank-0 lacks canonical kinzi sequence (1004 103A 1039); top='\(top)' panel=\(state.candidates.map(\.surface))"
        )
        if let expected = expectedSurface {
            ctx.assertEqual(top, expected, input + "_surface")
        }
    }

    public static let suite = TestSuite(name: "LangKinzi", cases: [

        TestCase("kinzi_mingalarpar_implicit") { ctx in
            assertRank0HasKinzi(ctx, input: "mingalarpar", expectedSurface: "မင်္ဂလာပါ")
        },

        TestCase("kinzi_mingalarpar_explicit") { ctx in
            // Explicit-plus virama form.
            assertRank0HasKinzi(ctx, input: "min+galarpar")
        },

        TestCase("kinzi_arnggar_tuesday") { ctx in
            // `aing+gar` → အင်္ဂါ "Tuesday" — kinzi over ga + tall aa.
            assertRank0HasKinzi(ctx, input: "aing+gar")
        },

        TestCase("kinzi_aingkyi_shirt") { ctx in
            // `aing+kyi` → အင်္ကျီ — kinzi over palatalised ka.
            assertRank0HasKinzi(ctx, input: "aing+kyi")
        },

        TestCase("kinzi_thingbaw_ship") { ctx in
            // `thin+baw` → သင်္ဘော. Note: `b` (single letter) maps
            // to ဘ U+1018; `bh` would be `b` + `h` = two consonants.
            assertRank0HasKinzi(ctx, input: "thin+baw")
        },

        // Negative invariant: a kinzi-bearing surface must NOT mix
        // the canonical sequence with a duplicate `င် ` standalone
        // coda. `မင်င်္` is structurally invalid.
        TestCase("kinzi_noDoubleNgaCoda") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "mingalarpar", context: [])
            let top = state.candidates.first?.surface ?? ""
            // Count occurrences of `1004 103A` (asat-bearing nga).
            let scalars = Array(top.unicodeScalars).map(\.value)
            var ngaAsatCount = 0
            for i in 0..<max(0, scalars.count - 1) {
                if scalars[i] == 0x1004 && scalars[i+1] == 0x103A {
                    ngaAsatCount += 1
                }
            }
            ctx.assertEqual(ngaAsatCount, 1, "kinzi_one_nga")
        },

        // Negative: kinzi surfaces must not contain trailing
        // ASCII-letter leakage from the typed buffer.
        TestCase("kinzi_noAsciiLeak") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "mingalarpar", context: [])
            let top = state.candidates.first?.surface ?? ""
            let hasAscii = top.unicodeScalars.contains { $0.value >= 0x20 && $0.value <= 0x7E }
            ctx.assertFalse(
                hasAscii,
                "kinzi_clean",
                detail: "rank-0 contains ASCII: '\(top)'"
            )
        },
    ])
}
