import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-069: bare `a*` (and the propagating `aa*`, `aaa*`,
/// `+a*`, `<C>+a*`, `a*<X>` shapes) must not produce a rank-0 Myanmar
/// surface carrying the orphan `1021 103A` (independent vowel `အ` +
/// asat) adjacency. The independent vowel `အ` is a placeholder
/// consonant whose only purpose is to host dependent-vowel marks;
/// suppressing its "inherent vowel" via asat leaves no pronounceable
/// syllable, so `1021 103A` standalone is structurally meaningless.
///
/// TASK-052 (digit + 1021 103A) and TASK-057 (tone + 1021 103A)
/// already filter their specific shapes. This suite locks the bare
/// case — `1021 103A` with neither a preceding digit nor a preceding
/// tone marker.
///
/// Burmese rule reference: asat (U+103A) suppresses the inherent
/// vowel of a true consonant (U+1000..U+1020) or Great Sa (U+103F).
/// The independent vowel `အ` (U+1021) is not a true consonant — it
/// occupies the boundary slot in the Unicode block precisely because
/// it is the vowel-only base. Its inherent vowel is intrinsic to its
/// identity; "stripping" it produces an undefined shape.
///
/// Sibling shapes `e*`/`i*`/`o*`/`u*` route to legal forms with
/// real coda consonants (ya-asat / nya-asat) or particle variants;
/// they are pinned as regression baseline.
public enum BareIndepVowelAsatSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// True when `surface` contains the bare `1021 103A` adjacency
    /// where the `1021` is NOT preceded by a digit (TASK-052 case)
    /// and NOT preceded by a tone marker (TASK-057 case). This is
    /// the gap-class predicate.
    private static func surfaceHasBareIndepVowelAsat(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 2 else { return false }
        @inline(__always) func isDigit(_ v: UInt32) -> Bool {
            (v >= 0x30 && v <= 0x39) || (v >= 0x1040 && v <= 0x1049)
        }
        for i in 1..<scalars.count {
            guard scalars[i - 1] == 0x1021 && scalars[i] == 0x103A else {
                continue
            }
            // Skip the TASK-052 / TASK-057 cases — they have their
            // own sanitizers.
            if i >= 2 {
                let pre = scalars[i - 2]
                if isDigit(pre) { continue }
                if pre == 0x1037 || pre == 0x1038 { continue }
            }
            return true
        }
        return false
    }

    public static let suite = TestSuite(name: "BareIndepVowelAsat", cases: [

        // Headline acceptance: no rank-0 surface for any `a*` shape
        // (or its repeats / `+`-prefixed / suffixed forms) may carry
        // the `1021 103A` adjacency.
        TestCase("bareIndepVowelAsat_noRank0Adjacency") { ctx in
            let engine = emptyEngine()
            for buffer in [
                "a*", "aa*", "aaa*", "+a*",
                "a*ka", "a*+ka", "a*ya", "a*ar",
                "a*aing", "a*aung", "a*aw",
                "ka+a*", "ya+a*",
            ] {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first else {
                    ctx.assertTrue(false, buffer, detail: "panel empty")
                    continue
                }
                ctx.assertFalse(
                    surfaceHasBareIndepVowelAsat(top.surface),
                    buffer,
                    detail: "rank-0='\(top.surface)' [\(hex(top.surface))] carries bare 1021 103A"
                )
            }
        },

        // Stronger: no rank in the panel may carry the bare
        // `1021 103A` adjacency. The literal raw buffer escape hatch
        // is exempt (it's pure ASCII so the predicate doesn't fire
        // on it). The fix should clean the entire candidate pool,
        // not just rank 0.
        TestCase("bareIndepVowelAsat_noPanelAdjacency") { ctx in
            let engine = emptyEngine()
            for buffer in [
                "a*", "aa*", "aaa*", "+a*",
                "a*ka", "a*+ka", "a*ya",
                "ka+a*", "ya+a*",
            ] {
                let state = engine.update(buffer: buffer, context: [])
                for (i, c) in state.candidates.enumerated() {
                    ctx.assertFalse(
                        surfaceHasBareIndepVowelAsat(c.surface),
                        buffer,
                        detail: "rank-\(i) '\(c.surface)' [\(hex(c.surface))] carries bare 1021 103A"
                    )
                }
            }
        },

        // The literal raw buffer must remain reachable in the panel
        // (CLAUDE.md §2 escape hatch). Even when every Myanmar
        // candidate is filtered, the user must still be able to
        // commit the typed input verbatim.
        TestCase("bareIndepVowelAsat_literalReachable") { ctx in
            let engine = emptyEngine()
            for buffer in [
                "a*", "aa*", "aaa*",
                "a*ka", "a*ya",
            ] {
                let state = engine.update(buffer: buffer, context: [])
                let surfaces = state.candidates.map(\.surface)
                ctx.assertTrue(
                    surfaces.contains(buffer),
                    buffer,
                    detail: "literal '\(buffer)' missing from panel; surfaces=\(surfaces)"
                )
            }
        },

        // Sibling shapes must continue to produce their existing
        // rank-0 forms. These are the regression baseline.
        TestCase("siblingVowelAsat_unchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expectedScalars: [UInt32])] = [
                ("e*", [0x1021, 0x101A, 0x103A]),
                ("i*", [0x1021, 0x100A, 0x103A]),
                ("o*", [0x1021, 0x102D, 0x102F, 0x101A, 0x103A]),
                ("u*", [0x1026]),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let actual = Array(surface.unicodeScalars.map(\.value))
                ctx.assertTrue(
                    actual == c.expectedScalars,
                    c.buffer,
                    detail: "expected=\(c.expectedScalars.map { String(format: "%04X", $0) }) got '\(hex(surface))'"
                )
            }
        },

        // The predicate above must NOT fire on TASK-052 / TASK-057
        // shapes (those have their own sanitizers). This is a guard
        // for the predicate itself.
        TestCase("predicate_skipsTask052And057") { ctx in
            // TASK-052: digit + 1021 103A — predicate must NOT flag.
            let task052 = "\u{0030}\u{1021}\u{103A}"
            ctx.assertFalse(
                surfaceHasBareIndepVowelAsat(task052),
                "task052",
                detail: "predicate falsely flagged digit + 1021 103A"
            )
            // TASK-057: tone + 1021 103A — predicate must NOT flag.
            let task057 = "\u{1037}\u{1021}\u{103A}"
            ctx.assertFalse(
                surfaceHasBareIndepVowelAsat(task057),
                "task057",
                detail: "predicate falsely flagged tone + 1021 103A"
            )
            // Plain consonant + 103A — predicate must NOT flag.
            let plain = "\u{1000}\u{103A}"
            ctx.assertFalse(
                surfaceHasBareIndepVowelAsat(plain),
                "plain",
                detail: "predicate falsely flagged consonant + 103A"
            )
            // Bare 1021 103A — predicate MUST flag.
            let bareCase = "\u{1021}\u{103A}"
            ctx.assertTrue(
                surfaceHasBareIndepVowelAsat(bareCase),
                "bareCase",
                detail: "predicate failed to flag 1021 103A"
            )
        },
    ])
}
