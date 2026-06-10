import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for the TASK-081 follow-up: the attested-surface exemption
/// (`sanitizeMalformedMyanmarMarks(preservedSurfaces:)`) exists for
/// *lexicalized irregular* spellings (`ယောက်ျား`, `ကျွန်ုပ်`), but the
/// shipped lexicon also carries a residue of *encoding-broken* corpus
/// rows — segmentation/typo artifacts that violate Unicode storage
/// order rather than the syllable grammar. An unconditional exemption
/// resurfaced those on exact-reading input, four of them at rank 0:
///
///   - `.ka`    → `့က`   (U+1037 dot-below with no base)
///   - `tang+`  → `တင္`  (dangling U+1039 virama)
///   - `vu.d+`  → `ဗုဒ္`  (dangling U+1039 virama)
///   - `myi.u:` → `မျိူး` (102D+1030 typo cluster for 102D+102F)
///   - `aykya:` → `ေကြး` (U+1031 before any base)
///
/// The rule encoded here: the exemption protects orthography no
/// grammar generates but a dictionary attests; it must never protect
/// shapes no orthography — regular or irregular — can produce. The
/// engine-side gate is `isEncodingInvalidSurface`; the durable fix is
/// corpus_builder-side filtering plus regeneration (tracked as
/// follow-up in TASK-081).
public enum EncodingInvalidLexiconRowContainmentSuite {

    private static func bundledStores(_ ctx: TestContext) -> (SQLiteCandidateStore, TrigramLanguageModel)? {
        guard let lexPath = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lexPath),
              let lmPath = BundledArtifacts.trigramLMPath,
              let lm = try? TrigramLanguageModel(path: lmPath) else {
            ctx.assertTrue(true, "skipped_noBundledArtifacts")
            return nil
        }
        return (store, lm)
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// The leaked readings and their encoding-broken store surfaces.
    private static let leakedRows: [(buffer: String, malformed: String)] = [
        (".ka",    "\u{1037}\u{1000}"),
        ("tang+",  "\u{1010}\u{1004}\u{1039}"),
        ("vu.d+",  "\u{1017}\u{102F}\u{1012}\u{1039}"),
        ("myi.u:", "\u{1019}\u{103B}\u{102D}\u{1030}\u{1038}"),
        ("aykya:", "\u{1031}\u{1000}\u{103C}\u{1038}"),
    ]

    public static let suite = TestSuite(name: "EncodingInvalidLexiconRowContainment", cases: [

        // The predicate flags exactly the four storage-order violation
        // classes…
        TestCase("predicate_flagsEncodingBrokenShapes") { ctx in
            let broken: [(label: String, surface: String)] = [
                ("orphanLeadingDotBelow",  "\u{1037}\u{1000}"),
                ("orphanLeadingVowelSign", "\u{102C}\u{1000}"),
                ("danglingViramaFinal",    "\u{1010}\u{1004}\u{1039}"),
                ("danglingViramaMid",      "\u{1017}\u{102F}\u{1012}\u{1039}"),
                ("eVowelBeforeAnyBase",    "\u{1031}\u{1000}\u{103C}\u{1038}"),
                ("eVowelAfterVowelSign",   "\u{1000}\u{102C}\u{1031}"),
                ("iUuTypoCluster",         "\u{1019}\u{103B}\u{102D}\u{1030}\u{1038}"),
            ]
            for c in broken {
                ctx.assertTrue(
                    BurmeseEngine.isEncodingInvalidSurface(c.surface),
                    c.label,
                    detail: "[\(hex(c.surface))] should be flagged encoding-invalid"
                )
            }
        },

        // …and nothing else: lexicalized irregulars, the legal
        // cross-category chains, kinzi, and symbol particles all pass.
        TestCase("predicate_keepsAttestedAndRegularShapes") { ctx in
            let clean: [(label: String, surface: String)] = [
                ("yaPinAfterAsat",       "ယောက်ျား"),
                ("uVowelAfterAsat",      "ကျွန်ုပ်"),
                ("shCodaLoanword",       "ရှ်"),
                ("legalIoChain",         "ကို"),
                ("eVowelAfterMedial",    "မြေဧက"),
                ("eVowelPlusTallAa",     "ကျောင်း"),
                ("kinziStack",           "မင်္ဂလာ"),
                ("symbolParticle",       "၎င်း"),
                ("plainWord",            "သာ၍"),
            ]
            for c in clean {
                ctx.assertFalse(
                    BurmeseEngine.isEncodingInvalidSurface(c.surface),
                    c.label,
                    detail: "'\(c.surface)' [\(hex(c.surface))] must NOT be flagged"
                )
            }
        },

        // Exact-reading input must not resurface the encoding-broken
        // rows at any rank, and rank 0 must be encoding-clean.
        TestCase("production_leakedRowsStayContained") { ctx in
            guard let (store, lm) = bundledStores(ctx) else { return }
            for c in leakedRows {
                let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
                let candidates = engine.update(buffer: c.buffer, context: []).candidates
                ctx.assertFalse(
                    candidates.contains { $0.surface == c.malformed },
                    "\(c.buffer)_absent",
                    detail: "encoding-broken row '\(c.malformed)' [\(hex(c.malformed))] leaked; panel = \(candidates.map(\.surface))"
                )
                let top = candidates.first?.surface ?? ""
                ctx.assertFalse(
                    BurmeseEngine.isEncodingInvalidSurface(top),
                    "\(c.buffer)_rank0Clean",
                    detail: "rank 0 '\(top)' [\(hex(top))] is encoding-invalid"
                )
            }
        },

        // The containment must not over-filter: the lexicalized
        // irregulars the exemption exists for stay reachable in the
        // top 3 on their exact aliases.
        TestCase("production_lexicalizedIrregularsStayReachable") { ctx in
            guard let (store, lm) = bundledStores(ctx) else { return }
            let attested: [(buffer: String, expected: String)] = [
                ("youtar:",  "ယောက်ျား"),
                ("kwyanote", "ကျွန်ုပ်"),
            ]
            for c in attested {
                let engine = BurmeseEngine(candidateStore: store, languageModel: lm)
                let candidates = engine.update(buffer: c.buffer, context: []).candidates
                let rank = candidates.firstIndex { $0.surface == c.expected }
                ctx.assertTrue(
                    rank != nil && rank! < 3,
                    c.buffer,
                    detail: "expected '\(c.expected)' in top 3; got \(candidates.prefix(5).map(\.surface))"
                )
            }
        },

        // A history entry recorded while a malformed row was reachable
        // must not keep resurrecting it: the encoding-invalid filter
        // applies to the history-attested set too.
        TestCase("production_historyDoesNotResurrectMalformedSurface") { ctx in
            guard let (store, lm) = bundledStores(ctx) else { return }
            let tempPath = NSTemporaryDirectory() + "task081-gap-history-\(UUID().uuidString).sqlite"
            defer { try? FileManager.default.removeItem(atPath: tempPath) }
            guard let history = SQLiteUserHistoryStore(path: tempPath) else {
                ctx.fail("setup", detail: "could not create temp history store")
                return
            }
            let malformed = "\u{1010}\u{1004}\u{1039}" // တင္ (dangling virama)
            history.record(reading: Romanization.aliasReading("tang+"), surface: malformed)
            let engine = BurmeseEngine(
                candidateStore: store,
                historyStore: history,
                languageModel: lm
            )
            let candidates = engine.update(buffer: "tang+", context: []).candidates
            ctx.assertFalse(
                candidates.contains { $0.surface == malformed },
                "historyContainment",
                detail: "history resurfaced encoding-broken 'တင္'; panel = \(candidates.map(\.surface))"
            )
        },
    ])
}
