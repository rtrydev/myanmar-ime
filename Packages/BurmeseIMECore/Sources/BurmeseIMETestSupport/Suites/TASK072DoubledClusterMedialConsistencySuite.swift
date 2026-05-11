import Foundation
import BurmeseIMECore

/// TASK-072: Oneshot and incremental keystroke paths must agree on
/// the rank-0 surface for any buffer. The corpus rebuild (2026-05-11)
/// shifted ranking margins so that doubled cluster-alias buffers
/// (`kyaungtharkyaungthar`, `kyaungthawkyaungtha`, …) produce a
/// MIXED ya-pin / ya-yit surface from the oneshot path while
/// the incremental path locks in ya-yit / ya-yit.
///
/// Two related symptoms:
///   1. oneshot vs incremental disagreement (IncrementalParitySuite).
///   2. mixed medial within a single oneshot output (the SAME
///      cluster shape inside the same buffer should not flip between
///      ya-pin and ya-yit).
///
/// The fix below targets symptom 2 directly — when a buffer contains
/// two or more occurrences of the same cluster-alias onset (e.g.
/// `kyaung`, `khyin`, `gyaa`, `chu`, …), they should resolve to the
/// same medial. Symptom 1 falls out as a consequence: with consistent
/// medial selection, oneshot and incremental no longer disagree.
public enum TASK072DoubledClusterMedialConsistencySuite {

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

    private static func makeBundledEngine() -> BurmeseEngine? {
        guard let lexPath = BundledArtifacts.lexiconPath,
              let store = SQLiteCandidateStore(path: lexPath),
              let lmPath = BundledArtifacts.trigramLMPath,
              let lm = try? TrigramLanguageModel(path: lmPath) else {
            return nil
        }
        return BurmeseEngine(candidateStore: store, languageModel: lm)
    }

    private static func incrementalTop(_ buffer: String) -> String? {
        guard let engine = makeBundledEngine() else { return nil }
        var top: String?
        for i in 1...buffer.count {
            let prefix = String(buffer.prefix(i))
            let state = engine.update(buffer: prefix, context: [])
            top = state.candidates.first?.surface
        }
        return top
    }

    private static func oneshotTop(_ buffer: String) -> String? {
        guard let engine = makeBundledEngine() else { return nil }
        let state = engine.update(buffer: buffer, context: [])
        return state.candidates.first?.surface
    }

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }
            .joined(separator: " ")
    }

    /// Count occurrences of `medialScalar` (U+103B ya-pin or U+103C
    /// ya-yit) in `surface`. Used to detect mixed-medial surfaces.
    private static func medialOccurrences(_ surface: String, _ scalar: UInt32) -> Int {
        surface.unicodeScalars.filter { $0.value == scalar }.count
    }

    public static let suite: TestSuite = {
        var cases: [TestCase] = []

        // Symptom 2: mixed medial inside a single oneshot output.
        // For a buffer that contains two occurrences of the same
        // cluster-alias onset (e.g. `kyaung`), the rank-0 oneshot
        // surface must NOT mix ya-pin (U+103B) and ya-yit (U+103C).
        // Either both clusters resolve to ya-pin (`ကျောင်`) or
        // both to ya-yit (`ကြောင်`) — never one of each.
        let mixedMedialCases: [(buffer: String, gloss: String)] = [
            ("kyaungtharkyaungthar", "doubled kyaung+thar"),
            ("kyaungthawkyaungtha",  "doubled kyaung+thaw / kyaung+tha"),
        ]
        for c in mixedMedialCases {
            cases.append(TestCase("oneshot_mixedMedialForbidden_\(c.buffer)") { ctx in
                guard let engine = bundledEngine(ctx) else { return }
                let state = engine.update(buffer: c.buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                let yapinCount = medialOccurrences(top, 0x103B)
                let yayitCount = medialOccurrences(top, 0x103C)
                ctx.assertTrue(
                    yapinCount == 0 || yayitCount == 0,
                    c.buffer,
                    detail: "(\(c.gloss)) top='\(top)' (\(hex(top))) has \(yapinCount) ya-pin and \(yayitCount) ya-yit"
                )
            })
        }

        // Symptom 1: oneshot vs incremental must agree on the
        // failing buffers. (Covers
        // `IncrementalParitySuite.incrementalEqualsOneshot_acrossCorpus`
        // for the two known regressions.)
        let parityCases: [String] = [
            "kyaungtharkyaungthar",
            "kyaungthawkyaungtha",
        ]
        for buffer in parityCases {
            cases.append(TestCase("incrementalEqualsOneshot_\(buffer)") { ctx in
                guard makeBundledEngine() != nil else {
                    ctx.assertTrue(true, "skipped_noBundledArtifacts")
                    return
                }
                guard let oneshot = oneshotTop(buffer),
                      let incremental = incrementalTop(buffer) else { return }
                ctx.assertTrue(
                    oneshot == incremental,
                    buffer,
                    detail: "oneshot='\(oneshot)' (\(hex(oneshot))) incremental='\(incremental)' (\(hex(incremental)))"
                )
            })
        }

        // Broader class probe: doubled-cluster-alias buffers with
        // OTHER cluster keys (`khy`/`ghy`/`gy`). These currently pass
        // — the test locks the predicate in so a future regression
        // can't reintroduce the divergence on a different cluster.
        let broaderCases: [String] = [
            "gyaagyaa",       // gy+aa twice (ya-pin/ya-yit symmetric)
            "khyaikhyai",     // khy+ai twice
        ]
        for buffer in broaderCases {
            cases.append(TestCase("broader_mixedMedialForbidden_\(buffer)") { ctx in
                guard let engine = bundledEngine(ctx) else { return }
                let state = engine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                let yapinCount = medialOccurrences(top, 0x103B)
                let yayitCount = medialOccurrences(top, 0x103C)
                ctx.assertTrue(
                    yapinCount == 0 || yayitCount == 0,
                    buffer,
                    detail: "top='\(top)' (\(hex(top))) has \(yapinCount) ya-pin and \(yayitCount) ya-yit"
                )
            })
        }

        return TestSuite(name: "TASK072DoubledClusterMedialConsistency", cases: cases)
    }()
}
