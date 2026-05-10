import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-049: an asat (`U+103A`) that lands directly after
/// a medial scalar (`U+103B` ya-pin, `U+103C` ya-yit, `U+103D` wa-hswe,
/// `U+103E` ha-htoe) with no intervening coda consonant is
/// orthographically invalid Burmese. A medial is part of the onset
/// cluster — it modifies the onset's articulation. The syllable still
/// needs either an inherent vowel or a closing coda consonant + asat.
/// The pre-fix engine emitted `<C><medial> 103A` (e.g. `kya*` → `ကျ်`,
/// `kw*` → `ကွ်`) at rank 0 because the parser's legality scan walked
/// back through medials as "skippable" marks before reaching the
/// consonant base.
///
/// Burmese rule reference (CLAUDE.md §1):
///   `<C><medial(s)><V><coda?>` — medials live in the onset slot,
///   never the coda slot. Asat closes a coda consonant, not a medial.
///   The legitimate medial-bearing closed-syllable shape places a
///   coda consonant between the medial and the asat:
///   `<C><medial(s)><coda-consonant><103A>` (e.g. `ကျန်` =
///   `1000 103B 1014 103A`).
///
/// The bug class spans every medial family and every base consonant.
public enum MedialPlusAsatRejectionSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// True when `surface` contains a `<medial> 103A` two-scalar
    /// adjacency where the medial is in U+103B..U+103E.
    private static func surfaceHasMedialPlusAsat(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 2 else { return false }
        for i in 1..<scalars.count {
            let prev = scalars[i - 1]
            if prev >= 0x103B && prev <= 0x103E && scalars[i] == 0x103A {
                return true
            }
        }
        return false
    }

    /// Reproduction inputs from the task table: every medial family
    /// over a representative consonant onset, plus triple-medial
    /// onsets.
    private static let bugInputs: [String] = [
        // ya-pin (103B)
        "kya*", "khya*", "gya*", "sya*", "tya*", "nya*", "pya*", "phya*",
        "bya*", "lya*", "hya*",
        // ya-yit (103C)
        "kra*", "khra*", "gra*", "tra*", "pra*", "bra*", "mra*",
        // wa-hswe (103D)
        "kw*", "khw*", "gw*", "sw*", "tw*", "nw*", "pw*", "bw*",
        "mw*", "yw*", "lw*", "hw*",
        // ha-htoe (103E) — `h` prefix
        "hma*", "hna*", "hnga*", "hla*", "hwa*",
        // double medials
        "kyw*", "khyw*", "myw*", "lyw*",
        // triple medials (ha-htoe + onset + ya-pin/ya-yit + wa-hswe)
        "hkyw*", "hkrw*",
    ]

    /// Inputs whose clean medial-bearing surface (with vowel or with
    /// a coda) must remain reachable as a positive control.
    private static let regressionGuards: [(buffer: String, expectedHex: String)] = [
        ("kya",   "1000 103B"),                            // ကျ — medial + inherent (no explicit aa scalar)
        ("kyan*", "1000 103B 1014 103A"),                  // ကျန် — medial + coda + asat
        ("kyar*", "1000 103B 101B 103A"),                  // ကျရ် — medial + coda + asat (ra)
        ("kyaw*", "1000 103B 1031 102C 103A"),             // ကျော် — medial + aw cluster
        ("kyaung*", "1000 103B 1031 102C 1004 103A"),      // ကျောင် — medial + aung
        ("kywan", "1000 103B 103D 1014 103A"),             // ကျွန် — double medial + coda
        ("hman",  "1019 103E 1014 103A"),                  // မှန် — ha-htoe + coda
    ]

    public static let suite = TestSuite(name: "MedialPlusAsatRejection", cases: [

        // Acceptance Criterion 1: NO candidate may carry the
        // `<medial> 103A` adjacency for a `<C><medial>*` buffer.
        TestCase("noCandidateSurface_carriesMedialPlusAsat") { ctx in
            let engine = emptyEngine()
            for buffer in bugInputs {
                let state = engine.update(buffer: buffer, context: [])
                for c in state.candidates {
                    ctx.assertFalse(
                        surfaceHasMedialPlusAsat(c.surface),
                        buffer,
                        detail: "candidate '\(c.surface)' [\(hex(c.surface))] contains <medial> 103A"
                    )
                }
            }
        },

        // Direct legality-scan predicate test: scalar sequences with
        // `<medial> 103A` adjacency (no intervening coda consonant)
        // must be rejected. Covers every medial family and the
        // multi-medial cases.
        TestCase("scanOutputLegality_rejectsMedialPlusAsat") { ctx in
            let cases: [(label: String, scalars: [UInt32])] = [
                ("kya*",  [0x1000, 0x103B, 0x103A]),
                ("khya*", [0x1001, 0x103B, 0x103A]),
                ("gya*",  [0x1002, 0x103B, 0x103A]),
                ("mya*",  [0x1019, 0x103C, 0x103A]),
                ("pya*",  [0x1015, 0x103C, 0x103A]),
                ("bya*",  [0x1018, 0x103C, 0x103A]),
                ("kw*",   [0x1000, 0x103D, 0x103A]),
                ("pw*",   [0x1015, 0x103D, 0x103A]),
                ("hma*",  [0x1019, 0x103E, 0x103A]),
                ("hna*",  [0x1014, 0x103E, 0x103A]),
                ("kyw*",  [0x1000, 0x103B, 0x103D, 0x103A]),
                ("hkyw*", [0x101F, 0x1000, 0x103C, 0x103D, 0x103A]),
            ]
            for c in cases {
                let s = String(c.scalars.compactMap(Unicode.Scalar.init).map(Character.init))
                let legal = SyllableParser.scanOutputLegality(s)
                ctx.assertFalse(
                    legal,
                    c.label,
                    detail: "scanOutputLegality returned true for malformed scalars '\(hex(s))'"
                )
            }
        },

        // Counter-examples — legitimate medial-bearing surfaces with
        // a coda consonant before the asat must REMAIN legal.
        TestCase("scanOutputLegality_acceptsLegalMedialCodaShapes") { ctx in
            let cases: [(label: String, scalars: [UInt32])] = [
                // <C> medial 1014 103A — kyan*
                ("kyan*", [0x1000, 0x103B, 0x1014, 0x103A]),
                // <C> medial 101B 103A — kyar*
                ("kyar*", [0x1000, 0x103B, 0x101B, 0x103A]),
                // <C> medial medial 1014 103A — kywan
                ("kywan", [0x1000, 0x103B, 0x103D, 0x1014, 0x103A]),
                // <C> medial 1031 102C 103A — kyaw* (aw cluster after medial)
                ("kyaw*", [0x1000, 0x103B, 0x1031, 0x102C, 0x103A]),
                // <C> medial 1031 102C 1004 103A — kyaung*
                ("kyaung*", [0x1000, 0x103B, 0x1031, 0x102C, 0x1004, 0x103A]),
                // <C> ha-htoe 1014 103A — hman
                ("hman", [0x1019, 0x103E, 0x1014, 0x103A]),
            ]
            for c in cases {
                let s = String(c.scalars.compactMap(Unicode.Scalar.init).map(Character.init))
                let legal = SyllableParser.scanOutputLegality(s)
                ctx.assertTrue(
                    legal,
                    c.label,
                    detail: "scanOutputLegality wrongly rejected legal scalars '\(hex(s))'"
                )
            }
        },

        // Engine-end regression: legitimate medial-bearing surfaces
        // (with vowel or coda) must continue to surface in the panel.
        TestCase("legitimateMedialSurfaces_remainReachable") { ctx in
            let engine = emptyEngine()
            for entry in regressionGuards {
                let state = engine.update(buffer: entry.buffer, context: [])
                let panelHexes = state.candidates.map { hex($0.surface) }
                ctx.assertTrue(
                    panelHexes.contains(entry.expectedHex),
                    entry.buffer,
                    detail: "expected '\(entry.expectedHex)' in panel; first 5: \(panelHexes.prefix(5))"
                )
            }
        },
    ])
}
