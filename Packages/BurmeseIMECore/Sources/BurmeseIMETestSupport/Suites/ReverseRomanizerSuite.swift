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
    ])
}
