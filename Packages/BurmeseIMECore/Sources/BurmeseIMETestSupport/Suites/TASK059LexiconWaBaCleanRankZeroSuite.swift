import Foundation
import BurmeseIMECore

/// TASK-059 regression gate. Burmese corpus text uses U+1040 (digit zero)
/// and U+101D (consonant `wa`) interchangeably, so before the 2026-05-11
/// corpus regeneration the lexicon held many `wa`/`ba`-reading entries
/// whose surface carried a Myanmar digit the user never typed
/// (`wa` -> `၁ဝ`, `ba` -> `ဘ၀`, etc). The corpus-builder
/// `_canonicalize_confusables` fix + regeneration removed the poison;
/// this suite locks in the rank-0 cleanliness predicate so a future
/// rebuild can't silently re-introduce it.
///
/// Predicate: for an input containing no ASCII digit, the rank-0 surface
/// must contain no Myanmar digit scalar (U+1040..U+1049).
public enum TASK059LexiconWaBaCleanRankZeroSuite {

    private static let myanmarDigits: ClosedRange<UInt32> = 0x1040...0x1049

    private static func containsMyanmarDigit(_ s: String) -> Bool {
        s.unicodeScalars.contains { myanmarDigits.contains($0.value) }
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

    public static let suite: TestSuite = {
        var cases: [TestCase] = []

        // Rank-0 must be free of phantom Myanmar digits for the bug
        // buffers (no ASCII digit in input).
        let bugBuffers = ["wa", "ba", "wa.", "wa:", "ba.", "bar", "war", "wun"]
        for buffer in bugBuffers {
            cases.append(TestCase("rank0_noPhantomDigit_\(buffer)") { ctx in
                guard let engine = bundledEngine(ctx) else { return }
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first else {
                    ctx.fail("rank0_missing", detail: "no candidates for '\(buffer)'")
                    return
                }
                let hex = top.surface.unicodeScalars
                    .map { String(format: "%04X", $0.value) }
                    .joined(separator: " ")
                ctx.assertTrue(
                    !containsMyanmarDigit(top.surface),
                    detail: "phantom Myanmar digit at rank 0 for '\(buffer)': surface='\(top.surface)' (\(hex))"
                )
            })
        }

        // When the user DOES type an ASCII digit, a Myanmar digit at the
        // typed position is correct (digit-as-literal, CLAUDE.md §3); the
        // predicate still bans a phantom digit at a non-typed position.
        // For `wa1` the legal shapes are `ဝ၁` or `ဝ1`; `၁ဝ၁` is the
        // pre-fix bug.
        cases.append(TestCase("rank0_wa1_digitOnlyAtTypedPosition") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "wa1", context: [])
            guard let top = state.candidates.first else {
                ctx.fail("rank0_missing", detail: "no candidates for 'wa1'")
                return
            }
            let hex = top.surface.unicodeScalars
                .map { String(format: "%04X", $0.value) }
                .joined(separator: " ")
            // Pre-fix rank 0 was `၁ဝ၁` (leading phantom `၁`). Lock in
            // that the surface does not start with a Myanmar digit.
            let firstIsDigit = top.surface.unicodeScalars.first
                .map { myanmarDigits.contains($0.value) } ?? false
            ctx.assertTrue(
                !firstIsDigit,
                detail: "leading phantom Myanmar digit at rank 0 for 'wa1': surface='\(top.surface)' (\(hex))"
            )
        })

        return TestSuite(name: "TASK059LexiconWaBaCleanRankZero", cases: cases)
    }()
}
