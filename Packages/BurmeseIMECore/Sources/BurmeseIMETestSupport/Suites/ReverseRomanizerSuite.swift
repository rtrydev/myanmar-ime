import BurmeseIMECore

public enum ReverseRomanizerSuite {
    public static let suite = TestSuite(name: "ReverseRomanizer", cases: [

        TestCase("reverse_ky") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("ကြ"), "kya")
        },

        TestCase("reverse_ky2") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("ကျ"), "ky2a")
        },

        TestCase("reverse_kw") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("ကွ"), "kwa")
        },

        TestCase("reverse_hk") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("ကှ"), "hka")
        },

        TestCase("reverse_hkwy2") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("ကျွှ"), "hkwy2a")
        },

        TestCase("reverse_par") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("ပာ"), "par")
        },

        TestCase("reverse_thar") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("သာ"), "thar")
        },

        TestCase("reverse_kyaw") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("ကြော်"), "kyaw")
        },

        TestCase("reverse_ay2") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("ဧ"), "ay2")
        },

        TestCase("reverse_u2Colon") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("ဦး"), "u2:")
        },

        TestCase("reverse_minGalarPar") { ctx in
            // ပါ uses tall-aa U+102B, but `correctAaShape` resolves shape from
            // the base consonant — the reverse form drops the `2` so the
            // reading matches what users actually type.
            ctx.assertEqual(ReverseRomanizer.romanize("မင်္ဂလာပါ"), "min+galarpar")
        },

        TestCase("reverse_tallAa_stripsDigit") { ctx in
            // All ar-shape aa variants collapse to the digit-less form.
            ctx.assertEqual(ReverseRomanizer.romanize("\u{1015}\u{102B}"), "par")
            ctx.assertEqual(ReverseRomanizer.romanize("\u{1015}\u{102B}\u{1038}"), "par:")
            ctx.assertEqual(ReverseRomanizer.romanize("\u{1000}\u{1031}\u{102B}\u{103A}"), "kaw")
            ctx.assertEqual(ReverseRomanizer.romanize("\u{1000}\u{1031}\u{102B}\u{1000}\u{103A}"), "kout")
            ctx.assertEqual(ReverseRomanizer.romanize("\u{1000}\u{1031}\u{102B}\u{1004}\u{103A}"), "kaung")
        },

        TestCase("roundTrip_thar") { ctx in
            let parser = SyllableParser()
            let forward = parser.parse("thar").first?.output ?? ""
            let reversed = ReverseRomanizer.romanize(forward)
            let roundTrip = parser.parse(reversed).first?.output ?? ""
            ctx.assertEqual(forward, roundTrip)
        },

        TestCase("roundTrip_kyaw") { ctx in
            let parser = SyllableParser()
            let forward = parser.parse("kyaw").first?.output ?? ""
            let reversed = ReverseRomanizer.romanize(forward)
            let roundTrip = parser.parse(reversed).first?.output ?? ""
            ctx.assertEqual(forward, roundTrip)
        },

        TestCase("roundTrip_minGalarPar") { ctx in
            // Feed the tall-aa canonical reading through the parser, reverse
            // its surface, and re-parse: the digit-stripped reverse form
            // must parse to the same short-aa surface that `"min+galarpar"`
            // produces directly.
            let parser = SyllableParser()
            let forward = parser.parse("min+galarpar2").first?.output ?? ""
            let reversed = ReverseRomanizer.romanize(forward)
            let roundTrip = parser.parse(reversed).first?.output ?? ""
            let shortAaForward = parser.parse("min+galarpar").first?.output ?? ""
            ctx.assertEqual(shortAaForward, roundTrip)
        },

        TestCase("roundTrip_lexiconSurfaces") { ctx in
            // For each surface below (drawn from real lexicon-like words),
            // reverse-romanize then forward-parse; the shape of `ar/ar2`
            // (U+102B/U+102C) is allowed to differ because `correctAaShape`
            // re-selects the right variant at engine-emission time.
            let parser = SyllableParser()
            let surfaces = [
                "\u{1021}",                                      // အ
                "\u{1021}\u{1019}",                              // အမ
                "\u{1021}\u{1019}\u{1031}",                      // အမေ
                "\u{1021}\u{1019}\u{1031}\u{101B}\u{102D}\u{1000}\u{1014}\u{103A}",  // အမေရိကန်
                "\u{1015}\u{1009}\u{1039}\u{1005}",              // ပဉ္စ
                "\u{1000}\u{103B}\u{103D}\u{1014}\u{103A}\u{1010}\u{1031}\u{102C}\u{103A}", // ကျွန်တော်
                "\u{1000}\u{103C}\u{1031}\u{102C}\u{1004}\u{103A}\u{1038}", // ကြောင်း
                "\u{1014}\u{103E}\u{1004}\u{1037}\u{103A}",      // နှင့်
            ]
            for surface in surfaces {
                let reversed = ReverseRomanizer.romanize(surface)
                let parsed = parser.parse(reversed).first?.output ?? ""
                let normalized = normalizeAaShapeForTest(parsed)
                let expected = normalizeAaShapeForTest(surface)
                ctx.assertEqual(normalized, expected,
                    "roundTrip reversed=\(reversed)")
            }
        },

        TestCase("reverse_kinzi_tinKyi") { ctx in
            // တင်္ကြီး = U+1010 U+1004 U+103A U+1039 U+1000 U+103C U+102E U+1038
            let surface = "\u{1010}\u{1004}\u{103A}\u{1039}\u{1000}\u{103C}\u{102E}\u{1038}"
            ctx.assertEqual(ReverseRomanizer.romanize(surface), "tin+kyi:")
        },

        TestCase("roundTrip_kinzi_tinKyi") { ctx in
            let parser = SyllableParser()
            let surface = "\u{1010}\u{1004}\u{103A}\u{1039}\u{1000}\u{103C}\u{102E}\u{1038}"
            let reversed = ReverseRomanizer.romanize(surface)
            let roundTrip = parser.parse(reversed).first?.output ?? ""
            ctx.assertEqual(roundTrip, surface)
        },

        TestCase("roundTrip_kinzi_mingalar") { ctx in
            // မင်္ဂလာ with no override surface form — asserts the direct
            // surface→reverse→parse loop round-trips.
            let parser = SyllableParser()
            let surface = "\u{1019}\u{1004}\u{103A}\u{1039}\u{1002}\u{101C}\u{102C}"
            let reversed = ReverseRomanizer.romanize(surface)
            let roundTrip = parser.parse(reversed).first?.output ?? ""
            ctx.assertEqual(roundTrip, surface)
        },

        TestCase("reverse_kinzi_preserves_plainVirama") { ctx in
            // Plain virama stack (consonant + 1039 + consonant) with no kinzi
            // should still be handled. ကမ္ဘာ = U+1000 U+1019 U+1039 U+1018 U+102C.
            let surface = "\u{1000}\u{1019}\u{1039}\u{1018}\u{102C}"
            ctx.assertEqual(ReverseRomanizer.romanize(surface), "kam+bar")
        },

        TestCase("reverse_gha") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("ဃ"), "gha")
        },

        TestCase("reverse_shortIndependentI") { ctx in
            // tasks/ 04: canonical forward reading for ဣ is `i.` (short
            // independent i), not the `ii.` that raw standalone-vowel
            // rules previously emitted.
            ctx.assertEqual(ReverseRomanizer.romanize("ဣ"), "i.")
        },

        TestCase("reverse_shortIndependentU") { ctx in
            // tasks/ 04: ဥ reverses to `u` (short u) so the lexicon
            // alias agrees with what a typist produces for bare `u`.
            ctx.assertEqual(ReverseRomanizer.romanize("ဥ"), "u")
        },

        TestCase("reverse_onsetlessA_an") { ctx in
            // tasks/ 04: `အံ` family → `an` family, matching the forward
            // rules added in commit 083c428.
            ctx.assertEqual(ReverseRomanizer.romanize("\u{1021}\u{1036}"), "an")
            ctx.assertEqual(ReverseRomanizer.romanize("\u{1021}\u{1036}\u{1037}"), "an.")
            ctx.assertEqual(ReverseRomanizer.romanize("\u{1021}\u{1036}\u{1038}"), "an:")
        },

        TestCase("reverse_onsetlessA_ar") { ctx in
            // tasks/ 04: `အာ` / `အား` reverse to `ar` / `ar:`, matching
            // the forward-default vowel rule rather than the `ahar`
            // compound the consonant path emits.
            ctx.assertEqual(ReverseRomanizer.romanize("\u{1021}\u{102C}"), "ar")
            ctx.assertEqual(ReverseRomanizer.romanize("\u{1021}\u{102C}\u{1038}"), "ar:")
        },

        TestCase("reverse_longIndependentI") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("ဤ"), "ii")
        },

        TestCase("reverse_independentO") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("ဩ"), "oo")
        },

        TestCase("reverse_independentOTonal") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("ဪ"), "oo:")
        },

        TestCase("reverse_locativeSymbol") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("၍"), "ywe")
        },

        TestCase("reverse_genitiveSymbol") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("၏"), "ei")
        },

        TestCase("reverse_greatSa") { ctx in
            // ဿ behaves as a consonant with its inherent vowel.
            ctx.assertEqual(ReverseRomanizer.romanize("ဿ"), "ssa")
        },

        TestCase("reverse_greatSaInWord") { ctx in
            // ပြဿနာ is a common Pali loanword ("problem") that embeds ဿ.
            let reversed = ReverseRomanizer.romanize("ပြဿနာ")
            ctx.assertTrue(reversed.contains("ss"),
                "containsSs", detail: "expected 'ss' in \(reversed)")
        },

        TestCase("roundTrip_shortIndependentI") { ctx in
            let parser = SyllableParser()
            let forward = parser.parse("ii.").first?.output ?? ""
            ctx.assertEqual(forward, "\u{1023}")
            // Reverse returns the canonical short-i reading `i.` rather
            // than the forward `ii.` rule — both forward-parse back to
            // `ဣ` via the engine's override (see tasks/ 04).
            let reversed = ReverseRomanizer.romanize(forward)
            ctx.assertEqual(reversed, "i.")
        },

        TestCase("roundTrip_longIndependentI") { ctx in
            let parser = SyllableParser()
            let forward = parser.parse("ii").first?.output ?? ""
            ctx.assertEqual(forward, "\u{1024}")
        },

        TestCase("roundTrip_locativeSymbol") { ctx in
            let parser = SyllableParser()
            let forward = parser.parse("ywe").first?.output ?? ""
            ctx.assertEqual(forward, "\u{104D}")
            let reversed = ReverseRomanizer.romanize(forward)
            ctx.assertEqual(reversed, "ywe")
        },

        TestCase("roundTrip_genitiveSymbol") { ctx in
            let parser = SyllableParser()
            let forward = parser.parse("ei").first?.output ?? ""
            ctx.assertEqual(forward, "\u{104F}")
        },

        TestCase("reverse_nnyaAsOnset") { ctx in
            // ညစာ (U+100A U+1005 U+102C) should round-trip through "ny".
            ctx.assertEqual(ReverseRomanizer.romanize("\u{100A}\u{1005}\u{102C}"), "nyasar")
        },

        TestCase("reverse_nyaAsOnset") { ctx in
            // ဉ (U+1009) keeps the digit-disambiguated "ny2" key.
            ctx.assertEqual(ReverseRomanizer.romanize("\u{1009}"), "ny2a")
        },

        TestCase("roundTrip_nnyaOnset") { ctx in
            let parser = SyllableParser()
            let forward = parser.parse("nyi").first?.output ?? ""
            ctx.assertEqual(forward, "\u{100A}\u{102E}")
            let reversed = ReverseRomanizer.romanize(forward)
            let roundTrip = parser.parse(reversed).first?.output ?? ""
            ctx.assertEqual(forward, roundTrip)
        },

        TestCase("roundTrip_nyaOnset") { ctx in
            // "ny2" is the canonical reverse-romanization for the rare ဉ
            // (U+1009). Digits are stripped from composing input, so typing
            // "ny" surfaces both ည (canonical) and ဉ (alias of ny2). The
            // round-trip assertion is that ReverseRomanizer still names the
            // rare letter correctly and that it shows up as a candidate.
            let parser = SyllableParser()
            ctx.assertEqual(ReverseRomanizer.romanize("\u{1009}\u{102C}"), "ny2ar")
            let candidates = parser.parseCandidates("nyar", maxResults: 8).map(\.output)
            ctx.assertTrue(candidates.contains("\u{100A}\u{102C}"),
                detail: "expected ညာ in candidates: \(candidates)")
            ctx.assertTrue(candidates.contains("\u{1009}\u{102C}"),
                detail: "expected ဉာ in candidates (via ny2 alias): \(candidates)")
        },
    ])
}

// Collapse both aa scalars to the short form so the round-trip check
// ignores the engine's downstream tall/short selection.
private func normalizeAaShapeForTest(_ s: String) -> String {
    var out = ""
    for scalar in s.unicodeScalars {
        if scalar.value == 0x102B {
            out.unicodeScalars.append(Unicode.Scalar(0x102C)!)
        } else {
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}
