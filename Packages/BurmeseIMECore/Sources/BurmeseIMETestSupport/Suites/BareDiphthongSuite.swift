import Foundation
import BurmeseIMECore

public enum BareDiphthongSuite {

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

    private static func parseTop(_ input: String) -> String {
        SyllableParser().parse(input).first?.output ?? ""
    }

    private static let diphthongPrefix: [UInt32] = [0x102D, 0x102F, 0x1004, 0x103A]

    private static func startsWithDiphthong(_ surface: String) -> Bool {
        let scalars = surface.unicodeScalars.map(\.value)
        // Tolerate a leading invisible base (ZWNJ) or independent vowel
        // (`အ`) ahead of the diphthong sequence.
        for offset in 0...min(1, scalars.count) {
            guard scalars.count >= offset + diphthongPrefix.count else { continue }
            if Array(scalars[offset..<offset + diphthongPrefix.count]) == diphthongPrefix {
                return true
            }
        }
        return false
    }

    public static let suite = TestSuite(name: "BareDiphthong", cases: [

        // Task 04: bare `ai` diphthong (`ိုင်`) must win over the
        // `ain` 3-char vowel-coda rule (`ိန်`) when the buffer is shaped
        // `aing<…>`. Both decompositions consume the same chars and
        // tie on the parser DP score, so the canonical diphthong
        // anchored reading needs a deterministic tiebreak in its
        // favour.
        TestCase("aing_topUsesDiphthongPrefix") { ctx in
            let top = parseTop("aing")
            ctx.assertTrue(
                startsWithDiphthong(top),
                "aing_diphthongTop",
                detail: "top=\(top.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " "))"
            )
        },

        TestCase("aingthi_topUsesDiphthongPrefix") { ctx in
            let top = parseTop("aingthi")
            ctx.assertTrue(
                startsWithDiphthong(top),
                "aingthi_diphthongTop",
                detail: "top=\(top.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " "))"
            )
        },

        TestCase("ainggar_topUsesDiphthongPrefix") { ctx in
            // Combined task 03 + task 04 case: the diphthong `ai`
            // anchors the leading vowel + bare `ng`, and the kinzi
            // inference (task 03) fires for the trailing `gar`.
            // The top must start with the diphthong `ိုင်`.
            let top = parseTop("ainggar")
            ctx.assertTrue(
                startsWithDiphthong(top),
                "ainggar_diphthongTop",
                detail: "top=\(top.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " "))"
            )
        },

        // Negative controls: every shape that already produces the
        // diphthong at rank 1 must continue to do so.
        // (`aina` is intentionally absent — the parser picks the
        // `ain` rule and drops the trailing `a`, which is a separate
        // behaviour outside this task's scope.)
        TestCase("diphthongShapes_unchanged") { ctx in
            for input in [
                "aim",      // `aim` has no 3-char rule — ai + m
                "ait",      // `ai` + `t`
                "aitha",    // `ai` + `tha`
                "aitkya",   // `ai` + `t` + `kya`
                "ai",       // bare diphthong
            ] {
                let top = parseTop(input)
                ctx.assertTrue(
                    startsWithDiphthong(top),
                    "diphthongUnchanged.\(input)",
                    detail: "top=\(top)"
                )
            }
        },

        // Explicit `ain` rule paths: when the user wants the short-i
        // + na-asat reading they still get it, since neither the
        // diphthong nor the kinzi inference applies past `ain<vowel>`
        // / `ain.` / `ain:` shapes.
        TestCase("explicitAinShortIPathsRemain") { ctx in
            let cases: [(String, [UInt32])] = [
                ("ain",  [0x102D, 0x1014, 0x103A]),
                ("ain.", [0x102D, 0x1014, 0x1037, 0x103A]),
            ]
            for (input, expectedTail) in cases {
                let top = parseTop(input)
                let scalars = top.unicodeScalars.map(\.value)
                let suffix = Array(scalars.suffix(expectedTail.count))
                ctx.assertEqual(
                    suffix, expectedTail,
                    "ainPathRetained.\(input)"
                )
            }
        },

        // End-to-end through the engine (with bundled lexicon + LM)
        // to confirm the surface reaches the user-visible top.
        TestCase("aing_engineTop_diphthong") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "aing", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertTrue(
                startsWithDiphthong(top),
                "aing_engineTop",
                detail: "top=\(top) all=\(state.candidates.map(\.surface))"
            )
        },

        TestCase("aingthi_engineTop_diphthong") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "aingthi", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertTrue(
                startsWithDiphthong(top),
                "aingthi_engineTop",
                detail: "top=\(top) all=\(state.candidates.map(\.surface))"
            )
        },

        // Combined task 03 + 04: `ainggar` should land on the canonical
        // kinzi-anchored Pali surface `အိုင်္ဂါ` at rank 1. The
        // diphthong `ai` provides the leading vowel cluster, the bare
        // `ng` is the kinzi upper, the trailing `g` is the kinzi
        // lower, and `ar` rounds out the descender's tall-aa.
        TestCase("ainggar_engineTop_kinziDiphthong") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "ainggar", context: [])
            let top = state.candidates.first?.surface ?? ""
            // U+1021 အ + U+102D ိ + U+102F ု + U+1004 င + U+103A ် +
            // U+1039 ္ + U+1002 ဂ + U+102B ါ
            let expected: [UInt32] = [0x1021, 0x102D, 0x102F, 0x1004, 0x103A, 0x1039, 0x1002, 0x102B]
            let actual = top.unicodeScalars.map(\.value)
            ctx.assertEqual(
                actual, expected,
                "ainggar_kinziDiphthong"
            )
        },
    ])
}
