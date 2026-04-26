import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for the mid-buffer-digit splice-inside-cluster bug
/// (TASK-001): the splice position computed from the digit-stripped
/// prefix's standalone parse can land *one scalar short* of the
/// kinzi-stacked candidate's actual prefix length, because the
/// standalone parse does not include the kinzi virama (U+1039) that
/// the full-buffer parse infers for prefixes like `min` / `thin`.
///
/// The result is a digit inserted between the dependent vowel and the
/// closing asat (U+103A) of the same syllable — e.g. `မင်္ကြော၁်ပါ`
/// where the digit `၁` sits between `ော` and `်` (asat). Burmese
/// orthography forbids any character — and certainly any digit —
/// between a base+vowel cluster and the asat that closes it.
///
/// This suite asserts the structural rule directly on the rendered
/// scalar sequence of the engine's top candidate: no candidate at any
/// rank may contain a digit (ASCII or Myanmar) immediately followed by
/// an asat.
public enum MidBufferDigitAsatSplitSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    /// Returns true when the surface contains any `<digit><asat>`
    /// adjacency — the orthographic-ordering violation signature.
    private static func hasDigitBeforeAsat(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        for i in 1..<scalars.count {
            let prev = scalars[i - 1]
            let isAsciiDigit = prev >= 0x30 && prev <= 0x39
            let isMyanmarDigit = prev >= 0x1040 && prev <= 0x1049
            guard isAsciiDigit || isMyanmarDigit else { continue }
            if scalars[i] == 0x103A { return true }
        }
        return false
    }

    /// Inputs that match the bug's general class:
    /// `<kinzi-able prefix><asat-closing syllable><digit><tail>`.
    /// The kinzi-able prefixes are `min`, `thin`; the asat-closing
    /// syllables exercise -aw / -aung / -in / -an / -at codas.
    private static let kinziDigitInputs: [String] = [
        "minkyaw1par",      // min + kyaw (-aw, asat) + 1 + par
        "minkyaw2par",
        "thinkyaw1par",     // thin + kyaw (-aw) + 1 + par
        "thinkyaw1nay",
        "minnaung1par",     // min + naung (-aung) + 1 + par
        "minkyaung1par",    // min + kyaung (-aung) + 1 + par
        "minkyat1par",      // min + kyat (-at coda) + 1 + par
        "thinkyaw2nay",
        "minnaung2tar",
    ]

    /// Inputs that are NOT kinzi-able but share the digit-after-asat
    /// shape — these must stay clean (already working today, regression
    /// guard).
    private static let nonKinziDigitInputs: [String] = [
        "kyaw1par",
        "naung1tar",
        "kyat1par",
        "tin1tin",
    ]

    public static let suite = TestSuite(name: "MidBufferDigitAsatSplit", cases: [

        // Top-1 must never carry a digit-before-asat adjacency.
        TestCase("kinziPrefix_digitDoesNotSplitClusterAsat") { ctx in
            let engine = emptyEngine()
            for input in kinziDigitInputs {
                let top = engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
                ctx.assertFalse(
                    hasDigitBeforeAsat(top),
                    input,
                    detail: "top '\(top)' contains digit immediately followed by asat (U+103A)"
                )
            }
        },

        // Stronger: no candidate at any rank should carry a
        // digit-before-asat adjacency. The structurally clean sibling
        // already exists — keep the panel free of broken alternatives.
        TestCase("kinziPrefix_noCandidateAtAnyRankHasDigitBeforeAsat") { ctx in
            let engine = emptyEngine()
            for input in kinziDigitInputs {
                let cands = engine.update(buffer: input, context: []).candidates
                for (rank, cand) in cands.enumerated() {
                    ctx.assertFalse(
                        hasDigitBeforeAsat(cand.surface),
                        input,
                        detail: "candidate #\(rank) '\(cand.surface)' contains digit-before-asat adjacency"
                    )
                }
            }
        },

        // Regression guard: non-kinzi inputs already work and must
        // continue to.
        TestCase("nonKinziPrefix_remainsClean") { ctx in
            let engine = emptyEngine()
            for input in nonKinziDigitInputs {
                let top = engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
                ctx.assertFalse(
                    hasDigitBeforeAsat(top),
                    input,
                    detail: "top '\(top)' contains digit-before-asat adjacency"
                )
            }
        },
    ])
}
