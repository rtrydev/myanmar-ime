import Foundation
import BurmeseIMECore

/// Per-engine state held on the Swift side of the FFI. The C shell sees
/// only an opaque `burmese_engine_t*` (a UInt64 handle ID bit-cast into
/// a pointer). This indirection means a use-after-free on the C side
/// reads a stale ID and returns nil instead of dereferencing freed
/// Swift memory.
final class FFIEngineHandle: @unchecked Sendable {

    /// Mutable so `reconcile_settings` can rebuild the engine when
    /// `clusterAliasesEnabled` flips — `SyllableParser` bakes that flag
    /// at init time, so the only honest fix is a fresh `BurmeseEngine`.
    var engine: BurmeseEngine

    /// Process-local mirror of the IME settings. The C shell drives
    /// this via per-key setters wired to GSettings `changed::*`
    /// signals; the engine reads through `IMESettings` accessors.
    let settings: IMESettings

    let lexiconPath: String?
    let lmPath: String?
    let historyPath: String?

    var state: CompositionState
    let lock = NSLock()

    init(
        engine: BurmeseEngine,
        settings: IMESettings,
        lexiconPath: String?,
        lmPath: String?,
        historyPath: String?
    ) {
        self.engine = engine
        self.settings = settings
        self.lexiconPath = lexiconPath
        self.lmPath = lmPath
        self.historyPath = historyPath
        self.state = CompositionState()
    }
}

final class HandleRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var nextId: UInt64 = 1
    private var map: [UInt64: FFIEngineHandle] = [:]

    func register(_ h: FFIEngineHandle) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextId
        nextId += 1
        map[id] = h
        return id
    }

    func lookup(_ id: UInt64) -> FFIEngineHandle? {
        lock.lock()
        defer { lock.unlock() }
        return map[id]
    }

    func remove(_ id: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        map.removeValue(forKey: id)
    }
}

let handleRegistry = HandleRegistry()

/// UInt64 handle ID ↔ opaque C pointer conversion. The pointer is never
/// dereferenced on the C side — it round-trips back through `lookup`.
@inline(__always)
func handlePointer(_ id: UInt64) -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(bitPattern: UInt(id))
}

@inline(__always)
func handleId(_ ptr: UnsafeMutableRawPointer?) -> UInt64? {
    guard let ptr else { return nil }
    return UInt64(UInt(bitPattern: ptr))
}
