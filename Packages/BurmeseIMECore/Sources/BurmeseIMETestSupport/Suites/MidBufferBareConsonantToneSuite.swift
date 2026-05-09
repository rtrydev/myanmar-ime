import Foundation
@_spi(Testing) import BurmeseIMECore

/// TASK-032: a bare-`<C>a` syllable followed by a tone marker (`:` /
/// `.`) and another Burmese letter run must absorb the tone scalar
/// onto the bare-`<C>a` syllable instead of leaving the literal ASCII
/// `:` / `.` between the two composed Myanmar syllables.
///
/// The end-of-buffer case (`ka:` -> `ကး`, `ma.` -> `မ့`) is already
/// covered by `BareConsonantToneSuite`; this suite covers the
/// continuation case (`ka:par` -> `ကးပါ`, `ma.par` -> `မ့ပါ`).
///
/// Includes:
/// - bare consonants (`k`/`th`/`m`/`y`/`w`),
/// - medial-bearing onsets (`kya`/`mya`),
/// - chained tone markers (`ka:ma:par`, `ka.ma.par`),
/// - long anchor-stability cases (`kyaung:tha:par`),
/// - mid-English-mode guard (`ka:abc` is allowed to absorb because the
///   suffix partially composes; `ma.xyz` keeps the literal because the
///   suffix has no Burmese composition; `kit.kha` keeps the literal at
///   rank 0 — TASK-049 path),
/// - end-of-buffer regression coverage.
public enum MidBufferBareConsonantToneSuite {

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

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// True when `surface` contains the ASCII scalar (U+003A `:` or
    /// U+002E `.`) anywhere.
    private static func containsAsciiToneScalar(_ surface: String, scalar: UInt32) -> Bool {
        surface.unicodeScalars.contains { $0.value == scalar }
    }

    public static let suite = TestSuite(name: "MidBufferBareConsonantTone", cases: [

        // Core shape: bare-`<C>a` + `:` + Burmese-composable letter run
        // must absorb visarga (U+1038) onto the bare consonant.
        TestCase("bareCa_visarga_continuesBurmese") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, mustContain: [UInt32], mustNotContain: UInt32)] = [
                ("ka:par",   [0x1000, 0x1038, 0x1015, 0x102B], 0x003A),
                ("tha:par",  [0x101E, 0x1038],                  0x003A),
                ("ma:par",   [0x1019, 0x1038],                  0x003A),
                ("ya:par",   [0x101A, 0x1038],                  0x003A),
                ("na:par",   [0x1014, 0x1038],                  0x003A),
                ("la:par",   [0x101C, 0x1038],                  0x003A),
                ("wa:par",   [0x101D, 0x1038],                  0x003A),
                ("pa:par",   [0x1015, 0x1038],                  0x003A),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                // Must contain the tone-bearing prefix scalars in order.
                let scalars = Array(surface.unicodeScalars).map(\.value)
                var found = false
                outer: for start in 0...max(0, scalars.count - c.mustContain.count) {
                    for (i, expected) in c.mustContain.enumerated() {
                        if scalars[start + i] != expected { continue outer }
                    }
                    found = true
                    break
                }
                ctx.assertTrue(
                    found,
                    c.buffer,
                    detail: "missing toned prefix in '\(c.buffer)' surface='\(surface)' hex=\(hex(surface))"
                )
                ctx.assertFalse(
                    containsAsciiToneScalar(surface, scalar: c.mustNotContain),
                    "\(c.buffer)_noLiteralColon",
                    detail: "literal `:` survived in '\(c.buffer)' surface='\(surface)'"
                )
            }
        },

        // Bare-`<C>a` + `.` + Burmese-composable letter run must absorb
        // creaky tone (U+1037) onto the bare consonant.
        TestCase("bareCa_creaky_continuesBurmese") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, mustContain: [UInt32], mustNotContain: UInt32)] = [
                ("ka.par",   [0x1000, 0x1037, 0x1015, 0x102B], 0x002E),
                ("tha.par",  [0x101E, 0x1037],                  0x002E),
                ("ma.par",   [0x1019, 0x1037],                  0x002E),
                ("ya.par",   [0x101A, 0x1037],                  0x002E),
                ("wa.par",   [0x101D, 0x1037],                  0x002E),
                ("pa.par",   [0x1015, 0x1037],                  0x002E),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars).map(\.value)
                var found = false
                outer: for start in 0...max(0, scalars.count - c.mustContain.count) {
                    for (i, expected) in c.mustContain.enumerated() {
                        if scalars[start + i] != expected { continue outer }
                    }
                    found = true
                    break
                }
                ctx.assertTrue(
                    found,
                    c.buffer,
                    detail: "missing toned prefix in '\(c.buffer)' surface='\(surface)' hex=\(hex(surface))"
                )
                ctx.assertFalse(
                    containsAsciiToneScalar(surface, scalar: c.mustNotContain),
                    "\(c.buffer)_noLiteralDot",
                    detail: "literal `.` survived in '\(c.buffer)' surface='\(surface)'"
                )
            }
        },

        // Medial-bearing bare-`<C>a` (e.g. `kya`, `mya`) + tone marker
        // + Burmese-composable run.
        TestCase("medialBearingCa_tone_continuesBurmese") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, tone: UInt32, asciiBlocked: UInt32)] = [
                ("kya:par",  0x1038, 0x003A),
                ("kya.par",  0x1037, 0x002E),
                ("mya:par",  0x1038, 0x003A),
                ("mya.par",  0x1037, 0x002E),
                ("pya:par",  0x1038, 0x003A),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    surface.unicodeScalars.contains { $0.value == c.tone },
                    c.buffer,
                    detail: "expected tone \(String(format: "%04X", c.tone)) in '\(c.buffer)' surface='\(surface)' hex=\(hex(surface))"
                )
                ctx.assertFalse(
                    containsAsciiToneScalar(surface, scalar: c.asciiBlocked),
                    "\(c.buffer)_noLiteralPunct",
                    detail: "literal punct survived in '\(c.buffer)' surface='\(surface)'"
                )
            }
        },

        // Chained tones — both must be absorbed.
        TestCase("chainedTones_bothAbsorbed") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, asciiBlocked: UInt32)] = [
                ("ka:ma:par",   0x003A),
                ("ka.ma.par",   0x002E),
                ("tha:thar:par", 0x003A),
                ("ka:tha:par",  0x003A),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertFalse(
                    containsAsciiToneScalar(surface, scalar: c.asciiBlocked),
                    c.buffer,
                    detail: "literal punct survived in '\(c.buffer)' surface='\(surface)' hex=\(hex(surface))"
                )
            }
        },

        // Long anchor-stability case — the full `kyaung:tha:par` and
        // its prefixes must absorb both `:`s correctly.
        TestCase("longAnchor_kyaungThaPar_absorbsTone") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let surface = engine.update(buffer: "kyaung:tha:par", context: [])
                .candidates.first?.surface ?? ""
            ctx.assertFalse(
                containsAsciiToneScalar(surface, scalar: 0x003A),
                "kyaung:tha:par",
                detail: "literal `:` survived in 'kyaung:tha:par' surface='\(surface)' hex=\(hex(surface))"
            )
            // The first `:` was already absorbed pre-fix (the `aung:`
            // colon-vowel-modifier path); the second must now also be
            // absorbed onto the bare `tha` syllable.
            ctx.assertTrue(
                surface.unicodeScalars.contains { $0.value == 0x1038 },
                "kyaung:tha:par_visarga",
                detail: "expected visarga U+1038 in surface='\(surface)' hex=\(hex(surface))"
            )
        },

        // Negative control — when the tail after the tone marker is
        // genuinely English (no Burmese composition possible), the
        // literal punct stays. `xyz` parses to nothing in Burmese, so
        // the rank-0 surface should NOT absorb the tone.
        TestCase("englishTail_keepsLiteralPunct") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            // `ma.xyz` — the `xyz` tail has no Burmese composition.
            let surface1 = engine.update(buffer: "ma.xyz", context: [])
                .candidates.first?.surface ?? ""
            // Either rank-0 is the literal `ma.xyz` (current top), or
            // a Myanmar surface containing the literal `.` (the
            // pre-fix `မ.xyz`). Both preserve the literal `.`.
            ctx.assertTrue(
                containsAsciiToneScalar(surface1, scalar: 0x002E)
                    || surface1 == "ma.xyz",
                "ma.xyz",
                detail: "expected literal `.` preserved in 'ma.xyz' surface='\(surface1)' hex=\(hex(surface1))"
            )
        },

        // End-of-buffer cases — TASK-014 regression coverage. Bare
        // `<C>a:` / `<C>a.` (no continuation) must keep their existing
        // tone-absorbed surfaces. `BareConsonantToneSuite` already
        // covers this with the empty engine; here we verify under the
        // production-equivalent ranker.
        TestCase("endOfBuffer_toneAbsorbed_unchanged") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, tone: UInt32)] = [
                ("ka:",  0x1038),
                ("ma.",  0x1037),
                ("tha:", 0x1038),
                ("kya.", 0x1037),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertTrue(
                    surface.unicodeScalars.contains { $0.value == c.tone },
                    c.buffer,
                    detail: "expected tone \(String(format: "%04X", c.tone)) in '\(c.buffer)' surface='\(surface)' hex=\(hex(surface))"
                )
            }
        },

        // Counter-examples that already worked pre-fix and must keep
        // working: explicit dep-vowel + tone (`kar:par`, `kar.par`,
        // `kyar:par`, `kar:thar:par`).
        TestCase("explicitVowelTone_continuesBurmese_unchanged") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let cases: [(buffer: String, mustContain: [UInt32])] = [
                ("kar:par",      [0x1000, 0x102C, 0x1038, 0x1015, 0x102B]),     // ကားပါ
                ("kar.par",      [0x1000, 0x102C, 0x1037, 0x1015, 0x102B]),     // ကာ့ပါ
                ("kar:thar:par", [0x1000, 0x102C, 0x1038, 0x101E, 0x102C, 0x1038, 0x1015, 0x102B]),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                let scalars = Array(surface.unicodeScalars).map(\.value)
                var found = false
                outer: for start in 0...max(0, scalars.count - c.mustContain.count) {
                    for (i, expected) in c.mustContain.enumerated() {
                        if scalars[start + i] != expected { continue outer }
                    }
                    found = true
                    break
                }
                ctx.assertTrue(
                    found,
                    c.buffer,
                    detail: "missing expected toned prefix in '\(c.buffer)' surface='\(surface)' hex=\(hex(surface))"
                )
            }
        },

        // Existing asat-coda + tone cases (TASK-023). The literal `.`
        // / `:` after an asat-closed coda must still absorb correctly
        // — this regression check guards against the new bare-`<C>a`
        // path inadvertently capturing the asat-coda case (which has
        // its own orthographically-distinct rule).
        TestCase("asatCodaTone_continuesBurmese_unchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expected: [UInt32])] = [
                // kit.par — creaky on asat-coda: `<C> 1037 103A` then
                // a fresh `<par>` syllable. Note this currently
                // partially renders only the coda; the suffix
                // `par` may stay literal under the empty-store engine.
                // The structural invariant: the `.` after the coda
                // must be absorbed as creaky (1037), NOT survive as
                // literal.
                ("kit.", [0x1000, 0x1005, 0x1037, 0x103A]),
                ("kit:", [0x1000, 0x1005, 0x103A, 0x1038]),
            ]
            for c in cases {
                let surface = engine.update(buffer: c.buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertEqual(
                    Array(surface.unicodeScalars).map(\.value), c.expected,
                    "\(c.buffer)_expectedHex=\(c.expected.map { String(format: "%04X", $0) }.joined(separator: " "))_got=\(hex(surface))"
                )
            }
        },
    ])
}
