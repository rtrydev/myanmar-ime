import BurmeseIMECore

public enum RomanizationSuite {
    public static let suite = TestSuite(name: "Romanization", cases: [

        TestCase("consonantCount") { ctx in
            ctx.assertEqual(Romanization.consonants.count, 33)
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
    ])
}
