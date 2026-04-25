import BurmeseIMECore

/// Coverage for task 03: `Grammar.canTakeMedialYa` must reject onsets
/// that have zero or near-zero lexicon support — `ha`, `nya`, `nnya`.
/// The lexicon shows `ဟျ` carries 1 entry (`ဟျောင်` 19×), `ဉျ` and
/// `ညျ` carry 0 entries; admitting them at full legality 100 lets
/// typo-close inputs like `hy2a` / `nyy2a` reach the panel as
/// plausibly-ranked top picks for orthography that is not part of the
/// language as written. The native-attested onsets (`la + ya-pin` =
/// `လျ`, `ya + ya-pin` = `ယျ`) stay legal.
public enum MedialYaForbiddenBasesSuite {

    /// Bases that must NOT carry medial ya-pin. Listed with the
    /// romanization key the engine uses for them so the test reads
    /// cleanly.
    private static let forbidden: [(roman: String, base: Character)] = [
        ("h",   Myanmar.ha),
        ("ny",  Myanmar.nnya),  // ny → ဉ (`nya` → `nnya` per romanization)
        ("ny2", Myanmar.nya),   // ny2 → ည (digit-disambiguated)
    ]

    /// Native-attested ya-pin onsets that must continue to parse at
    /// full legality. Ensures the trim doesn't accidentally remove
    /// the well-supported sonorant + ya-pin shapes.
    private static let allowed: [(roman: String, base: Character)] = [
        ("k",   Myanmar.ka),
        ("g",   Myanmar.ga),
        ("p",   Myanmar.pa),
        ("b",   Myanmar.ba),
        ("m",   Myanmar.ma),
        ("l",   Myanmar.la),
        ("y",   Myanmar.ya),
    ]

    public static let suite = TestSuite(name: "MedialYaForbiddenBases", cases: [

        // Grammar table: forbidden bases must report `false` for
        // ya-pin medial.
        TestCase("canTakeMedialYa_rejectsUnattestedBases") { ctx in
            for entry in forbidden {
                ctx.assertFalse(
                    Grammar.canConsonantTakeMedial(entry.base, Myanmar.medialYa),
                    "\(entry.roman)+ya2 (canConsonantTakeMedial)",
                    detail: "base=\(String(entry.base)) accepted ya-pin but lexicon support is < 2 entries"
                )
            }
        },

        // Native-attested ya-pin forms must continue to parse.
        TestCase("canTakeMedialYa_acceptsAttestedBases") { ctx in
            for entry in allowed {
                ctx.assertTrue(
                    Grammar.canConsonantTakeMedial(entry.base, Myanmar.medialYa),
                    "\(entry.roman)+ya2 (canConsonantTakeMedial)",
                    detail: "base=\(String(entry.base)) was rejected for ya-pin"
                )
            }
        },

        // Parser path: `hy2a` / `nyy2a` / `ny2y2a` must not emit a
        // legal parse with onset = ha/nnya/nya + ya-pin. A legal
        // sibling (e.g. two-syllable split) must take the top.
        TestCase("parser_doesNotEmitForbiddenYaPinAsTopLegal") { ctx in
            let parser = SyllableParser()
            let medialYa: UInt32 = 0x103B
            let cases: [(buffer: String, base: Character)] = [
                ("hy2a",    Myanmar.ha),
                ("nyy2a",   Myanmar.nnya),
                ("ny2y2a",  Myanmar.nya),
            ]
            for entry in cases {
                let parses = parser.parseCandidates(entry.buffer, maxResults: 4)
                for parse in parses where parse.legalityScore > 0 {
                    let scalars = Array(parse.output.unicodeScalars)
                    let hasBaseFollowedByMedialYa: Bool = {
                        for i in 0..<scalars.count - 1
                        where Character(scalars[i]) == entry.base {
                            if scalars[i + 1].value == medialYa { return true }
                        }
                        return false
                    }()
                    ctx.assertFalse(
                        hasBaseFollowedByMedialYa,
                        entry.buffer,
                        detail: "legal parse '\(parse.output)' has \(String(entry.base)) + ya-pin (forbidden, legality=\(parse.legalityScore))"
                    )
                }
            }
        },

        // Engine path: end-to-end, the top candidate for these
        // typo-close buffers must not be the unattested onset.
        TestCase("engine_doesNotEmitForbiddenYaPinAsTop") { ctx in
            let medialYa: UInt32 = 0x103B
            let cases: [(buffer: String, base: Character)] = [
                ("hy2a",    Myanmar.ha),
                ("nyy2a",   Myanmar.nnya),
                ("ny2y2a",  Myanmar.nya),
            ]
            for entry in cases {
                let state = BurmeseEngine().update(buffer: entry.buffer, context: [])
                guard let top = state.candidates.first?.surface else { continue }
                let scalars = Array(top.unicodeScalars)
                let hasBaseFollowedByMedialYa: Bool = {
                    for i in 0..<scalars.count - 1
                    where Character(scalars[i]) == entry.base {
                        if scalars[i + 1].value == medialYa { return true }
                    }
                    return false
                }()
                ctx.assertFalse(
                    hasBaseFollowedByMedialYa,
                    entry.buffer,
                    detail: "top='\(top)' has \(String(entry.base)) + ya-pin (forbidden)"
                )
            }
        },

        // Regression: well-attested ya-pin parses must keep full
        // legality. `ly2a` → လျ (801 entries) and `yy2a` → ယျ
        // (96 entries) are the controls.
        TestCase("parser_attestedYaPinRetainsFullLegality") { ctx in
            let parser = SyllableParser()
            let medialYa: UInt32 = 0x103B
            let cases: [(buffer: String, base: Character)] = [
                ("ly2a",  Myanmar.la),
                ("yy2a",  Myanmar.ya),
            ]
            for entry in cases {
                let parses = parser.parseCandidates(entry.buffer, maxResults: 4)
                let hasLegalOnset = parses.contains { parse in
                    guard parse.legalityScore > 0 else { return false }
                    let scalars = Array(parse.output.unicodeScalars)
                    for i in 0..<scalars.count - 1
                    where Character(scalars[i]) == entry.base {
                        if scalars[i + 1].value == medialYa { return true }
                    }
                    return false
                }
                ctx.assertTrue(
                    hasLegalOnset,
                    entry.buffer,
                    detail: "expected `\(String(entry.base)) + ya-pin` to retain a legal parse, parses=\(parses.map { ($0.output, $0.legalityScore) })"
                )
            }
        },
    ])
}
