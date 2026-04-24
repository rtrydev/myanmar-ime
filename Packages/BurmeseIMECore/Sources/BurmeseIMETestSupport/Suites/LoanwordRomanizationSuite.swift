import BurmeseIMECore

public enum LoanwordRomanizationSuite {

    private static func assertTop(
        _ ctx: TestContext,
        _ input: String,
        _ expected: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let top = BurmeseEngine().update(buffer: input, context: [])
            .candidates
            .first?
            .surface ?? ""
        ctx.assertEqual(top, expected, input, file: file, line: line)
    }

    private static func assertTopHasPrefix(
        _ ctx: TestContext,
        _ input: String,
        _ prefix: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let top = BurmeseEngine().update(buffer: input, context: [])
            .candidates
            .first?
            .surface ?? ""
        let topScalars = Array(top.unicodeScalars.map(\.value))
        let prefixScalars = Array(prefix.unicodeScalars.map(\.value))
        ctx.assertTrue(
            topScalars.starts(with: prefixScalars),
            input,
            detail: "\(input) expected prefix \(prefix), got \(top)",
            file: file,
            line: line
        )
    }

    private static func assertNoInitialYaYit(
        _ ctx: TestContext,
        _ input: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let top = BurmeseEngine().update(buffer: input, context: [])
            .candidates
            .first?
            .surface ?? ""
        let scalars = Array(top.unicodeScalars.map(\.value))
        let hasInitialYaYit = scalars.count >= 2 && scalars[1] == 0x103C
        ctx.assertFalse(
            hasInitialYaYit,
            input,
            detail: "\(input) should stay a native non-Cr reading, got \(top)",
            file: file,
            line: line
        )
    }

    public static let suite: TestSuite = {
        var cases: [TestCase] = [
            TestCase("paliCrAliasesReachYaYitClusters") { ctx in
                assertTop(ctx, "bra", "\u{1017}\u{103C}")               // ဗြ
                assertTop(ctx, "bri", "\u{1017}\u{103C}\u{102E}")       // ဗြီ
                assertTop(ctx, "bru", "\u{1017}\u{103C}\u{1030}")       // ဗြူ
                assertTop(ctx, "gragat", "\u{1002}\u{103C}\u{1002}\u{1010}\u{103A}") // ဂြဂတ်
                assertTop(ctx, "pray", "\u{1015}\u{103C}\u{1031}")      // ပြေ
                assertTopHasPrefix(ctx, "krist", "\u{1000}\u{103C}")    // ကြ...
                assertTopHasPrefix(ctx, "trasya", "\u{1010}\u{103C}")   // တြ...
                assertTopHasPrefix(ctx, "tran", "\u{1010}\u{103C}")     // တြ...
                assertTopHasPrefix(ctx, "dravid", "\u{1012}\u{103C}")   // ဒြ...
            },

            TestCase("paliChrAliasesReachAspiratedYaYitClusters") { ctx in
                assertTopHasPrefix(ctx, "bhrama", "\u{1018}\u{103C}")   // ဘြ...
                assertTopHasPrefix(ctx, "khrist", "\u{1001}\u{103C}")   // ခြ...
                assertTopHasPrefix(ctx, "dhrama", "\u{1013}\u{103C}")   // ဓြ...
                assertTopHasPrefix(ctx, "phraya", "\u{1016}\u{103C}")   // ဖြ...
            },

            TestCase("nativeSeparatedRaReadingsStayNative") { ctx in
                for input in ["bara", "gari", "para", "tari", "dari"] {
                    assertNoInitialYaYit(ctx, input)
                }
            },

            TestCase("reverseRomanizerAddsLoanwordCrAliases") { ctx in
                let aliases = Romanization.indexedComposeReadings(for: "vyah+ma")
                    .map(\.composeReading)
                ctx.assertTrue(
                    aliases.contains("brahma"),
                    "brahmaComposeAlias",
                    detail: "expected brahma alias for vyah+ma, got \(aliases)"
                )
                ctx.assertTrue(
                    aliases.contains("vrahma"),
                    "vrahmaComposeAlias",
                    detail: "expected vrahma alias for vyah+ma, got \(aliases)"
                )
            },
        ]

        #if canImport(SQLite3)
        cases.append(TestCase("sqliteLookupFindsLoanwordCrAliasRows") { ctx in
            do {
                let handle = try SQLiteLexiconFixture.build(
                    name: "loanwordCr",
                    rows: [
                        .init(
                            id: 1,
                            surface: "\u{1017}\u{103C}\u{101F}\u{1039}\u{1019}", // ဗြဟ္မ
                            reading: "vyah+ma",
                            score: 1000
                        ),
                    ]
                )
                defer { handle.cleanup() }
                let surfaces = handle.store.lookup(prefix: "brahma", previousSurface: nil)
                    .map(\.surface)
                ctx.assertTrue(
                    surfaces.contains("\u{1017}\u{103C}\u{101F}\u{1039}\u{1019}"),
                    "sqliteBrahmaAlias",
                    detail: "expected ဗြဟ္မ for brahma, got \(surfaces)"
                )
            } catch {
                ctx.fail("sqliteFixture", detail: "failed to build fixture: \(error)")
            }
        })
        #endif
        return TestSuite(name: "LoanwordRomanization", cases: cases)
    }()
}
