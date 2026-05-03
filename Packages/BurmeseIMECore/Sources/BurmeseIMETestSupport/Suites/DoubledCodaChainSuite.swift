import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-039: Onsetless doubled-`e` (and similar) inputs produce a
/// surface where two `<C><U+103A>` closed-coda fragments chain on a
/// single anchor with no new base between them
/// (e.g. `eea` → `1021 101A 103A 101A 103A`). The pattern is
/// orthographically illegal — Burmese never has two ya-asat
/// codas back-to-back attached to the same base.
///
/// The suite covers:
///   - The dedicated predicate
///     `surfaceContainsDoubledCodaChain` recognises the bug shape on
///     the documented inputs and rejects legitimate
///     `<base><coda><base><coda>` shapes.
///   - The engine never surfaces a doubled-coda chain at any rank
///     in the panel for `eea` / `een` / `eeng` / `eeing` / `een+ka`
///     when at least one clean sibling exists.
///   - The bare `ee` independent-vowel override (`အီ`) still wins.
public enum DoubledCodaChainSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    public static let suite = TestSuite(name: "DoubledCodaChain", cases: [

        // Direct unit tests of the new predicate.
        TestCase("predicate_flagsDoubledCodaChain") { ctx in
            let violators: [(String, [UInt32])] = [
                ("eea",     [0x1021, 0x101A, 0x103A, 0x101A, 0x103A]),
                ("een",     [0x1021, 0x101A, 0x103A, 0x101A, 0x103A, 0x1014]),
                ("eeng",    [0x1021, 0x101A, 0x103A, 0x101A, 0x103A, 0x1004]),
                ("een+ka",  [0x1021, 0x101A, 0x103A, 0x101A, 0x103A, 0x1014, 0x1039, 0x1000]),
                ("eeing",   [0x1021, 0x101A, 0x103A, 0x101A, 0x103A, 0x1004, 0x103A, 0x1039, 0x1002]),
                ("aye+e",   [0x1027, 0x101A, 0x103A, 0x101A, 0x103A]),
                ("aye+e_alt", [0x1021, 0x1031, 0x101A, 0x103A, 0x101A, 0x103A]),
            ]
            for (label, scalars) in violators {
                var s = ""
                s.unicodeScalars.append(
                    contentsOf: scalars.compactMap { Unicode.Scalar($0) }
                )
                ctx.assertTrue(
                    BurmeseEngine.surfaceContainsDoubledCodaChain(s),
                    label,
                    detail: "predicate failed to flag '\(label)' surface='\(s)'"
                )
            }
            // Negative cases: legitimate `<base><coda><base><coda>` shapes
            // where the second coda has its OWN consonant base (the
            // intervening consonant is the new syllable's base, not just
            // a coda continuation).
            let nonViolators: [(String, [UInt32])] = [
                ("let_pet", [0x101C, 0x1000, 0x103A, 0x1015, 0x1000, 0x103A]),
                ("kintkint",
                 [0x1000, 0x1004, 0x103A, 0x1010, 0x1000, 0x1004, 0x103A, 0x1010]),
                ("ngantnin",
                 [0x1004, 0x1014, 0x103A, 0x1010, 0x1014, 0x1004, 0x103A]),
                ("aye_one_only", [0x1021, 0x101A, 0x103A]),  // single coda
                ("ee", [0x1021, 0x102E]),  // bare-vowel override surface
            ]
            for (label, scalars) in nonViolators {
                var s = ""
                s.unicodeScalars.append(
                    contentsOf: scalars.compactMap { Unicode.Scalar($0) }
                )
                ctx.assertFalse(
                    BurmeseEngine.surfaceContainsDoubledCodaChain(s),
                    label,
                    detail: "predicate over-flagged '\(label)' surface='\(s)'"
                )
            }
        },

        // Engine: the rank-0 surface for the documented buffers must
        // not carry the doubled-coda pattern. Either the engine
        // produces a legal-structure parse (e.g. the `ee` →
        // `အီ` override extending to `eea` → `အီ` + literal-tail) or
        // the surface is the bare buffer fallthrough — both are
        // acceptable per the task's desired state.
        TestCase("engine_rank0FreeOfDoubledCodaChain") { ctx in
            let buffers = ["eea", "een", "eeng", "eeing", "een+ka"]
            for buffer in buffers {
                let surface = emptyEngine()
                    .update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    BurmeseEngine.surfaceContainsDoubledCodaChain(surface),
                    buffer,
                    detail: "rank-0 carries doubled-coda chain for '\(buffer)' surface='\(surface)'"
                )
            }
        },

        // Engine: every candidate in the panel for the documented
        // buffers must be free of the doubled-coda pattern when at
        // least one clean sibling exists. (For inputs whose every
        // parse is illegal, the fallback policy may surface the
        // violator at rank 0 — but the engine can almost always
        // produce at least an `อီ` + literal-tail shape for these.)
        TestCase("engine_panelFreeOfDoubledCodaChainWhenSiblingExists") { ctx in
            let buffers = ["eea", "een", "eeng", "eeing", "een+ka"]
            for buffer in buffers {
                let candidates = emptyEngine()
                    .update(buffer: buffer, context: [])
                    .candidates
                let cleanExists = candidates.contains {
                    !BurmeseEngine.surfaceContainsDoubledCodaChain($0.surface)
                }
                guard cleanExists else { continue }
                for (i, c) in candidates.enumerated() {
                    ctx.assertFalse(
                        BurmeseEngine.surfaceContainsDoubledCodaChain(c.surface),
                        buffer,
                        detail: "rank-\(i) violates for '\(buffer)' surface='\(c.surface)'"
                    )
                }
            }
        },

        // Regression: the bare-`ee` override still produces `အီ` at
        // rank 0.
        TestCase("engine_bareEeOverrideUnchanged") { ctx in
            let surface = emptyEngine()
                .update(buffer: "ee", context: [])
                .candidates.first?.surface ?? ""
            ctx.assertEqual(surface, "\u{1021}\u{102E}", "ee", file: #file, line: #line)
        },

        // Regression: legitimate `<C><coda><C><coda>` two-syllable
        // shapes survive untouched (`let+pet` → `လက်ပက်`).
        TestCase("engine_twoSyllableCodaChainSurvives") { ctx in
            let surface = emptyEngine()
                .update(buffer: "let+pet", context: [])
                .candidates.first?.surface ?? ""
            ctx.assertEqual(
                surface,
                "\u{101C}\u{1000}\u{103A}\u{1015}\u{1000}\u{103A}",
                "let+pet",
                file: #file,
                line: #line
            )
        },
    ])
}
