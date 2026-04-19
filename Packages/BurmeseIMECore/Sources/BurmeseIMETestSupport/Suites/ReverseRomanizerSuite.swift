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

        TestCase("reverse_minGalarPar2") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("မင်္ဂလာပါ"), "min+galarpar2")
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

        TestCase("roundTrip_minGalarPar2") { ctx in
            let parser = SyllableParser()
            let forward = parser.parse("min+galarpar2").first?.output ?? ""
            let reversed = ReverseRomanizer.romanize(forward)
            let roundTrip = parser.parse(reversed).first?.output ?? ""
            ctx.assertEqual(forward, roundTrip)
        },

        TestCase("reverse_gha") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("ဃ"), "gha")
        },

        TestCase("reverse_shortIndependentI") { ctx in
            ctx.assertEqual(ReverseRomanizer.romanize("ဣ"), "ii.")
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
            let reversed = ReverseRomanizer.romanize(forward)
            ctx.assertEqual(reversed, "ii.")
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
