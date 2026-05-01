import Foundation
import BurmeseIMECore

// All `@_cdecl` exports listed here mirror the signatures in
// `native/linux/ibus-engine/src/ffi.h`. Keep the two in sync — the C
// compiler catches drift via link errors at engine-binary build time.

@inline(__always)
private func cstr(_ p: UnsafePointer<CChar>?) -> String? {
    guard let p else { return nil }
    return String(cString: p)
}

@inline(__always)
private func cstrOrEmpty(_ p: UnsafePointer<CChar>?) -> String {
    cstr(p) ?? ""
}

// MARK: - Engine lifecycle

@_cdecl("burmese_engine_new")
public func burmese_engine_new(
    _ lexiconPath: UnsafePointer<CChar>?,
    _ lmPath: UnsafePointer<CChar>?,
    _ historyPath: UnsafePointer<CChar>?,
    _ settingsSuiteName: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    let lexicon: any CandidateStore
    if let p = cstr(lexiconPath), !p.isEmpty,
       let store = SQLiteCandidateStore(path: p) {
        lexicon = store
    } else {
        lexicon = EmptyCandidateStore()
    }

    let history: any UserHistoryStore
    if let p = cstr(historyPath), !p.isEmpty {
        let parent = (p as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try? FileManager.default.createDirectory(
                atPath: parent, withIntermediateDirectories: true
            )
        }
        history = SQLiteUserHistoryStore(path: p) ?? EmptyUserHistoryStore()
    } else {
        history = EmptyUserHistoryStore()
    }

    let lm: any LanguageModel
    if let p = cstr(lmPath), !p.isEmpty,
       let trigram = try? TrigramLanguageModel(path: p) {
        lm = trigram
    } else {
        lm = NullLanguageModel()
    }

    let suiteName = cstr(settingsSuiteName)
    let settings = IMESettings(suiteName: suiteName)

    let engine = BurmeseEngine(
        candidateStore: lexicon,
        historyStore: history,
        languageModel: lm,
        settings: settings
    )

    let handle = FFIEngineHandle(
        engine: engine,
        settings: settings,
        lexiconPath: cstr(lexiconPath),
        lmPath: cstr(lmPath),
        historyPath: cstr(historyPath)
    )
    let id = handleRegistry.register(handle)
    return handlePointer(id)
}

@_cdecl("burmese_engine_free")
public func burmese_engine_free(_ ptr: UnsafeMutableRawPointer?) {
    guard let id = handleId(ptr) else { return }
    handleRegistry.remove(id)
}

// MARK: - Composition

@_cdecl("burmese_engine_update")
public func burmese_engine_update(
    _ ptr: UnsafeMutableRawPointer?,
    _ rawBuffer: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else {
        return cstringDup("{}")
    }
    let buffer = cstrOrEmpty(rawBuffer)
    h.lock.lock()
    defer { h.lock.unlock() }
    h.state = h.engine.update(buffer: buffer, context: h.state.committedContext)
    return cstringDup(encodeSnapshotJSON(UpdateSnapshot(state: h.state)))
}

@_cdecl("burmese_engine_commit")
public func burmese_engine_commit(
    _ ptr: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>? {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else {
        return cstringDup("")
    }
    h.lock.lock()
    defer { h.lock.unlock() }
    let surface = h.engine.commit(state: h.state)
    h.engine.recordSelection(state: h.state)
    h.state = CompositionState(committedContext: h.state.committedContext)
    return cstringDup(surface)
}

@_cdecl("burmese_engine_record_selection")
public func burmese_engine_record_selection(_ ptr: UnsafeMutableRawPointer?) {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else { return }
    h.lock.lock()
    defer { h.lock.unlock() }
    h.engine.recordSelection(state: h.state)
}

@_cdecl("burmese_engine_set_selected")
public func burmese_engine_set_selected(
    _ ptr: UnsafeMutableRawPointer?,
    _ idx: Int32
) {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else { return }
    h.lock.lock()
    defer { h.lock.unlock() }
    let i = Int(idx)
    guard i >= 0, i < h.state.candidates.count else { return }
    h.state.selectedCandidateIndex = i
}

@_cdecl("burmese_engine_cancel")
public func burmese_engine_cancel(
    _ ptr: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>? {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else {
        return cstringDup("")
    }
    h.lock.lock()
    defer { h.lock.unlock() }
    let raw = h.engine.cancel(state: h.state)
    h.state = CompositionState(committedContext: h.state.committedContext)
    return cstringDup(raw)
}

@_cdecl("burmese_engine_push_committed_context")
public func burmese_engine_push_committed_context(
    _ ptr: UnsafeMutableRawPointer?,
    _ surface: UnsafePointer<CChar>?
) {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else { return }
    let s = cstrOrEmpty(surface)
    guard !s.isEmpty else { return }
    h.lock.lock()
    defer { h.lock.unlock() }
    var context = h.state.committedContext
    context.append(s)
    // Cap to last 4 entries — engine + punctuation mapper only need the
    // tail. Mirrors the macOS `BurmeseInputController` ring buffer size.
    if context.count > 4 {
        context.removeFirst(context.count - 4)
    }
    h.state.committedContext = context
}

@_cdecl("burmese_engine_clear_committed_context")
public func burmese_engine_clear_committed_context(_ ptr: UnsafeMutableRawPointer?) {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else { return }
    h.lock.lock()
    defer { h.lock.unlock() }
    h.state.committedContext = []
}

// MARK: - Settings (per-key setters; called from GSettings change handlers)

@_cdecl("burmese_engine_set_candidate_page_size")
public func burmese_engine_set_candidate_page_size(
    _ ptr: UnsafeMutableRawPointer?,
    _ value: Int32
) {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else { return }
    h.settings.candidatePageSize = Int(value)
}

@_cdecl("burmese_engine_set_commit_on_space")
public func burmese_engine_set_commit_on_space(
    _ ptr: UnsafeMutableRawPointer?,
    _ value: Int32
) {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else { return }
    h.settings.commitOnSpace = (value != 0)
}

@_cdecl("burmese_engine_set_cluster_aliases_enabled")
public func burmese_engine_set_cluster_aliases_enabled(
    _ ptr: UnsafeMutableRawPointer?,
    _ value: Int32
) {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else { return }
    let newValue = (value != 0)
    let oldValue = h.settings.clusterAliasesEnabled
    h.settings.clusterAliasesEnabled = newValue
    if newValue != oldValue {
        rebuildEngine(h)
    }
}

@_cdecl("burmese_engine_set_lm_prune_margin")
public func burmese_engine_set_lm_prune_margin(
    _ ptr: UnsafeMutableRawPointer?,
    _ value: Double
) {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else { return }
    h.settings.lmPruneMargin = value
}

@_cdecl("burmese_engine_set_anchor_commit_threshold")
public func burmese_engine_set_anchor_commit_threshold(
    _ ptr: UnsafeMutableRawPointer?,
    _ value: Int32
) {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else { return }
    h.settings.anchorCommitThreshold = Int(value)
}

@_cdecl("burmese_engine_set_burmese_punctuation_enabled")
public func burmese_engine_set_burmese_punctuation_enabled(
    _ ptr: UnsafeMutableRawPointer?,
    _ value: Int32
) {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else { return }
    h.settings.burmesePunctuationEnabled = (value != 0)
}

@_cdecl("burmese_engine_set_number_measure_words_enabled")
public func burmese_engine_set_number_measure_words_enabled(
    _ ptr: UnsafeMutableRawPointer?,
    _ value: Int32
) {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else { return }
    h.settings.numberMeasureWordsEnabled = (value != 0)
}

@_cdecl("burmese_engine_set_learning_enabled")
public func burmese_engine_set_learning_enabled(
    _ ptr: UnsafeMutableRawPointer?,
    _ value: Int32
) {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else { return }
    h.settings.learningEnabled = (value != 0)
}

@_cdecl("burmese_engine_reconcile_settings")
public func burmese_engine_reconcile_settings(_ ptr: UnsafeMutableRawPointer?) {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else { return }
    rebuildEngine(h)
}

private func rebuildEngine(_ h: FFIEngineHandle) {
    h.lock.lock()
    defer { h.lock.unlock() }
    let lexicon: any CandidateStore = {
        if let p = h.lexiconPath, let store = SQLiteCandidateStore(path: p) {
            return store
        }
        return EmptyCandidateStore()
    }()
    let history: any UserHistoryStore = {
        if let p = h.historyPath, let store = SQLiteUserHistoryStore(path: p) {
            return store
        }
        return EmptyUserHistoryStore()
    }()
    let lm: any LanguageModel = {
        if let p = h.lmPath, let model = try? TrigramLanguageModel(path: p) {
            return model
        }
        return NullLanguageModel()
    }()
    h.engine = BurmeseEngine(
        candidateStore: lexicon,
        historyStore: history,
        languageModel: lm,
        settings: h.settings
    )
    h.state = CompositionState()
}

// MARK: - Punctuation auto-mapping

/// Empty-buffer case: when the user types a mappable ASCII punctuation
/// character (`. ! ? , ;`) directly after a Myanmar surface, return the
/// Myanmar replacement. Returns NULL when the policy doesn't apply
/// (settings off, buffer non-empty, prior context not Myanmar, char not
/// mappable). Caller frees with `burmese_engine_string_free`.
///
/// Mirrors the empty-buffer branch in `BurmeseInputController.swift:178`
/// so the C side doesn't need to duplicate the rule table.
@_cdecl("burmese_engine_map_empty_buffer_punctuation")
public func burmese_engine_map_empty_buffer_punctuation(
    _ ptr: UnsafeMutableRawPointer?,
    _ asciiChar: Int32
) -> UnsafeMutablePointer<CChar>? {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else { return nil }
    h.lock.lock()
    defer { h.lock.unlock() }
    guard h.settings.burmesePunctuationEnabled else { return nil }
    guard !h.state.isActive else { return nil }
    guard let scalar = Unicode.Scalar(Int(asciiChar)) else { return nil }
    let ch = Character(scalar)
    guard let mapped = PunctuationMapper.mapped(ch) else { return nil }
    let lastContext = h.state.committedContext.last ?? ""
    guard PunctuationMapper.isMyanmar(lastContext) else { return nil }
    return cstringDup(mapped)
}

// MARK: - Diagnostics / utility

@_cdecl("burmese_engine_diagnostics")
public func burmese_engine_diagnostics(
    _ ptr: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>? {
    guard let id = handleId(ptr), let h = handleRegistry.lookup(id) else {
        return cstringDup("{}")
    }
    var lines: [String] = []
    lines.append("\"version\":\"\(BurmeseIMEFFIVersion)\"")
    func fileSize(_ path: String?) -> Int64 {
        guard let path, !path.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }
    lines.append("\"lexicon_path\":\(jsonString(h.lexiconPath ?? ""))")
    lines.append("\"lexicon_bytes\":\(fileSize(h.lexiconPath))")
    lines.append("\"lm_path\":\(jsonString(h.lmPath ?? ""))")
    lines.append("\"lm_bytes\":\(fileSize(h.lmPath))")
    lines.append("\"history_path\":\(jsonString(h.historyPath ?? ""))")
    lines.append("\"history_bytes\":\(fileSize(h.historyPath))")
    return cstringDup("{" + lines.joined(separator: ",") + "}")
}

@_cdecl("burmese_engine_reverse_romanize")
public func burmese_engine_reverse_romanize(
    _ myanmarUtf8: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    let input = cstrOrEmpty(myanmarUtf8)
    let result = ReverseRomanizer.romanize(input)
    return cstringDup(result)
}

@_cdecl("burmese_engine_string_free")
public func burmese_engine_string_free(_ ptr: UnsafeMutablePointer<CChar>?) {
    guard let ptr else { return }
    free(ptr)
}

// MARK: - Helpers

private let BurmeseIMEFFIVersion = "0.1.0"

private func jsonString(_ s: String) -> String {
    do {
        let data = try JSONSerialization.data(withJSONObject: [s])
        let str = String(data: data, encoding: .utf8) ?? "[\"\"]"
        // Strip surrounding `[` and `]` to get just the quoted scalar.
        return String(str.dropFirst().dropLast())
    } catch {
        return "\"\""
    }
}
