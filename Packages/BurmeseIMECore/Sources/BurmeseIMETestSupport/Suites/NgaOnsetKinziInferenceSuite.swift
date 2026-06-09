import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-082: the implicit kinzi/stack inference must never
/// propose nga (U+1004) as the inferred stack LOWER — kinzi over nga
/// (`င်္င` = `1004 103A 1039 1004`) is essentially unattested in Burmese
/// orthography. The letter sequence `…n|ng…` / `…ng|ng…` (a nasal-coda
/// vowel rule followed by a nga-onset syllable, e.g. `နိုင်ငံ` =
/// `နိုင်` + `ငံ`) is written with a plain nga onset, never with kinzi.
///
/// Before the fix, the inference fabricated `မင်္ငနေ` for `minnganay`
/// and `နိုင်္ငန်က` for `naingngank`, promoted them to rank 0
/// unconditionally, and corrupted the entire panel for longer
/// compounds (`naingngankhyar:thar:` → all-kinzi panel with the
/// lexicon entry `နိုင်ငံခြားသား` unreachable).
///
/// Legitimate kinzi (velar/dental lowers: `မင်္ဂလာ`, doubled-letter
/// `gg` signals, explicit `+`) must stay untouched — those are pinned
/// here as controls and by DoubledLetterKinziSuite /
/// KinziInferenceSuite / ExplicitPlusKinziDisplacementSuite.
public enum NgaOnsetKinziInferenceSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
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

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// True when `surface` contains kinzi over nga:
    /// `1004 103A 1039 1004`.
    private static func containsKinziOverNga(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 4 else { return false }
        for i in 0...(scalars.count - 4) where
            scalars[i] == 0x1004 && scalars[i + 1] == 0x103A
            && scalars[i + 2] == 0x1039 && scalars[i + 3] == 0x1004 {
            return true
        }
        return false
    }

    /// True when `surface` contains any kinzi triple `1004 103A 1039`.
    private static func containsKinzi(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 3 else { return false }
        for i in 0...(scalars.count - 3) where
            scalars[i] == 0x1004 && scalars[i + 1] == 0x103A && scalars[i + 2] == 0x1039 {
            return true
        }
        return false
    }

    /// Bug-class buffers: nasal-coda vowel rule + nga onset. None of
    /// these carries an explicit `+`, so no candidate should ever
    /// render kinzi over nga.
    private static let bugBuffers: [String] = [
        "minnganay",
        "naingngank",
        "naingngan",
        "naingngankhyar:t",
        "naingngankhyar:thar:",
        "kinngar",
        "aingngar",
    ]

    public static let suite = TestSuite(name: "NgaOnsetKinziInference", cases: [

        // The inference must not fabricate kinzi-over-nga in ANY
        // candidate on the bare engine — the shape is ungrammatical
        // regardless of lexicon/LM availability.
        TestCase("bareEngine_noCandidateCarriesKinziOverNga") { ctx in
            let engine = emptyEngine()
            for buffer in bugBuffers {
                let state = engine.update(buffer: buffer, context: [])
                for c in state.candidates {
                    ctx.assertFalse(
                        containsKinziOverNga(c.surface),
                        buffer,
                        detail: "candidate '\(c.surface)' [\(hex(c.surface))] carries kinzi over nga"
                    )
                }
            }
        },

        // Production: rank 0 is kinzi-over-nga-free for the minimal
        // trigger and the country-word family.
        TestCase("production_rank0KinziFree") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for buffer in ["minnganay", "naingngank", "naingngankhyar:t"] {
                let top = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    containsKinziOverNga(top),
                    buffer,
                    detail: "rank 0 '\(top)' [\(hex(top))] carries kinzi over nga"
                )
            }
        },

        // Production: incremental typing of the full compound never
        // shows a kinzi-over-nga prefix at rank 0, and the final
        // panel contains the lexicon entry `နိုင်ငံခြားသား`.
        TestCase("production_incrementalCompoundNeverCorrupts") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let full = "naingngankhyar:thar:"
            var buffer = ""
            for ch in full {
                buffer.append(ch)
                let top = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    containsKinziOverNga(top),
                    "incremental_\(buffer)",
                    detail: "rank 0 '\(top)' [\(hex(top))] carries kinzi over nga"
                )
            }
            let finalCandidates = engine.update(buffer: full, context: []).candidates
            ctx.assertTrue(
                finalCandidates.contains { $0.surface == "နိုင်ငံခြားသား" },
                "finalPanel_containsLexiconEntry",
                detail: "expected 'နိုင်ငံခြားသား' in panel; got \(finalCandidates.prefix(8).map(\.surface))"
            )
        },

        // Production: the plain nga-onset reading holds the panel for
        // the mid-word state (`naingngank` → `နိုင်ငံက` reachable).
        TestCase("production_plainNgaOnsetReachable") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let candidates = engine.update(buffer: "naingngank", context: []).candidates
            ctx.assertTrue(
                candidates.contains { $0.surface == "နိုင်ငံက" },
                "naingngank",
                detail: "expected 'နိုင်ငံက' in panel; got \(candidates.prefix(6).map(\.surface))"
            )
        },

        // Controls: legitimate kinzi inference is unchanged — velar
        // non-nga lowers keep their kinzi rendering at rank 0.
        TestCase("production_legitimateKinziUnchanged") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [String] = [
                "mingalarpar",   // မင်္ဂလာပါ — in+g kinzi
                "kingga",        // doubled-letter gg kinzi signal
            ]
            for buffer in cases {
                let top = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    containsKinzi(top) && !containsKinziOverNga(top),
                    buffer,
                    detail: "expected kinzi (non-nga lower) at rank 0; got '\(top)' [\(hex(top))]"
                )
            }
        },
    ])
}
