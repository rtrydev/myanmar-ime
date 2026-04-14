/// Standalone test runner for BurmeseIMECore.
/// Runs without Xcode/XCTest — usable with Command Line Tools only.

import Foundation
import BurmeseIMECore
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - Test Infrastructure

nonisolated(unsafe) var totalTests = 0
nonisolated(unsafe) var passedTests = 0
nonisolated(unsafe) var failedTests: [(String, String)] = []

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ name: String) {
    totalTests += 1
    if a == b {
        passedTests += 1
    } else {
        failedTests.append((name, "Expected '\(b)', got '\(a)'"))
    }
}

func assertTrue(_ condition: Bool, _ name: String, detail: String = "") {
    totalTests += 1
    if condition {
        passedTests += 1
    } else {
        failedTests.append((name, detail.isEmpty ? "Condition was false" : detail))
    }
}

func assertFalse(_ condition: Bool, _ name: String, detail: String = "") {
    assertTrue(!condition, name, detail: detail)
}

func assertGreaterThan(_ a: Int, _ b: Int, _ name: String) {
    totalTests += 1
    if a > b {
        passedTests += 1
    } else {
        failedTests.append((name, "Expected \(a) > \(b)"))
    }
}

func escapeUnicode(_ str: String) -> String {
    str.unicodeScalars.map { scalar in
        if scalar.value > 0x7e || scalar.value < 0x20 {
            return "\\u{\(String(scalar.value, radix: 16))}"
        }
        return String(scalar)
    }.joined()
}

// MARK: - Parse Helper

let parser = SyllableParser()
let engine = BurmeseEngine()

func parse(_ input: String) -> String {
    let parses = parser.parse(input)
    return parses.first?.output ?? ""
}

func runTest(_ name: String, _ body: () -> Void) {
    print("  Running: \(name)...", terminator: " ")
    body()
    print("done")
}

// ===================================================================
// ROMANIZATION TESTS
// ===================================================================

print("=== Romanization Tests ===")

runTest("consonantCount") {
    assertEqual(Romanization.consonants.count, 33, "consonantCount")
}

runTest("consonantRoundTrip") {
    let romans = Romanization.consonants.map(\.roman)
    let uniqueRomans = Set(romans)
    assertEqual(romans.count, uniqueRomans.count, "consonantRoundTrip")
}

runTest("consonantLookups") {
    assertEqual(Romanization.romanToConsonant["k"], Myanmar.ka, "consonantLookup_ka")
    assertEqual(Romanization.romanToConsonant["th"], Myanmar.sa, "consonantLookup_tha")
    assertEqual(Romanization.consonantToRoman[Myanmar.ka], "k", "consonantReverse_ka")
}

runTest("vowelKeysSorted") {
    let keys = Romanization.vowelKeysByLength
    assertTrue(keys.count > 0, "vowelKeys_nonEmpty")
    var sorted = true
    for i in 1..<keys.count {
        if keys[i-1].count < keys[i].count { sorted = false; break }
    }
    assertTrue(sorted, "vowelKeysSortedByLength")
}

runTest("vowelLookups") {
    assertEqual(Romanization.romanToVowel["ar"]?.myanmar, "\u{102C}", "vowelLookup_ar")
    assertEqual(Romanization.romanToVowel["+"]?.myanmar, "\u{1039}", "vowelLookup_virama")
}

runTest("normalize") {
    assertEqual(Romanization.normalize("ABC"), "abc", "normalize_lowercase")
    assertEqual(Romanization.normalize("thar2"), "thar", "normalize_stripsDigits")
    assertEqual(Romanization.normalize("min+galar"), "min+galar", "normalize_keepsSpecials")
    assertEqual(Romanization.normalize("hello!@#"), "hello", "normalize_stripsInvalid")
}

runTest("composingChars") {
    for ch: Character in Array("abcdefghijklmnopqrstuvwxyz+*':.") {
        assertTrue(Romanization.composingCharacters.contains(ch),
                   "composingChar_\(ch)", detail: "Missing: \(ch)")
    }
    // Digits are intentionally NOT composing — they always emit as literal text.
    for ch: Character in Array("0123456789") {
        assertFalse(Romanization.composingCharacters.contains(ch),
                    "digitNotComposing_\(ch)", detail: "Digit should not compose: \(ch)")
    }
    for ch: Character in ["!", "@", "#", "$", "%", " "] {
        assertFalse(Romanization.composingCharacters.contains(ch),
                    "nonComposingChar_\(ch)", detail: "Should not be composing: \(ch)")
    }
}

// ===================================================================
// GRAMMAR TESTS
// ===================================================================

print("=== Grammar Tests ===")

runTest("medialLegality") {
    assertTrue(Grammar.canConsonantTakeMedial(Myanmar.ka, Myanmar.medialRa), "medialRa_ka")
    assertTrue(Grammar.canConsonantTakeMedial(Myanmar.ka, Myanmar.medialYa), "medialYa_ka")
    assertTrue(Grammar.canConsonantTakeMedial(Myanmar.ka, Myanmar.medialWa), "medialWa_ka")
    assertTrue(Grammar.canConsonantTakeMedial(Myanmar.ka, Myanmar.medialHa), "medialHa_ka")
    assertFalse(Grammar.canConsonantTakeMedial(Myanmar.nga, Myanmar.medialRa), "medialRa_nga_illegal")
    assertEqual(Grammar.medialCombinations.count, 11, "medialCombinations_count")
}

runTest("syllableValidation") {
    assertGreaterThan(
        Grammar.validateSyllable(onset: Myanmar.ka, medials: [], vowelRoman: "ar"), 0,
        "validate_ka_ar_legal"
    )
    assertGreaterThan(
        Grammar.validateSyllable(onset: nil, medials: [], vowelRoman: "ay2"), 0,
        "validate_standalone_ay2"
    )
    // "ar" without onset is legal but low-priority (10) — dependent vowels
    // can appear standalone with U+200C prefix, but onset+vowel paths are preferred
    let arNoOnset = Grammar.validateSyllable(onset: nil, medials: [], vowelRoman: "ar")
    assertTrue(arNoOnset > 0 && arNoOnset < 100, "validate_noOnset_ar_lowPriority",
               detail: "Expected low positive score, got \(arNoOnset)")
}

// ===================================================================
// ENGINE TESTS
// ===================================================================

print("=== Engine Tests ===")

runTest("emptyBuffer") {
    let state = engine.update(buffer: "", context: [])
    assertFalse(state.isActive, "emptyBuffer_inactive")
    assertTrue(state.candidates.isEmpty, "emptyBuffer_noCandidates")
}

runTest("singleConsonant") {
    let state = engine.update(buffer: "k", context: [])
    assertTrue(state.isActive, "singleConsonant_active")
    assertTrue(!state.candidates.isEmpty, "singleConsonant_hasCandidates")
}

runTest("commit_thar") {
    let state = engine.update(buffer: "thar", context: [])
    let committed = engine.commit(state: state)
    assertEqual(committed, "သာ", "commit_thar")
}

runTest("cancel_thar") {
    let state = engine.update(buffer: "thar", context: [])
    let cancelled = engine.cancel(state: state)
    assertEqual(cancelled, "thar", "cancel_thar")
}

runTest("normalize_uppercase") {
    let state = engine.update(buffer: "THAR", context: [])
    assertEqual(state.rawBuffer, "thar", "normalize_uppercase")
}

runTest("grammarFirst") {
    let state = engine.update(buffer: "thar", context: [])
    if let first = state.candidates.first {
        assertTrue(first.source == .grammar, "candidates_grammarFirst")
    } else {
        assertTrue(false, "candidates_grammarFirst", detail: "No candidates")
    }
}

runTest("maxPageSize") {
    let state = engine.update(buffer: "k", context: [])
    assertTrue(state.candidates.count <= BurmeseEngine.candidatePageSize, "maxPageSize")
}

runTest("preservesTrailingDigits") {
    // Digits are composing characters but are not parseable after a complete
    // syllable — the engine should hold them as a literal tail rather than
    // silently dropping them through the parser's no-match branch.
    let state = engine.update(buffer: "min:123", context: [])
    let committed = engine.commit(state: state)
    assertTrue(committed.hasSuffix("123"), "preservesTrailingDigits_suffix",
               detail: "Expected '123' suffix, got: \(escapeUnicode(committed))")
    assertTrue(committed.hasPrefix("မင်း"), "preservesTrailingDigits_prefix",
               detail: "Expected မင်း prefix, got: \(escapeUnicode(committed))")
}

runTest("candidatesIncludeTrailingDigits") {
    let state = engine.update(buffer: "thar123", context: [])
    assertTrue(!state.candidates.isEmpty, "candidatesIncludeTrailingDigits_nonEmpty")
    var allHaveTail = true
    for candidate in state.candidates where !candidate.surface.hasSuffix("123") {
        allHaveTail = false
    }
    assertTrue(allHaveTail, "candidatesIncludeTrailingDigits_allHaveTail")
}

runTest("preservesNonComposingTail") {
    let state = engine.update(buffer: "thar!", context: [])
    let committed = engine.commit(state: state)
    assertTrue(committed.hasSuffix("!"), "preservesNonComposingTail",
               detail: "Expected '!' suffix, got: \(escapeUnicode(committed))")
}

runTest("preservesMixedDigitAndPunctuationTail") {
    let state = engine.update(buffer: "min:123!", context: [])
    let committed = engine.commit(state: state)
    assertTrue(committed.hasSuffix("123!"), "preservesMixedTail",
               detail: "Expected '123!' suffix, got: \(escapeUnicode(committed))")
}

runTest("thar2_commitsDigitLiteral") {
    // Digits are never consumed as vowel-variant tokens. "thar2" commits as
    // သာ followed by the literal "2".
    let state = engine.update(buffer: "thar2", context: [])
    let committed = engine.commit(state: state)
    assertEqual(committed, "သာ2", "thar2_commitsDigitLiteral")
}

runTest("candidates_aaShapeMatchesDescender") {
    // Grammar filtering: each candidate's aa sign is auto-corrected to
    // match the preceding consonant. Descender onsets (ပ here) take tall
    // ါ (U+102B); non-descender onsets (သ) take short ာ (U+102C). The
    // wrong-shape sibling is never emitted.
    let par = engine.update(buffer: "par", context: [])
    let parHasTall = par.candidates.contains { $0.surface.contains("\u{102B}") }
    let parHasShort = par.candidates.contains { $0.surface.contains("\u{102C}") }
    assertTrue(parHasTall, "candidates_par_tallAa", detail: "Expected ါ variant for ပ onset")
    assertFalse(parHasShort, "candidates_par_noShortAa", detail: "ာ must not appear after ပ")

    let thar = engine.update(buffer: "thar", context: [])
    let tharHasShort = thar.candidates.contains { $0.surface.contains("\u{102C}") }
    let tharHasTall = thar.candidates.contains { $0.surface.contains("\u{102B}") }
    assertTrue(tharHasShort, "candidates_thar_shortAa", detail: "Expected ာ variant for သ onset")
    assertFalse(tharHasTall, "candidates_thar_noTallAa", detail: "ါ must not appear after သ")
}

runTest("grammarFilter_medialHaLongI_rejected") {
    let score = Grammar.validateSyllable(
        onset: Myanmar.ka,
        medials: [Myanmar.medialHa],
        vowelRoman: "i:"
    )
    assertEqual(score, 0, "grammarFilter_medialHaLongI")
}

runTest("grammarFilter_tripleMedialComplexVowel_rejected") {
    let score = Grammar.validateSyllable(
        onset: Myanmar.ka,
        medials: [Myanmar.medialYa, Myanmar.medialWa, Myanmar.medialHa],
        vowelRoman: "aung"
    )
    assertEqual(score, 0, "grammarFilter_tripleMedial")
}

runTest("grammarFilter_palaRetroflexDiphthong_rejected") {
    let score = Grammar.validateSyllable(
        onset: Myanmar.tta,
        medials: [],
        vowelRoman: "ote"
    )
    assertEqual(score, 0, "grammarFilter_palaRetroflex")
}

runTest("standaloneTallAa_splitsAsLiteralTail") {
    // "ar2" without an onset has no legal grammar parse (tall aa requires
    // a descender consonant), so the engine should shrink to "ar" → ာ
    // and emit "2" as a literal tail. The ါ variant remains available as a
    // candidate only when an appropriate onset is present.
    let state = engine.update(buffer: "ar2", context: [])
    let committed = engine.commit(state: state)
    assertTrue(committed.hasSuffix("2"), "ar2_literalTail",
               detail: "Expected '2' suffix, got: \(escapeUnicode(committed))")
    assertFalse(committed.contains("\u{102B}"), "ar2_noTallAa",
                detail: "Expected no ါ (U+102B), got: \(escapeUnicode(committed))")
    assertTrue(committed.contains("\u{102C}"), "ar2_hasShortAa",
               detail: "Expected ာ (U+102C), got: \(escapeUnicode(committed))")
}

runTest("pureUnconvertibleBuffer_commitsRaw") {
    let state = engine.update(buffer: "123", context: [])
    assertTrue(state.isActive, "pureUnconvertibleBuffer_active")
    assertTrue(state.candidates.isEmpty, "pureUnconvertibleBuffer_noCandidates")
    assertEqual(engine.commit(state: state), "123", "pureUnconvertibleBuffer_commit")
}

// ===================================================================
// KNOWN-GOOD FIXTURE TESTS (digit-free scheme)
// ===================================================================

print("=== Known-Good Fixtures ===")

runTest("thar") { assertEqual(parse("thar"), "သာ", "knownGood_thar") }
runTest("kyaw") { assertEqual(parse("kyaw"), "ကြော်", "knownGood_kyaw") }
runTest("min+galarpar") { assertEqual(parse("min+galarpar"), "မင်္ဂလာပာ", "knownGood_minGalarPar") }

// ===================================================================
// CLUSTER-SOUND SHORTCUTS
// ===================================================================

print("=== Cluster-Sound Shortcut Tests ===")

// Ja family (k + ya-pin, optional wa-hswe)
runTest("cluster_j")         { assertEqual(parse("j"),        "ကျ",                "cluster_j") }
runTest("cluster_ja")        { assertEqual(parse("ja"),       "ကျ",                "cluster_ja") }
runTest("cluster_jw")        { assertEqual(parse("jw"),       "ကျွ",               "cluster_jw") }
runTest("cluster_jwantaw")   { assertEqual(parse("jwantaw"),  "ကျွန်တော်",         "cluster_jwantaw") }

// Cha family (kh + ya-pin)
runTest("cluster_ch")        { assertEqual(parse("ch"),       "ချ",                "cluster_ch") }
runTest("cluster_chit")      { assertEqual(parse("chit"),     "ချစ်",              "cluster_chit") }

// Sha family (r + ha-htoe)
runTest("cluster_sha")       { assertEqual(parse("sha"),      "ရှ",                "cluster_sha") }
runTest("cluster_shar")      { assertEqual(parse("shar"),     "ရှာ",               "cluster_shar") }

// Gy exists as a cluster candidate alongside the existing ဂြ reading.
runTest("cluster_gyw_candidate") {
    let outputs = parser.parseCandidates("gyw", maxResults: 4).map(\.output)
    assertTrue(outputs.contains("ဂျွ"), "cluster_gyw_hasJwa",
               detail: "candidates: \(outputs)")
}

// Aspirated sonorants already work via the h-prefix medial scheme.
runTest("aspirated_hnga")    { assertEqual(parse("hnga"),     "ငှ",                "aspirated_hnga") }
runTest("aspirated_hma")     { assertEqual(parse("hma"),      "မှ",                "aspirated_hma") }
runTest("aspirated_hla")     { assertEqual(parse("hla"),      "လှ",                "aspirated_hla") }
runTest("aspirated_hna")     { assertEqual(parse("hna"),      "နှ",                "aspirated_hna") }
runTest("aspirated_hnya")    { assertEqual(parse("hnya"),     "\u{1009}\u{103E}",  "aspirated_hnya") }

// Canonical regression: structural forms still produce the same outputs.
// Digits are stripped by normalize(), so canonical alias keys are digit-free.
runTest("canonical_hr")      { assertEqual(parse("hr"),       "ရှ",                "canonical_hr") }
runTest("canonical_gy_isYaYit") { assertEqual(parse("gy"),    "ဂြ",                "canonical_gy_isYaYit") }
runTest("canonical_kya_isYaYit") { assertEqual(parse("kya"),  "ကြ",                "canonical_kya_isYaYit") }


// ===================================================================
// KNOWN-BAD LEGACY DIVERGENCE TESTS
// ===================================================================

print("=== Known-Bad Legacy Divergence Tests ===")

func checkNoMixedScript(_ input: String, _ name: String) {
    let result = parse(input)
    let hasMyanmarChar = result.unicodeScalars.contains { Myanmar.isMyanmar($0) }
    let hasLatinChar = result.unicodeScalars.contains {
        let v = $0.value
        return (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
    }
    assertFalse(hasMyanmarChar && hasLatinChar, name,
                detail: "Mixed script: \(escapeUnicode(result))")
}

runTest("foo_noMixedScript") { checkNoMixedScript("foo", "knownBad_foo_noMixedScript") }
runTest("abc_noMixedScript") { checkNoMixedScript("abc", "knownBad_abc_noMixedScript") }

runTest("par_noLatinInOutput") {
    let result = parse("par")
    for scalar in result.unicodeScalars {
        assertTrue(
            Myanmar.isMyanmar(scalar) || scalar.value == 0x200C,
            "knownBad_par_noLatinInOutput",
            detail: "Found non-Myanmar U+\(String(scalar.value, radix: 16))"
        )
    }
}


// ===================================================================
// LEADING-VOWEL / U+200C TESTS
// ===================================================================

print("=== Leading-Vowel / U+200C Tests ===")

runTest("leadingVowel_u") { assertEqual(parse("u"), "\u{200C}\u{1030}", "leadingVowel_u") }
runTest("leadingVowel_ay") { assertEqual(parse("ay"), "\u{200C}\u{1031}", "leadingVowel_ay") }
runTest("leadingVowel_aw") { assertEqual(parse("aw"), "\u{200C}\u{1031}\u{102C}\u{103A}", "leadingVowel_aw") }
runTest("leadingVowel_aw:") { assertEqual(parse("aw:"), "\u{200C}\u{1031}\u{102C}", "leadingVowel_aw_colon") }
runTest("leadingVowel_own") { assertEqual(parse("own"), "\u{200C}\u{102F}\u{1014}\u{103A}", "leadingVowel_own") }

// ===================================================================
// REVERSE ROMANIZER TESTS
// ===================================================================

print("=== Reverse Romanizer Tests ===")

runTest("reverse_ky") {
    assertEqual(ReverseRomanizer.romanize("ကြ"), "kya", "reverse_ky")
}

runTest("reverse_ky2") {
    assertEqual(ReverseRomanizer.romanize("ကျ"), "ky2a", "reverse_ky2")
}

runTest("reverse_kw") {
    assertEqual(ReverseRomanizer.romanize("ကွ"), "kwa", "reverse_kw")
}

runTest("reverse_hk") {
    assertEqual(ReverseRomanizer.romanize("ကှ"), "hka", "reverse_hk")
}

runTest("reverse_hkwy2") {
    assertEqual(ReverseRomanizer.romanize("ကျွှ"), "hkwy2a", "reverse_hkwy2")
}

runTest("reverse_par") {
    assertEqual(ReverseRomanizer.romanize("ပာ"), "par", "reverse_par")
}

runTest("reverse_ay2") {
    assertEqual(ReverseRomanizer.romanize("ဧ"), "ay2", "reverse_ay2")
}

runTest("reverse_u2:") {
    assertEqual(ReverseRomanizer.romanize("ဦး"), "u2:", "reverse_u2:")
}

runTest("reverse_thar") {
    assertEqual(ReverseRomanizer.romanize("သာ"), "thar", "reverse_thar")
}

runTest("reverse_kyaw") {
    assertEqual(ReverseRomanizer.romanize("ကြော်"), "kyaw", "reverse_kyaw")
}

runTest("reverse_minGalarPar2") {
    assertEqual(ReverseRomanizer.romanize("မင်္ဂလာပါ"), "min+galarpar2", "reverse_minGalarPar2")
}

runTest("reverse_roundTrip") {
    // Forward parse then reverse should be stable
    let inputs = ["thar", "kyaw", "min+galarpar2"]
    for input in inputs {
        let forward = parse(input)
        let reversed = ReverseRomanizer.romanize(forward)
        let roundTrip = parse(reversed)
        assertEqual(forward, roundTrip, "roundTrip_\(input)")
    }
}

// ===================================================================
// LEXICON RANKING TESTS
// ===================================================================

print("=== Lexicon Ranking Tests ===")

struct FixedLexiconStore: CandidateStore {
    var byPrefix: [String: [Candidate]] = [:]
    var byBigram: [String: [String: [Candidate]]] = [:]
    func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
        var out: [Candidate] = []
        if let prev = previousSurface, let hits = byBigram[prev]?[prefix] {
            out += hits
        }
        if let hits = byPrefix[prefix] { out += hits }
        return out
    }
}

runTest("lexiconOrdering_higherFrequencyFirst") {
    let store = FixedLexiconStore(byPrefix: [
        "kyar": [
            Candidate(surface: "ကျား", reading: "kyar", source: .lexicon, score: 400),
            Candidate(surface: "ကြား", reading: "kyar", source: .lexicon, score: 900),
        ]
    ])
    let engine = BurmeseEngine(candidateStore: store)
    let state = engine.update(buffer: "kyar", context: [])
    let lex = state.candidates.filter { $0.source == .lexicon }
    let first = lex.firstIndex(where: { $0.surface == "ကြား" }) ?? -1
    let second = lex.firstIndex(where: { $0.surface == "ကျား" }) ?? -1
    assertTrue(first >= 0 && second >= 0 && first < second,
        "lexiconOrdering_higherFrequencyFirst",
        detail: "ordering: \(lex.map(\.surface))")
}

runTest("lexiconOrdering_aliasPenaltyBeatsFrequency") {
    struct AnyPrefixStore: CandidateStore {
        let candidates: [Candidate]
        func lookup(prefix: String, previousSurface: String?) -> [Candidate] {
            candidates
        }
    }
    // Buffer "kyar:" yields aliasPrefix "kyar:". Both entries' aliasReading
    // normalizes to "kyar:" (match quality 2), so the tiebreak falls to
    // aliasPenalty (0 < 1) before score. Use surfaces that don't collide
    // with grammar output so the lexicon-specific sort path is exercised.
    let store = AnyPrefixStore(candidates: [
        Candidate(surface: "HIGH", reading: "ky2ar:", source: .lexicon, score: 1500),
        Candidate(surface: "LOW", reading: "kyar:", source: .lexicon, score: 800),
    ])
    let engine = BurmeseEngine(candidateStore: store)
    let state = engine.update(buffer: "kyar:", context: [])
    let firstLex = state.candidates.first(where: { $0.source == .lexicon })
    assertEqual(firstLex?.surface ?? "<none>", "LOW", "lexiconOrdering_aliasPenaltyBeatsFrequency")
}

runTest("lexiconOrdering_exactAliasBeatsComposeMatchQuality") {
    let store = FixedLexiconStore(byPrefix: [
        "min+galarpar": [
            Candidate(surface: "Bmin", reading: "mingalarpar2", source: .lexicon, score: 2000),
            Candidate(surface: "Amin", reading: "min+galarpar2", source: .lexicon, score: 600),
        ]
    ])
    let engine = BurmeseEngine(candidateStore: store)
    let state = engine.update(buffer: "min+galarpar", context: [])
    let firstLex = state.candidates.first(where: { $0.source == .lexicon })
    assertEqual(firstLex?.surface ?? "<none>", "Amin", "lexiconOrdering_exactAliasBeatsComposeMatchQuality")
}

runTest("merge_exactAliasLexiconFillsSlotsZeroAndOne") {
    let store = FixedLexiconStore(byPrefix: [
        "min+galarpar": [
            Candidate(surface: "AA", reading: "min+galarpar2", source: .lexicon, score: 1000),
            Candidate(surface: "BB", reading: "min+galarpar3", source: .lexicon, score: 900),
        ]
    ])
    let engine = BurmeseEngine(candidateStore: store)
    let state = engine.update(buffer: "min+galarpar", context: [])
    assertTrue(state.candidates.count >= 3, "merge_exactAliasSlots_countCheck",
        detail: "got \(state.candidates.count) candidates")
    assertEqual(state.candidates.first?.surface ?? "<none>", "AA", "merge_exactAliasSlot0")
    if state.candidates.count >= 2 {
        assertEqual(state.candidates[1].surface, "BB", "merge_exactAliasSlot1")
    }
}

runTest("merge_onlyExactComposeWhenNoExactAlias") {
    let store = FixedLexiconStore(byPrefix: [
        "mingalarpar": [
            Candidate(surface: "မင်္ဂလာပါ", reading: "min+galarpar2", source: .lexicon, score: 1000),
        ]
    ])
    let engine = BurmeseEngine(candidateStore: store)
    let state = engine.update(buffer: "mingalarpar", context: [])
    assertEqual(state.candidates.first?.surface ?? "<none>", "မင်္ဂလာပါ",
        "merge_composeOnlyPrioritized")
    assertEqual(state.candidates.first?.source ?? .grammar, .lexicon,
        "merge_composeOnlyPrioritized_source")
}

runTest("merge_trailingLexiconDoesNotDisplacePrimaryGrammar") {
    let store = FixedLexiconStore(byPrefix: [
        "thar": [
            Candidate(surface: "FakeLexicon", reading: "tharx", source: .lexicon, score: 999),
        ]
    ])
    let engine = BurmeseEngine(candidateStore: store)
    let state = engine.update(buffer: "thar", context: [])
    if let lexIdx = state.candidates.firstIndex(where: { $0.surface == "FakeLexicon" }) {
        let gramIdx = state.candidates.firstIndex(where: { $0.source == .grammar }) ?? Int.max
        assertTrue(gramIdx < lexIdx, "merge_trailingLexiconAfterGrammar",
            detail: "grammar at \(gramIdx), lexicon at \(lexIdx)")
    } else {
        assertTrue(true, "merge_trailingLexiconAfterGrammar")
    }
}

runTest("merge_lexiconSurfaceMatchingGrammarIsMergedNotDuplicated") {
    let store = FixedLexiconStore(byPrefix: [
        "thar": [
            Candidate(surface: "သာ", reading: "thar", source: .lexicon, score: 750),
        ]
    ])
    let engine = BurmeseEngine(candidateStore: store)
    let state = engine.update(buffer: "thar", context: [])
    let matches = state.candidates.filter { $0.surface == "သာ" }
    assertEqual(matches.count, 1, "merge_surfaceMerge_noDupe")
    assertEqual(matches.first?.source ?? .lexicon, .grammar, "merge_surfaceMerge_keepsGrammar")
}

runTest("merge_pageSizeNeverExceedsLimit") {
    let store = FixedLexiconStore(byPrefix: [
        "kyar": [
            Candidate(surface: "ကြား", reading: "kyar:", source: .lexicon, score: 900),
            Candidate(surface: "ကျား", reading: "ky2ar:", source: .lexicon, score: 800),
            Candidate(surface: "ExtraA", reading: "kyarx1", source: .lexicon, score: 700),
            Candidate(surface: "ExtraB", reading: "kyarx2", source: .lexicon, score: 600),
            Candidate(surface: "ExtraC", reading: "kyarx3", source: .lexicon, score: 500),
        ]
    ])
    let engine = BurmeseEngine(candidateStore: store)
    let state = engine.update(buffer: "kyar", context: [])
    assertTrue(state.candidates.count <= BurmeseEngine.candidatePageSize,
        "merge_pageSizeLimit", detail: "got \(state.candidates.count)")
}

#if canImport(SQLite3)

struct SQLiteFixtureRow {
    let id: Int64
    let surface: String
    let reading: String
    let score: Double
}

func makeInMemoryLexicon(
    entries: [SQLiteFixtureRow],
    bigrams: [(prev: String, entryID: Int64, score: Double)] = [],
    name: String
) -> SQLiteCandidateStore? {
    let dbURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("lexrank_\(name)_\(UUID().uuidString).sqlite")
    var db: OpaquePointer?
    guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { return nil }
    defer { sqlite3_close(db) }

    let schema = """
        CREATE TABLE entries (
            id INTEGER PRIMARY KEY,
            surface TEXT NOT NULL,
            canonical_reading TEXT NOT NULL,
            unigram_score REAL NOT NULL
        );
        CREATE TABLE reading_index (
            canonical_reading TEXT NOT NULL,
            entry_id INTEGER NOT NULL REFERENCES entries(id),
            rank_score REAL NOT NULL
        );
        CREATE TABLE bigram_context (
            prev_surface TEXT NOT NULL,
            next_entry_id INTEGER NOT NULL REFERENCES entries(id),
            score REAL NOT NULL
        );
        """
    guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { return nil }

    for row in entries {
        let sql = """
            INSERT INTO entries (id, surface, canonical_reading, unigram_score)
            VALUES (\(row.id), '\(row.surface)', '\(row.reading)', \(row.score));
            INSERT INTO reading_index (canonical_reading, entry_id, rank_score)
            VALUES ('\(row.reading)', \(row.id), \(row.score));
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { return nil }
    }
    for bg in bigrams {
        let sql = """
            INSERT INTO bigram_context (prev_surface, next_entry_id, score)
            VALUES ('\(bg.prev)', \(bg.entryID), \(bg.score));
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { return nil }
    }
    return SQLiteCandidateStore(path: dbURL.path)
}

func doubleEqual(_ a: Double, _ b: Double, _ name: String, epsilon: Double = 0.001) {
    totalTests += 1
    if abs(a - b) < epsilon {
        passedTests += 1
    } else {
        failedTests.append((name, "Expected \(b), got \(a)"))
    }
}

runTest("sqliteScore_aliasPenaltyApplied") {
    guard let store = makeInMemoryLexicon(
        entries: [.init(id: 1, surface: "ကျား", reading: "ky2ar:", score: 500.0)],
        name: "aliasPenalty"
    ) else {
        failedTests.append(("sqliteScore_aliasPenaltyApplied", "Failed to open in-memory lexicon"))
        totalTests += 1
        return
    }
    let results = store.lookup(prefix: "kyar:", previousSurface: nil)
    guard let hit = results.first(where: { $0.surface == "ကျား" }) else {
        failedTests.append(("sqliteScore_aliasPenaltyApplied", "No hit for 'kyar:'"))
        totalTests += 1
        return
    }
    doubleEqual(hit.score, 500.0 - 1000.0, "sqliteScore_aliasPenaltyApplied")
}

runTest("sqliteScore_separatorPenaltyAppliedOnComposeMatch") {
    guard let store = makeInMemoryLexicon(
        entries: [.init(id: 1, surface: "မင်္ဂလာပါ", reading: "min+galarpar2", score: 1000.0)],
        name: "sepPenalty"
    ) else {
        failedTests.append(("sqliteScore_separatorPenalty", "Failed to open"))
        totalTests += 1
        return
    }
    let results = store.lookup(prefix: "mingalarpar", previousSurface: nil)
    guard let hit = results.first(where: { $0.surface == "မင်္ဂလာပါ" }) else {
        failedTests.append(("sqliteScore_separatorPenalty", "No compose hit; got \(results)"))
        totalTests += 1
        return
    }
    doubleEqual(hit.score, 1000.0 - 1000.0 - 250.0, "sqliteScore_separatorPenaltyAppliedOnComposeMatch")
}

runTest("sqliteScore_bigramBonusApplied") {
    guard let store = makeInMemoryLexicon(
        entries: [.init(id: 1, surface: "ကျား", reading: "kyar:", score: 500.0)],
        bigrams: [(prev: "ကြီး", entryID: 1, score: 500.0)],
        name: "bigramBonus"
    ) else {
        failedTests.append(("sqliteScore_bigramBonus", "Failed to open"))
        totalTests += 1
        return
    }
    let results = store.lookup(prefix: "kyar:", previousSurface: "ကြီး")
    guard let hit = results.first else {
        failedTests.append(("sqliteScore_bigramBonus", "No hit"))
        totalTests += 1
        return
    }
    doubleEqual(hit.score, 500.0 + 500.0, "sqliteScore_bigramBonusApplied")
}

runTest("sqliteDedup_bigramHitWinsOverPlainPrefixHit") {
    guard let store = makeInMemoryLexicon(
        entries: [.init(id: 1, surface: "ကျား", reading: "kyar:", score: 400.0)],
        bigrams: [(prev: "ကြီး", entryID: 1, score: 400.0)],
        name: "dedup"
    ) else {
        failedTests.append(("sqliteDedup_bigramWins", "Failed to open"))
        totalTests += 1
        return
    }
    let results = store.lookup(prefix: "kyar:", previousSurface: "ကြီး")
    let matches = results.filter { $0.surface == "ကျား" }
    assertEqual(matches.count, 1, "sqliteDedup_bigramWins_count")
    if let hit = matches.first {
        doubleEqual(hit.score, 400.0 + 500.0, "sqliteDedup_bigramHitSurvives")
    }
}

#endif

// -- Real-lexicon example word ranking (requires the bundled SQLite DB)

func repoRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // TestRunner/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // BurmeseIMECore/
        .deletingLastPathComponent()  // Packages/
        .deletingLastPathComponent()  // repo root
}

let bundledLexiconPath = repoRootURL()
    .appendingPathComponent("native/macos/Data/BurmeseLexicon.sqlite")
    .path

if FileManager.default.fileExists(atPath: bundledLexiconPath),
   let store = SQLiteCandidateStore(path: bundledLexiconPath) {

    let realEngine = BurmeseEngine(candidateStore: store)

    // (surface, approximate-frequency-from-TSV)
    let commonWordCases: [(surface: String, frequency: Int)] = [
        ("မင်္ဂလာပါ", 10000),
        ("သို့", 9444),
        ("ပါ", 9200),
        ("မင်္ဂလာ", 9000),
        ("မြန်မာ", 9000),
        ("သာ", 9000),
        ("သည်", 8729),
        ("ကို", 8522),
        ("ကောင်း", 8500),
        ("လူ", 8460),
        ("နှင့်", 8380),
    ]

    for testCase in commonWordCases {
        let canonical = ReverseRomanizer.romanize(testCase.surface)
        let typed = canonical
            .filter { !"23+'".contains($0) }  // compose-lookup key
        let name = "realLexicon_\(testCase.surface)_typed_\(typed)"
        runTest(name) {
            guard !typed.isEmpty else {
                failedTests.append((name, "Empty typed form for \(testCase.surface)"))
                totalTests += 1
                return
            }
            let state = realEngine.update(buffer: typed, context: [])
            let top3 = Array(state.candidates.prefix(3)).map(\.surface)
            assertTrue(top3.contains(testCase.surface), name,
                detail: "typed='\(typed)' freq=\(testCase.frequency) top3=\(top3)")
        }
    }

    runTest("realLexicon_mingalarpar_baseWordNotOutrankedByContinuation") {
        let rawResults = store.lookup(prefix: "mingalarpar", previousSurface: nil)
        let surfaces = rawResults.map(\.surface)
        guard let baseIdx = surfaces.firstIndex(of: "မင်္ဂလာပါ") else {
            failedTests.append(("realLexicon_mingalarpar_base",
                "Expected မင်္ဂလာပါ in results; got \(surfaces)"))
            totalTests += 1
            return
        }
        for (i, surface) in surfaces.enumerated()
            where surface != "မင်္ဂလာပါ" && surface.hasPrefix("မင်္ဂလာပါ")
        {
            assertTrue(i >= baseIdx,
                "realLexicon_mingalarpar_base_vs_\(surface)",
                detail: "base at \(baseIdx), continuation \(surface) at \(i)")
        }
    }

    runTest("realLexicon_par_exposesPaaParticle") {
        let state = realEngine.update(buffer: "par", context: [])
        let surfaces = state.candidates.map(\.surface)
        assertTrue(surfaces.contains("ပါ"),
            "realLexicon_par_exposesPaaParticle",
            detail: "surfaces=\(surfaces)")
    }
} else {
    runTest("realLexicon_skipped_noBundledDB") {
        assertTrue(true, "realLexicon_skipped_noBundledDB")
    }
}

// ===================================================================
// RESULTS
// ===================================================================

print("\n" + String(repeating: "=", count: 60))
if failedTests.isEmpty {
    print("ALL \(totalTests) TESTS PASSED")
} else {
    print("\(passedTests)/\(totalTests) passed, \(failedTests.count) FAILED:")
    for (name, detail) in failedTests {
        print("  FAIL: \(name) — \(detail)")
    }
}
print(String(repeating: "=", count: 60))

if !failedTests.isEmpty {
    exit(1)
}

