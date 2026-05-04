import Foundation
import BurmeseIMECore

/// Property-based checks over generated inputs. Each case pins its own seed so
/// failures are reproducible — the reported detail string carries the seed and
/// (where meaningful) a shrunken reproducer.
public enum PropertySuite {

    private static func stripInvisibles(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.value != 0x200B && $0.value != 0x200C })
    }

    /// Long buffers for which the single-shot parse and the
    /// character-by-character incremental parse must produce the same
    /// top candidate. Any divergence is a sliding-window regression.
    private static let slidingWindowWhitelist: [String] = [
        "mingalarparshinbyar",
        "mingalarparshinbyarthwar",
        "thankyoushinbyar",
        "myanmarpyaeparpyar",
        "htayhninsaparpar",
        "kyemaminbyar",
        "ngarmyartawbyar",
        "parhartamin",
        "thankyoushinbyarpar",
        "arpegaparshinpyar",
        "bawamingalarpar",
        "kyemyarmingalarpar",
        "arpegahtwatpyar",
        "lay2mingalarparshinbyar",
    ]

    /// Buffers that diverge between single-shot and incremental top-1
    /// for known reasons — kept here so a future engine fix that
    /// converges them surfaces as a test failure (the suite below
    /// asserts they STILL diverge). The remaining entry stems from a
    /// parser-side beam-width quirk (cluster-preference rule for `ky`)
    /// rather than the kinzi-promotion bug, which TASK-001 (the
    /// windowing-aware strict-stack rank-0 promotion) resolved. The
    /// `pyaepyaemingalarpar` and `shinbyarmingalarpar` entries that
    /// previously lived here have been removed and are now expected to
    /// converge — the WindowingKinziPromotionSuite asserts the
    /// converged behaviour.
    private static let slidingWindowKnownDivergent: [String] = [
        // TASK-001: the windowing-aware strict-kinzi rank-0 promotion
        // makes the FULL-buffer pass correctly render kinzi for every
        // `mingalarpar` repetition. The INCREMENTAL pass, however,
        // freezes the prefix at boundary points where the kinzi
        // inference cannot yet fire (the prefix `ming` alone has no
        // stack site to promote), so the second-and-later `mingalarpar`
        // repeats render without kinzi in the frozen-prefix layer.
        // Converging this requires a follow-up that re-renders the
        // frozen prefix with kinzi-promotion as new keystrokes extend
        // the inference window forward. Listed here so that follow-up
        // fix lands as a green test.
        String(repeating: "mingalarpar", count: 3),
        String(repeating: "mingalarpar", count: 5),
    ]

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
        // Upstream `Romanization.normalize` lowercases every buffer
        // before composition, so surfaces can only carry lowercase
        // ASCII letters. Narrowed to 0x61..0x7A (tasks/ 08) — any
        // uppercase leak is now a visible regression rather than a
        // silent miss.
        for i in 0..<lastMyanmarIdx {
            let v = scalars[i].value
            if v >= 0x61 && v <= 0x7A {
                // Latin letter before the last Myanmar char = interleaving.
                return true
            }
        }
        return false
    }

    private static func hasAnchoredMyanmarMarks(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars.map(\.value))
        func isBase(_ v: UInt32) -> Bool {
            (v >= 0x1000 && v <= 0x1021) || v == 0x103F
        }
        func isIndependentVowel(_ v: UInt32) -> Bool {
            v >= 0x1023 && v <= 0x102A
        }
        func isDependentVowel(_ v: UInt32) -> Bool {
            v >= 0x102B && v <= 0x1032
        }
        func isToneMark(_ v: UInt32) -> Bool {
            v >= 0x1036 && v <= 0x1038
        }
        func isMedial(_ v: UInt32) -> Bool {
            v >= 0x103B && v <= 0x103E
        }
        for i in scalars.indices {
            let v = scalars[i]
            guard isDependentVowel(v) || isToneMark(v) || isMedial(v) else {
                continue
            }
            var j = i - 1
            while j >= 0 {
                let w = scalars[j]
                if isBase(w) { break }
                if isToneMark(v), isIndependentVowel(w) { break }
                if w == 0x103A {
                    if isToneMark(v) {
                        j -= 1
                        continue
                    }
                    return false
                }
                if w == 0x1039 || w == 0x200C || isIndependentVowel(w) {
                    return false
                }
                if v == 0x1031 && w == 0x1031 {
                    return false
                }
                if isDependentVowel(w) || isToneMark(w) || isMedial(w) {
                    j -= 1
                    continue
                }
                return false
            }
            if j < 0 { return false }
        }
        return true
    }

    private static func hasAsciiSurfaceScalar(_ surface: String) -> Bool {
        surface.unicodeScalars.contains {
            $0.value >= 0x21 && $0.value <= 0x7E
        }
    }

    /// True iff `surface` contains a `<digit>` (ASCII or Myanmar)
    /// scalar immediately followed by U+103A (asat). The asat needs a
    /// consonant base on its left; digits never serve as one, so this
    /// adjacency is a structural orthography violation.
    private static func surfaceContainsDigitBeforeAsat(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 2 else { return false }
        for i in 1..<scalars.count {
            let prev = scalars[i - 1]
            let isDigit = (prev >= 0x30 && prev <= 0x39)
                || (prev >= 0x1040 && prev <= 0x1049)
            guard isDigit else { continue }
            if scalars[i] == 0x103A { return true }
        }
        return false
    }

    /// True iff `surface` contains a `<digit><1021><103A>` adjacency —
    /// the indirect-via-`အ` shape that TASK-052 targets. The orphan-
    /// mark anchor injector inserts U+1021 to satisfy an asat that has
    /// no consonant base; when the asat sits after a digit the
    /// injection produces this signature cluster (`1*` → `၁အ်`).
    private static func surfaceContainsDigitIndependentAAsat(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 3 else { return false }
        for i in 2..<scalars.count {
            let prev = scalars[i - 2]
            let isDigit = (prev >= 0x30 && prev <= 0x39)
                || (prev >= 0x1040 && prev <= 0x1049)
            guard isDigit else { continue }
            if scalars[i - 1] == 0x1021 && scalars[i] == 0x103A { return true }
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

        // MARK: - Property 4: every dependent sign is anchored
        cases.append(TestCase("property_noOrphanMyanmarMarks_acrossSources") { ctx in
            let engine = BurmeseEngine()
            var rng = SeededRandom(seed: 0x5151_0101_5151_0101)
            let targeted = [
                "nayout", "kayout", "phyayout", "bayaung",
                "nayaw", "kayaw", "payayout", "aungain",
                "aungout", "outain",
            ]
            var buffers = targeted
            for _ in 0..<500 {
                let len = Int(rng.next() % 24) + 1
                buffers.append(BurmeseGenerators.randomBuffer(length: len, rng: &rng))
            }
            var failures = 0
            var firstFailure: String?
            for buffer in buffers {
                let state = engine.update(buffer: buffer, context: [])
                let hasCleanCandidate = state.candidates.contains {
                    !hasAsciiSurfaceScalar($0.surface)
                        && hasAnchoredMyanmarMarks($0.surface)
                }
                guard hasCleanCandidate else { continue }
                for cand in state.candidates {
                    if hasAsciiSurfaceScalar(cand.surface) { continue }
                    if !hasAnchoredMyanmarMarks(cand.surface) {
                        failures += 1
                        if firstFailure == nil {
                            firstFailure =
                                "seed=0x5151010151510101 buffer=\(buffer) surface=\(cand.surface) source=\(cand.source)"
                        }
                        break
                    }
                }
            }
            ctx.assertEqual(failures, 0,
                            "orphanMyanmarMarks_\(firstFailure ?? "ok")")
        })

        // MARK: - Property 4: sliding-window equivalence on a curated whitelist
        //
        // For each whitelisted buffer the single-shot top-1 and the
        // character-by-character top-1 must agree.
        cases.append(TestCase("property_slidingWindow_matchesSingleShot_onWhitelist") { ctx in
            let engine = BurmeseEngine()
            var mismatches = 0
            var firstFailure: String?
            for buf in Self.slidingWindowWhitelist {
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

        // This list should stay empty. It exists only to make any temporary
        // accepted sliding-window divergence visible until that buffer can
        // be promoted to the whitelist above.
        cases.append(TestCase("property_slidingWindow_knownDivergent_staysDivergent") { ctx in
            var stillConverged: [String] = []
            for buf in Self.slidingWindowKnownDivergent {
                // Fresh engines: the anchor / frozen-prefix state from a
                // previous call would otherwise mask divergences that
                // appear only when typing the buffer from scratch.
                let fullEngine = BurmeseEngine()
                let state = fullEngine.update(buffer: buf, context: [])
                guard let topFull = state.candidates.first else { continue }
                let incrEngine = BurmeseEngine()
                var rebuilt = incrEngine.update(buffer: "", context: [])
                for i in 1...buf.count {
                    rebuilt = incrEngine.update(buffer: String(buf.prefix(i)), context: [])
                }
                guard let topIncremental = rebuilt.candidates.first else { continue }
                if stripInvisibles(topFull.surface) == stripInvisibles(topIncremental.surface) {
                    stillConverged.append(buf)
                }
            }
            ctx.assertTrue(stillConverged.isEmpty,
                           "slidingWindow_knownDivergent_drift",
                           detail: "these buffers are no longer divergent and can be " +
                               "promoted to the whitelist: \(stillConverged)")
        })

        // MARK: - Property 4b: no `<digit>(1021)?103A` adjacency in any
        // candidate (TASK-052). Asat requires a consonant base on its
        // left — digits never serve as one. The randomly-generated
        // buffer set used by other property cases never includes
        // digits or `*`, so this case generates its own corpus from
        // an alphabet that DOES include both.
        cases.append(TestCase("property_noDigitBeforeAsat_acrossSources") { ctx in
            var rng = SeededRandom(seed: 0xD162_A5A7_8FAC_5252)
            let engine = BurmeseEngine()
            // Curated reproductions from TASK-052 plus a deterministic
            // random sample drawn from {a-z, 0-9, *, +, :, .}.
            var buffers: [String] = [
                "1*", "1*1", "12*34", "1*2*3", "12*",
                "1*ka", "ka1*", "ka12*", "1*+ka", "1*ka1*",
                "min1*ga", "0*0", "9*9*9", "*1*",
            ]
            let alphabet: [Character] = Array("abcdefghijklmnopqrstuvwxyz0123456789*+:.")
            for _ in 0..<800 {
                let len = Int(rng.next() % 18) + 2
                var chars: [Character] = []
                chars.reserveCapacity(len)
                for _ in 0..<len { chars.append(rng.pick(alphabet)) }
                buffers.append(String(chars))
            }
            var failures = 0
            var firstFailure: String?
            for buffer in buffers {
                let state = engine.update(buffer: buffer, context: [])
                for cand in state.candidates {
                    if surfaceContainsDigitIndependentAAsat(cand.surface)
                        || surfaceContainsDigitBeforeAsat(cand.surface) {
                        failures += 1
                        if firstFailure == nil {
                            firstFailure =
                                "buffer=\(buffer) surface=\(cand.surface) source=\(cand.source)"
                        }
                        break
                    }
                }
            }
            ctx.assertEqual(failures, 0,
                            "digitBeforeAsat_\(firstFailure ?? "ok")")
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
                    // Partial-composition surfaces (Myanmar prefix + literal
                    // ASCII tail, emitted when the right-shrink probe drops
                    // unparseable trailing letters — see task 01) intentionally
                    // re-anchor on a shorter parseable prefix. The anchor
                    // monotonicity guarantee only applies between cleanly-
                    // composed surfaces.
                    if Self.hasAsciiSurfaceScalar(stripped) {
                        prevPrefix = ""
                        prevTop = ""
                        continue
                    }
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
