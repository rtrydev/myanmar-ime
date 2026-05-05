import Foundation
import BurmeseIMECore

/// Step 4 / Tier 2 — C4, C5, C6, C7 (medial legality).
///
/// Each medial sign is exercised on at least one legal base. The
/// canonical-order invariant (◌ျ < ◌ြ < ◌ွ < ◌ှ in Unicode) is
/// asserted on multi-medial outputs. Forbidden combinations
/// (e.g. retroflex + ya-pin, stop + ha-htoe) must not surface as
/// the rank-0 panel candidate.
public enum LangMedialLegalitySuite {

    private static func bareEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func surfaces(_ input: String) -> [String] {
        bareEngine().update(buffer: input, context: []).candidates.map(\.surface)
    }

    private static func panelContains(_ ctx: TestContext, input: String, scalars: [UInt32]) {
        let needle = String(scalars.compactMap { Unicode.Scalar($0).map { Character($0) } })
        let hit = surfaces(input).contains { $0.range(of: needle, options: .literal) != nil }
        ctx.assertTrue(
            hit,
            input,
            detail: "expected \(needle) (\(scalars.map { String(format: "%04X", $0) }.joined(separator: " "))) in any panel surface; got \(surfaces(input))"
        )
    }

    private static func rank0Excludes(_ ctx: TestContext, input: String, scalars: [UInt32], label: String) {
        let needle = String(scalars.compactMap { Unicode.Scalar($0).map { Character($0) } })
        let top = surfaces(input).first ?? ""
        ctx.assertFalse(
            top.range(of: needle, options: .literal) != nil,
            label,
            detail: "rank-0 surface should not contain \(needle): '\(top)'"
        )
    }

    public static let suite = TestSuite(name: "LangMedialLegality", cases: [

        // C4-* — ya-yit (◌ြ U+103C) on legal bases.
        TestCase("yaYit_kya")  { ctx in panelContains(ctx, input: "kyar",  scalars: [0x1000, 0x103C, 0x102C]) },
        TestCase("yaYit_khya") { ctx in panelContains(ctx, input: "khya",  scalars: [0x1001, 0x103C]) },
        TestCase("yaYit_gya")  { ctx in panelContains(ctx, input: "gya",   scalars: [0x1002, 0x103C]) },
        TestCase("yaYit_pya")  { ctx in panelContains(ctx, input: "pya",   scalars: [0x1015, 0x103C]) },
        TestCase("yaYit_mya")  { ctx in panelContains(ctx, input: "mya",   scalars: [0x1019, 0x103C]) },
        TestCase("yaYit_hya")  { ctx in panelContains(ctx, input: "hya",   scalars: [0x101F, 0x103C]) },

        // C4-* — ya-pin (◌ျ U+103B) via digit-disambiguated input.
        TestCase("yaPin_ky2a")  { ctx in panelContains(ctx, input: "ky2a",  scalars: [0x1000, 0x103B]) },
        TestCase("yaPin_my2a")  { ctx in panelContains(ctx, input: "my2a",  scalars: [0x1019, 0x103B]) },
        TestCase("yaPin_ly2a")  { ctx in panelContains(ctx, input: "ly2a",  scalars: [0x101C, 0x103B]) },
        TestCase("yaPin_yy2a")  { ctx in panelContains(ctx, input: "yy2a",  scalars: [0x101A, 0x103B]) },

        // C4-* — wa-swe (◌ွ U+103D)
        TestCase("waSwe_kwa")  { ctx in panelContains(ctx, input: "kwa", scalars: [0x1000, 0x103D]) },
        TestCase("waSwe_mwa")  { ctx in panelContains(ctx, input: "mwa", scalars: [0x1019, 0x103D]) },
        TestCase("waSwe_thwa") { ctx in panelContains(ctx, input: "thwa", scalars: [0x101E, 0x103D]) },
        TestCase("waSwe_hwa")  { ctx in panelContains(ctx, input: "hwa", scalars: [0x101F, 0x103D]) },

        // C4-* — ha-htoe (◌ှ U+103E) on sonorants only.
        TestCase("haHtoe_hma") { ctx in panelContains(ctx, input: "hma", scalars: [0x1019, 0x103E]) },
        TestCase("haHtoe_hna") { ctx in panelContains(ctx, input: "hna", scalars: [0x1014, 0x103E]) },
        TestCase("haHtoe_hla") { ctx in panelContains(ctx, input: "hla", scalars: [0x101C, 0x103E]) },
        TestCase("haHtoe_hnga"){ ctx in panelContains(ctx, input: "hnga", scalars: [0x1004, 0x103E]) },

        // C5-* — forbidden medial-base combinations: rank-0 must NOT
        // produce the literal forbidden shape.
        TestCase("forbidden_haYaPin") { ctx in
            // ha + ya-pin is excluded from `Grammar.canTakeMedialYa`.
            rank0Excludes(ctx, input: "hy2a", scalars: [0x101F, 0x103B], label: "haYaPin")
        },
        TestCase("forbidden_nyaYaPin") { ctx in
            rank0Excludes(ctx, input: "nyy2a", scalars: [0x100A, 0x103B], label: "nnyaYaPin")
        },
        TestCase("forbidden_kHaHtoe") { ctx in
            rank0Excludes(ctx, input: "khha", scalars: [0x1000, 0x103E], label: "kaHaHtoe")
        },
        TestCase("forbidden_pHaHtoe") { ctx in
            rank0Excludes(ctx, input: "phha", scalars: [0x1015, 0x103E], label: "paHaHtoe")
        },
        TestCase("forbidden_tHaHtoe") { ctx in
            rank0Excludes(ctx, input: "thha", scalars: [0x1010, 0x103E], label: "taHaHtoe")
        },

        // C6-* — multi-medial canonical-order: when two medials
        // surface, U+103B/103C precede U+103D, which precedes U+103E.
        TestCase("multiMedial_canonicalOrder_kywaa") { ctx in
            // m + ya-pin/ya-yit + wa-swe + aa
            let candidates = surfaces("kywaa")
            ctx.assertTrue(!candidates.isEmpty, detail: "no candidates for 'kywaa'")
            for candidate in candidates {
                let medials = candidate.unicodeScalars.compactMap { scalar -> UInt32? in
                    (0x103B...0x103E).contains(scalar.value) ? scalar.value : nil
                }
                if medials.count >= 2 {
                    var inOrder = true
                    for i in 1..<medials.count where medials[i-1] >= medials[i] {
                        inOrder = false
                        break
                    }
                    ctx.assertTrue(
                        inOrder,
                        "kywaa",
                        detail: "medials out of canonical order in '\(candidate)': \(medials.map { String(format: "%04X", $0) })"
                    )
                }
            }
        },

        // C7-* — triple-medial vowel restriction. `mywh` + non-aa
        // vowel should not produce a rank-0 surface.
        TestCase("tripleMedial_inherent_legal") { ctx in
            panelContains(ctx, input: "mywha", scalars: [0x1019, 0x103C, 0x103D, 0x103E])
        },
        TestCase("tripleMedial_aa_legal") { ctx in
            panelContains(ctx, input: "mywhar", scalars: [0x1019, 0x103C, 0x103D, 0x103E, 0x102C])
        },
        TestCase("tripleMedial_i_illegal_atRank0") { ctx in
            rank0Excludes(ctx, input: "mywhi", scalars: [0x1019, 0x103C, 0x103D, 0x103E, 0x102E], label: "tripleMedialI")
        },
        TestCase("tripleMedial_o_illegal_atRank0") { ctx in
            rank0Excludes(ctx, input: "mywho", scalars: [0x1019, 0x103C, 0x103D, 0x103E, 0x102D, 0x102F], label: "tripleMedialO")
        },
    ])
}
