import BurmeseIMECore

public enum ClusterAliasSuite {
    public static let suite = TestSuite(name: "ClusterAlias", cases: [

        TestCase("clusterAliasesEnabled_jMatchesKaMedialYa") { ctx in
            let parser = SyllableParser(useClusterAliases: true)
            let surfaces = parser.parseCandidates("j", maxResults: 8).map(\.output)
            ctx.assertTrue(
                surfaces.contains("ကျ"),
                detail: "expected 'j' to parse as ကျ with cluster aliases on, got: \(surfaces)"
            )
        },

        TestCase("clusterAliasesDisabled_jHasNoClusterOnset") { ctx in
            let parser = SyllableParser(useClusterAliases: false)
            let surfaces = parser.parseCandidates("j", maxResults: 8).map(\.output)
            ctx.assertFalse(
                surfaces.contains("ကျ"),
                detail: "cluster parse leaked through with aliases disabled: \(surfaces)"
            )
        },

        TestCase("clusterAliasesDisabled_doesNotBreakOtherOnsets") { ctx in
            let parser = SyllableParser(useClusterAliases: false)
            let parses = parser.parseCandidates("ka", maxResults: 4)
            ctx.assertFalse(
                parses.isEmpty,
                detail: "disabling cluster aliases should not break standard onsets"
            )
        },

        TestCase("cluster_j") { ctx in
            let parser = SyllableParser(useClusterAliases: true)
            ctx.assertEqual(parser.parse("j").first?.output ?? "", "ကျ")
        },

        TestCase("cluster_ja") { ctx in
            let parser = SyllableParser(useClusterAliases: true)
            ctx.assertEqual(parser.parse("ja").first?.output ?? "", "ကျ")
        },

        TestCase("cluster_jw") { ctx in
            let parser = SyllableParser(useClusterAliases: true)
            ctx.assertEqual(parser.parse("jw").first?.output ?? "", "ကျွ")
        },

        TestCase("cluster_jwantaw") { ctx in
            let parser = SyllableParser(useClusterAliases: true)
            ctx.assertEqual(parser.parse("jwantaw").first?.output ?? "", "ကျွန်တော်")
        },

        TestCase("cluster_ch") { ctx in
            let parser = SyllableParser(useClusterAliases: true)
            ctx.assertEqual(parser.parse("ch").first?.output ?? "", "ချ")
        },

        TestCase("cluster_chit") { ctx in
            let parser = SyllableParser(useClusterAliases: true)
            ctx.assertEqual(parser.parse("chit").first?.output ?? "", "ချစ်")
        },

        TestCase("cluster_sha") { ctx in
            let parser = SyllableParser(useClusterAliases: true)
            ctx.assertEqual(parser.parse("sha").first?.output ?? "", "ရှ")
        },

        TestCase("cluster_shar") { ctx in
            let parser = SyllableParser(useClusterAliases: true)
            ctx.assertEqual(parser.parse("shar").first?.output ?? "", "ရှာ")
        },

        TestCase("cluster_gyw_hasJwa") { ctx in
            let parser = SyllableParser(useClusterAliases: true)
            let outputs = parser.parseCandidates("gyw", maxResults: 4).map(\.output)
            ctx.assertTrue(
                outputs.contains("ဂျွ"),
                detail: "candidates: \(outputs)"
            )
        },

        TestCase("aspirated_hnga") { ctx in
            let parser = SyllableParser()
            ctx.assertEqual(parser.parse("hnga").first?.output ?? "", "ငှ")
        },

        TestCase("aspirated_hma") { ctx in
            let parser = SyllableParser()
            ctx.assertEqual(parser.parse("hma").first?.output ?? "", "မှ")
        },

        TestCase("aspirated_hla") { ctx in
            let parser = SyllableParser()
            ctx.assertEqual(parser.parse("hla").first?.output ?? "", "လှ")
        },

        TestCase("aspirated_hna") { ctx in
            let parser = SyllableParser()
            ctx.assertEqual(parser.parse("hna").first?.output ?? "", "နှ")
        },

        TestCase("aspirated_hnya") { ctx in
            let parser = SyllableParser()
            ctx.assertEqual(parser.parse("hnya").first?.output ?? "", "\u{1009}\u{103E}")
        },

        TestCase("canonical_hr") { ctx in
            let parser = SyllableParser()
            ctx.assertEqual(parser.parse("hr").first?.output ?? "", "ရှ")
        },

        TestCase("canonical_gy_isYaYit") { ctx in
            let parser = SyllableParser()
            ctx.assertEqual(parser.parse("gy").first?.output ?? "", "ဂြ")
        },

        TestCase("canonical_kya_isYaYit") { ctx in
            let parser = SyllableParser()
            ctx.assertEqual(parser.parse("kya").first?.output ?? "", "ကြ")
        },

        TestCase("cluster_jar_exposesYaYit") { ctx in
            let parser = SyllableParser(useClusterAliases: true)
            let surfaces = parser.parseCandidates("jar", maxResults: 8).map(\.output)
            ctx.assertTrue(
                surfaces.contains("ကြာ"),
                detail: "expected 'jar' candidates to include ကြာ, got: \(surfaces)"
            )
            ctx.assertTrue(
                surfaces.contains("ကျာ"),
                detail: "expected 'jar' candidates to include ကျာ, got: \(surfaces)"
            )
        },

        TestCase("cluster_char_exposesYaYit") { ctx in
            let parser = SyllableParser(useClusterAliases: true)
            let surfaces = parser.parseCandidates("char", maxResults: 8).map(\.output)
            ctx.assertTrue(
                surfaces.contains("ခြာ"),
                detail: "expected 'char' candidates to include ခြာ, got: \(surfaces)"
            )
            ctx.assertTrue(
                surfaces.contains("ချာ"),
                detail: "expected 'char' candidates to include ချာ, got: \(surfaces)"
            )
        },
    ])
}
