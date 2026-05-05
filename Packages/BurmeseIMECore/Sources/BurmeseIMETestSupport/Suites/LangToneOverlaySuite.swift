import Foundation
import BurmeseIMECore

/// Step 4 / Tier 2 — C9, C36 (tone overlay).
///
/// The three Burmese tones (low / creaky / heavy) layer over the
/// same syllable. The orthographic markers are `(none) / ◌့ / း`.
/// For each tone-eligible rime, all three forms must be reachable.
/// At most one tone marker per syllable; the marker position is
/// after any coda asat.
public enum LangToneOverlaySuite {

    private static func bareEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func panelContains(
        _ ctx: TestContext,
        input: String,
        scalars: [UInt32],
        label: String
    ) {
        let needle = String(scalars.compactMap { Unicode.Scalar($0).map { Character($0) } })
        let surfaces = bareEngine().update(buffer: input, context: []).candidates.map(\.surface)
        let hit = surfaces.contains { $0.range(of: needle, options: .literal) != nil }
        ctx.assertTrue(
            hit,
            label,
            detail: "expected \(needle) in panel for '\(input)'; got \(surfaces)"
        )
    }

    private static func toneTriple(
        _ ctx: TestContext,
        base: String,
        suffix: String,
        scalarsLow: [UInt32],
        scalarsCreaky: [UInt32],
        scalarsHeavy: [UInt32]
    ) {
        panelContains(ctx, input: base + suffix,        scalars: scalarsLow,    label: "\(base+suffix)_low")
        panelContains(ctx, input: base + suffix + ".",  scalars: scalarsCreaky, label: "\(base+suffix).creaky")
        panelContains(ctx, input: base + suffix + ":",  scalars: scalarsHeavy,  label: "\(base+suffix):heavy")
    }

    public static let suite = TestSuite(name: "LangToneOverlay", cases: [

        // -aa rime: round (m → မ) and tall (p → ပ)
        TestCase("tone_mar_triple") { ctx in
            toneTriple(ctx, base: "m", suffix: "ar",
                       scalarsLow:    [0x1019, 0x102C],
                       scalarsCreaky: [0x1019, 0x102C, 0x1037],
                       scalarsHeavy:  [0x1019, 0x102C, 0x1038])
        },
        TestCase("tone_par_triple") { ctx in
            toneTriple(ctx, base: "p", suffix: "ar",
                       scalarsLow:    [0x1015, 0x102B],
                       scalarsCreaky: [0x1015, 0x102B, 0x1037],
                       scalarsHeavy:  [0x1015, 0x102B, 0x1038])
        },

        // -i rime
        TestCase("tone_mi_triple") { ctx in
            // creaky 'mi.' uses U+102D (no separate creaky tone scalar)
            panelContains(ctx, input: "mi",   scalars: [0x1019, 0x102E],         label: "mi_low")
            panelContains(ctx, input: "mi.",  scalars: [0x1019, 0x102D],         label: "mi.creaky")
            panelContains(ctx, input: "mi:",  scalars: [0x1019, 0x102E, 0x1038], label: "mi:heavy")
        },

        // -u rime
        TestCase("tone_mu_triple") { ctx in
            panelContains(ctx, input: "mu",   scalars: [0x1019, 0x1030],         label: "mu_low")
            panelContains(ctx, input: "mu.",  scalars: [0x1019, 0x102F],         label: "mu.creaky")
            panelContains(ctx, input: "mu:",  scalars: [0x1019, 0x1030, 0x1038], label: "mu:heavy")
        },

        // -in rime (closed) — tone follows asat
        TestCase("tone_min_triple") { ctx in
            panelContains(ctx, input: "min",  scalars: [0x1019, 0x1004, 0x103A],         label: "min_low")
            panelContains(ctx, input: "min.", scalars: [0x1019, 0x1004, 0x1037, 0x103A], label: "min.creaky")
            panelContains(ctx, input: "min:", scalars: [0x1019, 0x1004, 0x103A, 0x1038], label: "min:heavy")
        },

        // -aing diphthong rime
        TestCase("tone_kaing_triple") { ctx in
            panelContains(ctx, input: "kaing",  scalars: [0x1000, 0x102D, 0x102F, 0x1004, 0x103A], label: "kaing_low")
            panelContains(ctx, input: "kaing.", scalars: [0x1000, 0x102D, 0x102F, 0x1004, 0x1037, 0x103A], label: "kaing.creaky")
            panelContains(ctx, input: "kaing:", scalars: [0x1000, 0x102D, 0x102F, 0x1004, 0x103A, 0x1038], label: "kaing:heavy")
        },

        // -aung diphthong (descender base = tall aa overlay).
        // Prescript U+1031 is stored after the consonant in logical
        // order: ပေါင် = 1015 1031 102B 1004 103A.
        TestCase("tone_paung_triple_tallAa") { ctx in
            panelContains(ctx, input: "paung",  scalars: [0x1015, 0x1031, 0x102B, 0x1004, 0x103A], label: "paung_low")
            panelContains(ctx, input: "paung.", scalars: [0x1015, 0x1031, 0x102B, 0x1004, 0x1037, 0x103A], label: "paung.creaky")
            panelContains(ctx, input: "paung:", scalars: [0x1015, 0x1031, 0x102B, 0x1004, 0x103A, 0x1038], label: "paung:heavy")
        },

        // Negative invariant: more than one tone marker per syllable
        // is invalid and must not surface as rank-0.
        TestCase("doubleToneMarker_excludedFromRank0") { ctx in
            // `mar.:` would be creaky+heavy on the same syllable —
            // not a legal Burmese form.
            let state = bareEngine().update(buffer: "mar.:", context: [])
            let top = state.candidates.first?.surface ?? ""
            let scalars = top.unicodeScalars.map(\.value)
            let creakyCount = scalars.filter { $0 == 0x1037 }.count
            let heavyCount = scalars.filter { $0 == 0x1038 }.count
            ctx.assertFalse(
                creakyCount > 0 && heavyCount > 0,
                "doubleTone",
                detail: "rank-0 has both creaky+heavy: '\(top)'"
            )
        },
    ])
}
