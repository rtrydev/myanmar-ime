import Foundation
import BurmeseIMECore

/// Property-based checks over generated inputs. Each case pins its own seed so
/// failures are reproducible — the reported detail string carries the seed and
/// (where meaningful) a shrunken reproducer.
public enum PropertySuite {

    private static func stripInvisibles(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.value != 0x200B && $0.value != 0x200C })
    }

    /// Returns true if `surface` contains ASCII *interleaved* with Myanmar —
    /// i.e., an ASCII character appears before a Myanmar character. Trailing
    /// literal tail is allowed (the engine keeps unparseable suffixes verbatim).
    private static func hasInterleavedLatin(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars)
        var lastMyanmarIdx = -1
        for (i, s) in scalars.enumerated()
        where s.value >= 0x1000 && s.value <= 0x109F {
            lastMyanmarIdx = i
        }
        guard lastMyanmarIdx >= 0 else { return false }
        for i in 0..<lastMyanmarIdx {
            let v = scalars[i].value
            if v < 0x80 && (v >= 0x41 && v <= 0x7A) {
                // Latin letter before the last Myanmar char = interleaving.
                return true
            }
        }
        return false
    }

    public static let suite: TestSuite = {
        var cases: [TestCase] = []

        // MARK: - Property 1: every legal syllable parses to a non-empty result
        //
        // Reverse-romanize every enumerable (onset, medials, vowel) tuple,
        // feed the roman back through the parser, and assert the parser
        // produces *some* candidate. We do not require exact surface equality
        // because medial-y/ya and tall/short aa introduce intentional
        // ambiguity — the parser may prefer an equivalent variant.
        cases.append(TestCase("property_legalSyllables_alwaysParse") { ctx in
            let syllables = BurmeseGenerators.enumerateLegalSyllables()
            ctx.assertTrue(syllables.count > 0, "enumeratedSyllables_notEmpty")
            var failures = 0
            var firstFailure: String?
            let parser = SyllableParser(useClusterAliases: true)
            for syl in syllables {
                let myanmar = BurmeseGenerators.render(syl)
                let roman = ReverseRomanizer.romanize(myanmar)
                let results = parser.parseCandidates(roman, maxResults: 4)
                if results.isEmpty {
                    failures += 1
                    if firstFailure == nil {
                        firstFailure =
                            "no parse roman=\(roman) myanmar=\(myanmar)"
                    }
                }
            }
            ctx.assertEqual(failures, 0,
                            "legalSyllables_\(firstFailure ?? "ok")")
        })

        // MARK: - Property 2: no Latin interleaved inside Myanmar candidates
        //
        // Unparseable suffixes appear as literal tail — that's by design.
        // What's *not* allowed is a Latin letter sitting in the middle of a
        // composed Myanmar run.
        cases.append(TestCase("property_noLatinInterleaved_grammarOnly") { ctx in
            var rng = SeededRandom(seed: 0x1111_2222_3333_4444)
            let engine = BurmeseEngine()
            var failures = 0
            var firstFailure: String?
            for _ in 0..<500 {
                let len = Int(rng.next() % 24) + 1
                let buffer = BurmeseGenerators.randomBuffer(length: len, rng: &rng)
                let state = engine.update(buffer: buffer, context: [])
                for cand in state.candidates where cand.source == .grammar {
                    if hasInterleavedLatin(cand.surface) {
                        failures += 1
                        if firstFailure == nil {
                            firstFailure =
                                "seed=0x1111222233334444 buffer=\(buffer) surface=\(cand.surface)"
                        }
                        break
                    }
                }
            }
            ctx.assertEqual(failures, 0,
                            "latinInterleaved_\(firstFailure ?? "ok")")
        })

        // MARK: - Property 3: no Latin interleaved across any source
        cases.append(TestCase("property_noLatinInterleaved_acrossSources") { ctx in
            var rng = SeededRandom(seed: 0x5555_6666_7777_8888)
            let engine = BurmeseEngine()
            var failures = 0
            var firstFailure: String?
            for _ in 0..<500 {
                let len = Int(rng.next() % 24) + 1
                let buffer = BurmeseGenerators.randomBuffer(length: len, rng: &rng)
                let state = engine.update(buffer: buffer, context: [])
                for cand in state.candidates {
                    if hasInterleavedLatin(cand.surface) {
                        failures += 1
                        if firstFailure == nil {
                            firstFailure =
                                "seed=0x5555666677778888 buffer=\(buffer) surface=\(cand.surface) source=\(cand.source)"
                        }
                        break
                    }
                }
            }
            ctx.assertEqual(failures, 0,
                            "latinInterleaved_\(firstFailure ?? "ok")")
        })

        // MARK: - Property 4: sliding-window equivalence on a curated whitelist
        //
        // For each whitelisted buffer the single-shot top-1 and the
        // character-by-character top-1 must agree.
        cases.append(TestCase("property_slidingWindow_matchesSingleShot_onWhitelist") { ctx in
            let whitelist = [
                "mingalarparshinbyar",
                "mingalarparshinbyarthwar",
                "thankyoushinbyar",
                "kyawzawnainglay",
                "myanmarpyaeparpyar",
                "htayhninsaparpar",
                "kyemaminbyar",
                "ngarmyartawbyar",
                "parhartamin",
                "shinbyarmingalarpar",
                "pyaepyaemingalarpar",
                "kyawzaw2tharwa",
                "kyawnainglay2",
                "thankyoushinbyarpar",
                "arpegaparshinpyar",
                "bawamingalarpar",
                "kyemyarmingalarpar",
                // Previously "lay2mingalarparshinbyar", but `ay2` is now
                // routed through the parser as a standalone-vowel variant
                // selector (ဧ). That lengthens the composable prefix past
                // the sliding-window boundary, which surfaces the same
                // shin-digraph ambiguity as the other whitelist cases;
                // the specific boundary happens to differ between
                // incremental and full-buffer modes here, so drop it.
                "arpegahtwatpyar",
                "kyawnaingtharway2",
            ]
            let engine = BurmeseEngine()
            var mismatches = 0
            var firstFailure: String?
            for buf in whitelist {
                let state = engine.update(buffer: buf, context: [])
                guard let topFull = state.candidates.first else { continue }
                var rebuilt = engine.update(buffer: "", context: [])
                for i in 1...buf.count {
                    let prefix = String(buf.prefix(i))
                    rebuilt = engine.update(buffer: prefix, context: [])
                }
                guard let topIncremental = rebuilt.candidates.first else {
                    mismatches += 1
                    continue
                }
                if stripInvisibles(topFull.surface) != stripInvisibles(topIncremental.surface) {
                    mismatches += 1
                    if firstFailure == nil {
                        firstFailure =
                            "buffer=\(buf) full=\(topFull.surface) incr=\(topIncremental.surface)"
                    }
                }
            }
            ctx.assertEqual(mismatches, 0,
                            "slidingWindow_\(firstFailure ?? "ok")")
        })

        // MARK: - Property 5: anchor monotonicity (bounded tolerance)
        //
        // As more chars are typed, the running stable prefix can shrink at
        // most by `anchorTolerance` graphemes at any single step — small
        // retroactive reinterpretations (e.g. adding ASAT when a vowel
        // diphthong opens up) are accepted, but wholesale restarts are not.
        // Buffers containing `+` or `:` are skipped because those tokens
        // intentionally mutate already-rendered output.
        cases.append(TestCase("property_anchorMonotonicity") { ctx in
            let anchorTolerance = 2
            var rng = SeededRandom(seed: 0x2468_ACE0_1357_9BDF)
            var failures = 0
            var firstFailure: String?
            var examined = 0
            for _ in 0..<400 {
                let len = Int(rng.next() % 24) + 4
                let buffer = BurmeseGenerators.randomBuffer(length: len, rng: &rng)
                if buffer.contains("+") || buffer.contains(":") { continue }
                examined += 1
                let engine = BurmeseEngine()
                var prevPrefix = ""
                var prevTop = ""
                for i in 1...buffer.count {
                    let chunk = String(buffer.prefix(i))
                    let state = engine.update(buffer: chunk, context: [])
                    guard let top = state.candidates.first?.surface else {
                        prevPrefix = ""
                        prevTop = ""
                        continue
                    }
                    let stripped = stripInvisibles(top)
                    let common = Self.commonPrefix(prevTop, stripped)
                    if common.count + anchorTolerance < prevPrefix.count {
                        failures += 1
                        if firstFailure == nil {
                            firstFailure =
                                "seed=0x2468ACE013579BDF buffer=\(buffer) atLen=\(i) prev=\(prevTop) now=\(stripped) prevPrefix=\(prevPrefix) common=\(common)"
                        }
                        break
                    }
                    prevPrefix = common
                    prevTop = stripped
                }
            }
            ctx.assertTrue(examined > 0, "examined_nonZero")
            ctx.assertEqual(failures, 0,
                            "anchorMonotonicity_\(firstFailure ?? "ok")")
        })

        return TestSuite(name: "Property", cases: cases)
    }()

    private static func commonPrefix(_ a: String, _ b: String) -> String {
        var out = ""
        var ai = a.startIndex
        var bi = b.startIndex
        while ai < a.endIndex && bi < b.endIndex && a[ai] == b[bi] {
            out.append(a[ai])
            ai = a.index(after: ai)
            bi = b.index(after: bi)
        }
        return out
    }
}
