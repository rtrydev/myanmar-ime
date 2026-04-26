import Foundation
@_spi(Testing) import BurmeseIMECore

/// Regression suite for TASK-007: standalone particle / independent-
/// vowel rules (`ei` → `၏`, `ywe` → `၍`, `oo` → `ဩ`, `ii` → `ဤ`,
/// `u2` → `ဦ`, etc.) match aggressively mid-buffer between two
/// consonants where the resulting surface is structurally invalid
/// Burmese.
///
/// The bug class is the surface-level pattern `<consonant base>
/// <independent-vowel-or-particle scalar>` mid-string. When at least
/// one sibling in the panel has no such pollution, the polluted
/// candidate is dropped post-rank. Standalone usage (`ei` / `ywe` /
/// `oo` / `ii` / `u2` typed alone) keeps the particle reading at any
/// rank as a last-resort fallback — mirroring the
/// `sanitizeOrphanZwnj` pattern.
///
/// Class A inputs have at least one orthographically clean sibling
/// reachable through the existing parser; the post-rank filter
/// suffices. Class B inputs have NO clean sibling because the
/// parser's only available decomposition for the bare-vowel mid-
/// buffer position is the standalone rule itself — these are
/// documented as a structural limitation pending new dependent-
/// vowel `oo`/`ii` rules and intentionally have weaker assertions.
public enum StandaloneParticleMidBufferSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func topSurface(_ engine: BurmeseEngine, _ input: String) -> String {
        engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
    }

    /// Polluting scalars: independent vowels (U+1023..U+102A) and
    /// free-standing particles (U+104D `ywe`, U+104F `ei`).
    private static let pollutingScalars: Set<UInt32> = [
        0x1023, 0x1024, 0x1025, 0x1026, 0x1027, 0x1029, 0x102A,
        0x104D, 0x104F,
    ]

    /// True when `surface` contains a polluting scalar at a position
    /// preceded by another Myanmar consonant base (U+1000..U+1021)
    /// earlier in the surface. This is the structural shape the fix
    /// must suppress.
    private static func hasMidSurfacePollution(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        for i in 0..<scalars.count where pollutingScalars.contains(scalars[i]) {
            for j in 0..<i {
                let v = scalars[j]
                if v >= 0x1000 && v <= 0x1021 { return true }
            }
        }
        return false
    }

    /// Class A inputs: rank-0 surface must not contain a mid-buffer
    /// standalone-particle / independent-vowel scalar (U+1023..U+102A,
    /// U+104D, U+104F) preceded by a Myanmar consonant base. The
    /// parser-level skip on the standalone-vowel transition forces a
    /// competing onset+vowel parse to win.
    ///
    /// Class B inputs from the original task table (`loo`, `loohit`,
    /// `looktar`, `kooyay`, `tarii`, `thiimar`) are folded into this
    /// list — the parser-level skip turned out to apply to them too,
    /// because every alternative decomposition the parser had
    /// available avoided the standalone scalar (often via the
    /// non-standalone `i.` / `i2` / multi-syllable `o` rules).
    private static let classAInputs: [String] = [
        "monein", "shisein", "kein", "leik", "phei",
        "thwarei", "minywe", "kywetawn",
        "loo", "loohit", "looktar", "kooyay", "tarii", "thiimar",
    ]

    /// Standalone usage that must continue to surface the particle /
    /// independent-vowel reading (at any rank — but it must be
    /// present in the panel).
    private static let standaloneCases: [(buffer: String, expectedScalar: UInt32)] = [
        ("ei",  0x104F),  // ၏
        ("ywe", 0x104D),  // ၍
        ("oo",  0x1029),  // ဩ
        ("ii",  0x1024),  // ဤ
        ("u2",  0x1026),  // ဦ
    ]

    public static let suite = TestSuite(name: "StandaloneParticleMidBuffer", cases: [

        // Class A: clean sibling reachable; rank 0 must not be polluted.
        TestCase("classA_topCandidateClean") { ctx in
            let engine = emptyEngine()
            for buffer in classAInputs {
                let top = topSurface(engine, buffer)
                ctx.assertFalse(
                    hasMidSurfacePollution(top),
                    buffer,
                    detail: "top='\(top)' [\(hex(top))] contains mid-surface polluting scalar (independent-vowel or free-standing particle preceded by a consonant base)"
                )
            }
        },

        // Bare standalone particle / independent-vowel usage must
        // keep the particle reading reachable in the panel. Last-
        // resort fallback: when the parser can produce ONLY the
        // standalone form, it is allowed at any rank. When clean
        // siblings exist, the standalone is allowed but does not
        // need to be rank 0.
        TestCase("standalone_remainsReachable") { ctx in
            let engine = emptyEngine()
            for entry in standaloneCases {
                let cs = engine.update(buffer: entry.buffer, context: [])
                let foundInPanel = cs.candidates.contains { cand in
                    cand.surface.unicodeScalars.contains {
                        $0.value == entry.expectedScalar
                    }
                }
                ctx.assertTrue(
                    foundInPanel,
                    entry.buffer,
                    detail: "expected scalar U+\(String(format: "%04X", entry.expectedScalar)) reachable in panel; got \(cs.candidates.prefix(4).map(\.surface))"
                )
            }
        },
    ])
}
