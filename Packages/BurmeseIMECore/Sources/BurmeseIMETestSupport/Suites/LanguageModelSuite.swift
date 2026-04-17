import Foundation
import BurmeseIMECore

public enum LanguageModelSuite {

    private static func writeFixture(_ fixture: LMFixtureBuilder.Fixture) throws -> URL {
        let data = LMFixtureBuilder.build(fixture)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lm_\(UUID().uuidString).bin")
        try data.write(to: url)
        return url
    }

    private static func approxEqual(_ a: Double, _ b: Double, epsilon: Double = 1e-5) -> Bool {
        abs(a - b) < epsilon
    }

    public static let suite = TestSuite(name: "LanguageModel", cases: [

        TestCase("null_returnsConstant") { ctx in
            let lm = NullLanguageModel(constantLogProb: -7.5)
            ctx.assertEqual(lm.logProb(surface: "သာ", context: []), -7.5)
            ctx.assertEqual(lm.logProb(surface: "သာ", context: ["ကို"]), -7.5)
            ctx.assertEqual(lm.logProb(surface: "သာ", context: ["a", "b", "c"]), -7.5)
        },

        TestCase("reader_unigramLookup") { ctx in
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
            do {
                let url = try writeFixture(fixture)
                defer { try? FileManager.default.removeItem(at: url) }
                let lm = try TrigramLanguageModel(path: url.path)
                ctx.assertEqual(lm.vocabSize, 5, "vocabSize")
                ctx.assertEqual(lm.wordId(for: "က"), UInt32(0), "wordId_k")
                ctx.assertEqual(lm.wordId(for: "ကို"), UInt32(1), "wordId_ko")
                ctx.assertTrue(lm.wordId(for: "unknownword") == nil, "wordId_missing")
                ctx.assertTrue(
                    approxEqual(lm.logProb(surface: "က", context: []), -1.0),
                    "unigram_k"
                )
                ctx.assertTrue(
                    approxEqual(lm.logProb(surface: "ကို", context: []), -2.0),
                    "unigram_ko"
                )
                ctx.assertTrue(
                    approxEqual(lm.logProb(surface: "nope", context: []), -5.0),
                    "unigram_unkFallback"
                )
            } catch {
                ctx.fail("reader_unigramLookup", detail: "\(error)")
            }
        },

        TestCase("reader_bigramBacksOffToUnigram") { ctx in
            let fixture = LMFixtureBuilder.Fixture(
                vocab: ["က", "ကို", "<s>", "</s>", "<unk>"],
                bosIndex: 2, eosIndex: 3, unkIndex: 4,
                unigrams: [
                    (0, -1.0, -0.3),
                    (1, -2.0, 0.0),
                    (2, -0.5, -0.2),
                    (4, -5.0, 0.0),
                ],
                bigrams: [
                    (0, 1, -1.5, 0.0),
                ],
                trigrams: []
            )
            do {
                let url = try writeFixture(fixture)
                defer { try? FileManager.default.removeItem(at: url) }
                let lm = try TrigramLanguageModel(path: url.path)
                ctx.assertTrue(
                    approxEqual(lm.logProb(surface: "ကို", context: ["က"]), -1.5),
                    "bigramDirect"
                )
                ctx.assertTrue(
                    approxEqual(lm.logProb(surface: "nope", context: ["<s>"]), -5.0 + -0.2),
                    "bigramBackoff"
                )
            } catch {
                ctx.fail("reader_bigramBacksOffToUnigram", detail: "\(error)")
            }
        },

        TestCase("reader_trigramHitBeatsBackoff") { ctx in
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
                    (0, 1, -1.5, -0.2),
                    (1, 3, -2.3, 0.0),
                ],
                trigrams: [
                    (0, 1, 3, -0.9),
                ]
            )
            do {
                let url = try writeFixture(fixture)
                defer { try? FileManager.default.removeItem(at: url) }
                let lm = try TrigramLanguageModel(path: url.path)
                ctx.assertTrue(
                    approxEqual(
                        lm.logProb(surface: "</s>", context: ["က", "ကို"]),
                        -0.9
                    ),
                    "trigramDirect"
                )
                ctx.assertTrue(
                    approxEqual(
                        lm.logProb(surface: "</s>", context: ["ကို", "ကို"]),
                        -2.3
                    ),
                    "trigramBackoffToBigram"
                )
            } catch {
                ctx.fail("reader_trigramHitBeatsBackoff", detail: "\(error)")
            }
        },

        TestCase("reader_scoreSurface_decomposesMultiWordCandidates") { ctx in
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
            do {
                let url = try writeFixture(fixture)
                defer { try? FileManager.default.removeItem(at: url) }
                let lm = try TrigramLanguageModel(path: url.path)
                let good = lm.scoreSurface("ကျွန်တော်", context: [])
                let bad = lm.scoreSurface("ကျွန်ဈော်", context: [])
                ctx.assertTrue(approxEqual(good, -4.5), "knownWordsSum")
                ctx.assertTrue(bad < good, "unknownPieceScoresLower",
                               detail: "good=\(good) bad=\(bad)")
                ctx.assertTrue(lm.hasVocabulary, "hasVocabulary")
            } catch {
                ctx.fail("reader_scoreSurface", detail: "\(error)")
            }
        },

        TestCase("reader_rejectsBadMagic") { ctx in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("lm_bad_\(UUID().uuidString).bin")
            do {
                try Data(repeating: 0, count: 64).write(to: url)
                defer { try? FileManager.default.removeItem(at: url) }
                do {
                    _ = try TrigramLanguageModel(path: url.path)
                    ctx.fail("rejectsBadMagic", detail: "Expected throw, got success")
                } catch {
                    ctx.assertTrue(true, "threwAsExpected")
                }
            } catch {
                ctx.fail("rejectsBadMagic", detail: "setup failed: \(error)")
            }
        },
    ])
}
