import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-085: Burmese writes loanword final consonant
/// clusters as a closed syllable followed by a bare killed consonant —
/// `ဘတ်စ်` (bus), `ဗိုင်းရပ်စ်` (virus), `ဝက်ဘ်ဆိုက်` (website),
/// `ပတ်စ်ပို့` (passport), `မော်ဒယ်လ်` (model), `အက်စ်` (the letter S).
/// The shipped lexicon carries 453 entries with this `<C>်<C>်` shape.
///
/// The TASK-039/TASK-045 doubled-coda-chain predicate flagged ANY pair
/// of asats whose in-between run is exactly one bare consonant, which
/// is precisely this legitimate loanword shape — not just the
/// doubled-`e`-rule bug pattern (`… 101A 103A 101A 103A …`) it was
/// written for. The false positive collapsed whole buffers to a
/// literal-only panel once the literal fallback counted as the clean
/// sibling. The `e` rule is the only rule that emits a coda without an
/// explicit coda key, and it always emits ya-asat (`101A 103A`), so the
/// predicate is now restricted to runs whose lone consonant is ya
/// (U+101A) — covering everything the `e` rule can fabricate while
/// leaving the loanword class alone (no store entry carries `<C>်ယ်`).
public enum LoanwordBareConsonantCodaSuite {

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

    public static let suite = TestSuite(name: "LoanwordBareConsonantCoda", cases: [

        // The predicate must NOT flag attested loanword bare-consonant
        // asat codas: the lone consonant between the two asats is not
        // ya, so the shape cannot come from a doubled `e` rule.
        TestCase("predicate_acceptsLoanwordBareConsonantCodas") { ctx in
            let attested: [(String, String)] = [
                ("bus",       "ဘတ်စ်"),
                ("bus_kar",   "ဘတ်စ်ကား"),
                ("virus",     "ဗိုင်းရပ်စ်"),
                ("web",       "ဝက်ဘ်ဆိုက်"),
                ("passport",  "ပတ်စ်ပို့"),
                ("el",        "အယ်လ်"),
                ("us",        "ယူအက်စ်"),
                ("model",     "မော်ဒယ်လ်"),
                ("es",        "အက်စ်"),
                ("facebook",  "ဖေ့စ်ဘွတ်ခ်"),
                ("muslim",    "မွတ်စလင်မ်"),
            ]
            for (label, surface) in attested {
                ctx.assertFalse(
                    BurmeseEngine.surfaceContainsDoubledCodaChain(surface),
                    label,
                    detail: "predicate over-flagged attested loanword '\(surface)'"
                )
            }
        },

        // The genuine bug class — doubled ya-asat codas — must stay
        // flagged. (The full doubled-`e`-rule sweep lives in
        // DoubledCodaChainSuite; these are the canonical bug shapes
        // restated next to the loanword negatives for contrast.)
        TestCase("predicate_stillFlagsDoubledYaAsatChains") { ctx in
            let violators: [(String, [UInt32])] = [
                ("ra_yy", [0x101B, 0x101A, 0x103A, 0x101A, 0x103A]),
                ("ka_yy", [0x1000, 0x101A, 0x103A, 0x101A, 0x103A]),
                ("eea",   [0x1021, 0x101A, 0x103A, 0x101A, 0x103A]),
                ("let_ee", [0x101C, 0x1000, 0x103A, 0x101A, 0x103A, 0x101A, 0x103A]),
            ]
            for (label, scalars) in violators {
                var s = ""
                s.unicodeScalars.append(
                    contentsOf: scalars.compactMap { Unicode.Scalar($0) }
                )
                ctx.assertTrue(
                    BurmeseEngine.surfaceContainsDoubledCodaChain(s),
                    label,
                    detail: "predicate failed to flag doubled ya-asat chain '\(s)'"
                )
            }
        },

        // Canonical readings of the loanword class must surface their
        // entries — no literal-only collapse. `bats*kar:` is a
        // penalty-0 exact alias of a rank-600+ entry: top 3.
        TestCase("production_busKarReachesTop3") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let candidates = engine.update(buffer: "bats*kar:", context: []).candidates
            let rank = candidates.firstIndex { $0.surface == "ဘတ်စ်ကား" }
            ctx.assertTrue(
                rank != nil && rank! < 3,
                "bats*kar:",
                detail: "expected 'ဘတ်စ်ကား' in top 3; got \(candidates.prefix(5).map(\.surface)) (rank=\(rank.map(String.init) ?? "absent"))"
            )
        },

        // Panel presence for the rest of the class (one member per
        // coda consonant ခ/စ/ဘ/လ and per position in the word).
        TestCase("production_loanwordCodaClassReachable") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, expected: String)] = [
                ("bats*",        "ဘတ်စ်"),
                ("vaing:rap*s*", "ဗိုင်းရပ်စ်"),
                ("wetb*hsite",   "ဝက်ဘ်ဆိုက်"),
                ("pats*po.",     "ပတ်စ်ပို့"),
                ("el*",          "အယ်လ်"),
                ("mawdel*",      "မော်ဒယ်လ်"),
            ]
            for c in cases {
                let candidates = engine.update(buffer: c.buffer, context: []).candidates
                ctx.assertTrue(
                    candidates.contains { $0.surface == c.expected },
                    c.buffer,
                    detail: "expected '\(c.expected)' in panel; got \(candidates.map(\.surface))"
                )
            }
        },

        // No literal-only panel for any buffer that is the exact
        // penalty-0 alias of a store entry in this class.
        TestCase("production_noLiteralOnlyCollapse") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffers = [
                "bats*kar:", "vaing:rap*s*", "wetb*hsite",
                "pats*po.", "mawdel*", "el*",
            ]
            for buffer in buffers {
                let candidates = engine.update(buffer: buffer, context: []).candidates
                let hasMyanmar = candidates.contains { cand in
                    cand.surface.unicodeScalars.contains { $0.value >= 0x1000 && $0.value <= 0x109F }
                }
                ctx.assertTrue(
                    hasMyanmar,
                    buffer,
                    detail: "literal-only panel: \(candidates.map(\.surface))"
                )
            }
        },

        // Control: the accidental survivor keeps its rank 0 (exact hit
        // lands before the literal is injected).
        TestCase("production_yuahetsKeepsRank0") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let top = engine.update(buffer: "yuahets*", context: [])
                .candidates.first?.surface ?? ""
            ctx.assertEqual(top, "ယူအက်စ်", "yuahets*")
        },
    ])
}
