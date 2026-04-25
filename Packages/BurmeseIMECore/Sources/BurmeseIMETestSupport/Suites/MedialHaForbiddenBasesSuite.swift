import BurmeseIMECore

/// Coverage for task 03: `Grammar.canTakeMedialHa` must reject every
/// stop / affricate that has no native ha-htoe-bearing form. Modern
/// Burmese orthography limits ha-htoe (ှ U+103E) to nasals, liquids,
/// and semivowels — `ပှ`, `ဘှ`, `ဂှ`, `ဒှ`, `ဇှ`, `ကှ`, `တှ` and
/// friends are unattested.
public enum MedialHaForbiddenBasesSuite {

    /// Bases that must NOT carry medial ha-htoe under standard
    /// orthography. Each is declared with the romanization key the
    /// engine uses for it so the test reads cleanly.
    private static let forbidden: [(roman: String, base: Character)] = [
        ("k",   Myanmar.ka),
        ("kh",  Myanmar.kha),
        ("g",   Myanmar.ga),
        ("gh",  Myanmar.gha),
        ("s",   Myanmar.ca),     // စ (`sa` in romanization)
        ("hs",  Myanmar.cha),    // ဆ (`hsa`)
        ("z",   Myanmar.ja),     // ဇ (`za`)
        ("t",   Myanmar.ta),
        ("ht",  Myanmar.tha),    // ထ (`hta`)
        ("d",   Myanmar.da),
        ("dh",  Myanmar.dha),
        ("p",   Myanmar.pa),
        ("ph",  Myanmar.pha),
        ("v",   Myanmar.ba),     // ဗ (`va`)
        ("b",   Myanmar.bha),    // ဘ (`bha`)
        ("th",  Myanmar.sa),     // သ (`tha` → sa)
    ]

    /// Bases that must continue to carry medial ha-htoe — the
    /// canonical native ha-htoe forms. Asserted explicitly so a
    /// future over-trim of `canTakeMedialHa` shows up as a failure.
    private static let allowed: [(roman: String, base: Character)] = [
        ("m",   Myanmar.ma),
        ("n",   Myanmar.na),
        ("ng",  Myanmar.nga),
        ("ny",  Myanmar.nnya),
        ("ny2", Myanmar.nya),
        ("l",   Myanmar.la),
        ("y",   Myanmar.ya),
        ("w",   Myanmar.wa),
    ]

    public static let suite = TestSuite(name: "MedialHaForbiddenBases", cases: [

        // Grammar table: forbidden bases must report `false` for
        // ha-htoe medial.
        TestCase("canTakeMedialHa_rejectsNonNativeBases") { ctx in
            for entry in forbidden {
                ctx.assertFalse(
                    Grammar.canConsonantTakeMedial(entry.base, Myanmar.medialHa),
                    "\(entry.roman)+ha (canConsonantTakeMedial)",
                    detail: "base=\(String(entry.base)) accepted ha-htoe but no native form exists"
                )
            }
        },

        // Engine path: typing `h<base>a` must not emit a top
        // candidate with the malformed base + ha-htoe surface for
        // any of the forbidden bases.
        TestCase("engine_doesNotEmitForbiddenHaHtoeAsTop") { ctx in
            let medialHa: UInt32 = 0x103E
            for entry in forbidden {
                // Build buffer like `h<roman>a` — the engine maps
                // `h<C>` to `<C>` + ha-htoe medial when allowed.
                let buffer = "h" + entry.roman + "a"
                let state = BurmeseEngine().update(buffer: buffer, context: [])
                guard let top = state.candidates.first?.surface else { continue }
                let scalars = Array(top.unicodeScalars)
                let hasBaseFollowedByHaHtoe: Bool = {
                    for i in 0..<scalars.count - 1 where Character(scalars[i]) == entry.base {
                        if scalars[i + 1].value == medialHa { return true }
                    }
                    return false
                }()
                ctx.assertFalse(
                    hasBaseFollowedByHaHtoe,
                    buffer,
                    detail: "top='\(top)' has \(String(entry.base)) + ha-htoe (forbidden)"
                )
            }
        },

        // Native ha-htoe forms must continue to parse.
        TestCase("canTakeMedialHa_acceptsNativeBases") { ctx in
            for entry in allowed {
                ctx.assertTrue(
                    Grammar.canConsonantTakeMedial(entry.base, Myanmar.medialHa),
                    "\(entry.roman)+ha (canConsonantTakeMedial)",
                    detail: "base=\(String(entry.base)) was rejected for ha-htoe"
                )
            }
        },
    ])
}
