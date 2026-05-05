import Foundation
import BurmeseIMECore

/// Step 4 / Tier 2 — C8 (closed syllables, each coda type).
///
/// Burmese closed syllables end in either a consonant + asat (-k, -ng,
/// -c, -t, -p, -n, -m, -y) or anusvara (-an3 / U+1036). Each coda
/// type gets one canonical-base test on `k` (က) so the coverage is a
/// clean inventory matrix.
public enum LangCodaInventorySuite {

    private static func bareEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func panelContains(
        _ ctx: TestContext,
        input: String,
        scalars: [UInt32]
    ) {
        let needle = String(scalars.compactMap { Unicode.Scalar($0).map { Character($0) } })
        let surfaces = bareEngine().update(buffer: input, context: []).candidates.map(\.surface)
        let hit = surfaces.contains { $0.range(of: needle, options: .literal) != nil }
        ctx.assertTrue(
            hit,
            input,
            detail: "expected \(needle) in panel; got \(surfaces)"
        )
    }

    public static let suite = TestSuite(name: "LangCodaInventory", cases: [

        // -k coda
        TestCase("coda_k_et") { ctx in
            panelContains(ctx, input: "ket", scalars: [0x1000, 0x1000, 0x103A])
        },

        // -ng coda
        TestCase("coda_ng_in") { ctx in
            panelContains(ctx, input: "kin", scalars: [0x1000, 0x1004, 0x103A])
        },

        // -c coda
        TestCase("coda_c_it") { ctx in
            panelContains(ctx, input: "kit", scalars: [0x1000, 0x1005, 0x103A])
        },

        // -t coda
        TestCase("coda_t_at") { ctx in
            panelContains(ctx, input: "kat", scalars: [0x1000, 0x1010, 0x103A])
        },

        // -n coda
        TestCase("coda_n_an") { ctx in
            panelContains(ctx, input: "kan", scalars: [0x1000, 0x1014, 0x103A])
        },

        // -p coda (ka + ate2 → kate2 = `ကိပ်`)
        TestCase("coda_p_ate2") { ctx in
            panelContains(ctx, input: "kate2", scalars: [0x1000, 0x102D, 0x1015, 0x103A])
        },

        // -m coda (an2 = `မ်`)
        TestCase("coda_m_an2") { ctx in
            panelContains(ctx, input: "kan2", scalars: [0x1000, 0x1019, 0x103A])
        },

        // -y coda (e = `ယ်`)
        TestCase("coda_y_e") { ctx in
            panelContains(ctx, input: "ke", scalars: [0x1000, 0x101A, 0x103A])
        },

        // anusvara coda
        TestCase("coda_anusvara_an3") { ctx in
            panelContains(ctx, input: "kan3", scalars: [0x1000, 0x1036])
        },

        // -aing diphthong + ng coda
        TestCase("coda_aing") { ctx in
            panelContains(ctx, input: "kaing", scalars: [0x1000, 0x102D, 0x102F, 0x1004, 0x103A])
        },

        // -aung diphthong + ng coda. Prescript U+1031 is stored
        // after the consonant in logical order.
        TestCase("coda_aung") { ctx in
            panelContains(ctx, input: "kaung", scalars: [0x1000, 0x1031, 0x102C, 0x1004, 0x103A])
        },

        // -out diphthong + k coda
        TestCase("coda_out") { ctx in
            panelContains(ctx, input: "kout", scalars: [0x1000, 0x1031, 0x102C, 0x1000, 0x103A])
        },
    ])
}
