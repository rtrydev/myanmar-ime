import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for task 02: cluster keys (`ky`, `khy`, `gy`, `ghy`, plus
/// their `w`-medial variants) must default to ya-pin (ျ) on top, not
/// ya-yit (ြ). The lexicon shows ya-pin dominates these clusters by
/// 4-50x — `ကျ` 1.95M vs `ကြ` 531k, `ကျော်` 275k vs `ကြော်` 30k,
/// `ဂျပန်` 87k vs `ဂြပန်` 0 — and the previous five-entry
/// `yapinPrimaryBareBuffers` carve-out was a per-word patch over a
/// parser-level alias asymmetry that the lexicon could not fully
/// recover.
public enum ClusterMedialPreferenceSuite {

    private static let yaPin: UInt32 = 0x103B
    private static let yaYit: UInt32 = 0x103C

    private static func containsYaPin(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value == yaPin }
    }

    private static func containsYaYit(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value == yaYit }
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

    public static let suite = TestSuite(name: "ClusterMedialPreference", cases: [

        // Bare-engine path (no lexicon, no LM): ya-pin must win the
        // ranker tie for every cluster key in the preferred set. The
        // earlier hardcode only covered five exact bare buffers; this
        // case asserts the rule is generalized to any buffer whose
        // first onset cluster is `ky` / `khy` / `gy` / `ghy`.
        TestCase("bareEngine_clusterKey_yaPinTop") { ctx in
            let engine = BurmeseEngine()
            let buffers = [
                "kya", "kyaw", "kyantaw", "kyanma", "kyat", "kyin",
                "khya", "khyaw", "khyit",
                "gya", "gypan", "gyat",
                "ghya", "ghyaw",
            ]
            for buffer in buffers {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(buffer, detail: "no candidates")
                    continue
                }
                ctx.assertTrue(
                    containsYaPin(top),
                    buffer,
                    detail: "expected ya-pin (U+103B) on top, got '\(top)'"
                )
                ctx.assertFalse(
                    containsYaYit(top),
                    buffer,
                    detail: "ya-yit (U+103C) must not appear on top for '\(buffer)', got '\(top)'"
                )
            }
        },

        // Bundled engine path (full lexicon + LM): the same rule must
        // hold end-to-end. This is the production behaviour users see.
        TestCase("bundledEngine_clusterKey_yaPinTop") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, expectedSurface: String)] = [
                ("kya",      "\u{1000}\u{103B}"),
                ("kyaw",     "\u{1000}\u{103B}\u{1031}\u{102C}\u{103A}"),
                ("kyantaw",  "\u{1000}\u{103B}\u{1014}\u{103A}\u{1010}\u{1031}\u{102C}\u{103A}"),
                ("gypan",    "\u{1002}\u{103B}\u{1015}\u{1014}\u{103A}"),
                ("gyat",     "\u{1002}\u{103B}\u{1010}\u{103A}"),
                ("kyay",     "\u{1000}\u{103B}\u{1031}"),
                ("kyi",      "\u{1000}\u{103B}\u{102E}"),
                ("kywan",    "\u{1000}\u{103B}\u{103D}\u{1014}\u{103A}"),
                ("khyay",    "\u{1001}\u{103B}\u{1031}"),
                ("khyin",    "\u{1001}\u{103B}\u{1004}\u{103A}"),
            ]
            for entry in cases {
                let state = engine.update(buffer: entry.buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(entry.buffer, detail: "no candidates")
                    continue
                }
                let stripped = String(
                    top.unicodeScalars.filter { $0.value != 0x200B && $0.value != 0x200C }
                )
                ctx.assertEqual(stripped, entry.expectedSurface, entry.buffer)
            }
        },

        // The ya-yit sibling must remain reachable in the candidate
        // panel — task 02 is a ranking flip, not a substitution.
        TestCase("bareEngine_yaYitSiblingStillInPanel") { ctx in
            let engine = BurmeseEngine()
            for buffer in ["kyaw", "kya", "gypan"] {
                let state = engine.update(buffer: buffer, context: [])
                let any = state.candidates.contains { containsYaYit($0.surface) }
                ctx.assertTrue(
                    any,
                    buffer,
                    detail: "ya-yit sibling must be reachable in panel"
                )
            }
        },

        // Non-cluster keys are untouched. `j` / `ch` already preferred
        // ya-pin via cluster aliases at aliasCost 0; that behaviour
        // must not regress.
        TestCase("nonClusterKeys_unchanged") { ctx in
            let engine = BurmeseEngine()
            for buffer in ["jar", "char"] {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(buffer, detail: "no candidates")
                    continue
                }
                ctx.assertTrue(
                    containsYaPin(top),
                    buffer,
                    detail: "ya-pin must remain top for '\(buffer)', got '\(top)'"
                )
            }
        },

        // Removing the per-buffer hardcode must not regress any of the
        // five `task13_yapin_*` exact-bare-buffer cases (kywan / kyay /
        // kyi / khyay / khyin). This exercises the cluster-rule path
        // for them through the bundled engine.
        TestCase("task13_yapin_buffers_stillTop") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(String, String)] = [
                ("kywan", "\u{1000}\u{103B}\u{103D}\u{1014}\u{103A}"),
                ("kyay",  "\u{1000}\u{103B}\u{1031}"),
                ("kyi",   "\u{1000}\u{103B}\u{102E}"),
                ("khyay", "\u{1001}\u{103B}\u{1031}"),
                ("khyin", "\u{1001}\u{103B}\u{1004}\u{103A}"),
            ]
            for (buffer, expected) in cases {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first?.surface else {
                    ctx.fail(buffer, detail: "no candidates")
                    continue
                }
                let stripped = String(
                    top.unicodeScalars.filter { $0.value != 0x200B && $0.value != 0x200C }
                )
                ctx.assertEqual(stripped, expected, buffer)
            }
        },

        // The hardcoded `yapinPrimaryBareBuffers` set is gone — the
        // cluster-driven rule should reduce it to empty. This guards
        // against re-introducing the per-buffer patch.
        TestCase("yapinPrimaryBareBuffers_isEmpty") { ctx in
            ctx.assertTrue(
                BurmeseEngine.yapinPrimaryBareBuffers.isEmpty,
                "yapinPrimaryBareBuffers",
                detail: "expected empty set, got \(BurmeseEngine.yapinPrimaryBareBuffers)"
            )
        },
    ])
}
