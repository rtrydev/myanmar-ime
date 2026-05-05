import Foundation
import BurmeseIMECore

/// Step 4 / Sweep — orthographic-purity scan over a sample of
/// inputs covering every category. Each rank-0 surface must
/// satisfy the universal Burmese orthographic invariants:
///
/// 1. No `[U+200C, combining-mark]` adjacency (orphan-ZWNJ).
/// 2. Tone markers ◌့ (U+1037) and း (U+1038) only follow a
///    vowel sign or asat — never a bare consonant base.
/// 3. Asat ◌် (U+103A) never stands alone — always preceded
///    by a consonant or vowel sign.
/// 4. Virama ◌္ (U+1039) only appears between two consonants.
public enum LangOrthographicPuritySweepSuite {

    private static let sampleInputs: [String] = [
        // Atomic inventory
        "ka", "tha", "pa", "ngar", "wa",
        // Dependent vowels
        "mar", "mi", "mu", "may", "mo", "min", "kaung",
        // Independent vowels
        "u", "i", "ay", "oo", "u2", "ii.",
        // Anusvara
        "kan3", "man3",
        // Codas
        "ket", "kin", "kat", "kan", "kan3",
        // Multi-syllable, kinzi
        "lunar", "hsayar", "mingalarpar",
        // Pali
        "dhamma", "parrami",
        // Loanwords
        "ahmayri.kan", "arsha",
        // Particles
        "swarpartal", "lumyar:",
        // Punctuation/digits
        "thar.", "kar2", "2024",
    ]

    private static func bareEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func bundledEngineOrFallback(_ ctx: TestContext) -> BurmeseEngine {
        if let lexPath = BundledArtifacts.lexiconPath,
           let store = SQLiteCandidateStore(path: lexPath),
           let lmPath = BundledArtifacts.trigramLMPath,
           let lm = try? TrigramLanguageModel(path: lmPath) {
            return BurmeseEngine(candidateStore: store, languageModel: lm)
        }
        return bareEngine()
    }

    private static func hasOrphanZwnj(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        for i in 0..<max(0, scalars.count - 1) {
            if scalars[i].value == 0x200C
                && (Myanmar.isDependentVowel(scalars[i+1])
                    || Myanmar.isMedial(scalars[i+1])
                    || scalars[i+1].value == 0x1036
                    || scalars[i+1].value == 0x1037
                    || scalars[i+1].value == 0x1038
                    || scalars[i+1].value == 0x103A
                    || scalars[i+1].value == 0x1039) {
                return true
            }
        }
        return false
    }

    private static func toneFollowsVowelOrAsat(_ surface: String) -> (ok: Bool, detail: String) {
        let scalars = Array(surface.unicodeScalars)
        for i in 1..<scalars.count {
            if scalars[i].value == 0x1037 || scalars[i].value == 0x1038 {
                let prev = scalars[i-1]
                let prevOk = Myanmar.isDependentVowel(prev)
                    || prev.value == 0x103A
                    || prev.value == 0x1036
                if !prevOk {
                    return (false, "tone U+\(String(format: "%04X", scalars[i].value)) at index \(i) follows U+\(String(format: "%04X", prev.value))")
                }
            }
        }
        return (true, "")
    }

    private static func asatNotIsolated(_ surface: String) -> (ok: Bool, detail: String) {
        let scalars = Array(surface.unicodeScalars)
        for i in 0..<scalars.count {
            if scalars[i].value == 0x103A {
                guard i > 0 else { return (false, "asat at index 0") }
                let prev = scalars[i-1]
                let prevOk = Myanmar.isConsonant(prev)
                    || Myanmar.isDependentVowel(prev)
                    || Myanmar.isMedial(prev)
                if !prevOk {
                    return (false, "asat U+103A at index \(i) follows U+\(String(format: "%04X", prev.value))")
                }
            }
        }
        return (true, "")
    }

    private static func viramaBetweenConsonants(_ surface: String) -> (ok: Bool, detail: String) {
        let scalars = Array(surface.unicodeScalars)
        for i in 0..<scalars.count {
            if scalars[i].value == 0x1039 {
                guard i > 0, i + 1 < scalars.count else { return (false, "virama at boundary, idx=\(i)") }
                // Kinzi exception: the canonical kinzi sequence is
                // `1004 103A 1039 <next-consonant>` — so the virama
                // is preceded by an asat (U+103A), not a consonant
                // directly. Both immediate neighbours of the virama
                // must still bracket a consonant on each side.
                let prev = scalars[i-1]
                let next = scalars[i+1]
                let prevIsConsonant = Myanmar.isConsonant(prev)
                let prevIsKinziAsat = prev.value == 0x103A && i >= 2 && scalars[i-2].value == 0x1004
                if !(prevIsConsonant || prevIsKinziAsat) || !Myanmar.isConsonant(next) {
                    return (false, "virama U+1039 not between consonants at idx \(i): U+\(String(format: "%04X", prev.value))-U+1039-U+\(String(format: "%04X", next.value))")
                }
            }
        }
        return (true, "")
    }

    public static let suite = TestSuite(name: "LangOrthographicPuritySweep", cases: [

        TestCase("noOrphanZwnj") { ctx in
            let engine = bundledEngineOrFallback(ctx)
            for input in sampleInputs {
                let top = engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
                ctx.assertFalse(
                    hasOrphanZwnj(top),
                    input,
                    detail: "rank-0 has orphan-ZWNJ: '\(top)'"
                )
            }
        },

        TestCase("toneFollowsVowelOrAsat") { ctx in
            let engine = bundledEngineOrFallback(ctx)
            for input in sampleInputs {
                let top = engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
                let result = toneFollowsVowelOrAsat(top)
                ctx.assertTrue(
                    result.ok,
                    input,
                    detail: "tone-position violation in '\(top)': \(result.detail)"
                )
            }
        },

        TestCase("asatNotIsolated") { ctx in
            let engine = bundledEngineOrFallback(ctx)
            for input in sampleInputs {
                let top = engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
                let result = asatNotIsolated(top)
                ctx.assertTrue(
                    result.ok,
                    input,
                    detail: "asat-position violation in '\(top)': \(result.detail)"
                )
            }
        },

        TestCase("viramaBetweenConsonants") { ctx in
            let engine = bundledEngineOrFallback(ctx)
            for input in sampleInputs {
                let top = engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
                let result = viramaBetweenConsonants(top)
                ctx.assertTrue(
                    result.ok,
                    input,
                    detail: "virama-position violation in '\(top)': \(result.detail)"
                )
            }
        },
    ])
}
