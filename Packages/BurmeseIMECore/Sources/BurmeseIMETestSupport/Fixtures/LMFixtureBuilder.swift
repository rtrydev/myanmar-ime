import Foundation

/// Emits a `BurmeseLM.bin` byte stream matching `LanguageModel/FORMAT.md`.
/// Mirrors what the Python builder will emit so reader tests stay
/// self-contained (no on-disk fixture required).
public enum LMFixtureBuilder {

    public struct Fixture {
        public var vocab: [String]
        public var bosIndex: Int
        public var eosIndex: Int
        public var unkIndex: Int
        /// (word_id, log_prob, backoff)
        public var unigrams: [(UInt32, Float, Float)]
        /// (w1, w2, log_prob, backoff)
        public var bigrams: [(UInt32, UInt32, Float, Float)]
        /// (w1, w2, w3, log_prob)
        public var trigrams: [(UInt32, UInt32, UInt32, Float)]

        public init(
            vocab: [String],
            bosIndex: Int,
            eosIndex: Int,
            unkIndex: Int,
            unigrams: [(UInt32, Float, Float)],
            bigrams: [(UInt32, UInt32, Float, Float)],
            trigrams: [(UInt32, UInt32, UInt32, Float)]
        ) {
            self.vocab = vocab
            self.bosIndex = bosIndex
            self.eosIndex = eosIndex
            self.unkIndex = unkIndex
            self.unigrams = unigrams
            self.bigrams = bigrams
            self.trigrams = trigrams
        }
    }

    public static func build(_ fx: Fixture) -> Data {
        var out = Data()

        out.append(contentsOf: Array("BURMLM01".utf8))
        appendU32(&out, 1)                      // version
        appendU32(&out, 3)                      // order
        appendU32(&out, UInt32(fx.vocab.count))
        appendU32(&out, UInt32(fx.unigrams.count))
        appendU32(&out, UInt32(fx.bigrams.count))
        appendU32(&out, UInt32(fx.trigrams.count))
        appendU32(&out, UInt32(fx.bosIndex))
        appendU32(&out, UInt32(fx.eosIndex))
        appendU32(&out, UInt32(fx.unkIndex))
        appendU32(&out, 0)                      // reserved

        var offsets: [(offset: UInt32, length: UInt32)] = []
        var blob = Data()
        for surface in fx.vocab {
            let bytes = Array(surface.utf8)
            offsets.append((UInt32(blob.count), UInt32(bytes.count)))
            blob.append(contentsOf: bytes)
        }
        out.append(blob)

        for (off, len) in offsets {
            appendU32(&out, off)
            appendU32(&out, len)
        }

        let sortedIds: [UInt32] = (0..<fx.vocab.count)
            .sorted { fx.vocab[$0].utf8.lexicographicallyPrecedes(fx.vocab[$1].utf8) }
            .map { UInt32($0) }
        for id in sortedIds {
            appendU32(&out, id)
        }

        let unigramSorted = fx.unigrams.sorted { $0.0 < $1.0 }
        for (id, lp, bo) in unigramSorted {
            appendU32(&out, id)
            appendF32(&out, lp)
            appendF32(&out, bo)
            appendU32(&out, 0)
        }

        let bigramSorted = fx.bigrams.sorted {
            ($0.0, $0.1) < ($1.0, $1.1)
        }
        for (w1, w2, lp, bo) in bigramSorted {
            appendU32(&out, w1)
            appendU32(&out, w2)
            appendF32(&out, lp)
            appendF32(&out, bo)
        }

        let trigramSorted = fx.trigrams.sorted {
            ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2)
        }
        for (w1, w2, w3, lp) in trigramSorted {
            appendU32(&out, w1)
            appendU32(&out, w2)
            appendU32(&out, w3)
            appendF32(&out, lp)
        }

        return out
    }

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendF32(_ data: inout Data, _ value: Float) {
        var v = value.bitPattern.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}
