import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-087: the tall/round-aa structural rule (descender
/// onsets {ခ ဂ င ဒ ပ ဝ} take tall ါ) applies to plain onsets — after a
/// virama-stack LOWER the aa shape is a per-word lexical convention
/// (MLC: `သိက္ခာ`, `ရိက္ခာ`, `ဥပေက္ခာ`, `စန္ဒာ`, `နန္ဒာ` round, but
/// `သဒ္ဓါ`, `မဂ္ဂါ…` tall; a full-store scan finds 153 stack-lower+aa
/// sites whose curated shape contradicts the structural prediction).
/// `correctAaShape` used to apply the structural rule unconditionally,
/// fabricating unattested `src=lexicon` spellings (`သိက္ခါ`) and making
/// the curated forms unreachable at any rank after the
/// `expandAaVariants` dedupe.
///
/// The fix skips the rewrite when the aa's base consonant is a PLAIN
/// stack lower (`<C> 1039 <C>` — the shape is authored: store surfaces
/// pass through verbatim, parser outputs keep the typed shape). Kinzi
/// (`103A 1039 <C>`) stays under the structural rule — the corpus
/// attests tall uniformly for kinzi+ဂ (`အင်္ဂါ`, `ဘင်္ဂါလီ`) and the
/// parser's own top-1 for kinzi buffers carries round aa, so the
/// rewrite is what produces the correct kinzi rendering.
public enum StackLowerAaShapeFidelitySuite {

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

    public static let suite = TestSuite(name: "StackLowerAaShapeFidelity", cases: [

        // `correctAaShape` must preserve the authored shape when the
        // aa's base is a plain virama-stack lower — both directions.
        TestCase("correctAaShape_preservesPlainStackLowerShapes") { ctx in
            let preserved: [(String, String)] = [
                ("thikkhar_round",  "သိက္ခာ"),
                ("rikkhar_round",   "ရိက္ခာ"),
                ("sandar_round",    "စန္ဒာ"),
                ("nandar_round",    "နန္ဒာ"),
                ("arnandar_round",  "အာနန္ဒာ"),
                ("upaykkhar_round", "ဥပေက္ခာ"),
                ("adhippar_round",  "အဓိပ္ပာယ်"),
                ("thaddhar_tall",   "သဒ္ဓါ"),
                ("maggar_tall",     "မဂ္ဂါဝပ်"),
                ("mettar_round",    "မေတ္တာ"),
                ("kambar_round",    "ကမ္ဘာ"),
            ]
            for (label, surface) in preserved {
                let actual = BurmeseEngine.correctAaShape(surface)
                ctx.assertEqual(actual, surface, label)
            }
        },

        // Kinzi bases are also virama-preceded (`103A 1039 <C>`) but
        // stay under the structural rule — the skip must not catch
        // them (the parser's top-1 for kinzi buffers carries round
        // aa, and the rewrite is what produces the attested `အင်္ဂါ`).
        TestCase("correctAaShape_kinziStaysStructural") { ctx in
            // အင်္ဂာ → အင်္ဂါ
            let kinziRound = "\u{1021}\u{1004}\u{103A}\u{1039}\u{1002}\u{102C}"
            let kinziTall = "\u{1021}\u{1004}\u{103A}\u{1039}\u{1002}\u{102B}"
            ctx.assertEqual(
                BurmeseEngine.correctAaShape(kinziRound),
                kinziTall,
                "kinzi_ga_aa"
            )
        },

        // Plain-onset behavior unchanged: descender onsets take tall,
        // others round, old-style tall variants normalize.
        TestCase("correctAaShape_plainOnsetsUnchanged") { ctx in
            let rewrites: [(String, String, String)] = [
                ("par",  "ပာ", "ပါ"),
                ("kar2", "ကါ", "ကာ"),
                ("dhar2", "ဓါး", "ဓား"),
            ]
            for (label, input, expected) in rewrites {
                ctx.assertEqual(BurmeseEngine.correctAaShape(input), expected, label)
            }
        },

        // Curated round-aa spellings reach the panel (top 3) for their
        // canonical readings, and no fabricated tall twin is offered
        // as a lexicon hit.
        TestCase("production_curatedRoundStackLowerSpellingsReachable") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, expected: String, fabricated: String)] = [
                ("thi.kkhar", "သိက္ခာ",  "သိက္ခါ"),
                ("ri.kkhar",  "ရိက္ခာ",  "ရိက္ခါ"),
                ("sandar",    "စန္ဒာ",   "စန္ဒါ"),
                ("nandar",    "နန္ဒာ",   "နန္ဒါ"),
                ("arnandar",  "အာနန္ဒာ", "အာနန္ဒါ"),
                ("upaykkhar", "ဥပေက္ခာ", "ဥပေက္ခါ"),
            ]
            for c in cases {
                let candidates = engine.update(buffer: c.buffer, context: []).candidates
                let rank = candidates.firstIndex { $0.surface == c.expected }
                ctx.assertTrue(
                    rank != nil && rank! < 3,
                    c.buffer,
                    detail: "expected '\(c.expected)' in top 3; got \(candidates.prefix(5).map(\.surface)) (rank=\(rank.map(String.init) ?? "absent"))"
                )
                let fabricatedLexicon = candidates.contains {
                    $0.surface == c.fabricated && $0.source == .lexicon
                }
                ctx.assertFalse(
                    fabricatedLexicon,
                    "\(c.buffer)_noFabricatedLexiconTwin",
                    detail: "fabricated '\(c.fabricated)' offered as a lexicon hit"
                )
            }
        },

        // The fix must be shape-preserving, not round-forcing: curated
        // TALL stack-lower spellings keep the tall hook.
        TestCase("production_curatedTallStackLowerSpellingsPreserved") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, expected: String)] = [
                ("thaddhar",        "သဒ္ဓါ"),
                ("thaddhartarar:",  "သဒ္ဓါတရား"),
            ]
            for c in cases {
                let candidates = engine.update(buffer: c.buffer, context: []).candidates
                let rank = candidates.firstIndex { $0.surface == c.expected }
                ctx.assertTrue(
                    rank != nil && rank! < 3,
                    c.buffer,
                    detail: "expected '\(c.expected)' in top 3; got \(candidates.prefix(5).map(\.surface)) (rank=\(rank.map(String.init) ?? "absent"))"
                )
            }
        },

        // Where both shapes are real store entries, both must be
        // panel-reachable as distinct candidates rather than
        // collapsing into one.
        TestCase("production_dualEntrySpellingsBothReachable") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let candidates = engine.update(buffer: "adhi.ppary*", context: []).candidates
            for expected in ["အဓိပ္ပာယ်", "အဓိပ္ပါယ်"] {
                ctx.assertTrue(
                    candidates.contains { $0.surface == expected },
                    "adhi.ppary*_\(expected)",
                    detail: "expected '\(expected)' in panel; got \(candidates.map(\.surface))"
                )
            }
        },

        // Controls verified working today — must not regress.
        TestCase("production_controlsKeepRank0") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, expected: String)] = [
                ("kambar",    "ကမ္ဘာ"),
                ("mayt+tar",  "မေတ္တာ"),
            ]
            for c in cases {
                let top = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertEqual(top, c.expected, c.buffer)
            }
            // Kinzi tall-aa stays correct end-to-end.
            let kinzi = engine.update(buffer: "in+gar", context: []).candidates
            ctx.assertTrue(
                kinzi.contains { $0.surface == "အင်္ဂါ" },
                "in+gar",
                detail: "expected 'အင်္ဂါ' in panel; got \(kinzi.map(\.surface))"
            )
        },
    ])
}
