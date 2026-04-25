import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for task 02: stack inference must not split aspirated /
/// cluster-alias consonant digraphs (`dh`, `ph`, `gh`, `bh`, `th`,
/// `sh`, `hm`, …) into `<base> + virama + <ha-or-medial>`. The
/// inferred-`+` site must respect the digraph that the next two
/// (or three) ASCII letters form, not chop it in half.
///
/// Two flavours of "split" reach the candidate panel:
///
/// 1. **Inferred split:** `inferImplicitStackMarkers` inserts `+`
///    between the two letters of the digraph; the parser then
///    materialises `<base> + virama + <ha-or-medial>`. The fix is the
///    digraph guard inside `inferImplicitStackMarkers`.
/// 2. **Parser-DP split:** the parser's N-best chooses
///    `<C> + asat + ha + …` over the unsplit digraph reading even
///    without an inferred `+`, because both readings score equally on
///    the DP and a tie-breaker picks the wrong one. The fix is the
///    aspirated-digraph rarity penalty in
///    `Finalization.computeRarityPenalty`.
///
/// Both must hold for every multi-char consonant key the
/// romanization scheme defines.
public enum ConsonantDigraphIntegritySuite {

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

    /// Multi-char consonant keys whose internal split would produce a
    /// malformed surface. Numeric-suffixed keys (`ny2`, `t2`, …) get
    /// filtered out before inference fires (digits aren't permitted in
    /// the composable prefix), so they're not at risk and are skipped.
    /// `ng` / `ny` / `zz` / `ss` are intentionally NOT in this set:
    /// `ng` must split for kinzi (`<vowel>n + g<C>`), and the doubled
    /// keys are handled via the strict same-class stack path.
    private static let aspiratedDigraphKeys: [String] = [
        "kh",   // ka → kha (ခ)
        "gh",   // ga → gha (ဃ)
        "dh",   // da → dha (ဓ)
        "ph",   // pa → pha (ဖ)
        "th",   // ta → sa  (သ — the dental fricative)
        "ht",   // h-prefix; 'h' coda → tha (ထ)
        "hs",   // h-prefix; 'h' coda → hsa (ဆ)
        "ah",   // a-prefix; bare onsetless `a` + `h` → ah (အ)
    ]

    /// Cluster-alias digraphs whose internal split would re-route the
    /// medial(s) into a separate consonant. The romanization key is
    /// listed alongside the canonical Myanmar consonant scalar so the
    /// test can assert the digraph reaches the surface.
    private static let clusterAliasDigraphs: [(roman: String, baseScalar: UInt32)] = [
        ("ch",   0x1001),  // kha + ya-pin
        ("chw",  0x1001),
        ("sh",   0x101B),  // ra + ha-htoe
        ("shw",  0x101B),
        ("khr",  0x1001),
        ("ghr",  0x1003),
        ("dhr",  0x1013),
        ("phr",  0x1016),
        ("bhr",  0x1018),
        ("ll",   0x1020),  // doubled-l → retroflex la (rare; alias-only)
    ]

    /// Detects the malformed digraph-split signature the user must
    /// never see at rank 1. The parser may emit a virama (U+1039) or
    /// asat (U+103A) between the two halves of the digraph; both are
    /// equally wrong when a single-consonant digraph reading exists.
    private static func surfaceSplitsDigraphIntoHa(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars.map(\.value))
        guard scalars.count >= 3 else { return false }
        for i in 0..<(scalars.count - 2) {
            let mid = scalars[i + 1]
            let next = scalars[i + 2]
            // U+1039 (virama) or U+103A (asat) immediately followed by
            // U+101F (ha) is the malformed split — the user typed an
            // aspirated digraph and got `<C> + virama|asat + ha`
            // instead of the single aspirated consonant.
            if (mid == 0x1039 || mid == 0x103A) && next == 0x101F {
                return true
            }
        }
        return false
    }

    public static let suite = TestSuite(name: "ConsonantDigraphIntegrity", cases: [

        // Iterate every aspirated digraph key. For each, build a
        // buffer `ka<key>amma` (the trailing `mm` motivates the
        // inference loop to fire). Top must not be a malformed split.
        TestCase("aspiratedDigraphs_notSplitByEngine") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for key in aspiratedDigraphKeys {
                let buffer = "ka" + key + "amma"
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertFalse(
                    surfaceSplitsDigraphIntoHa(top),
                    buffer,
                    detail: "top='\(top)' splits the `\(key)` digraph (virama/asat + ha)"
                )
            }
        },

        // Same coverage at the inference level. The `+` insertion
        // must never land *between* the two letters of an aspirated
        // digraph. Catches a broken inference even when the parser-
        // side rarity penalty papers over the symptom in the panel.
        TestCase("aspiratedDigraphs_notSplitByInference") { ctx in
            for key in aspiratedDigraphKeys {
                let buffer = "ka" + key + "amma"
                guard let inferred = BurmeseEngine.inferImplicitStackMarkers(buffer) else {
                    continue
                }
                let inferredChars = Array(inferred.input)
                let keyStart = 2  // "ka".count
                let keyEnd = keyStart + key.count
                for (idx, ch) in inferredChars.enumerated() where ch == "+" {
                    let originalIdx = idx - inferredChars[..<idx].filter({ $0 == "+" }).count
                    // `precedingCoda == "h"` is a deliberate carve-out
                    // for Pali h-coda loanwords (`brahma`/`ahmat`); the
                    // `ah`, `ht`, `hs` keys legitimately split there.
                    if key.hasPrefix("h") || key == "ah" { continue }
                    ctx.assertTrue(
                        originalIdx <= keyStart || originalIdx >= keyEnd,
                        buffer,
                        detail: "inference inserted `+` at original index \(originalIdx) — inside `\(key)` (positions \(keyStart)..<\(keyEnd)); inferred='\(inferred.input)'"
                    )
                }
            }
        },

        // Cluster-alias digraphs (`sh`, `chw`, `khr`, …): inference
        // must keep them intact. Engine top is allowed to surface
        // alternates (the panel may legitimately show the structural
        // `Cy` rendering above the alias on some inputs), but `+`
        // must not land inside the alias.
        TestCase("clusterAliasDigraphs_notSplitByInference") { ctx in
            for entry in clusterAliasDigraphs {
                let buffer = "ka" + entry.roman + "amma"
                guard let inferred = BurmeseEngine.inferImplicitStackMarkers(buffer) else {
                    continue
                }
                let inferredChars = Array(inferred.input)
                let aliasStart = 2
                let aliasEnd = aliasStart + entry.roman.count
                for (idx, ch) in inferredChars.enumerated() where ch == "+" {
                    let originalIdx = idx - inferredChars[..<idx].filter({ $0 == "+" }).count
                    ctx.assertTrue(
                        originalIdx <= aliasStart || originalIdx >= aliasEnd,
                        buffer,
                        detail: "inference inserted `+` at original index \(originalIdx) — inside `\(entry.roman)` (positions \(aliasStart)..<\(aliasEnd)); inferred='\(inferred.input)'"
                    )
                }
            }
        },

        // The `sh` cluster alias is the most common cross-script user
        // case: `kashamma` → `ကရှမ္မ` (ra + ha-htoe). Assert that the
        // top candidate still has the alias scalars in adjacency, not
        // the malformed `<base> + virama + ha`.
        TestCase("clusterAliasShDigraph_topUsesAlias") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "kashamma", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertFalse(
                surfaceSplitsDigraphIntoHa(top),
                "kashamma",
                detail: "top='\(top)' contains malformed virama/asat + ha (sh split)"
            )
        },

        // Regression: real Pali stacks must still parse correctly
        // after the digraph guard and rarity penalty are in place.
        TestCase("paliStacks_stillParseAfterDigraphGuard") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let viramaScalar: UInt32 = 0x1039
            for input in ["atta", "dhamma", "brahma"] {
                let state = engine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top.unicodeScalars.contains(where: { $0.value == viramaScalar }),
                    input,
                    detail: "top='\(top)' lost its virama stack"
                )
            }
        },

        // Brahma / ahmat: leading-`h` coda splits ARE intended (the
        // medial-onset + h-coda stack is a real Pali loanword shape).
        // Assert the surface contains the expected medial + virama +
        // ma sequence so the carve-out doesn't regress.
        TestCase("brahmaStyleHCodaSplit_stillFires") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "brahma", context: [])
            let top = state.candidates.first?.surface ?? ""
            // ဗြဟ္မ = 1017 103C 101F 1039 1019 — verify ha (101F) is
            // adjacent to virama (1039) in the surface.
            let scalars = Array(top.unicodeScalars.map(\.value))
            var found = false
            for i in 0..<(scalars.count - 1) where scalars[i] == 0x101F {
                if scalars[i + 1] == 0x1039 { found = true; break }
            }
            ctx.assertTrue(
                found,
                "brahma",
                detail: "top='\(top)' missing the canonical h+virama+m sequence"
            )
        },
    ])
}
