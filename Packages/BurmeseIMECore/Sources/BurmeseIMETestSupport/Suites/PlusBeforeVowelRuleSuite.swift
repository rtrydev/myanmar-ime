import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-047: a user-typed `+` between a bare consonant (or
/// `<C>ar` / `<C>ay` short-cluster) and a following onset-less
/// vowel-rule (`aung`, `aing`, `i`, …) must materialise as a hard
/// syllable boundary, not a soft separator that lets the right-hand
/// vowel-rule consume the left-hand consonant as its onset. The bug:
/// the parser's soft-`+` arc admits the merge silently, so user input
/// like `ka+aung` produces `ကောင်` (single syllable, the `k` consumed
/// as the onset of `aung`) at rank 0 — and worse, the two-syllable
/// `ကအောင်` interpretation is absent from the entire candidate panel.
///
/// Acceptance: each `<C><a/ar/ay>+<vowel-rule>` buffer must surface
/// the two-syllable `<C-side><1021><vowel-rule-side>` form somewhere
/// in the candidate panel; rank 0 strongly preferred.
public enum PlusBeforeVowelRuleSuite {

    /// Production-equivalent engine factory; `nil` if bundled
    /// artifacts are absent.
    private static func makeBundledEngine() -> BurmeseEngine? {
        guard let lp = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lp),
              let lmp = BundledArtifacts.trigramLMPath,
              let lm = try? TrigramLanguageModel(path: lmp) else {
            return nil
        }
        return BurmeseEngine(candidateStore: store, languageModel: lm)
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
    }

    /// Bug-class buffers from TASK-047 *Steps to Reproduce*. Each
    /// row's two-syllable form must appear in the candidate panel.
    /// Severity classes (annotated in the task):
    ///   - panel-reachability: bare-`<C>+<vowel-rule>` shapes where
    ///     the merge wins rank 0 AND the two-syllable form is absent
    ///     from the panel.
    ///   - rank-only: `<C>ar+<vowel-rule>` and `<C>ay+<vowel-rule>`
    ///     shapes where the two-syllable form is reachable at
    ///     rank ≥ 1 but the merge wins rank 0.
    private static let twoSyllableExpectations: [(String, [UInt32])] = [
        ("ka+aung",  [0x1000, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
        ("ma+aung",  [0x1019, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
        ("ya+aung",  [0x101A, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
        ("ta+aung",  [0x1010, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
        ("kar+aung", [0x1000, 0x102C, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
        ("mar+aung", [0x1019, 0x102C, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
        ("kay+aung", [0x1000, 0x1031, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
        ("ka+aing",  [0x1000, 0x1021, 0x102D, 0x102F, 0x1004, 0x103A]),
        ("kar+aing", [0x1000, 0x102C, 0x1021, 0x102D, 0x102F, 0x1004, 0x103A]),
        ("ka+i",     [0x1000, 0x1021, 0x102E]),
        ("k+aung",   [0x1000, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
    ]

    public static let suite = TestSuite(name: "PlusBeforeVowelRule", cases: [

        // Bare-engine panel-reachability: at minimum, the
        // two-syllable surface for every bug-class buffer must be in
        // the candidate panel. The bare engine has no lexicon /
        // history rerank, so this isolates the parser-side fix.
        TestCase("bareEngine_panelContainsTwoSyllableForm") { ctx in
            let engine = BurmeseEngine()
            for (buffer, expectedScalars) in twoSyllableExpectations {
                let state = engine.update(buffer: buffer, context: [])
                let expected = String(String.UnicodeScalarView(
                    expectedScalars.compactMap { Unicode.Scalar($0) }
                ))
                let panelHasIt = state.candidates.contains { $0.surface == expected }
                ctx.assertTrue(
                    panelHasIt,
                    "\(buffer)_bareEngine",
                    detail: "expected '\(expected)' (\(hex(expected))); top10=\(state.candidates.prefix(10).map(\.surface))"
                )
            }
        },

        // Production-equivalent panel-reachability: same assertion
        // through the bundled lexicon + LM stack.
        TestCase("productionEngine_panelContainsTwoSyllableForm") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            for (buffer, expectedScalars) in twoSyllableExpectations {
                let state = engine.update(buffer: buffer, context: [])
                let expected = String(String.UnicodeScalarView(
                    expectedScalars.compactMap { Unicode.Scalar($0) }
                ))
                let panelHasIt = state.candidates.contains { $0.surface == expected }
                ctx.assertTrue(
                    panelHasIt,
                    "\(buffer)_productionEngine",
                    detail: "expected '\(expected)' (\(hex(expected))); top10=\(state.candidates.prefix(10).map(\.surface))"
                )
            }
        },

        // Rank-0 assertion for the bare-`<C>+<vowel-rule>` subclass
        // (severity panel-reachability per the task table). The
        // bare-consonant LHS cannot be silently merged into the next
        // syllable's onset under the user's explicit `+`, so the
        // two-syllable form should win rank 0.
        TestCase("bareEngine_rank0IsTwoSyllable_bareConsonantLHS") { ctx in
            let engine = BurmeseEngine()
            let bareCases: [(String, [UInt32])] = [
                ("ka+aung",  [0x1000, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
                ("ma+aung",  [0x1019, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
                ("ka+aing",  [0x1000, 0x1021, 0x102D, 0x102F, 0x1004, 0x103A]),
                ("ka+i",     [0x1000, 0x1021, 0x102E]),
                ("k+aung",   [0x1000, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
            ]
            for (buffer, expectedScalars) in bareCases {
                let state = engine.update(buffer: buffer, context: [])
                let expected = String(String.UnicodeScalarView(
                    expectedScalars.compactMap { Unicode.Scalar($0) }
                ))
                ctx.assertEqual(
                    state.candidates.first?.surface ?? "",
                    expected,
                    "\(buffer)_bareEngine_rank0"
                )
            }
        },

        // Regression guards: TASK-031 explicit-`+` kinzi / virama
        // stacks must not be displaced. `min+ga` (kinzi at rank 0),
        // `ka+ka` (virama-stack subsequence), `pad+ma` (cross-class
        // virama-stack subsequence). The looser "contains the
        // virama-stack scalar triple" check mirrors the existing
        // `ExplicitPlusVowelSuite` invariant — the user-facing
        // `<upper> 1039 <lower>` clusters survive my anchor
        // injection unchanged.
        TestCase("regressionGuard_explicitPlusStacksUnchanged") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            // Strict check: the kinzi rendering wins rank 0 for
            // `min+ga`. TASK-031 guards this; my fix must not
            // displace it.
            let kinziState = engine.update(buffer: "min+ga", context: [])
            ctx.assertEqual(
                kinziState.candidates.first?.surface ?? "",
                "\u{1019}\u{1004}\u{103A}\u{1039}\u{1002}",
                "min+ga_kinziAtRank0"
            )
            // Loose check: virama-stack scalar triple present in the
            // top-1 surface for `ka+ka` and `pad+ma`. The exact
            // surface scalars can vary (e.g. `ka+ka` may surface as
            // `က္က` or `ကက္က` depending on which engine layer
            // re-shapes the inherent-A); both contain the
            // `<upper> 1039 <lower>` triple.
            let stacks: [(String, UInt32, UInt32)] = [
                ("ka+ka",  0x1000, 0x1000),
                ("pad+ma", 0x1012, 0x1019),
            ]
            for (buffer, upper, lower) in stacks {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars).map(\.value)
                let hasTriple: Bool = {
                    guard scalars.count >= 3 else { return false }
                    for i in 0..<(scalars.count - 2)
                    where scalars[i] == upper
                       && scalars[i + 1] == 0x1039
                       && scalars[i + 2] == lower {
                        return true
                    }
                    return false
                }()
                ctx.assertTrue(
                    hasTriple,
                    "\(buffer)_regressionGuard",
                    detail: "expected virama-stack `\(String(format: "%04X", upper)) 1039 \(String(format: "%04X", lower))` in '\(surface)'"
                )
            }
        },

        // Soft-boundary non-regressions: existing well-formed shapes
        // (`thar+aung`, `ko+aung`, `ku+aung`) where the LHS has a
        // longer dep-vowel cluster keep their two-syllable rank-0
        // outputs.
        TestCase("regressionGuard_existingTwoSyllableSurfaces") { ctx in
            guard let engine = makeBundledEngine() else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            let preserved: [(String, [UInt32])] = [
                // သာအောင်
                ("thar+aung", [0x101E, 0x102C, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
                // ကိုအောင်
                ("ko+aung",   [0x1000, 0x102D, 0x102F, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
                // ကူအောင်
                ("ku+aung",   [0x1000, 0x1030, 0x1021, 0x1031, 0x102C, 0x1004, 0x103A]),
            ]
            for (buffer, expectedScalars) in preserved {
                let state = engine.update(buffer: buffer, context: [])
                let expected = String(String.UnicodeScalarView(
                    expectedScalars.compactMap { Unicode.Scalar($0) }
                ))
                ctx.assertEqual(
                    state.candidates.first?.surface ?? "",
                    expected,
                    "\(buffer)_regressionGuard"
                )
            }
        },
    ])
}
