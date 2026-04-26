import Foundation
@_spi(Testing) import BurmeseIMECore

/// Regression suite for orphan dependent-vowel signs (especially the
/// leading-e mark `ေ` U+1031) appearing in candidate surfaces with no
/// consonant base of their own.
///
/// Two structural shapes trigger the bug:
///
/// 1. **Bare-vowel + onset-less leading-e syllable** — `iaung`, `uaung`,
///    `oaung`, … The first character produces a promoted independent
///    vowel (`အီ`, `အူ`, `အို`); the second syllable's `ေ` (or another
///    dependent vowel) lands directly after the first base's dependent
///    vowel mark and has no anchor of its own.
/// 2. **Heavy-tone visarga `:` followed by an onset-less syllable** —
///    `thar:aung`, `tar:aung`, `par:i`, `ku:aung`, … The closing
///    visarga `း` (U+1038) terminates the previous syllable, but the
///    following dependent vowel of the next syllable hangs off the
///    same base because no consonant break has materialised.
///
/// Both patterns surface as **invalid Burmese**: a `1031` (or other
/// dep-vowel scalar) lands after another dep-vowel scalar — or after a
/// final tone marker — on the same base. The expected behaviour is for
/// the engine to back the right-shrink probe off so the broken prefix
/// is not committed, and let `composeLetterRunsInTail` render the
/// dropped tail with an explicit `အ` (U+1021) consonant base.
///
/// See `tasks/01-orphan-leading-vowel-after-dependent-vowel.md`.
public enum OrphanLeadingVowelSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func topSurface(_ engine: BurmeseEngine, _ input: String) -> String {
        engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
    }

    private static func isLegal(_ surface: String) -> Bool {
        SyllableParser.scanOutputLegality(surface)
    }

    /// True when the surface contains a dependent vowel scalar
    /// (0x102B–0x1032 or the asat 0x103A) that is not anchored to a
    /// consonant base — specifically the `1031` (e-kar) appearing
    /// after another dep-vowel scalar with no consonant base in
    /// between, or any dep-vowel scalar appearing after a tone-only
    /// scalar (1037/1038) without a fresh consonant base. This is the
    /// failure shape `scanOutputLegality` should already reject.
    private static func surfaceHasOrphanDepVowel(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        for i in 0..<scalars.count {
            let v = scalars[i]
            // E-kar (1031) must be the FIRST mark after its consonant base.
            // Walk back; if we cross any other dep-vowel before reaching a
            // base, it's an orphan.
            if v == 0x1031 {
                var j = i - 1
                while j >= 0 {
                    let w = scalars[j]
                    let isConsonantBase = (w >= 0x1000 && w <= 0x1021) || w == 0x103F
                    if isConsonantBase { break }
                    let isDepVowel = w >= 0x102B && w <= 0x1032
                    if isDepVowel { return true }
                    let isToneMark = w >= 0x1036 && w <= 0x1038
                    if isToneMark { return true }
                    let isMedial = w >= 0x103B && w <= 0x103E
                    if isMedial { j -= 1; continue }
                    if w == 0x103A {
                        // asat: previous syllable closed; e-kar after asat
                        // with no fresh consonant base is an orphan.
                        return true
                    }
                    if w == 0x1039 {
                        j -= 1
                        continue
                    }
                    // Anything else (independent vowel, ZWNJ, etc.) –
                    // walk continues, but if we reach beginning without
                    // a consonant base, fall out.
                    j -= 1
                }
            }
            // Any dep-vowel/medial after a tone marker (1037/1038)
            // without a fresh consonant break is an orphan.
            let isAttachableMark = (v >= 0x102B && v <= 0x1032)
                || (v >= 0x1036 && v <= 0x103E)
            if isAttachableMark, i >= 1 {
                let prev = scalars[i - 1]
                if prev == 0x1037 || prev == 0x1038 { return true }
            }
        }
        return false
    }

    public static let suite = TestSuite(name: "OrphanLeadingVowel", cases: [

        // ── Bare-vowel + onset-less leading-e syllable ─────────────────────
        // `iaung`, `uaung`, `oaung` should split into two syllables: the
        // first an independent-vowel-bearing single, the second `အောင်`
        // (with explicit U+1021). The current engine fuses them and emits
        // an orphan `ေ` after the first base's dep vowel.
        TestCase("bareVowel_leadingE_split") { ctx in
            let engine = emptyEngine()
            for input in ["iaung", "uaung", "oaung", "iaw", "uaw"] {
                let top = topSurface(engine, input)
                ctx.assertTrue(
                    isLegal(top),
                    input,
                    detail: "top '\(top)' fails scanOutputLegality"
                )
                ctx.assertFalse(
                    surfaceHasOrphanDepVowel(top),
                    input,
                    detail: "top '\(top)' contains orphan e-kar after dependent vowel"
                )
            }
        },

        // ── Visarga + onset-less leading-e syllable ────────────────────────
        // `thar:aung`, `tar:aung`, `kar:aung`, `par:aung` must NOT emit
        // a `1031` after the visarga `1038`. The expected rendering is
        // `<word with visarga> + အောင်` (with the leading `အ` providing
        // the consonant base for the e-kar).
        TestCase("visarga_leadingE_split") { ctx in
            let engine = emptyEngine()
            for input in [
                "thar:aung", "tar:aung", "kar:aung", "par:aung",
                "ku:aung", "ki:aung",
            ] {
                let top = topSurface(engine, input)
                ctx.assertTrue(
                    isLegal(top),
                    input,
                    detail: "top '\(top)' fails scanOutputLegality"
                )
                ctx.assertFalse(
                    surfaceHasOrphanDepVowel(top),
                    input,
                    detail: "top '\(top)' contains orphan e-kar after visarga"
                )
            }
        },

        // ── Visarga + onset-less single dep-vowel syllable ─────────────────
        // `thar:i`, `par:i`, `kay:i` close the previous syllable on a
        // visarga and then the suffix `i` produces a dependent vowel that
        // currently lands next to the visarga (`သားီ`) — orphan.
        TestCase("visarga_leadingDepVowel_split") { ctx in
            let engine = emptyEngine()
            for input in ["thar:i", "par:i", "kay:i", "tar:i"] {
                let top = topSurface(engine, input)
                ctx.assertTrue(
                    isLegal(top),
                    input,
                    detail: "top '\(top)' fails scanOutputLegality"
                )
                ctx.assertFalse(
                    surfaceHasOrphanDepVowel(top),
                    input,
                    detail: "top '\(top)' contains orphan dep-vowel after visarga"
                )
            }
        },

        // ── scanOutputLegality must directly reject the broken shapes ─────
        // Pinpoint test: the surface scan is the structural source of
        // truth. Once it is tightened, every downstream filter and the
        // right-shrink probe will see these as illegal.
        TestCase("scanRejectsOrphanShapes") { ctx in
            let cases: [(String, String)] = [
                // အ + ီ + ေ + ာ + င + ် (iaung)
                ("\u{1021}\u{102E}\u{1031}\u{102C}\u{1004}\u{103A}", "iaung"),
                // အ + ူ + ေ + ာ + င + ် (uaung)
                ("\u{1021}\u{1030}\u{1031}\u{102C}\u{1004}\u{103A}", "uaung"),
                // အ + ိ + ု + ေ + ာ + င + ် (oaung)
                ("\u{1021}\u{102D}\u{102F}\u{1031}\u{102C}\u{1004}\u{103A}", "oaung"),
                // ပ + ါ + း + ီ (par:i)
                ("\u{1015}\u{102B}\u{1038}\u{102E}", "par:i"),
                // က + ေ + း + ီ (kay:i)
                ("\u{1000}\u{1031}\u{1038}\u{102E}", "kay:i"),
            ]
            for (s, label) in cases {
                ctx.assertFalse(
                    SyllableParser.scanOutputLegality(s),
                    "scanOutputLegality(\(label))",
                    detail: "expected false (orphan dep-vowel) but got true"
                )
            }
        },

        // ── scanOutputLegality must accept legitimate multi-scalar clusters
        TestCase("scanAcceptsLegalClusters") { ctx in
            let cases: [(String, String)] = [
                // အောင် (aung — legal: e-kar then aa)
                ("\u{1021}\u{1031}\u{102C}\u{1004}\u{103A}", "aung"),
                // အေါ် (ေါ + ် — legal: e-kar then tall aa then asat)
                ("\u{1021}\u{1031}\u{102B}\u{103A}", "aw2*"),
                // အို (o cluster — legal: i then u)
                ("\u{1021}\u{102D}\u{102F}", "o"),
                // ကောင်း (kaung: with visarga at end; tone marker is final)
                ("\u{1000}\u{1031}\u{102C}\u{1004}\u{103A}\u{1038}", "kaung:"),
                // သား (visarga only — legal)
                ("\u{101E}\u{102C}\u{1038}", "thar:"),
                // အီ (independent + i — legal: single dep vowel)
                ("\u{1021}\u{102E}", "ee"),
                // အို (independent + i + u — legal o cluster)
                ("\u{1021}\u{102D}\u{102F}", "o variant"),
            ]
            for (s, label) in cases {
                ctx.assertTrue(
                    SyllableParser.scanOutputLegality(s),
                    "scanOutputLegality(\(label))",
                    detail: "expected true (legitimate cluster) but got false"
                )
            }
        },
    ])
}
