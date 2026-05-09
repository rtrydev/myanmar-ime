import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-033: a run of two-or-more contiguous `'` characters between
/// two Burmese-composable letter runs must NOT erase every Burmese
/// candidate from the panel. The TASK-056 sanitizer correctly drops
/// the `<myanmar>'+<myanmar>` violators, but the panel must continue
/// to surface a Burmese sibling — the same composition the user
/// would have got with a SINGLE `'` (which the parser silently
/// consumes as a soft separator).
///
/// Behaviour after fix:
/// - `<lhs>''<rhs>` (and `<lhs>'''<rhs>`, `<lhs>''''<rhs>`, …) where
///   both halves are Burmese-composable produce a Myanmar candidate
///   that elides the `'` run; the literal `<lhs>''<rhs>` remains as
///   a lower-rank fallback.
/// - Boundary cases (`<lhs>'`, `'<rhs>`, `<lhs>''`, `''<rhs>`) keep
///   their existing literal-bearing top surfaces.
/// - Single-apostrophe behaviour (`thar'mar`) is unchanged.
public enum DoubledMidBufferApostropheSuite {

    private static func bundledEngine(_ ctx: TestContext) -> BurmeseEngine? {
        guard let lexPath = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lexPath),
              let lmPath = BundledArtifacts.trigramLMPath,
              let lm = try? TrigramLanguageModel(path: lmPath) else {
            ctx.assertTrue(true, "skipped_noBundledArtifacts")
            return nil
        }
        return BurmeseEngine(candidateStore: store, languageModel: lm)
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    private static func containsAnyMyanmar(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value >= 0x1000 && $0.value <= 0x109F }
    }

    private static func containsAsciiApostrophe(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value == 0x0027 }
    }

    public static let suite = TestSuite(name: "DoubledMidBufferApostrophe", cases: [

        // Bug-class buffers must produce at least one Myanmar candidate
        // somewhere in the panel.
        TestCase("midBufferDoubled_panelHasMyanmar") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for buffer in [
                "thar''mar",
                "kar''par",
                "ka''ma",
                "mingalar''par",
                "kyaung''thar",
            ] {
                let cands = engine.update(buffer: buffer, context: []).candidates
                let myanmar = cands.first(where: {
                    containsAnyMyanmar($0.surface) && !containsAsciiApostrophe($0.surface)
                })
                ctx.assertTrue(
                    myanmar != nil,
                    buffer,
                    detail: "no apostrophe-elided Myanmar candidate in '\(buffer)' panel=\(cands.prefix(8).map(\.surface))"
                )
            }
        },

        // Verify the elided Myanmar surface matches the
        // single-apostrophe sibling surface — the user's intent for
        // doubled `''` is the same as `'` (soft separator).
        TestCase("midBufferDoubled_matchesSingleApostropheSurface") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let pairs: [(doubled: String, single: String)] = [
                ("thar''mar",       "thar'mar"),
                ("kar''par",        "kar'par"),
                ("ka''ma",          "ka'ma"),
                ("mingalar''par",   "mingalar'par"),
                ("kyaung''thar",    "kyaung'thar"),
                // Triple+ apostrophes — generalisation requirement.
                ("thar'''mar",      "thar'mar"),
                ("ka'''ma",         "ka'ma"),
            ]
            for pair in pairs {
                let singleTop = engine.update(buffer: pair.single, context: [])
                    .candidates.first?.surface ?? ""
                let doubledCands = engine.update(buffer: pair.doubled, context: []).candidates
                ctx.assertTrue(
                    doubledCands.contains(where: { $0.surface == singleTop }),
                    pair.doubled,
                    detail: "expected single-apostrophe top '\(singleTop)' (hex=\(hex(singleTop))) in '\(pair.doubled)' panel=\(doubledCands.prefix(8).map(\.surface))"
                )
            }
        },

        // Single-apostrophe control — must keep its existing rank-0
        // Myanmar surface unchanged.
        TestCase("singleApostrophe_topSurfaceUnchanged") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, expected: String)] = [
                ("thar'mar",     "သာမာ"),
                ("kar'par",      "ကာပါ"),
                ("mingalar'par", "မင်္ဂလာပါ"),
            ]
            for c in cases {
                let top = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top, c.expected,
                    "\(c.buffer)_singleApostropheRegression_got=\(hex(top))"
                )
            }
        },

        // Boundary controls — `<lhs>'`, `'<rhs>`, `<lhs>''`,
        // `''<rhs>` keep their literal-bearing tops. The fix must
        // ONLY synthesise the elided sibling for runs sitting BETWEEN
        // two Myanmar-composable letter runs.
        TestCase("boundaryApostrophes_keepLiteralTop") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, expected: String)] = [
                ("thar'",   "သာ'"),
                ("'thar",   "'သာ"),
                ("thar''",  "သာ''"),
                ("''thar",  "''သာ"),
            ]
            for c in cases {
                let top = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top, c.expected,
                    "\(c.buffer)_boundaryApostropheRegression_got=\(hex(top))"
                )
            }
        },

        // Mixed `'`/`*` runs — TASK-056's separate signature. These
        // must continue to drop violators and surface the literal
        // verbatim (the `*` leak is independent of the apostrophe-run
        // fix).
        TestCase("mixedApostropheAsteriskRun_unchanged") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cands = engine.update(buffer: "thar'*mar", context: []).candidates
            // Top must contain the literal `'*` (TASK-056 signature
            // ensures the asterisk leak is present in the surfaced
            // form).
            let top = cands.first?.surface ?? ""
            ctx.assertTrue(
                top.contains("'*") || top.contains("*"),
                "thar'*mar",
                detail: "expected `*` literal preserved in 'thar'*mar' top='\(top)' hex=\(hex(top))"
            )
        },
    ])
}
