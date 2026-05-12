import Foundation
import BurmeseIMECore

/// Symmetric `a-` prefix reachability for lexicon entries whose surface
/// starts with U+1021 (independent vowel `အ`).
///
/// Background: the LexiconBuilder synthesizes `ah-` prefix aliases for
/// every U+1021-leading entry (see TASK-046 commit 9b8f2cd / TASK-070).
/// Users who type the bare-`a` onset variant (`ain:` for `အင်း`,
/// `aaung` for `အောင်`, etc.) had no path to those lexicon rows because
/// the same prefix is also a valid parser rule for the dot-above
/// `ai-` shape (`အိန်း` `အိမ်း`). This suite locks in:
///
///   1. Panel reachability for the U+1021-leading surface under the
///      `a-` prefix — top 3 strongly preferred, panel presence is the
///      acceptance bar (per CLAUDE.md §7).
///   2. The structural rank-0 mapping for shapes the parser already
///      covers must NOT regress (e.g. `ain:` rank 0 stays `အိန်း`).
///   3. The existing `ah-` prefix control still works.
///
/// Production-equivalent only — skips cleanly if the bundled lexicon
/// or LM artifact is missing.
public enum AprefixIndependentVowelReachabilitySuite {

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

    private static func stripZW(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.value != 0x200B && $0.value != 0x200C })
    }

    public static let suite: TestSuite = {
        var cases: [TestCase] = []

        // MARK: - Panel reachability for `a-` prefix typing
        //
        // Each (buffer, expectedSurface) row asserts that the U+1021
        // anchor surface is reachable somewhere in the candidate panel.
        // The buffers are the user-typed `a` + canonical-alias-of-the-
        // surface form (e.g. `ain:` for `အင်း`, canonical `in:`).
        //
        // Note: we deliberately do NOT include `ain` (no tone) — that
        // prefix is saturated by 20+ penalty-0 `အိ…` rows (`အိမ်`,
        // `အိုင်` family) which fill the SQL LIMIT 20 before the
        // penalty-2 `အင်` row is reached. Per CLAUDE.md §7 such
        // structurally-undecidable cases are accepted as "panel-blind";
        // do not chase that one without a deeper lookup redesign.
        let aPrefixReachableCases: [(buffer: String, expected: String, gloss: String)] = [
            ("ain:",    "\u{1021}\u{1004}\u{103A}\u{1038}",                     "အင်း (in:)"),
            ("aaung",   "\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}",             "အောင် (aung)"),
            ("aalote",  "\u{1021}\u{101C}\u{102F}\u{1015}\u{103A}",             "အလုပ် (alote2, digit-stripped)"),
            ("aar:",    "\u{1021}\u{102C}\u{1038}",                             "အား (ar:)"),
            ("aan",     "\u{1021}\u{1014}\u{103A}",                             "အန် (an) — collides with own-entry aan, must still appear"),
            ("aatwet",  "\u{1021}\u{1010}\u{103D}\u{1000}\u{103A}",             "အတွက် (atwet)"),
            ("aphyit",  "\u{1021}\u{1016}\u{103C}\u{1005}\u{103A}",             "အဖြစ် (aphyit)"),
            ("aakyaung:", "\u{1021}\u{1000}\u{103C}\u{1031}\u{102C}\u{1004}\u{103A}\u{1038}", "အကြောင်း (akyaung:)"),
        ]
        for (buffer, expected, gloss) in aPrefixReachableCases {
            cases.append(TestCase("aPrefixPanelReachable_\(buffer)") { ctx in
                guard let engine = bundledEngine(ctx) else { return }
                let state = engine.update(buffer: buffer, context: [])
                let panel = state.candidates.map { stripZW($0.surface) }
                ctx.assertTrue(
                    panel.contains(expected),
                    detail: "(\(gloss)) buffer='\(buffer)' expected='\(expected)' panel=\(panel.prefix(12))"
                )
            })
        }

        // MARK: - Must-not-regress: structural `ain:` rank-0
        //
        // The parser rule for `ain:` produces the dot-above ai-vowel
        // surface `အိန်း` (entry 36721, alias_penalty=0). The new
        // synthetic `a-` alias must NOT displace this rank-0 mapping;
        // it lives mid-panel via the higher alias penalty.
        cases.append(TestCase("structuralAinColonStillRankZero_dotAboveAi") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "ain:", context: [])
            let top = stripZW(state.candidates.first?.surface ?? "")
            // အိန်း = 1021 102D 1014 103A 1038
            let expected = "\u{1021}\u{102D}\u{1014}\u{103A}\u{1038}"
            ctx.assertTrue(
                top == expected,
                detail: "rank-0 must remain the structural dot-above ai-shape; got top='\(top)' expected='\(expected)'"
            )
        })

        // MARK: - Control: existing `ah-` prefix still reaches its target
        //
        // The `ah-` block has been in place for a long time; the new
        // `a-` block must not break it.
        let ahPrefixControlCases: [(buffer: String, expected: String)] = [
            ("ahin:",  "\u{1021}\u{1004}\u{103A}\u{1038}"),                  // အင်း
            ("ahaung", "\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}"),          // အောင်
            ("ahar:",  "\u{1021}\u{102C}\u{1038}"),                          // အား
        ]
        for (buffer, expected) in ahPrefixControlCases {
            cases.append(TestCase("ahPrefixControl_\(buffer)") { ctx in
                guard let engine = bundledEngine(ctx) else { return }
                let state = engine.update(buffer: buffer, context: [])
                let panel = state.candidates.map { stripZW($0.surface) }
                ctx.assertTrue(
                    panel.contains(expected),
                    detail: "ah-control buffer='\(buffer)' expected='\(expected)' panel=\(panel.prefix(8))"
                )
            })
        }

        return TestSuite(name: "AprefixIndependentVowelReachability", cases: cases)
    }()
}
