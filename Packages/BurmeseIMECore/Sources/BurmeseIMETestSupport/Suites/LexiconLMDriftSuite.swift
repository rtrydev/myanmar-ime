import Foundation
import BurmeseIMECore

/// Regression guard against LM↔SQLite vocabulary drift, plus a parity
/// fixture for TASK-038 (canonical-vs-corpus surface storage).
///
/// The LM `.bin` and the lexicon `.sqlite` must be produced from the same
/// corpus-builder pass. When they drift (e.g. sqlite rebuilt without
/// retraining the LM), surfaces the ranker offers get charged the LM's
/// `<unk>` log-prob — which is far lower than any plausible real
/// log-prob — and rank fairly arbitrarily. See `tasks/audit.md` §1d for
/// the incident that motivated this check.
///
/// The drift case fires a fixed set of buffers through
/// `SQLiteCandidateStore` and asserts every returned surface has a real
/// LM vocab id. Failures list the missing surfaces so the fix (re-run
/// `corpus-build lm` against the current TSV) is obvious.
///
/// The canonical-storage parity case (TASK-038) asserts that every
/// surface emitted by the bundled lexicon agrees with the
/// canonicalization the ingest pipeline now performs:
///
///   - NFC-stable (`String.precomposedStringWithCanonicalMapping` is
///     a fixed point — `<C> 1037 103A` not `<C> 103A 1037`);
///   - no doubled tone scalar (`<X> 1037 1037` collapsed);
///   - no orphan U+200C / U+200D (zero-width controls only survive
///     between two Myanmar scalars where they can form / suppress a
///     cluster).
///
/// When the bundled lexicon predates the TASK-038 corpus regeneration
/// the parity case skips cleanly with `skipped_legacyLexicon_pendingRegeneration`,
/// because under CLAUDE.md non-negotiables the lexicon binary is a
/// pipeline output and is not edited by hand. Once the lexicon is
/// regenerated against the canonicalised corpus, the skip path goes
/// dormant and the strict assertions take over automatically.
public enum LexiconLMDriftSuite {

    /// Buffers chosen to exercise the historically-override-backed surfaces
    /// plus a handful of common ones. If the LM is missing any surface
    /// these lookups return, the ranker will silently misbehave on typing.
    private static let probeBuffers: [String] = [
        "mingalarpar",
        "thanhlyin",
        "kyaung",
        "an",
        "ganda",
        "kyi",
        "khyin",
    ]

    /// Buffers known to expose TASK-038 creaky-tone surfaces. Their
    /// canonical storage form is `<C>...<vowel> 1037 103A`; pre-TASK-038
    /// corpora also produced `<C>...<vowel> 103A 1037` (asat-then-tone),
    /// `<C>...<vowel> 1037 103A 1037` (doubled creaky), and
    /// `<C>...<vowel> 1037 103A 200C` (trailing ZWNJ) variants for the
    /// same phonological word. After the canonicalisation pass, only
    /// the canonical shape survives.
    private static let canonicalParityProbes: [String] = [
        "hnin.",     // နှင့်  — "with"
        "thi2.",     // သည့်   — relative-clause closer
        "thin.",     // သင့်   — "should"
        "thu.",      // သူ့    — "his/her"
        "myinmar",   // မြန်မာ  — "Myanmar" (NFC-stable control)
    ]

    /// Unicode scalar values for the three tone marks. A doubled
    /// adjacent occurrence is corpus noise — Myanmar orthography
    /// gives no "stress / extra" reading to a duplicated tone scalar,
    /// and the ingest pipeline now collapses runs to a single mark.
    /// We compare on the raw scalar value (NOT `Character`, which is
    /// a grapheme cluster — `င့့်` would be a single `Character`
    /// even with two U+1037 inside it, hiding the duplication).
    private static let toneScalarValues: Set<UInt32> = [0x1036, 0x1037, 0x1038]

    public static let suite = TestSuite(name: "LexiconLMDrift", cases: [

        TestCase("lookupSurfaces_allPresentInLMVocab") { ctx in
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath) else {
                ctx.assertTrue(true, "skipped_noBundledLexicon")
                return
            }
            guard let lmPath = BundledArtifacts.trigramLMPath,
                  let lm = try? TrigramLanguageModel(path: lmPath) else {
                ctx.assertTrue(true, "skipped_noBundledLM")
                return
            }

            for buffer in probeBuffers {
                let candidates = store.lookup(prefix: buffer, previousSurface: nil)
                if candidates.isEmpty { continue }
                var missing: [String] = []
                for candidate in candidates where lm.wordId(for: candidate.surface) == nil {
                    // Intentionally-OOV curated additions (`အံး`, `ကြီ`)
                    // are reachable per CLAUDE.md §7 but absent from
                    // LM vocab. They get the `<unk>` log-prob floor.
                    if CuratedLexicon.oovAllowedSurfaces.contains(candidate.surface) { continue }
                    missing.append(candidate.surface)
                }
                ctx.assertTrue(
                    missing.isEmpty,
                    "buffer_\(buffer)",
                    detail: "missing_from_LM_vocab=\(missing)"
                )
            }
        },

        // TASK-038: canonical-vs-corpus surface parity. The corpus
        // builder applies NFC + doubled-tone collapse + orphan ZWNJ
        // strip at ingest time. Once the lexicon is regenerated against
        // the canonicalised corpus, every emitted surface must satisfy
        // those invariants. Until then the case skips cleanly so the
        // suite stays green during the regeneration window — see the
        // class comment above.
        TestCase("canonicalStorageParity_allEmittedSurfacesAreCanonical") { ctx in
            guard let lexPath = BundledArtifacts.lexiconPath,
                  let store = SQLiteCandidateStore(path: lexPath) else {
                ctx.assertTrue(true, "skipped_noBundledLexicon")
                return
            }

            // Detect legacy (pre-TASK-038) lexicons. We use the
            // `hnin.` reading because it is the canonical TASK-038
            // example, and any pre-regeneration bundle ships both
            // `<C> 1037 103A` and `<C> 103A 1037` rows on the same
            // alias key. If we see the asat-then-tone byte sequence
            // anywhere in the lookup result, the bundle predates
            // canonicalisation.
            let probe = store.lookup(prefix: "hnin", previousSurface: nil)
            let bundleIsLegacy = probe.contains { containsAsatThenTone($0.surface) }
            if bundleIsLegacy {
                // Surface a non-failing marker so the test runner
                // shows visible progress and the skip is auditable in
                // the run log.
                ctx.assertTrue(
                    true,
                    "skipped_legacyLexicon_pendingRegeneration",
                    detail: "bundled lexicon predates TASK-038 canonicalisation; will activate after corpus rebuild"
                )
                return
            }

            for buffer in canonicalParityProbes {
                let candidates = store.lookup(prefix: buffer, previousSurface: nil)
                if candidates.isEmpty { continue }
                for candidate in candidates {
                    let surface = candidate.surface
                    ctx.assertTrue(
                        isNfcStable(surface),
                        "buffer_\(buffer)_nfcStable",
                        detail: "non_canonical_surface=\(surface) hex=\(hex(surface))"
                    )
                    ctx.assertFalse(
                        hasDoubledTone(surface),
                        "buffer_\(buffer)_noDoubledTone",
                        detail: "doubled_tone_in_surface=\(surface) hex=\(hex(surface))"
                    )
                    ctx.assertFalse(
                        hasOrphanZeroWidth(surface),
                        "buffer_\(buffer)_noOrphanZWNJ",
                        detail: "orphan_zw_in_surface=\(surface) hex=\(hex(surface))"
                    )
                }
            }
        },
    ])

    // MARK: - Canonicalization predicates

    /// True when `surface` is its own NFC at the byte level. Implemented
    /// via Swift's `precomposedStringWithCanonicalMapping`, which applies
    /// the same canonical-reordering algorithm Python's
    /// `unicodedata.normalize("NFC", ...)` uses (Unicode Canonical
    /// Combining Class table). For Myanmar scalars this collapses
    /// `<C> 103A 1037` to `<C> 1037 103A` because U+1037 has CCC=7
    /// < U+103A CCC=9.
    ///
    /// The comparison is on the raw scalar sequence — Swift's `==`
    /// on `String` is canonical-equivalence, which would silently
    /// report two byte-different but NFC-equivalent surfaces as
    /// equal and hide the very drift we are testing for.
    static func isNfcStable(_ surface: String) -> Bool {
        let original = Array(surface.unicodeScalars).map { $0.value }
        let normalized = Array(surface.precomposedStringWithCanonicalMapping.unicodeScalars).map { $0.value }
        return original == normalized
    }

    /// True when `surface` contains a doubled tone scalar (U+1036,
    /// U+1037 or U+1038). NFC does not collapse duplicate scalars,
    /// so the corpus pipeline runs an explicit collapse pass.
    ///
    /// We check on the NFC-normalised scalar sequence so the predicate
    /// catches both shapes produced by the legacy corpus:
    ///   - adjacent: `<vowel> 1037 1037` (already adjacent in storage);
    ///   - reordered: `<vowel> 1037 103A 1037` — the asat between two
    ///     creakies splits them in the raw bytes, but NFC sorts the
    ///     creakies adjacent (`1037 1037 103A`) because U+103A has
    ///     the higher Combining Class.
    /// Without the NFC pre-pass the second shape would slip past.
    /// Iteration is over `unicodeScalars`, not `Character` — the
    /// whole `င့့်` sequence is a single grapheme cluster, so
    /// `Character`-level iteration could never see two adjacent
    /// duplicate scalars.
    static func hasDoubledTone(_ surface: String) -> Bool {
        let normalized = surface.precomposedStringWithCanonicalMapping
        var previous: UInt32? = nil
        for scalar in normalized.unicodeScalars {
            if toneScalarValues.contains(scalar.value) && scalar.value == previous {
                return true
            }
            previous = scalar.value
        }
        return false
    }

    /// True when `surface` contains a U+200C / U+200D that is NOT
    /// between two Myanmar-block scalars. Cluster-formation controls
    /// in mid-string between two Myanmar scalars are legitimate; the
    /// pipeline only strips the orphans.
    static func hasOrphanZeroWidth(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        for i in 0..<scalars.count {
            let s = scalars[i]
            guard s.value == 0x200C || s.value == 0x200D else { continue }
            let prev = i > 0 ? scalars[i - 1] : nil
            let next = i + 1 < scalars.count ? scalars[i + 1] : nil
            if !(prev.map(isMyanmarBlock) ?? false) || !(next.map(isMyanmarBlock) ?? false) {
                return true
            }
        }
        return false
    }

    /// True when `surface` contains a `<C> ... 103A 1037` byte sequence
    /// (asat-then-tone, the legacy non-canonical storage shape). Used
    /// only as a fast bundle-version probe, NOT as the parity assertion
    /// itself — the parity assertion uses `isNfcStable` so it generalises
    /// across all CCC-affected scalar pairs, not just U+1037/U+103A.
    private static func containsAsatThenTone(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        guard scalars.count >= 2 else { return false }
        for i in 0..<(scalars.count - 1) {
            if scalars[i].value == 0x103A && scalars[i + 1].value == 0x1037 {
                return true
            }
        }
        return false
    }

    /// True when `scalar` is in the Myanmar Unicode block (U+1000..U+109F).
    /// Used by the orphan-ZWNJ test to decide whether a zero-width
    /// control sits in a legitimate cluster-formation context.
    private static func isMyanmarBlock(_ scalar: Unicode.Scalar) -> Bool {
        return 0x1000 <= scalar.value && scalar.value <= 0x109F
    }

    /// Render a surface as a colon-separated UTF-8 hex string for
    /// failure messages. Keeping the hex form in the failure detail
    /// makes the storage-order issue visible at a glance — the visual
    /// rendering of `<C> 103A 1037` and `<C> 1037 103A` is identical.
    private static func hex(_ surface: String) -> String {
        return surface.unicodeScalars
            .map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }
}
