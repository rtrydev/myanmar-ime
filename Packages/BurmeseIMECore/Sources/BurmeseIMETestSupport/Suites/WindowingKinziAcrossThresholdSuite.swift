import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-005: the one-shot top-1 candidate must not lose
/// kinzi from a syllable that the same engine renders WITH kinzi at
/// any shorter prefix. Once a buffer crosses the sliding-window
/// threshold (`compositionWindowSize = 18`), the engine splits into
/// `<frozenPrefix><activeTail>` and re-merges the rendered surfaces.
/// A poorly-chosen split could strand a kinzi-able pair (`<vowel>n +
/// <k|g>`-shape) at the prefix-tail boundary, leaving neither side
/// able to fire `inferImplicitStackMarkers` for that syllable. The
/// fix in `findSyllableSafeSplit` walks the split forward (past the
/// kinzi syllable) when the natural target site would split a
/// stack-able pair, and the windowed promotion preserves the inferred
/// surfaces through LM-margin pruning.
public enum WindowingKinziAcrossThresholdSuite {

    private static let kinziScalars: [UInt32] = [0x1004, 0x103A, 0x1039]
    private static let compositionWindowSize = 18

    private static func makeBundledEngine() -> BurmeseEngine? {
        guard let lexPath = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lexPath),
              let lmPath = BundledArtifacts.trigramLMPath,
              let lm = try? TrigramLanguageModel(path: lmPath) else {
            return nil
        }
        return BurmeseEngine(candidateStore: store, languageModel: lm)
    }

    private static func bundledEngine(_ ctx: TestContext) -> BurmeseEngine? {
        guard let engine = makeBundledEngine() else {
            ctx.assertTrue(true, "skipped_noBundledArtifacts")
            return nil
        }
        return engine
    }

    private static func countKinzi(_ surface: String) -> Int {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= kinziScalars.count else { return 0 }
        var count = 0
        for i in 0...(scalars.count - kinziScalars.count)
        where Array(scalars[i..<i + kinziScalars.count]) == kinziScalars {
            count += 1
        }
        return count
    }

    /// Bug-class buffers from the TASK-005 reproduction matrix plus
    /// follow-up regressions: every entry crosses the windowing
    /// threshold and contains at least one kinzi-able prefix
    /// (`min`/`tin`/`thin`-style) that the engine renders with kinzi
    /// at any shorter prefix.
    private static let bugClassInputs: [String] = [
        "minkyaungtharminkya",          // 19 chars
        "minkyaungtharminkyaung",       // 22 chars
        "minkyaungtharminkyaungthar",   // 26 chars
        "minkyawminkyawminkya",         // 20 chars (3× min, kinzi at all three)
        "tinkyawtinkyawtinkya",         // 20 chars (3× tin)
        "thinkyawthinkyawthin",         // 20 chars (3× thin)
        "minkyaungminkyaungmi",         // 20 chars (2× minkyaung)
        // Mixed-prefix regression coverage.
        "tinkyawminkyawmin",            // 17 chars (control: just under threshold)
        "minkyawtinkyawthinkyaw",       // 22 chars (mixed min/tin/thin)
        "tinkyawthinkyawtinkyaw",       // 22 chars
    ]

    public static let suite = TestSuite(name: "WindowingKinziAcrossThreshold", cases: [

        // Core acceptance: for every bug-class input, the rank-0
        // surface must contain at least as many kinzi sequences as
        // the rank-0 surface of any prefix `[0..k]` where `k <= 18`
        // of the same buffer. Programmatic check:
        TestCase("kinziCountIsMonotone_acrossWindowing") { ctx in
            guard makeBundledEngine() != nil else {
                ctx.assertTrue(true, "skipped_noBundledArtifacts")
                return
            }
            for input in bugClassInputs {
                guard let engine = makeBundledEngine() else { continue }
                guard input.count > compositionWindowSize else {
                    // 17-char control: just verify it renders with
                    // kinzi at all (sanity).
                    let state = engine.update(buffer: input, context: [])
                    let top = state.candidates.first?.surface ?? ""
                    ctx.assertTrue(
                        countKinzi(top) >= 1,
                        input,
                        detail: "control input '\(input)' rank-0='\(top)' lacks kinzi"
                    )
                    continue
                }
                let chars = Array(input)
                var maxPrefixKinzi = 0
                let upper = min(compositionWindowSize, chars.count)
                for k in 1...upper {
                    let prefix = String(chars[0..<k])
                    guard let prefixEngine = makeBundledEngine() else { continue }
                    let prefixState = prefixEngine.update(buffer: prefix, context: [])
                    if let top = prefixState.candidates.first?.surface {
                        maxPrefixKinzi = max(maxPrefixKinzi, countKinzi(top))
                    }
                }
                guard let fullEngine = makeBundledEngine() else { continue }
                let fullState = fullEngine.update(buffer: input, context: [])
                let fullTop = fullState.candidates.first?.surface ?? ""
                let fullKinzi = countKinzi(fullTop)
                ctx.assertTrue(
                    fullKinzi >= maxPrefixKinzi,
                    input,
                    detail: "rank-0='\(fullTop)' has \(fullKinzi) kinzi(s), but a shorter prefix renders with \(maxPrefixKinzi)"
                )
            }
        },

        // Specific scalar-position check on the seven matrix inputs:
        // assert the kinzi sequence appears at the FIRST `min`/`tin`/
        // `thin` position of the rendered surface. This catches a
        // fix that preserves the count by shifting kinzi to a
        // different position (e.g. only the LAST `min` rather than
        // the first).
        TestCase("kinziPositionPreserved_atFirstSyllable") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            // Each entry: (buffer, index of the consonant that
            // anchors the first kinzi syllable in the surface).
            // The kinzi sequence `1004 103A 1039` follows the anchor
            // consonant at scalar positions [base..base+3].
            let firstKinziChecks: [(String, UInt32)] = [
                ("minkyaungtharminkya", 0x1019),     // မ
                ("minkyaungtharminkyaung", 0x1019),
                ("minkyaungtharminkyaungthar", 0x1019),
                ("minkyawminkyawminkya", 0x1019),
                ("tinkyawtinkyawtinkya", 0x1010),    // တ
                ("thinkyawthinkyawthin", 0x101E),    // သ
                ("minkyaungminkyaungmi", 0x1019),
            ]
            for (input, anchor) in firstKinziChecks {
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                let scalars = Array(top.unicodeScalars).map(\.value)
                // First-syllable kinzi: anchor at scalars[0],
                // followed by `1004 103A 1039` at scalars[1..3].
                let hasFirstKinzi = scalars.count >= 4
                    && scalars[0] == anchor
                    && scalars[1] == 0x1004
                    && scalars[2] == 0x103A
                    && scalars[3] == 0x1039
                ctx.assertTrue(
                    hasFirstKinzi,
                    input,
                    detail: "rank-0='\(top)' missing kinzi at the first \(String(format: "U+%04X", anchor)) anchor"
                )
            }
        },

        // Existing TASK-001 regression guards: short buffers (no
        // windowing) must still surface kinzi at rank 0. The fix
        // must not over-restrict the un-windowed inference.
        TestCase("unwindowedShortBuffers_keepKinzi") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for input in ["mingalarpar", "kyawmingalarpar", "tinkyawtinkyaw"] {
                ctx.assertTrue(
                    input.count <= compositionWindowSize,
                    input,
                    detail: "control input must not exceed window size"
                )
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    countKinzi(top) >= 1,
                    input,
                    detail: "rank-0='\(top)'"
                )
            }
        },
    ])
}
