import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-044: kinzi from a previously-rendered prefix is
/// silently dropped from the candidate panel once the buffer grows
/// past ~22 chars, for the `mingalarpar*` family (and likely other
/// kinzi-rendering prefixes the windowing decision splits past).
///
/// TASK-005 (archived) established the invariant: for every buffer
/// `B` of length > `compositionWindowSize` (18) where any prefix
/// `B[0..k]` (`k <= 18`) renders with kinzi at rank 0, the panel of
/// `B` must contain at least one candidate carrying the same kinzi
/// sequence. That fix targeted the `<C>in<stack-onset>...` family.
/// The `mingalarpar*` family demonstrates the invariant is violated
/// in a different shape — the kinzi-bearing surface is panel-absent
/// (not just demoted to rank 1+), so the user has no manual-selection
/// fallback either.
///
/// Acceptance: hard panel-reachability floor (≥1 candidate with
/// kinzi). Rank-0 is preferred but not required (CLAUDE.md §7
/// "General reachability rule").
public enum MingalarKinziLongBufferSuite {

    private static let kinziScalars: [UInt32] = [0x1004, 0x103A, 0x1039]

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

    private static func hasKinzi(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= kinziScalars.count else { return false }
        for i in 0...(scalars.count - kinziScalars.count)
        where Array(scalars[i..<i + kinziScalars.count]) == kinziScalars {
            return true
        }
        return false
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

    /// Long-buffer probes from the TASK-044 reproduction matrix: every
    /// row past length 21 historically showed the kinzi-bearing surface
    /// missing from the candidate panel.
    private static let mingalarpar22Plus: [String] = [
        "mingalarparshinbyarthw",      // 22
        "mingalarparshinbyarthwa",     // 23
        "mingalarparshinbyarthwarmaylay",          // 30
        "mingalarparshinbyarthwarmaylaynaykaun",   // 37
    ]

    /// Family-coverage probes: extend a different kinzi-rendering
    /// prefix past the windowing threshold. The fix should not be
    /// `mingalarpar*`-specific.
    private static let otherKinziFamilies: [String] = [
        // `thingyan` carries kinzi at the first syllable; extend past
        // the threshold with arbitrary additional Burmese chars.
        "thingyanpwaitawkyaungtharmin",
        // `pyinnyaresaung` carries kinzi at the first syllable.
        "pyinnyaresaungtawkyaungthar",
    ]

    public static let suite = TestSuite(name: "MingalarKinziLongBuffer", cases: [

        // Sanity: short prefixes of `mingalarpar*` render with kinzi
        // at rank 0 in the production stack. Any failure here means
        // the LM/lexicon stack changed and the rest of the suite
        // needs to be re-grounded.
        TestCase("shortPrefixesRenderWithKinziAtRankZero") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for buffer in [
                "mingalarpar",
                "mingalarparshin",
                "mingalarparshinbya",
                "mingalarparshinbyar",
                "mingalarparshinbyart",
                "mingalarparshinbyarth",
            ] {
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    hasKinzi(top),
                    buffer,
                    detail: "short-prefix rank-0='\(top)' lacks kinzi"
                )
            }
        },

        // Hard floor — panel reachability. For every buffer past the
        // windowing threshold whose ≤18-char prefix renders with
        // kinzi at rank 0, the long buffer's panel must contain at
        // least one candidate carrying a kinzi sequence.
        TestCase("longBufferPanelContainsKinzi_mingalarFamily") { ctx in
            for buffer in mingalarpar22Plus {
                guard let engine = makeBundledEngine() else {
                    ctx.assertTrue(true, "skipped_noBundledArtifacts")
                    return
                }
                let state = engine.update(buffer: buffer, context: [])
                let kinziInPanel = state.candidates.contains { hasKinzi($0.surface) }
                ctx.assertTrue(
                    kinziInPanel,
                    buffer,
                    detail: "no kinzi-bearing candidate in panel; top10=\(state.candidates.prefix(10).map(\.surface))"
                )
            }
        },

        // Programmatic invariant (mirrors WindowingKinziAcrossThreshold):
        // for every long buffer whose ≤18-char prefix renders with
        // kinzi at rank 0, the MAX kinzi count across the panel must
        // be ≥ the kinzi count of any prefix `B[0..k]`'s rank-0
        // surface.
        TestCase("kinziCountIsMonotone_mingalarFamily") { ctx in
            for buffer in mingalarpar22Plus {
                guard let prefixEngine = makeBundledEngine() else {
                    ctx.assertTrue(true, "skipped_noBundledArtifacts")
                    return
                }
                let chars = Array(buffer)
                var maxPrefixKinzi = 0
                let upper = min(18, chars.count)
                for k in 1...upper {
                    let prefix = String(chars[0..<k])
                    guard let pe = makeBundledEngine() else { continue }
                    let pState = pe.update(buffer: prefix, context: [])
                    if let top = pState.candidates.first?.surface {
                        maxPrefixKinzi = max(maxPrefixKinzi, countKinzi(top))
                    }
                }
                _ = prefixEngine
                guard let engine = makeBundledEngine() else { continue }
                let state = engine.update(buffer: buffer, context: [])
                let panelMax = state.candidates.map { countKinzi($0.surface) }.max() ?? 0
                ctx.assertTrue(
                    panelMax >= maxPrefixKinzi,
                    buffer,
                    detail: "panel max kinzi = \(panelMax), prefix max kinzi = \(maxPrefixKinzi); top10=\(state.candidates.prefix(10).map(\.surface))"
                )
            }
        },

        // Family coverage: same hard floor on a non-`mingalar*`
        // kinzi-rendering prefix family. Confirms the fix is not
        // word-specific.
        TestCase("longBufferPanelContainsKinzi_otherFamilies") { ctx in
            for buffer in otherKinziFamilies {
                guard let engine = makeBundledEngine() else {
                    ctx.assertTrue(true, "skipped_noBundledArtifacts")
                    return
                }
                // Sanity: the short prefix renders with kinzi.
                guard let prefixEngine = makeBundledEngine() else { continue }
                let prefixLen = min(18, buffer.count)
                let prefix = String(buffer.prefix(prefixLen))
                let prefState = prefixEngine.update(buffer: prefix, context: [])
                let prefHasKinzi = prefState.candidates.first.map {
                    hasKinzi($0.surface)
                } ?? false
                guard prefHasKinzi else {
                    // The probe family doesn't actually render with
                    // kinzi at the production stack — skip rather
                    // than assert against a moving target.
                    ctx.assertTrue(true, "skipped_\(buffer)_prefixHasNoKinzi")
                    continue
                }
                let state = engine.update(buffer: buffer, context: [])
                let kinziInPanel = state.candidates.contains { hasKinzi($0.surface) }
                ctx.assertTrue(
                    kinziInPanel,
                    buffer,
                    detail: "no kinzi-bearing candidate in panel; top10=\(state.candidates.prefix(10).map(\.surface))"
                )
            }
        },
    ])
}
