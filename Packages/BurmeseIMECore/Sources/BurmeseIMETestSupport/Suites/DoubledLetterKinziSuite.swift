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
    ])
}
