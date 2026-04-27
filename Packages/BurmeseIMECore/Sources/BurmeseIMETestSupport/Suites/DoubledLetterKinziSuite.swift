import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-019: doubled-letter `gg` signals a kinzi-stack rendering
/// (`င်္`) regardless of which vowel rule produced the asat coda
/// preceding it. Two related bug shapes:
///
///   Bug A: `<C>(an|ang|aung)gg<rest>` produces no kinzi candidate
///          at all (e.g. `kanggar` → `ကငဂါ`, missing the kinzi);
///          fix surfaces a kinzi-bearing candidate at rank 0 or
///          rank ≥ 1.
///   Bug B: `<C>in<gg>...` fires kinzi but also emits the extra
///          `1002` ga (e.g. `kinggar` → `ကင်္ဂဂါ`); fix collapses
///          the doubled `g` so the rank-0 surface contains exactly
///          one `1002` past the kinzi virama.
public enum DoubledLetterKinziSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    /// True when `surface` contains the kinzi pattern
    /// `1004 103A 1039 <lower>` somewhere.
    private static func surfaceContainsKinzi(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        for i in 0..<(scalars.count - 2)
        where scalars[i] == 0x1004 && scalars[i + 1] == 0x103A
            && scalars[i + 2] == 0x1039 {
            return true
        }
        return false
    }

    /// True when `surface` contains a doubled-`1002` (`ga` ga) after
    /// a kinzi virama (the Bug B shape `1004 103A 1039 1002 1002`).
    private static func surfaceHasDoubledKinziGa(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        for i in 0..<(scalars.count - 4)
        where scalars[i] == 0x1004 && scalars[i + 1] == 0x103A
            && scalars[i + 2] == 0x1039 && scalars[i + 3] == 0x1002
            && scalars[i + 4] == 0x1002 {
            return true
        }
        return false
    }

    /// True when `surface` is structured as `<onset-consonant> <kinzi
    /// pattern> <rest>`, i.e. exactly one consonant scalar precedes
    /// the kinzi `1004 103A 1039`. No medial / vowel scalars are
    /// allowed between the onset consonant and the kinzi anchor.
    /// Used for the Bug B follow-up criterion: rank-0 surfaces for
    /// `<C>in<gg><rest>` buffers must not carry a stray `i-kar`
    /// (`102E`) or other vowel scalar before the kinzi.
    private static func surfaceHasCleanKinziPrefix(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 4 else { return false }
        // First scalar must be a consonant base (1000..1021 inclusive).
        let onset = scalars[0]
        guard (onset >= 0x1000 && onset <= 0x1021) || onset == 0x103F else {
            return false
        }
        // Kinzi anchor must start at scalar index 1.
        return scalars[1] == 0x1004
            && scalars[2] == 0x103A
            && scalars[3] == 0x1039
    }

    public static let suite = TestSuite(name: "DoubledLetterKinzi", cases: [

        // Bug A: `<C>angg<rest>` must surface a kinzi-bearing
        // candidate somewhere in the panel.
        TestCase("bugA_kinziSurfaceReachable") { ctx in
            let engine = emptyEngine()
            for buffer in [
                "kanggar", "manggar", "ranggar", "manggyi",
            ] {
                let state = engine.update(buffer: buffer, context: [])
                let hasKinzi = state.candidates.contains {
                    surfaceContainsKinzi($0.surface)
                }
                ctx.assertTrue(
                    hasKinzi,
                    buffer,
                    detail: "panel for '\(buffer)' contains no kinzi candidate; surfaces=\(state.candidates.map(\.surface))"
                )
            }
        },

        // Bug B: `<C>ing<gg>...` rank-0 surface must NOT have a
        // doubled `1002` ga after the kinzi virama.
        TestCase("bugB_noDoubledGaAfterKinzi") { ctx in
            let engine = emptyEngine()
            for buffer in [
                "kinggar", "singgyi", "tinggar",
                "hinggar", "ringgit",
            ] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    surfaceHasDoubledKinziGa(surface),
                    buffer,
                    detail: "rank-0 for '\(buffer)' has doubled `1002` after kinzi; surface='\(surface)'"
                )
            }
        },

        // Existing kinzi behaviour must be preserved.
        TestCase("counter_anggar_unchanged") { ctx in
            let engine = emptyEngine()
            let surface = engine.update(buffer: "anggar", context: [])
                .candidates.first?.surface ?? ""
            ctx.assertTrue(
                surfaceContainsKinzi(surface),
                "anggar",
                detail: "rank-0 for 'anggar' lost kinzi; surface='\(surface)'"
            )
        },

        // Bug B clean-prefix follow-up: rank-0 surfaces for
        // `<C>in<gg><rest>` buffers must place the kinzi immediately
        // after the leading onset consonant — no stray `i-kar`
        // (`102E`) or other vowel scalar between the onset and the
        // kinzi anchor. Without the doubled-letter pre-pass, the
        // parser splits `<C>in*+gg<rest>` into `<C> + i-kar + ng +
        // asat + virama + g + ...`, leaving an orphan `102E`. The
        // pre-pass collapses to `<C>in+g<rest>` which materialises
        // cleanly as `<C> + nga + asat + virama + g + ...`.
        TestCase("bugB_cleanKinziPrefix") { ctx in
            let engine = emptyEngine()
            for buffer in [
                "kinggar", "singgyi", "tinggar",
                "hinggar", "ringgit",
            ] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    surfaceHasCleanKinziPrefix(surface),
                    buffer,
                    detail: "rank-0 for '\(buffer)' has stray scalars before kinzi; surface='\(surface)'"
                )
            }
        },

        // Bug A rank-0 promotion: `<C>(an|aung)gg<rest>` must place
        // the kinzi-bearing candidate at rank 0 (not just somewhere
        // in the panel), matching the structural symmetry with
        // `<C>in<gg><rest>` and the buffer-leading `anggar` case.
        TestCase("bugA_kinziAtRank0") { ctx in
            let engine = emptyEngine()
            for buffer in [
                "kanggar", "manggar", "ranggar", "manggyi",
                "nganggar", "ranggam", "kanggalip",
            ] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    surfaceContainsKinzi(surface),
                    buffer,
                    detail: "rank-0 for '\(buffer)' is not kinzi; surface='\(surface)'"
                )
            }
        },

        // Bare-inherent-a tail with `<C>in<gg>a` shape (`kingga`,
        // `tingga`, …) — the doubled letter is the user's
        // explicit kinzi-stack signal even when the post-stack
        // syllable is bare-inherent-a. The pre-pass collapses to
        // `<C>in+ga`, which materialises a clean `ကင်္ဂ`
        // (kinzi + g + inherent-a) instead of the parser's open
        // form `ကင်ဂဂ` (doubled `1002`).
        TestCase("bareInherentATail_collapsesToKinzi") { ctx in
            let engine = emptyEngine()
            for buffer in ["kingga", "tingga", "singga", "ringga"] {
                let surface = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    surfaceContainsKinzi(surface),
                    buffer,
                    detail: "rank-0 for '\(buffer)' has no kinzi; surface='\(surface)'"
                )
                ctx.assertFalse(
                    surfaceHasDoubledKinziGa(surface),
                    buffer,
                    detail: "rank-0 for '\(buffer)' has doubled `1002` after kinzi; surface='\(surface)'"
                )
            }
        },

        // Overlap-with-longer-rule guard (`maingga`, `kainggar` …).
        // When a longer nga-asat-emitting vowel rule (`aing`, `aung`)
        // would naturally consume the buffer past the doubled letter,
        // the pre-pass MUST defer to the existing `ai+ng` collapse
        // (or the open form) instead of mis-segmenting the buffer
        // via the shorter `in` key. This avoids producing nonsense
        // rewrites like `main+ga` for `maingga` (the `in` key
        // overlaps the `aing` rule).
        TestCase("longerNgaAsatRuleOverlap_prepassDefers") { ctx in
            // `maingga`: longer `aing` covers chars[1..5], so the
            // shorter `in` match at chars[2..4] must defer.
            let mainggaResult = BurmeseEngine.inferImplicitStackMarkers("maingga")
            ctx.assertTrue(
                mainggaResult?.input != "main+ga",
                "maingga.notMainPlusGa",
                detail: "doubled-letter pre-pass mis-fired for maingga (in overlapped by aing); inferred='\(mainggaResult?.input ?? "nil")'"
            )
            // `kainggar`: longer `aing` covers chars[1..5], existing
            // `ai+ng` mid-buffer collapse owns the rewrite (`kai+gar`).
            let kainggarResult = BurmeseEngine.inferImplicitStackMarkers("kainggar")
            ctx.assertTrue(
                kainggarResult?.input == "kai+gar",
                "kainggar.aiPlusGar",
                detail: "expected 'kai+gar' but got '\(kainggarResult?.input ?? "nil")'"
            )
        },
    ])
}
