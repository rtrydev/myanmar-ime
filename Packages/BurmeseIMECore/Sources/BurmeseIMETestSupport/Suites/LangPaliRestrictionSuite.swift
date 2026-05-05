import Foundation
import BurmeseIMECore

/// Step 4 / Tier 3 — C18 (Pali retroflex onsets — vowel limits).
///
/// Pali retroflex onsets {ဋ ဌ ဍ ဎ ဏ ဠ ဈ} appear almost exclusively
/// in Sanskrit/Pali loanwords. They legally pair with the inherent
/// vowel, ◌ာ family, ◌ိ / ◌ု family, ◌ေ family, and anusvara
/// nasal codas. They do *not* legally pair with native-Burmese
/// diphthong finals (-aung, -aing, -ote, -ate, -ain). The IME
/// must not surface those combinations as the rank-0 candidate.
public enum LangPaliRestrictionSuite {

    private static func bareEngine() -> BurmeseEngine {
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

    private static func rank0Excludes(
        _ ctx: TestContext,
        input: String,
        scalars: [UInt32],
        label: String
    ) {
        guard let engine = bundledEngine(ctx) else { return }
        let needle = String(scalars.compactMap { Unicode.Scalar($0).map { Character($0) } })
        let top = engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
        let contains = top.range(of: needle, options: .literal) != nil
        ctx.assertFalse(
            contains,
            label,
            detail: "rank-0 wrongly contains \(needle): '\(top)'"
        )
    }

    private static func panelContains(
        _ ctx: TestContext,
        input: String,
        scalars: [UInt32]
    ) {
        guard let engine = bundledEngine(ctx) else { return }
        let needle = String(scalars.compactMap { Unicode.Scalar($0).map { Character($0) } })
        let surfaces = engine.update(buffer: input, context: []).candidates.map(\.surface)
        let hit = surfaces.contains { $0.range(of: needle, options: .literal) != nil }
        ctx.assertTrue(
            hit,
            input,
            detail: "expected \(needle) in panel; got \(surfaces)"
        )
    }

    public static let suite = TestSuite(name: "LangPaliRestriction", cases: [

        // Allowed: Pali retroflex + inherent + aa. The structural
        // digit-less variant is directly visible at the bare-engine
        // layer; in production it can be pushed onto a later page by
        // high-frequency lexicon continuations.
        TestCase("pali_t2_aa_panelHasRetroflex") { ctx in
            let surfaces = bareEngine().update(buffer: "tar", context: []).candidates.map(\.surface)
            let hasRetroflex = surfaces.contains { $0.unicodeScalars.contains(Unicode.Scalar(0x100B)!) }
            ctx.assertTrue(hasRetroflex, "tar_panelHasBti", detail: "panel for 'tar' lacks ဋ retroflex variant: \(surfaces)")
        },
        TestCase("pali_n2_aa_panelHasRetroflex") { ctx in
            let surfaces = bareEngine().update(buffer: "nar", context: []).candidates.map(\.surface)
            let hasRetroflex = surfaces.contains { $0.unicodeScalars.contains(Unicode.Scalar(0x100F)!) }
            ctx.assertTrue(hasRetroflex, "nar_panelHasNna", detail: "panel for 'nar' lacks ဏ retroflex variant: \(surfaces)")
        },
        TestCase("pali_l2_aa_panelHasRetroflex") { ctx in
            let surfaces = bareEngine().update(buffer: "lar", context: []).candidates.map(\.surface)
            let hasRetroflex = surfaces.contains { $0.unicodeScalars.contains(Unicode.Scalar(0x1020)!) }
            ctx.assertTrue(hasRetroflex, "lar_panelHasLla", detail: "panel for 'lar' lacks ဠ retroflex variant: \(surfaces)")
        },

        // Allowed: Pali retroflex + anusvara nasal coda — same
        // panel-selection mechanism.
        TestCase("pali_t2_an3_panelHasAnusvara") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let surfaces = engine.update(buffer: "tan3", context: []).candidates.map(\.surface)
            // Either retroflex OR plain dental + anusvara is acceptable.
            let hasAnusvara = surfaces.contains { $0.unicodeScalars.contains(Unicode.Scalar(0x1036)!) }
            ctx.assertTrue(hasAnusvara, "tan3_anusvara", detail: "panel for 'tan3' lacks anusvara form: \(surfaces)")
        },
        TestCase("pali_n2_an3_panelHasAnusvara") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let surfaces = engine.update(buffer: "nan3", context: []).candidates.map(\.surface)
            let hasAnusvara = surfaces.contains { $0.unicodeScalars.contains(Unicode.Scalar(0x1036)!) }
            ctx.assertTrue(hasAnusvara, "nan3_anusvara", detail: "panel for 'nan3' lacks anusvara form: \(surfaces)")
        },

        // Disallowed: Pali retroflex + native diphthong finals.
        // The user types the digit-less reading; the IME's variant
        // disambiguation must NOT produce the Pali-retroflex form
        // for a native-diphthong rime.
        TestCase("pali_taung_noRetroflex") { ctx in
            rank0Excludes(ctx, input: "taung",
                          scalars: [0x100B, 0x1031, 0x102C, 0x1004, 0x103A],
                          label: "ဋောင်")
        },

        TestCase("pali_taing_noRetroflex") { ctx in
            rank0Excludes(ctx, input: "taing",
                          scalars: [0x100B, 0x102D, 0x102F, 0x1004, 0x103A],
                          label: "ဋိုင်")
        },

        TestCase("pali_tote_noRetroflex") { ctx in
            rank0Excludes(ctx, input: "tote",
                          scalars: [0x100B, 0x102F, 0x1010, 0x103A],
                          label: "ဋုတ်")
        },

        TestCase("pali_tain_noRetroflex") { ctx in
            rank0Excludes(ctx, input: "tain",
                          scalars: [0x100B, 0x102D, 0x1014, 0x103A],
                          label: "ဋိန်")
        },

        TestCase("pali_naung_noRetroflex") { ctx in
            rank0Excludes(ctx, input: "naung",
                          scalars: [0x100F, 0x1031, 0x102C, 0x1004, 0x103A],
                          label: "ဏောင်")
        },

        TestCase("pali_nai_noRetroflex") { ctx in
            rank0Excludes(ctx, input: "nai",
                          scalars: [0x100F, 0x102D, 0x102F, 0x1004, 0x103A],
                          label: "ဏိုင်")
        },
    ])
}
