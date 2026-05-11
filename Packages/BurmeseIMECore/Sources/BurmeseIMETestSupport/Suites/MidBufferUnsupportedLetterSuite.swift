import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-068: ASCII letters that are not part of any
/// romanization rule (`f`, `q`, `x`, lone `c` not as `ch`/`chw`)
/// must not be silently absorbed into a phantom `1021` anchor when
/// they appear mid-buffer between parseable Burmese fragments.
///
/// Pre-fix the engine's DP would skip the unrecognized letter and
/// the materialise step would inject a `1021` (`အ`) at the position
/// the user typed the letter. The candidate's `reading` still
/// carried the original buffer letter, so the panel surfaced a
/// reading-vs-surface mismatch the user could not see (commits
/// `ka` + `အ` instead of preserving `f`).
///
/// Per TASK-043's literal-fallback policy and CLAUDE.md §3 ("digits
/// are literal"), unrecognized user-input characters must stay at
/// the typed position — either preserved verbatim in the surface OR
/// the literal raw buffer is promoted to rank 0. This suite checks
/// the latter: when the rawBuffer contains an unsupported ASCII
/// letter mid-buffer, the rank-0 surface either contains that
/// letter at the typed position OR equals the literal raw buffer.
public enum MidBufferUnsupportedLetterSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// True when `surface` contains any of the unsupported ASCII
    /// letters as a literal scalar. The fix's "preserve verbatim"
    /// option keeps the letter in the surface; the "promote literal"
    /// option keeps it in the surface (the surface IS the rawBuffer).
    private static func surfaceContainsLetter(_ surface: String, _ ch: Character) -> Bool {
        surface.contains(ch)
    }

    /// True when `surface` is structurally compatible with the
    /// user's typed `rawBuffer` for the unsupported-letter case:
    /// either every unsupported letter in rawBuffer appears in
    /// surface, OR surface equals rawBuffer (literal promotion).
    /// Cluster `c` (followed by `h`, the `ch`/`chw` aliases) is
    /// excluded — it is structurally meaningful and surfaces as
    /// the cluster's medial-bearing onset rather than a literal `c`.
    private static func surfaceHonorsUnsupportedLetters(
        surface: String,
        rawBuffer: String
    ) -> Bool {
        if surface == rawBuffer { return true }
        let chars = Array(rawBuffer)
        for i in 0..<chars.count {
            let ch = chars[i]
            guard Self.unsupportedLetters.contains(ch) else { continue }
            // Cluster-`c` carve-out: `c` followed by `h` is the
            // `ch` / `chw` cluster alias, structurally meaningful.
            if ch == "c" {
                let next = (i + 1 < chars.count) ? chars[i + 1] : nil
                if next == "h" { continue }
            }
            if !surface.contains(ch) { return false }
        }
        return true
    }

    /// ASCII letters never present in any onset / vowel / cluster
    /// alias key. `f`/`q`/`x` are absent from the rule tables
    /// entirely. `c` is conditionally unsupported: it appears only
    /// in `ch`/`chw` cluster aliases, so lone `c` (not followed by
    /// `h`) is effectively unsupported. The test cases below
    /// distinguish lone `c` from cluster-`c` by buffer shape.
    private static let unsupportedLetters: Set<Character> = ["f", "q", "x", "c"]

    public static let suite = TestSuite(name: "MidBufferUnsupportedLetter", cases: [

        // Headline acceptance: for every buffer in the bug-class
        // set, the rank-0 surface must either contain the
        // unsupported letter at its typed position OR equal the
        // literal raw buffer (TASK-068's option (a) / option (b)).
        TestCase("midUnsupportedLetter_rank0HonorsLetter") { ctx in
            let engine = emptyEngine()
            for buffer in [
                "kfa", "kqa", "kxa", "kca",
                "kfar", "makfaung",
                "kabfa", "kayfa",
                "min+f+gar", "min+gar+f+kya",
            ] {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first else {
                    ctx.assertTrue(false, buffer, detail: "panel empty")
                    continue
                }
                ctx.assertTrue(
                    surfaceHonorsUnsupportedLetters(
                        surface: top.surface,
                        rawBuffer: buffer
                    ),
                    buffer,
                    detail: "rank-0='\(top.surface)' [\(hex(top.surface))] omits unsupported letter from rawBuffer='\(buffer)'"
                )
            }
        },

        // Reading-vs-surface contract: a candidate's reading must
        // not claim to be `<...>f<...>` while the surface omits the
        // `f`. The bug pre-fix surfaced `reading='kfa'` with
        // `surface='ကအ'` — the `f` was advertised in reading but
        // dropped from surface.
        TestCase("midUnsupportedLetter_readingMatchesSurface") { ctx in
            let engine = emptyEngine()
            for buffer in [
                "kfa", "kqa", "kxa", "kca",
                "kfar", "makfaung",
                "min+f+gar", "min+gar+f+kya",
            ] {
                let state = engine.update(buffer: buffer, context: [])
                guard let top = state.candidates.first else { continue }
                // For each unsupported letter in the rank-0 reading,
                // assert it also appears in the rank-0 surface.
                // Cluster-`c` (`ch`/`chw`) is structurally meaningful
                // and exempt — its surface is the cluster's medial-
                // bearing onset rather than a literal `c`.
                let readingChars = Array(top.reading)
                for i in 0..<readingChars.count {
                    let ch = readingChars[i]
                    guard unsupportedLetters.contains(ch) else { continue }
                    if ch == "c" {
                        let next = (i + 1 < readingChars.count) ? readingChars[i + 1] : nil
                        if next == "h" { continue }
                    }
                    ctx.assertTrue(
                        top.surface.contains(ch),
                        "\(buffer):\(ch)",
                        detail: "rank-0 reading='\(top.reading)' carries '\(ch)' but surface='\(top.surface)' omits it"
                    )
                }
            }
        },

        // Literal raw buffer must remain reachable in the panel
        // regardless of which fix-option is chosen (CLAUDE.md §2).
        TestCase("midUnsupportedLetter_literalReachable") { ctx in
            let engine = emptyEngine()
            for buffer in [
                "kfa", "kqa", "kxa", "kfar", "makfaung",
                "kabfa", "kayfa",
            ] {
                let state = engine.update(buffer: buffer, context: [])
                let surfaces = state.candidates.map(\.surface)
                ctx.assertTrue(
                    surfaces.contains(buffer),
                    buffer,
                    detail: "literal '\(buffer)' missing from panel; surfaces=\(surfaces)"
                )
            }
        },

        // Buffer-prefix sanity: a pure-leading unsupported letter
        // (no parseable Myanmar prefix) was already correctly handled
        // pre-fix — the literal stays at rank 0. This is the
        // regression baseline.
        TestCase("leadingUnsupportedLetter_literalAtRank0") { ctx in
            let engine = emptyEngine()
            for buffer in ["f", "fa", "fk", "fka", "qa", "xa"] {
                let top = engine.update(buffer: buffer, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top, buffer,
                    "\(buffer)_leading_literal"
                )
            }
        },

        // Cluster-`c` (`ch`, `chw`) is supported and must NOT be
        // promoted to literal. `cha` → `ချ` (legitimate) and similar
        // need to keep working — the bug class is lone `c` (not
        // followed by `h` etc.), and the `c` in cluster-aliases is
        // structurally meaningful.
        TestCase("clusterC_unaffected") { ctx in
            let engine = emptyEngine()
            // `cha` is a cluster alias → ချ (1001 103B). Must NOT be
            // promoted to the literal `cha`.
            let topCha = engine.update(buffer: "cha", context: [])
                .candidates.first?.surface ?? ""
            ctx.assertFalse(
                topCha == "cha",
                "cha_clusterAlias",
                detail: "cluster-c (cha) must not be force-promoted to literal; got top='\(topCha)'"
            )
            // `chai` similarly.
            let topChai = engine.update(buffer: "chai", context: [])
                .candidates.first?.surface ?? ""
            ctx.assertFalse(
                topChai == "chai",
                "chai_clusterAlias",
                detail: "cluster-c (chai) must not be force-promoted to literal; got top='\(topChai)'"
            )
        },
    ])
}
