import XCTest
@testable import BurmeseIMECore

/// Tests for the LanguageModel protocol and the TrigramLanguageModel reader.
///
/// The fixture is built in-process via `LMFixtureBuilder` (below) so the
/// tests do not depend on the Python pipeline. The builder emits bytes
/// matching the format documented in
/// `Sources/BurmeseIMECore/LanguageModel/FORMAT.md`; any divergence here
/// also breaks parity with the Python writer.
final class LanguageModelTests: XCTestCase {

    // MARK: - NullLanguageModel

    func testNull_returnsConstant() {
        let lm = NullLanguageModel(constantLogProb: -7.5)
        XCTAssertEqual(lm.logProb(surface: "သာ", context: []), -7.5)
        XCTAssertEqual(lm.logProb(surface: "သာ", context: ["ကို"]), -7.5)
        XCTAssertEqual(lm.logProb(surface: "သာ", context: ["a", "b", "c"]), -7.5)
    }

    // MARK: - Binary format round-trip

    private func writeFixture(_ fixture: LMFixtureBuilder.Fixture) throws -> URL {
        let data = LMFixtureBuilder.build(fixture)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lm_\(UUID().uuidString).bin")
        try data.write(to: url)
        return url
    }

    func testReader_unigramLookup() throws {
        // vocab: ["က", "ကို", "<s>", "</s>", "<unk>"]
        // unigrams: က = -1.0, ကို = -2.0, <unk> = -5.0
        let fixture = LMFixtureBuilder.Fixture(
            vocab: ["က", "ကို", "<s>", "</s>", "<unk>"],
            bosIndex: 2, eosIndex: 3, unkIndex: 4,
            unigrams: [
                (0, -1.0, 0.0),
                (1, -2.0, 0.0),
                (4, -5.0, 0.0),
            ],
            bigrams: [],
            trigrams: []
        )
        let url = try writeFixture(fixture)
        defer { try? FileManager.default.removeItem(at: url) }

        let lm = try TrigramLanguageModel(path: url.path)
        XCTAssertEqual(lm.vocabSize, 5)
        XCTAssertEqual(lm.wordId(for: "က"), 0)
        XCTAssertEqual(lm.wordId(for: "ကို"), 1)
        XCTAssertNil(lm.wordId(for: "unknownword"))

        XCTAssertEqual(lm.logProb(surface: "က", context: []), -1.0, accuracy: 1e-5)
        XCTAssertEqual(lm.logProb(surface: "ကို", context: []), -2.0, accuracy: 1e-5)
        // Missing → <unk>
        XCTAssertEqual(lm.logProb(surface: "nope", context: []), -5.0, accuracy: 1e-5)
    }

    func testReader_bigramBacksOffToUnigram() throws {
        // <s> က ကို → bigram(က→ကို) = -1.5; bigram(<s>→unknown) backs off
        // to unigram(unknown)+bigram<s>backoff.
        let fixture = LMFixtureBuilder.Fixture(
            vocab: ["က", "ကို", "<s>", "</s>", "<unk>"],
            bosIndex: 2, eosIndex: 3, unkIndex: 4,
            unigrams: [
                (0, -1.0, -0.3),  // က with backoff weight
                (1, -2.0, 0.0),
                (2, -0.5, -0.2),  // <s> with backoff
                (4, -5.0, 0.0),
            ],
            bigrams: [
                (0, 1, -1.5, 0.0),  // က ကို
            ],
            trigrams: []
        )
        let url = try writeFixture(fixture)
        defer { try? FileManager.default.removeItem(at: url) }

        let lm = try TrigramLanguageModel(path: url.path)
        // Direct bigram hit
        XCTAssertEqual(lm.logProb(surface: "ကို", context: ["က"]), -1.5, accuracy: 1e-5)
        // Miss → backoff: unigram(<unk>) + backoff(<s>)
        XCTAssertEqual(
            lm.logProb(surface: "nope", context: ["<s>"]),
            -5.0 + -0.2,
            accuracy: 1e-5
        )
    }

    func testReader_trigramHitBeatsBackoff() throws {
        // (က, ကို, </s>) has a direct trigram score; reader must pick it
        // over any bigram fallback.
        let fixture = LMFixtureBuilder.Fixture(
            vocab: ["က", "ကို", "<s>", "</s>", "<unk>"],
            bosIndex: 2, eosIndex: 3, unkIndex: 4,
            unigrams: [
                (0, -1.0, 0.0),
                (1, -2.0, -0.1),
                (3, -1.2, 0.0),
                (4, -5.0, 0.0),
            ],
            bigrams: [
                (0, 1, -1.5, -0.2),   // က ကို
                (1, 3, -2.3, 0.0),    // ကို </s> (would be the fallback)
            ],
            trigrams: [
                (0, 1, 3, -0.9),      // က ကို </s>
            ]
        )
        let url = try writeFixture(fixture)
        defer { try? FileManager.default.removeItem(at: url) }

        let lm = try TrigramLanguageModel(path: url.path)
        XCTAssertEqual(
            lm.logProb(surface: "</s>", context: ["က", "ကို"]),
            -0.9,
            accuracy: 1e-5
        )
        // Missing trigram → backoff through bigram(ကို,</s>) + trigram-ctx backoff
        XCTAssertEqual(
            lm.logProb(surface: "</s>", context: ["ကို", "ကို"]),
            // trigram(ကို,ကို,</s>) missing → bigramScore(ကို, </s>) + backoff(bigram(ကို,ကို))
            // bigram(ကို,ကို) missing so trigram backoff = 0
            // bigramScore(ကို,</s>) hits bigram → -2.3
            -2.3,
            accuracy: 1e-5
        )
    }

    /// Multi-word surfaces decompose against vocab. A surface composed
    /// entirely of known words must outrank a surface whose middle piece
    /// is unknown — otherwise both collapse to `<unk>` and the engine's
    /// tiebreaker picks an arbitrary (often wrong) candidate, which is
    /// the bug that motivated `scoreSurface`.
    func testReader_scoreSurface_decomposesMultiWordCandidates() throws {
        // Vocab: ကျွန် (id 0), တော် (id 1), ဈော် not present.
        let fixture = LMFixtureBuilder.Fixture(
            vocab: ["ကျွန်", "တော်", "<s>", "</s>", "<unk>"],
            bosIndex: 2, eosIndex: 3, unkIndex: 4,
            unigrams: [
                (0, -2.0, 0.0),
                (1, -2.5, 0.0),
                (4, -12.0, 0.0),
            ],
            bigrams: [],
            trigrams: []
        )
        let url = try writeFixture(fixture)
        defer { try? FileManager.default.removeItem(at: url) }

        let lm = try TrigramLanguageModel(path: url.path)
        let good = lm.scoreSurface("ကျွန်တော်", context: [])
        let bad = lm.scoreSurface("ကျွန်ဈော်", context: [])
        // Good = -2.0 + -2.5 = -4.5; bad falls through unk for the second piece.
        XCTAssertEqual(good, -4.5, accuracy: 1e-5)
        XCTAssertLessThan(bad, good)
        XCTAssertTrue(lm.hasVocabulary)
    }

    func testReader_rejectsBadMagic() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lm_bad_\(UUID().uuidString).bin")
        try Data(repeating: 0, count: 64).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try TrigramLanguageModel(path: url.path))
    }
}

// MARK: - In-process fixture builder

/// Emits a `BurmeseLM.bin` byte stream matching FORMAT.md. Mirrors what the
/// Python builder will emit; kept in Swift-test scope so reader tests are
/// self-contained.
enum LMFixtureBuilder {

    struct Fixture {
        var vocab: [String]
        var bosIndex: Int
        var eosIndex: Int
        var unkIndex: Int
        /// (word_id, log_prob, backoff)
        var unigrams: [(UInt32, Float, Float)]
        /// (w1, w2, log_prob, backoff)
        var bigrams: [(UInt32, UInt32, Float, Float)]
        /// (w1, w2, w3, log_prob)
        var trigrams: [(UInt32, UInt32, UInt32, Float)]
    }

    static func build(_ fx: Fixture) -> Data {
        var out = Data()

        // Header
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

        // Surface blob — concat in id order, record offsets+lengths
        var offsets: [(offset: UInt32, length: UInt32)] = []
        var blob = Data()
        for surface in fx.vocab {
            let bytes = Array(surface.utf8)
            offsets.append((UInt32(blob.count), UInt32(bytes.count)))
            blob.append(contentsOf: bytes)
        }
        out.append(blob)

        // ID index (by id)
        for (off, len) in offsets {
            appendU32(&out, off)
            appendU32(&out, len)
        }

        // Surface-sorted table (ids sorted by their surface bytes)
        let sortedIds: [UInt32] = (0..<fx.vocab.count)
            .sorted { fx.vocab[$0].utf8.lexicographicallyPrecedes(fx.vocab[$1].utf8) }
            .map { UInt32($0) }
        for id in sortedIds {
            appendU32(&out, id)
        }

        // Unigram records — sort by word_id
        let unigramSorted = fx.unigrams.sorted { $0.0 < $1.0 }
        for (id, lp, bo) in unigramSorted {
            appendU32(&out, id)
            appendF32(&out, lp)
            appendF32(&out, bo)
            appendU32(&out, 0)  // _pad
        }

        // Bigram records — sort by (w1, w2)
        let bigramSorted = fx.bigrams.sorted {
            ($0.0, $0.1) < ($1.0, $1.1)
        }
        for (w1, w2, lp, bo) in bigramSorted {
            appendU32(&out, w1)
            appendU32(&out, w2)
            appendF32(&out, lp)
            appendF32(&out, bo)
        }

        // Trigram records — sort by (w1, w2, w3)
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
