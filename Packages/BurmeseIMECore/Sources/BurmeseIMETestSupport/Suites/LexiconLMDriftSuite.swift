import Foundation
import BurmeseIMECore

/// Regression guard against LM↔SQLite vocabulary drift.
///
/// The LM `.bin` and the lexicon `.sqlite` must be produced from the same
/// corpus-builder pass. When they drift (e.g. sqlite rebuilt without
/// retraining the LM), surfaces the ranker offers get charged the LM's
/// `<unk>` log-prob — which is far lower than any plausible real
/// log-prob — and rank fairly arbitrarily. See `tasks/audit.md` §1d for
/// the incident that motivated this check.
///
/// The test fires a fixed set of buffers through `SQLiteCandidateStore`
/// and asserts every returned surface has a real LM vocab id. Failures
/// list the missing surfaces so the fix (re-run `corpus-build lm` against
/// the current TSV) is obvious.
public enum LexiconLMDriftSuite {

    /// Buffers chosen to exercise the historically-override-backed surfaces
    /// plus a handful of common ones. If the LM is missing any surface
    /// these lookups return, the ranker will silently misbehave on typing.
    private static let probeBuffers: [String] = [
        "mingalarpar",
        "thanhlyin",
        "kyaung",
        "an",
        "ganda",
        "kyi",
        "khyin",
    ]

    public static let suite = TestSuite(name: "LexiconLMDrift", cases: [

        TestCase("lookupSurfaces_allPresentInLMVocab") { ctx in
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath) else {
                ctx.assertTrue(true, "skipped_noBundledLexicon")
                return
            }
            guard let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledLM")
                return
            }

            for buffer in probeBuffers {
                let candidates = store.lookup(prefix: buffer, previousSurface: nil)
                if candidates.isEmpty { continue }
                var missing: [String] = []
                for candidate in candidates where lm.wordId(for: candidate.surface) == nil {
                    missing.append(candidate.surface)
                }
                ctx.assertTrue(
                    missing.isEmpty,
                    "buffer_\(buffer)",
                    detail: "missing_from_LM_vocab=\(missing)"
                )
            }
        },
    ])
}
