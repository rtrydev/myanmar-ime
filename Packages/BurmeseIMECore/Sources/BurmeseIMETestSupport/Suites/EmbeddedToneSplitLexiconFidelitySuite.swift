import Foundation
import BurmeseIMECore

/// TASK-078: the embedded composing-punct split
/// (`splitAtLastEmbeddedComposingPunct`) used to freeze a parser-only
/// prefix and return early, skipping the whole-buffer lexicon /
/// history evidence entirely. Confirmed failure modes pinned here:
///
/// 1. The visible prefix flipped to the parser-canonical sibling on
///    the keystroke after the split fired (`kyaung:` rendered
///    `ကျောင်း`, then `kyaung:a` flipped the prefix to `ကြောင်းအ`),
///    and every completion candidate inherited the wrong prefix.
/// 2. Exact alias-index hits for the full reading (`myar:ar:` →
///    `များအား`, `sany*:sar:` → `စဉ်းစား`, `ng*:ka` → `၎င်းက`,
///    `ng*:to.` → `၎င်းတို့`, all penalty-0 rows in the shipped
///    lexicon) were unreachable at any rank.
/// 3. ဉ်/ည်-coda readings rendered raw ASCII `*:` wedged between
///    Myanmar scalars at rank 0 (`sany*:sar:` → `စန်ယ*:စား`).
/// 4. History was written under the full-buffer alias but read under
///    the active-suffix alias, so a committed selection was never
///    promoted on re-typing.
///
/// Control: `to.ei` → `တို့၏` is served by the same split branch and
/// was already correct — the fix must not regress it.
public enum EmbeddedToneSplitLexiconFidelitySuite {

    // MARK: Surfaces (scalar-escaped so editors/fonts can't reorder)

    /// ကျောင်း (school — ya-pin form, corpus-dominant for `kyaung:`)
    private static let kyaung =
        "\u{1000}\u{103B}\u{1031}\u{102C}\u{1004}\u{103A}\u{1038}"
    /// ကြောင်း (ya-yit sibling, parser-canonical)
    private static let kraung =
        "\u{1000}\u{103C}\u{1031}\u{102C}\u{1004}\u{103A}\u{1038}"
    /// အကြောင်း
    private static let akraung = "\u{1021}" + kraung
    /// ကျောင်းအကြောင်း (about the school)
    private static let kyaungAkraung = kyaung + akraung
    /// များ (plural marker — ya-pin, corpus-dominant for `myar:`)
    private static let myarPlural =
        "\u{1019}\u{103B}\u{102C}\u{1038}"
    /// မြား (arrow — ya-yit sibling)
    private static let myarArrow =
        "\u{1019}\u{103C}\u{102C}\u{1038}"
    /// အား
    private static let ar = "\u{1021}\u{102C}\u{1038}"
    /// များအား (exact penalty-0 alias row for `myar:ar:`)
    private static let myarAr = myarPlural + ar
    /// မြားအား (fabricated pre-fix rank 0)
    private static let myarArrowAr = myarArrow + ar
    /// စဉ်းစား (to think — exact alias row for `sany*:sar:`)
    private static let sanySar =
        "\u{1005}\u{1009}\u{103A}\u{1038}\u{1005}\u{102C}\u{1038}"
    /// ၎င်းက (exact alias row for `ng*:ka`)
    private static let laGaungKa =
        "\u{104E}\u{1004}\u{103A}\u{1038}\u{1000}"
    /// ၎င်းတို့ (exact alias row for `ng*:to.`)
    private static let laGaungTo =
        "\u{104E}\u{1004}\u{103A}\u{1038}\u{1010}\u{102D}\u{102F}\u{1037}"
    /// တို့၏ (control — already correct via the split branch)
    private static let toEi =
        "\u{1010}\u{102D}\u{102F}\u{1037}\u{104F}"

    // MARK: Helpers

    private static func bundledStores(
        _ ctx: TestContext
    ) -> (SQLiteCandidateStore, TrigramLanguageModel)? {
        guard let lexPath = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lexPath),
              let lmPath = BundledArtifacts.trigramLMPath,
              let lm = try? TrigramLanguageModel(path: lmPath) else {
            ctx.assertTrue(true, "skipped_noBundledArtifacts")
            return nil
        }
        return (store, lm)
    }

    private static func bundledEngine(_ ctx: TestContext) -> BurmeseEngine? {
        guard let (store, lm) = bundledStores(ctx) else { return nil }
        return BurmeseEngine(candidateStore: store, languageModel: lm)
    }

    private static func makeHistoryStore() -> (SQLiteUserHistoryStore, URL)? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "EmbeddedToneSplitHistory-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let path = dir.appendingPathComponent("UserHistory.sqlite").path
        guard let store = SQLiteUserHistoryStore(path: path) else { return nil }
        return (store, dir)
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    private static func startsWithScalars(_ surface: String, _ prefix: String) -> Bool {
        let h = Array(surface.unicodeScalars)
        let n = Array(prefix.unicodeScalars)
        guard h.count >= n.count else { return false }
        for i in 0..<n.count where h[i] != n[i] { return false }
        return true
    }

    private static func containsAsciiScalar(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value < 0x80 }
    }

    private static func containsMyanmarScalar(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value >= 0x1000 && $0.value <= 0x109F }
    }

    private static func describe(_ candidates: [Candidate]) -> String {
        candidates.prefix(12).enumerated()
            .map { "[\($0)] \($1.surface) (\(hex($1.surface))) src=\($1.source)" }
            .joined(separator: ", ")
    }

    public static let suite = TestSuite(name: "EmbeddedToneSplitLexiconFidelity", cases: [

        // Failure mode 1: the visible prefix must not flip to the
        // ya-yit sibling once the split fires. Progressive typing of
        // `kyaung:akyaung:` keeps rank 0 anchored on `ကျောင်း` from
        // the `kyaung:` keystroke onward.
        TestCase("prefixStable_kyaungColon_progressive") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let buffer = "kyaung:akyaung:"
            for i in 1...buffer.count {
                let prefix = String(buffer.prefix(i))
                let state = engine.update(buffer: prefix, context: [])
                let top = state.candidates.first?.surface ?? ""
                guard i >= "kyaung:".count else { continue }
                ctx.assertTrue(
                    startsWithScalars(top, kyaung),
                    "rank0PrefixStable.\(prefix)",
                    detail: "top='\(top)' (\(hex(top))) does not start with ကျောင်း (\(hex(kyaung)))"
                )
            }
            // Final panel: the composed target is reachable.
            let final = engine.update(buffer: buffer, context: [])
            ctx.assertTrue(
                final.candidates.contains { $0.surface == kyaungAkraung },
                "finalPanelContains_kyaungAkraung",
                detail: describe(final.candidates)
            )
            // One more keystroke makes the whole two-word reading the
            // frozen prefix of a NESTED split (`kyaung:akyaung:` +
            // `a`). The nested prefix render must stay evidence-
            // aligned all the way down.
            let nested = engine.update(buffer: buffer + "a", context: [])
            let nestedTop = nested.candidates.first?.surface ?? ""
            ctx.assertTrue(
                startsWithScalars(nestedTop, kyaungAkraung),
                "nestedPrefixStable_kyaungAkyaungA",
                detail: "top='\(nestedTop)' (\(hex(nestedTop))) does not start with ကျောင်းအကြောင်း"
            )
        },

        // Same buffer one-shot (no incremental state): the prefix must
        // come out lexicon/LM-preferred without any anchor history.
        TestCase("prefixStable_kyaungColon_oneShot") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "kyaung:akyaung:", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertTrue(
                startsWithScalars(top, kyaung),
                "rank0StartsWithKyaung",
                detail: "top='\(top)' (\(hex(top)))"
            )
            ctx.assertTrue(
                state.candidates.contains { $0.surface == kyaungAkraung },
                "panelContains_kyaungAkraung",
                detail: describe(state.candidates)
            )
        },

        // Failure mode 1 (completion shape): every Myanmar candidate
        // for `kyaung:a` carries the lexicon/LM-preferred prefix; the
        // pre-fix behavior fabricated `ကြောင်းအ…` completions.
        TestCase("completionsInheritLexiconPrefix_kyaungA") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "kyaung:a", context: [])
            for cand in state.candidates where containsMyanmarScalar(cand.surface) {
                ctx.assertTrue(
                    startsWithScalars(cand.surface, kyaung),
                    "candidatePrefix.\(cand.surface)",
                    detail: "'\(cand.surface)' (\(hex(cand.surface))) does not start with ကျောင်း"
                )
            }
        },

        // Failure mode 2: exact penalty-0 alias hit for the complete
        // reading must reach the panel, top 3 preferred. Pre-fix the
        // whole panel was `မြားအား…` fabrications.
        TestCase("exactAliasHit_myarAr_topThree") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "myar:ar:", context: [])
            let top3 = state.candidates.prefix(3).map(\.surface)
            ctx.assertTrue(
                top3.contains(myarAr),
                "myarAr_inTopThree",
                detail: describe(state.candidates)
            )
            // Completion candidates must carry the dominant rendering
            // of the prefix reading — no `မြားအား<completion>` rows
            // while `များအား` is the dominant rendering of `myar:ar:`.
            for cand in state.candidates {
                ctx.assertFalse(
                    startsWithScalars(cand.surface, myarArrowAr),
                    "noFabricatedArrowCompletion.\(cand.surface)",
                    detail: "'\(cand.surface)' (\(hex(cand.surface))) starts with မြားအား"
                )
            }
        },

        // Failure modes 2+3: digit-stripped ဉ-coda alias. Exact hit
        // `စဉ်းစား` must be reachable (top 3) and rank 0 must not wedge
        // raw ASCII `*`/`:` between Myanmar scalars.
        TestCase("exactAliasHit_sanyAsatSar_topThree") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "sany*:sar:", context: [])
            let top3 = state.candidates.prefix(3).map(\.surface)
            ctx.assertTrue(
                top3.contains(sanySar),
                "sanySar_inTopThree",
                detail: describe(state.candidates)
            )
            let top = state.candidates.first?.surface ?? ""
            ctx.assertTrue(
                containsMyanmarScalar(top) && !containsAsciiScalar(top),
                "rankZeroIsCleanMyanmar",
                detail: "top='\(top)' (\(hex(top)))"
            )
        },

        // Failure mode 2: ၎င်း compounds typed via the mid-buffer `*:`
        // asat-visarga alias.
        TestCase("exactAliasHit_laGaung_topThree") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            for (buffer, expected) in [("ng*:ka", laGaungKa), ("ng*:to.", laGaungTo)] {
                let state = engine.update(buffer: buffer, context: [])
                let top3 = state.candidates.prefix(3).map(\.surface)
                ctx.assertTrue(
                    top3.contains(expected),
                    "\(buffer)_inTopThree",
                    detail: "expected '\(expected)' (\(hex(expected))) in \(describe(state.candidates))"
                )
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    containsMyanmarScalar(top) && !containsAsciiScalar(top),
                    "\(buffer)_rankZeroIsCleanMyanmar",
                    detail: "top='\(top)' (\(hex(top)))"
                )
            }
        },

        // Non-regression control: `to.ei` is served by this same split
        // branch (open dot + vowel-led `ei`) and is correct today. The
        // fix must keep `တို့၏` at rank 0.
        TestCase("control_toEi_rankZero") { ctx in
            guard let engine = bundledEngine(ctx) else { return }
            let state = engine.update(buffer: "to.ei", context: [])
            let top = state.candidates.first?.surface ?? ""
            ctx.assertTrue(
                top == toEi,
                "toEi_rankZero",
                detail: "top='\(top)' (\(hex(top))) expected '\(toEi)' (\(hex(toEi))) — panel \(describe(state.candidates))"
            )
        },

        // Failure mode 4 (write side): committing a selection for a
        // split-branch buffer must store it under the full-buffer
        // alias. This already worked pre-fix (the branch overwrites
        // `lastHistoryKey`); kept as a round-trip guard.
        TestCase("history_writeKeyedOnFullAlias_myarAr") { ctx in
            guard let (store, lm) = bundledStores(ctx) else { return }
            guard let (history, dir) = makeHistoryStore() else {
                ctx.fail("setup", detail: "cannot open temp history store")
                return
            }
            defer { try? FileManager.default.removeItem(at: dir) }
            let engine = BurmeseEngine(
                candidateStore: store,
                historyStore: history,
                languageModel: lm
            )
            let state = engine.update(buffer: "myar:ar:", context: [])
            guard !state.candidates.isEmpty else {
                ctx.fail("setup", detail: "empty panel for myar:ar:")
                return
            }
            engine.recordSelection(state: state)
            let entries = history.listAll()
            ctx.assertTrue(
                entries.contains { $0.reading == "myar:ar:" },
                "storedUnderFullAlias",
                detail: "entries=\(entries.map { "\($0.reading)→\($0.surface)" })"
            )
        },

        // Failure mode 4 (read side): a surface previously committed
        // under the full-buffer alias must be promoted when the same
        // buffer is typed again. Pre-fix the branch only consulted
        // history for the active suffix (`ar:`), never `myar:ar:`.
        TestCase("history_promotedOnRetype_myarAr") { ctx in
            guard let (store, lm) = bundledStores(ctx) else { return }
            guard let (history, dir) = makeHistoryStore() else {
                ctx.fail("setup", detail: "cannot open temp history store")
                return
            }
            defer { try? FileManager.default.removeItem(at: dir) }
            // Simulate an earlier commit of the ya-yit sibling — a
            // surface the post-fix panel does not otherwise contain,
            // so promotion is unambiguously history-driven.
            history.record(reading: "myar:ar:", surface: myarArrowAr)
            let engine = BurmeseEngine(
                candidateStore: store,
                historyStore: history,
                languageModel: lm
            )
            let state = engine.update(buffer: "myar:ar:", context: [])
            let top = state.candidates.first
            ctx.assertTrue(
                top?.surface == myarArrowAr && top?.source == .history,
                "historySurfaceAtRankZero",
                detail: describe(state.candidates)
            )
            // The exact lexicon hit stays reachable right below.
            let top3 = state.candidates.prefix(3).map(\.surface)
            ctx.assertTrue(
                top3.contains(myarAr),
                "exactHitStillTopThree",
                detail: describe(state.candidates)
            )
        },
    ])
}
