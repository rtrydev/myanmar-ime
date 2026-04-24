import Foundation
import BurmeseIMECore

public enum ToneVariantMedialConsistencySuite {

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

    private static func firstYapinOrYayitScalar(_ surface: String) -> UInt32? {
        surface.unicodeScalars.first { scalar in
            scalar.value == 0x103B || scalar.value == 0x103C
        }?.value
    }

    public static let suite = TestSuite(name: "ToneVariantMedialConsistency", cases: [
        TestCase("yapinPrimaryToneVariantsKeepBareMedial") { ctx in
            guard let engine = bundledEngine(ctx) else { return }

            for root in BurmeseEngine.yapinPrimaryBareBuffers.sorted() {
                let bareState = engine.update(buffer: root, context: [])
                let bareTop = bareState.candidates.first?.surface ?? ""
                guard let bareMedial = firstYapinOrYayitScalar(bareTop) else {
                    ctx.fail(
                        "\(root).bareMedial",
                        detail: "expected a ya-pin/ya-yit medial in \(bareTop)"
                    )
                    continue
                }

                for tone in ["", ":", "."] {
                    let buffer = root + tone
                    let state = engine.update(buffer: buffer, context: [])
                    let top = state.candidates.first?.surface ?? ""
                    let medial = firstYapinOrYayitScalar(top)
                    let candidates = state.candidates.prefix(6)
                        .map { "\($0.surface)/\($0.reading)" }
                    ctx.assertTrue(
                        medial == bareMedial,
                        "\(buffer).medial",
                        detail: "\(buffer) top \(top) should match bare \(root) top \(bareTop); candidates=\(candidates)"
                    )
                }
            }
        },
    ])
}
