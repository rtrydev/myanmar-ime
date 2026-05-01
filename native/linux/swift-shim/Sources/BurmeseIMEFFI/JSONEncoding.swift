import Foundation
import BurmeseIMECore

/// JSON shape exposed across the FFI. Keeps the C/IBus side free of
/// Swift-specific marshalling: every `update` call returns a
/// self-describing snapshot the C engine can hand to `json-glib` (or
/// any other parser).
struct UpdateSnapshot: Encodable {
    struct CandidateView: Encodable {
        let surface: String
        let reading: String
        let source: String
        let score: Double
    }

    let preedit: String
    let candidates: [CandidateView]
    let selected: Int

    init(state: CompositionState) {
        self.preedit = state.rawBuffer
        self.candidates = state.candidates.map { c in
            let source: String = {
                switch c.source {
                case .grammar: return "grammar"
                case .lexicon: return "lexicon"
                case .history: return "history"
                }
            }()
            return CandidateView(
                surface: c.surface,
                reading: c.reading,
                source: source,
                score: c.score
            )
        }
        self.selected = state.selectedCandidateIndex
    }
}

private let snapshotEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = []
    return e
}()

func encodeSnapshotJSON(_ snapshot: UpdateSnapshot) -> String {
    do {
        let data = try snapshotEncoder.encode(snapshot)
        return String(data: data, encoding: .utf8) ?? "{}"
    } catch {
        return "{}"
    }
}

/// strdup-equivalent that hands a malloc'd `char*` back to C. The C
/// caller frees via `burmese_engine_string_free` (which calls `free`).
/// Returning nil on allocation failure is fine — callers null-check.
func cstringDup(_ s: String) -> UnsafeMutablePointer<CChar>? {
    return s.withCString { src -> UnsafeMutablePointer<CChar>? in
        let len = strlen(src)
        guard let buf = malloc(len + 1) else { return nil }
        memcpy(buf, src, len + 1)
        return buf.assumingMemoryBound(to: CChar.self)
    }
}
