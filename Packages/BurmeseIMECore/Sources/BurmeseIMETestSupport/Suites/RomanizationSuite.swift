import BurmeseIMECore

public enum RomanizationSuite {
    public static let suite = TestSuite(name: "Romanization", cases: [

        TestCase("consonantCount") { ctx in
            // 33 standard base consonants + ဿ (great sa, U+103F)
            // + a second key for ဉ (U+1009) disambiguated from ည (U+100A).
            ctx.assertEqual(Romanization.consonants.count, 35)
        },

        TestCase("consonantRomanKeysUnique") { ctx in
            let romans = Romanization.consonants.map(\.roman)
            ctx.assertEqual(romans.count, Set(romans).count,
                "Duplicate roman keys in consonant table")
        },

        TestCase("consonantLookup_k") { ctx in
            ctx.assertEqual(Romanization.romanToConsonant["k"], Myanmar.ka)
        },

        TestCase("consonantLookup_th") { ctx in
            ctx.assertEqual(Romanization.romanToConsonant["th"], Myanmar.sa)
        },

        TestCase("consonantReverse_ka") { ctx in
            ctx.assertEqual(Romanization.consonantToRoman[Myanmar.ka], "k")
        },

        TestCase("vowelKeysSortedByDescendingLength") { ctx in
            let keys = Romanization.vowelKeysByLength
            ctx.assertGreaterThan(keys.count, 0)
            var sorted = true
            for i in 1..<keys.count where keys[i-1].count < keys[i].count {
                sorted = false
                break
            }
            ctx.assertTrue(sorted, detail: "Keys not sorted by descending length")
        },

        TestCase("vowelLookup_ar") { ctx in
            let entry = Romanization.romanToVowel["ar"]
            ctx.assertTrue(entry != nil, detail: "ar not found")
            ctx.assertEqual(entry?.myanmar, "\u{102C}")
        },

        TestCase("vowelLookup_virama") { ctx in
            let entry = Romanization.romanToVowel["+"]
            ctx.assertTrue(entry != nil, detail: "+ not found")
            ctx.assertEqual(entry?.myanmar, "\u{1039}")
        },

        TestCase("normalize_lowercase") { ctx in
            ctx.assertEqual(Romanization.normalize("ABC"), "abc")
        },

        TestCase("normalize_stripsDigits") { ctx in
            ctx.assertEqual(Romanization.normalize("thar2"), "thar")
        },

        TestCase("normalize_keepsSpecials") { ctx in
            ctx.assertEqual(Romanization.normalize("min+galar"), "min+galar")
        },

        TestCase("normalize_stripsInvalid") { ctx in
            ctx.assertEqual(Romanization.normalize("hello!@#"), "hello")
        },

        TestCase("aliasReading_stripsNumericMarkers") { ctx in
            ctx.assertEqual(Romanization.aliasReading("ky2ar3"), "kyar")
        },

        TestCase("aliasReading_keepsOtherCharacters") { ctx in
            ctx.assertEqual(Romanization.aliasReading("u2:+"), "u:+")
        },

        TestCase("composeLookupKey_stripsDigitsAndSeparators") { ctx in
            ctx.assertEqual(
                Romanization.composeLookupKey("min+galarpar2"),
                "mingalarpar"
            )
        },

        TestCase("composeSeparatorPenaltyCount_countsOptionalSeparators") { ctx in
            ctx.assertEqual(
                Romanization.composeSeparatorPenaltyCount(for: "min+'galar"),
                2
            )
        },

        TestCase("composingCharacters_containsExpected") { ctx in
            for ch in Array("abcdefghijklmnopqrstuvwxyz+*':.") {
                ctx.assertTrue(
                    Romanization.composingCharacters.contains(ch),
                    "containsExpected.\(ch)",
                    detail: "Missing composing character: \(ch)"
                )
            }
            for ch in Array("0123456789") {
                ctx.assertFalse(
                    Romanization.composingCharacters.contains(ch),
                    "digitNotComposing.\(ch)",
                    detail: "Digit should not compose: \(ch)"
                )
            }
        },

        TestCase("composingCharacters_excludesSpecials") { ctx in
            for ch: Character in ["!", "@", "#", "$", "%", " ", "\n"] {
                ctx.assertFalse(
                    Romanization.composingCharacters.contains(ch),
                    "excludesSpecials.\(ch)"
                )
            }
        },

        TestCase("consonantLookup_gh") { ctx in
            ctx.assertEqual(Romanization.romanToConsonant["gh"], Myanmar.gha)
        },

        TestCase("consonantLookup_ss") { ctx in
            ctx.assertEqual(Romanization.romanToConsonant["ss"], Myanmar.greatSa)
        },

        TestCase("consonantLookup_nyIsNnya") { ctx in
            // "ny" must produce the common curly ည (U+100A, MYANMAR LETTER NNYA).
            ctx.assertEqual(Romanization.romanToConsonant["ny"], Myanmar.nnya)
        },

        TestCase("consonantLookup_ny2IsNya") { ctx in
            // The rarer flat ဉ (U+1009, MYANMAR LETTER NYA) lives under "ny2".
            ctx.assertEqual(Romanization.romanToConsonant["ny2"], Myanmar.nya)
        },

        TestCase("consonantReverse_nnya") { ctx in
            ctx.assertEqual(Romanization.consonantToRoman[Myanmar.nnya], "ny")
        },

        TestCase("consonantReverse_nya") { ctx in
            ctx.assertEqual(Romanization.consonantToRoman[Myanmar.nya], "ny2")
        },

        TestCase("consonants_containsBothNyaAndNnya") { ctx in
            ctx.assertTrue(Myanmar.consonants.contains(Myanmar.nya),
                detail: "Myanmar.consonants must include U+1009 (ဉ)")
            ctx.assertTrue(Myanmar.consonants.contains(Myanmar.nnya),
                detail: "Myanmar.consonants must include U+100A (ည)")
        },

        TestCase("vowelLookup_ii_shortIndependent") { ctx in
            let entry = Romanization.romanToVowel["ii."]
            ctx.assertTrue(entry != nil, detail: "ii. not found")
            ctx.assertEqual(entry?.myanmar, "\u{1023}")
            ctx.assertTrue(entry?.isStandalone == true, detail: "ii. must be standalone")
        },

        TestCase("vowelLookup_ii_longIndependent") { ctx in
            let entry = Romanization.romanToVowel["ii"]
            ctx.assertTrue(entry != nil, detail: "ii not found")
            ctx.assertEqual(entry?.myanmar, "\u{1024}")
            ctx.assertTrue(entry?.isStandalone == true, detail: "ii must be standalone")
        },

        TestCase("vowelLookup_oo_independent") { ctx in
            let entry = Romanization.romanToVowel["oo"]
            ctx.assertTrue(entry != nil, detail: "oo not found")
            ctx.assertEqual(entry?.myanmar, "\u{1029}")
            ctx.assertTrue(entry?.isStandalone == true, detail: "oo must be standalone")
        },

        TestCase("vowelLookup_ooTonal_independent") { ctx in
            let entry = Romanization.romanToVowel["oo:"]
            ctx.assertTrue(entry != nil, detail: "oo: not found")
            ctx.assertEqual(entry?.myanmar, "\u{102A}")
            ctx.assertTrue(entry?.isStandalone == true, detail: "oo: must be standalone")
        },

        TestCase("vowelLookup_locativeSymbol") { ctx in
            let entry = Romanization.romanToVowel["ywe"]
            ctx.assertTrue(entry != nil, detail: "ywe not found")
            ctx.assertEqual(entry?.myanmar, "\u{104D}")
            ctx.assertTrue(entry?.isStandalone == true, detail: "ywe must be standalone")
        },

        TestCase("vowelLookup_genitiveSymbol") { ctx in
            let entry = Romanization.romanToVowel["ei"]
            ctx.assertTrue(entry != nil, detail: "ei not found")
            ctx.assertEqual(entry?.myanmar, "\u{104F}")
            ctx.assertTrue(entry?.isStandalone == true, detail: "ei must be standalone")
        },
    ])
}
