import Foundation

/// A trigram language model backed by an mmap'd `BurmeseLM.bin` file.
///
/// Binary layout is documented in `FORMAT.md` next to this file. The hot
/// path is allocation-free: `logProb` resolves surfaces to `UInt32` ids via
/// binary search over the surface-sorted vocab table, then binary-searches
/// the fixed-width n-gram arrays.
public final class TrigramLanguageModel: LanguageModel, @unchecked Sendable {

    private struct Header {
        static let byteSize = 48
        static let magic: [UInt8] = Array("BURMLM01".utf8)
        static let supportedVersion: UInt32 = 1

        let version: UInt32
        let order: UInt32
        let nVocab: UInt32
        let nUnigram: UInt32
        let nBigram: UInt32
        let nTrigram: UInt32
        let idBos: UInt32
        let idEos: UInt32
        let idUnk: UInt32
    }

    private struct Layout {
        let blobOffset: Int
        let blobSize: Int
        let idIndexOffset: Int         // (u32 offset, u32 length) per id
        let surfaceSortedOffset: Int   // u32 id, sorted by referenced surface
        let unigramOffset: Int
        let bigramOffset: Int
        let trigramOffset: Int
    }

    public enum LoadError: Error {
        case fileNotFound
        case tooSmall
        case badMagic
        case unsupportedVersion(UInt32)
        case unsupportedOrder(UInt32)
        case truncated
    }

    public static let recordSize = 16
    private static let idIndexEntrySize = 8
    private static let surfaceSortedEntrySize = 4

    private let data: Data
    private let header: Header
    private let layout: Layout

    // Cached base pointer into the (mmapped) `data` blob. The Data is
    // initialized with `.mappedIfSafe` and stored as `private let`, so
    // its backing memory is stable for the LM's lifetime. Grabbing the
    // baseAddress once at init avoids reopening `withUnsafeBytes` on
    // every primitive read — the n-gram binary searches do thousands of
    // 4-byte reads per `decode()` call and the per-call bridging cost
    // dominates the actual byte access. `data` is retained as a `let`
    // so the mmap stays alive for the pointer's lifetime.
    private let basePtr: UnsafePointer<UInt8>

    // Surface → wordId resolution memo. `logProb` is called thousands of
    // times per keystroke from the lattice's Viterbi inner loop, and the
    // same surfaces (`ပါ`, `ဖြစ်`, `တယ်`) get re-resolved every time
    // because each call drops back into the 17-step binary search over
    // the 80k vocab. A bounded per-engine cache collapses each repeat to
    // a dictionary hit. Bounded eviction matches the candidate-store
    // pattern: drop the oldest 25% rather than wiping the whole map.
    private var idCache: [String: UInt32] = [:]
    private var idCacheOrder: [String] = []
    private let idCacheLock = NSLock()
    private static let idCacheCapacity = 8192
    private static let idCacheEvictBatch = 2048

    public init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw LoadError.fileNotFound
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe, .uncached])
        guard data.count >= Header.byteSize else {
            throw LoadError.tooSmall
        }

        let magicBytes = data.prefix(8)
        guard Array(magicBytes) == Header.magic else {
            throw LoadError.badMagic
        }

        let version: UInt32 = Self.readU32(data, at: 8)
        guard version == Header.supportedVersion else {
            throw LoadError.unsupportedVersion(version)
        }
        let order: UInt32 = Self.readU32(data, at: 12)
        guard order == 3 else {
            throw LoadError.unsupportedOrder(order)
        }

        let header = Header(
            version: version,
            order: order,
            nVocab: Self.readU32(data, at: 16),
            nUnigram: Self.readU32(data, at: 20),
            nBigram: Self.readU32(data, at: 24),
            nTrigram: Self.readU32(data, at: 28),
            idBos: Self.readU32(data, at: 32),
            idEos: Self.readU32(data, at: 36),
            idUnk: Self.readU32(data, at: 40)
        )

        // Blob length is inferred: total length minus everything that
        // follows. To avoid a forward-declaration chicken/egg, we scan the
        // id-index to compute the blob size. The builder writes the blob
        // immediately after the header, so its start is fixed.
        let blobOffset = Header.byteSize
        let idIndexSize = Int(header.nVocab) * Self.idIndexEntrySize
        let surfaceSortedSize = Int(header.nVocab) * Self.surfaceSortedEntrySize
        let unigramSize = Int(header.nUnigram) * Self.recordSize
        let bigramSize = Int(header.nBigram) * Self.recordSize
        let trigramSize = Int(header.nTrigram) * Self.recordSize
        let tail = idIndexSize + surfaceSortedSize + unigramSize + bigramSize + trigramSize
        guard data.count >= Header.byteSize + tail else {
            throw LoadError.truncated
        }
        let blobSize = data.count - Header.byteSize - tail
        guard blobSize >= 0 else { throw LoadError.truncated }

        let idIndexOffset = blobOffset + blobSize
        let surfaceSortedOffset = idIndexOffset + idIndexSize
        let unigramOffset = surfaceSortedOffset + surfaceSortedSize
        let bigramOffset = unigramOffset + unigramSize
        let trigramOffset = bigramOffset + bigramSize

        self.data = data
        self.header = header
        self.layout = Layout(
            blobOffset: blobOffset,
            blobSize: blobSize,
            idIndexOffset: idIndexOffset,
            surfaceSortedOffset: surfaceSortedOffset,
            unigramOffset: unigramOffset,
            bigramOffset: bigramOffset,
            trigramOffset: trigramOffset
        )
        // Pin a base pointer to the (mmapped) buffer. We hold `data` for
        // the LM's lifetime, so the underlying mmap pages stay resident
        // and the pointer remains valid. Safer than the alternative of
        // re-entering `withUnsafeBytes` per byte read because there is
        // no possible re-entrance: the LM is a read-only view, and the
        // value-type Data cannot be mutated through any path that
        // wouldn't also drop `self`.
        self.basePtr = data.withUnsafeBytes { raw in
            raw.bindMemory(to: UInt8.self).baseAddress!
        }
    }

    // MARK: - LanguageModel

    public func logProb(surface: String, context: [String]) -> Double {
        let wordId = resolveId(surface)
        switch context.count {
        case 0:
            return unigramLogProb(wordId)
        case 1:
            let c1 = resolveId(context[0])
            return bigramScore(w1: c1, w2: wordId)
        default:
            let c1 = resolveId(context[context.count - 2])
            let c2 = resolveId(context[context.count - 1])
            return trigramScore(w1: c1, w2: c2, w3: wordId)
        }
    }

    public var hasVocabulary: Bool { true }

    public var unknownLogProb: Double { unigramLogProb(header.idUnk) }

    public func containsSurface(_ surface: String) -> Bool {
        lookupSurface(surface) != nil
    }

    /// Greedy longest-match decomposition of `surface` against the
    /// vocabulary, summing per-word contextual log-probs. When a prefix
    /// of the remaining surface is in vocab, it's scored given the
    /// running history; otherwise a single character is consumed and
    /// charged the `<unk>` unigram log-prob so partial unknowns cost
    /// roughly the same as a complete unknown word.
    public func scoreSurface(_ surface: String, context: [String]) -> Double {
        guard !surface.isEmpty else { return 0.0 }
        let chars = Array(surface)
        var i = 0
        var score = 0.0
        var rolling = context
        let unkPenalty = unigramLogProb(header.idUnk)
        while i < chars.count {
            var matchLen = 0
            // Longest-match against vocab. Upper bound is arbitrary but
            // covers the longest compound entries we expect (~20 chars).
            let maxSpan = min(chars.count - i, 24)
            for span in stride(from: maxSpan, through: 1, by: -1) {
                let candidate = String(chars[i..<(i + span)])
                if lookupSurface(candidate) != nil {
                    score += logProb(surface: candidate, context: rolling)
                    rolling.append(candidate)
                    matchLen = span
                    break
                }
            }
            if matchLen == 0 {
                // Unknown character — advance one and charge <unk>.
                score += unkPenalty
                rolling.append(String(chars[i]))
                i += 1
            } else {
                i += matchLen
            }
        }
        return score
    }

    // MARK: - Public introspection (tests)

    public var bosId: UInt32 { header.idBos }
    public var eosId: UInt32 { header.idEos }
    public var unkId: UInt32 { header.idUnk }
    public var vocabSize: UInt32 { header.nVocab }

    public func wordId(for surface: String) -> UInt32? {
        lookupSurface(surface)
    }

    public func surface(for id: UInt32) -> String? {
        guard id < header.nVocab else { return nil }
        let (offset, length) = idIndexEntry(id)
        guard offset + length <= layout.blobSize else { return nil }
        let start = layout.blobOffset + Int(offset)
        let end = start + Int(length)
        return String(data: data.subdata(in: start..<end), encoding: .utf8)
    }

    // MARK: - ID resolution

    private func resolveId(_ surface: String) -> UInt32 {
        idCacheLock.lock()
        if let hit = idCache[surface] {
            idCacheLock.unlock()
            return hit
        }
        idCacheLock.unlock()

        let resolved = lookupSurface(surface) ?? header.idUnk

        idCacheLock.lock()
        if idCache[surface] == nil {
            if idCache.count >= Self.idCacheCapacity {
                let drop = min(Self.idCacheEvictBatch, idCacheOrder.count)
                for key in idCacheOrder.prefix(drop) {
                    idCache.removeValue(forKey: key)
                }
                idCacheOrder.removeFirst(drop)
            }
            idCache[surface] = resolved
            idCacheOrder.append(surface)
        }
        idCacheLock.unlock()
        return resolved
    }

    /// Binary search over the surface-sorted table. Each entry is a `u32`
    /// id; we compare against the referenced surface bytes in the blob.
    private func lookupSurface(_ surface: String) -> UInt32? {
        guard header.nVocab > 0 else { return nil }
        let needle = Array(surface.utf8)
        var lo = 0
        var hi = Int(header.nVocab)
        while lo < hi {
            let mid = (lo + hi) >> 1
            let id = readU32At(layout.surfaceSortedOffset + mid * Self.surfaceSortedEntrySize)
            let cmp = compareToSurface(needle: needle, id: id)
            if cmp == 0 {
                return id
            } else if cmp < 0 {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        return nil
    }

    /// Returns negative if needle < id's surface, zero if equal, positive if greater.
    private func compareToSurface(needle: [UInt8], id: UInt32) -> Int {
        let (offset, length) = idIndexEntry(id)
        let base = basePtr.advanced(by: layout.blobOffset + Int(offset))
        let n = min(needle.count, Int(length))
        for i in 0..<n {
            let a = needle[i]
            let b = base[i]
            if a != b { return Int(a) - Int(b) }
        }
        return needle.count - Int(length)
    }

    private func idIndexEntry(_ id: UInt32) -> (offset: UInt32, length: UInt32) {
        let base = layout.idIndexOffset + Int(id) * Self.idIndexEntrySize
        return (readU32At(base), readU32At(base + 4))
    }

    // MARK: - N-gram lookup

    private func unigramLogProb(_ w: UInt32) -> Double {
        guard let record = findUnigram(w) else {
            // Fall back to <unk>
            if w != header.idUnk, let unk = findUnigram(header.idUnk) {
                return Double(unk.logProb)
            }
            return -20.0
        }
        return Double(record.logProb)
    }

    private func bigramScore(w1: UInt32, w2: UInt32) -> Double {
        if let bi = findBigram(w1: w1, w2: w2) {
            return Double(bi.logProb)
        }
        let ctx = findUnigram(w1)
        let backoff = ctx.map { Double($0.backoff) } ?? 0.0
        return unigramLogProb(w2) + backoff
    }

    private func trigramScore(w1: UInt32, w2: UInt32, w3: UInt32) -> Double {
        if let tri = findTrigram(w1: w1, w2: w2, w3: w3) {
            return Double(tri.logProb)
        }
        let ctxBi = findBigram(w1: w1, w2: w2)
        let backoff = ctxBi.map { Double($0.backoff) } ?? 0.0
        return bigramScore(w1: w2, w2: w3) + backoff
    }

    private struct RecordPayload {
        let logProb: Float
        let backoff: Float
    }

    private func findUnigram(_ w: UInt32) -> RecordPayload? {
        let count = Int(header.nUnigram)
        guard count > 0 else { return nil }
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let base = layout.unigramOffset + mid * Self.recordSize
            let wordId = readU32At(base)
            if wordId == w {
                return RecordPayload(
                    logProb: readF32At(base + 4),
                    backoff: readF32At(base + 8)
                )
            } else if wordId < w {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return nil
    }

    private func findBigram(w1: UInt32, w2: UInt32) -> RecordPayload? {
        let count = Int(header.nBigram)
        guard count > 0 else { return nil }
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let base = layout.bigramOffset + mid * Self.recordSize
            let a = readU32At(base)
            let b = readU32At(base + 4)
            if a == w1 && b == w2 {
                return RecordPayload(
                    logProb: readF32At(base + 8),
                    backoff: readF32At(base + 12)
                )
            } else if (a, b) < (w1, w2) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return nil
    }

    private func findTrigram(w1: UInt32, w2: UInt32, w3: UInt32) -> RecordPayload? {
        let count = Int(header.nTrigram)
        guard count > 0 else { return nil }
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let base = layout.trigramOffset + mid * Self.recordSize
            let a = readU32At(base)
            let b = readU32At(base + 4)
            let c = readU32At(base + 8)
            if a == w1 && b == w2 && c == w3 {
                return RecordPayload(
                    logProb: readF32At(base + 12),
                    backoff: 0
                )
            } else if (a, b, c) < (w1, w2, w3) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return nil
    }

    // MARK: - Primitive reads

    // `loadUnaligned` is required because the variable-length blob means
    // the trailing tables (idIndex, surface-sorted, n-grams) are not
    // guaranteed 4-byte aligned in the file. Both x86_64 and arm64 handle
    // unaligned 32-bit loads in hardware without penalty.
    @inline(__always)
    private func readU32At(_ offset: Int) -> UInt32 {
        UnsafeRawPointer(basePtr).loadUnaligned(fromByteOffset: offset, as: UInt32.self)
    }

    @inline(__always)
    private func readF32At(_ offset: Int) -> Float {
        UnsafeRawPointer(basePtr).loadUnaligned(fromByteOffset: offset, as: Float.self)
    }

    private static func readU32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
    }
}
