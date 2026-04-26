import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-001: when the buffer crosses the sliding-window
/// threshold (compositionWindowSize = 18), the engine's rank-0
/// promotion of the strict-kinzi / strict-virama-stack inferred
/// candidate was unconditionally suppressed. The kinzi-bearing
/// candidate is generated and ranked into the panel at rank ≥ 1, but
/// the user-visible top is the non-kinzi parse — orthographically
/// wrong for any Burmese word whose romanization triggers an
/// implicit kinzi (or native virama-stack) in the active tail.
///
/// The most common reproducer is `<prefix>mingalarpar` with total
/// length > 18: `မင်္ဂလာပါ` (kinzi) is the standard spelling, while
/// `မင်ဂလာပါ` (no kinzi) is a misrendering. The bug class is general:
/// any tail containing `<vowel>n<velar/native-stackable>` exhibits it.
public enum WindowingKinziPromotionSuite {

    private static let kinziScalars: [UInt32] = [0x1004, 0x103A, 0x1039]
    private static let compositionWindowSize = 18

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func containsKinzi(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= kinziScalars.count else { return false }
        for i in 0...(scalars.count - kinziScalars.count) {
            if Array(scalars[i..<i + kinziScalars.count]) == kinziScalars {
                return true
            }
        }
        return false
    }

    /// Inputs that exercise the bug class:
    /// `<prefix>mingalarpar` where the total length crosses 18 chars
    /// and the tail's kinzi inference must survive into the top
    /// candidate. Prefixes are deliberately varied so this test
    /// guards the *class* of bug, not any single-word quirk.
    private static let kinziWindowedInputs: [String] = [
        "pyaepyaemingalarpar",          // 19 chars
        "shinbyarmingalarpar",          // 19 chars
        "kyawpyaemingalarpar",          // 19 chars
        "shitthitmingalarpar",          // 19 chars
        "kayinmamarmamamingalarpar",    // 25 chars (long prefix)
        "khinakyawmingalarpar",         // 20 chars
        "achittarmingalarpar",          // 19 chars
        "kyitkyitmingalarpar",          // 19 chars
    ]

    /// Inputs that DO NOT trigger windowing (≤ 18 chars). They must
    /// still surface kinzi at rank 0 — these are regression guards.
    private static let kinziUnwindowedInputs: [String] = [
        "mingalarpar",                  // 11 chars
        "kalarmingalarpar",             // 16 chars
        "kyawmingalarpar",              // 15 chars
    ]

    public static let suite = TestSuite(name: "WindowingKinziPromotion", cases: [

        // Core bug class: long buffers containing a tail with implicit
        // kinzi must surface the kinzi-bearing candidate at rank 0.
        TestCase("windowingKinziPromotion_topHasKinzi") { ctx in
            let engine = emptyEngine()
            for input in kinziWindowedInputs {
                ctx.assertTrue(
                    input.count > compositionWindowSize,
                    input,
                    detail: "test input must exceed window size to exercise the bug"
                )
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    containsKinzi(top),
                    input,
                    detail: "rank-0='\(top)' all=\(state.candidates.prefix(4).map(\.surface))"
                )
            }
        },

        // Regression guard: short buffers (no windowing) must still
        // promote kinzi to rank 0 — the fix must not over-restrict the
        // existing un-windowed promotion.
        TestCase("windowingKinziPromotion_unwindowedStillPromotes") { ctx in
            let engine = emptyEngine()
            for input in kinziUnwindowedInputs {
                ctx.assertTrue(
                    input.count <= compositionWindowSize,
                    input,
                    detail: "control input must not exceed window size"
                )
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    containsKinzi(top),
                    input,
                    detail: "rank-0='\(top)'"
                )
            }
        },

        // The kinzi candidate must also be present in the panel as a
        // discoverable variant (defensive: even if some future change
        // demotes it from rank 0, panel availability is the floor).
        TestCase("windowingKinziPromotion_kinziInPanel") { ctx in
            let engine = emptyEngine()
            for input in kinziWindowedInputs {
                let state = engine.update(buffer: input, context: [])
                let anyHasKinzi = state.candidates.contains(where: { containsKinzi($0.surface) })
                ctx.assertTrue(
                    anyHasKinzi,
                    input,
                    detail: "no kinzi-bearing candidate in panel: \(state.candidates.map(\.surface))"
                )
            }
        },
    ])
}
