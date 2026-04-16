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
    assertTrue(state.candidates.count <= BurmeseEngine.candidatePageSizeDefault, "maxPageSize")
}

runTest("longerBufferPreservesPreviouslyRenderedPrefix") {
    // Screenshot bug: typing more characters re-parsed the already-typed
    // portion and changed the rendered prefix. The top candidate for the
    // longer buffer must still begin with the top candidate seen for the
    // shorter buffer.
    let stabilityEngine = BurmeseEngine()
    let short = stabilityEngine.update(buffer: "kwyantaw", context: [])
    let longer = stabilityEngine.update(buffer: "kwyantawkahtamin", context: [])
    if let shortTop = short.candidates.first?.surface,
       let longerTop = longer.candidates.first?.surface {
        assertTrue(
            longerTop.hasPrefix(shortTop),
            "longerBufferPreservesPreviouslyRenderedPrefix",
            detail: "prefix drift: '\(escapeUnicode(longerTop))' should start with '\(escapeUnicode(shortTop))'"
        )
    } else {
        assertTrue(false, "longerBufferPreservesPreviouslyRenderedPrefix", detail: "missing candidates")
    }
}

runTest("preservesTrailingDigits") {
    // Digits in the tail are converted to Burmese in the primary candidate.
    let state = engine.update(buffer: "min:123", context: [])
    let committed = engine.commit(state: state)
    assertTrue(committed.hasSuffix("၁၂၃"), "preservesTrailingDigits_suffix",
               detail: "Expected '၁၂၃' suffix, got: \(escapeUnicode(committed))")
    assertTrue(committed.hasPrefix("မင်း"), "preservesTrailingDigits_prefix",
               detail: "Expected မင်း prefix, got: \(escapeUnicode(committed))")
    // Arabic-digit variant is also available.
    let hasArabic = state.candidates.contains { $0.surface.hasSuffix("123") }
    assertTrue(hasArabic, "preservesTrailingDigits_arabicVariant")
}

runTest("candidatesIncludeTrailingDigits") {
    let state = engine.update(buffer: "thar123", context: [])
    assertTrue(!state.candidates.isEmpty, "candidatesIncludeTrailingDigits_nonEmpty")
    // Every candidate should end with either Burmese or Arabic digits.
    let allHaveTail = state.candidates.allSatisfy {
        $0.surface.hasSuffix("၁၂၃") || $0.surface.hasSuffix("123")
    }
    assertTrue(allHaveTail, "candidatesIncludeTrailingDigits_allHaveTail")
    // Primary candidate should have Burmese digits.
    assertTrue(state.candidates.first!.surface.hasSuffix("၁၂၃"),
               "candidatesIncludeTrailingDigits_primaryBurmese")
    // Arabic-digit variant should also be present.
    let hasArabic = state.candidates.contains { $0.surface.hasSuffix("123") }
    assertTrue(hasArabic, "candidatesIncludeTrailingDigits_arabicVariant")
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
    assertTrue(committed.hasSuffix("၁၂၃!"), "preservesMixedTail_burmese",
               detail: "Expected '၁၂၃!' suffix, got: \(escapeUnicode(committed))")
    // Arabic-digit variant should also be present.
    let hasArabic = state.candidates.contains { $0.surface.hasSuffix("123!") }
    assertTrue(hasArabic, "preservesMixedTail_arabicVariant")
}

runTest("thar2_commitsDigitLiteral") {
    // Digits are never consumed as vowel-variant tokens. "thar2" commits as
    // သာ followed by Burmese "၂" (primary) with Arabic "2" as alternative.
    let state = engine.update(buffer: "thar2", context: [])
    let committed = engine.commit(state: state)
    assertEqual(committed, "သာ၂", "thar2_commitsDigitLiteral")
    let hasArabic = state.candidates.contains { $0.surface == "သာ2" }
    assertTrue(hasArabic, "thar2_arabicVariant")
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
    assertTrue(committed.hasSuffix("၂"), "ar2_literalTail",
               detail: "Expected '၂' suffix, got: \(escapeUnicode(committed))")
    assertFalse(committed.contains("\u{102B}"), "ar2_noTallAa",
                detail: "Expected no ါ (U+102B), got: \(escapeUnicode(committed))")
    assertTrue(committed.contains("\u{102C}"), "ar2_hasShortAa",
               detail: "Expected ာ (U+102C), got: \(escapeUnicode(committed))")
}

runTest("progressiveTyping_mingalarpar_producesCorrectOutput") {
    // Bug: anchor commits "min+gala" as မင်္ဂလ, then "r" becomes standalone
    // onset ရ instead of vowel suffix "ar" → ာ. Expected: မင်္ဂလာပါ.
    let progressiveEngine = BurmeseEngine()
    let keystrokes = Array("min+galarpar")
    var buffer = ""
    for ch in keystrokes {
        buffer.append(ch)
        _ = progressiveEngine.update(buffer: buffer, context: [])
    }
    let finalState = progressiveEngine.update(buffer: "min+galarpar", context: [])
    let top = finalState.candidates.first?.surface ?? ""
    let stripped = top.unicodeScalars
        .filter { $0.value != 0x200B && $0.value != 0x200C }
        .map { String($0) }.joined()
    assertEqual(stripped, "မင်္ဂလာပါ", "progressiveTyping_mingalarpar")
}

runTest("progressiveTyping_kwyantawkahtamin_producesCorrectSuffix") {
    // Bug: anchor locks wrong syllable boundaries. "kah" committed as ကဟ
    // instead of later becoming ka + hta (ကထ). The suffix must parse as
    // ကထမင် regardless of ya-pin/ya-yit prefix (LM-dependent).
    let progressiveEngine = BurmeseEngine()
    let keystrokes = Array("kwyantawkahtamin")
    var buffer = ""
    for ch in keystrokes {
        buffer.append(ch)
        _ = progressiveEngine.update(buffer: buffer, context: [])
    }
    let finalState = progressiveEngine.update(buffer: "kwyantawkahtamin", context: [])
    let top = finalState.candidates.first?.surface ?? ""
    let stripped = top.unicodeScalars
        .filter { $0.value != 0x200B && $0.value != 0x200C }
        .map { String($0) }.joined()
    assertTrue(stripped.hasSuffix("ကထမင်"), "progressiveTyping_kwyantawkahtamin_suffix",
        detail: "Expected suffix ကထမင်, got \(escapeUnicode(stripped))")
}

runTest("leadingDigits_parsedWithBurmeseText") {
    // "123kwyantaw" → leading digits should convert to ၁၂၃ and
    // the composable portion should still parse as Burmese.
    let state = engine.update(buffer: "123kwyantaw", context: [])
    assertTrue(!state.candidates.isEmpty, "leadingDigits_hasCandidates")
    let primary = state.candidates[0].surface
    assertTrue(primary.hasPrefix("၁၂၃"), "leadingDigits_burmesePrefix",
               detail: "Expected ၁၂၃ prefix, got: \(escapeUnicode(primary))")
    // The composable part "kwyantaw" must not appear as raw latin.
    assertFalse(primary.contains("kwyantaw"), "leadingDigits_noRawLatin",
                detail: "Should not contain raw latin: \(escapeUnicode(primary))")
    // Arabic-digit variant should also be present.
    let hasArabic = state.candidates.contains { $0.surface.hasPrefix("123") }
    assertTrue(hasArabic, "leadingDigits_arabicVariant")
}

runTest("leadingDigits_withTrailingDigits") {
    // "123thar456" → ၁၂₃ + သာ + ၄၅၆ (primary), 123 + သာ + 456 (secondary)
    let state = engine.update(buffer: "123thar456", context: [])
    assertTrue(!state.candidates.isEmpty, "leadingTrailingDigits_hasCandidates")
    let primary = state.candidates[0].surface
    assertTrue(primary.hasPrefix("၁၂၃"), "leadingTrailingDigits_burmesePrefix",
               detail: "Expected ၁၂₃ prefix, got: \(escapeUnicode(primary))")
    assertTrue(primary.hasSuffix("၄၅၆"), "leadingTrailingDigits_burmeseSuffix",
               detail: "Expected ၄₅₆ suffix, got: \(escapeUnicode(primary))")
    let hasArabic = state.candidates.contains {
        $0.surface.hasPrefix("123") && $0.surface.hasSuffix("456")
    }
    assertTrue(hasArabic, "leadingTrailingDigits_arabicVariant")
}

runTest("pureDigitBuffer_producesBurmeseAndArabicCandidates") {
    let state = engine.update(buffer: "123", context: [])
    assertTrue(state.isActive, "pureDigitBuffer_active")
    assertTrue(!state.candidates.isEmpty, "pureDigitBuffer_hasCandidates")
    assertEqual(state.candidates[0].surface, "၁၂၃", "pureDigitBuffer_primaryBurmese")
    assertTrue(state.candidates.count >= 2, "pureDigitBuffer_hasTwoCandidates")
    assertEqual(state.candidates[1].surface, "123", "pureDigitBuffer_secondaryArabic")
    assertEqual(engine.commit(state: state), "၁၂၃", "pureDigitBuffer_commitsBurmese")
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
// MIXED-SCRIPT REJECTION TESTS
// ===================================================================
// Unparseable Latin must either stay raw or produce pure Myanmar output —
// never mixed. Previous browser engines leaked Latin fragments into the
// commit; we explicitly regress against that.

print("=== Mixed-Script Rejection Tests ===")

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
    assertTrue(state.candidates.count <= BurmeseEngine.candidatePageSizeDefault,
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

    // Prefix-stability regression (screenshot bug). Needs the real LM
    // because the drift is LM-driven — with NullLM all parses tie and
    // parser tiebreakers give stable output.
    let bundledLMPath = repoRootURL()
        .appendingPathComponent("native/macos/Data/BurmeseLM.bin")
        .path
    if FileManager.default.fileExists(atPath: bundledLMPath),
       let lm = try? TrigramLanguageModel(path: bundledLMPath) {
        let stabilityEngine = BurmeseEngine(candidateStore: store, languageModel: lm)
        runTest("prefixStability_kwyantaw_keepsPrefixWhenExtended") {
            let short = stabilityEngine.update(buffer: "kwyantaw", context: [])
            let longer = stabilityEngine.update(buffer: "kwyantawkahtamin", context: [])
            guard let shortTop = short.candidates.first?.surface,
                  let longerTop = longer.candidates.first?.surface else {
                failedTests.append(("prefixStability_kwyantaw", "missing candidates"))
                totalTests += 1
                return
            }
            // Strip ZWSPs for comparison: lexicon candidates embed U+200B
            // word-boundary markers that grammar candidates lack.
            let shortStripped = String(shortTop.unicodeScalars.filter { $0.value != 0x200B })
            let longerStripped = String(longerTop.unicodeScalars.filter { $0.value != 0x200B })
            assertTrue(
                longerStripped.hasPrefix(shortStripped),
                "prefixStability_kwyantaw_keepsPrefixWhenExtended",
                detail: "drift: longer='\(escapeUnicode(longerTop))' short='\(escapeUnicode(shortTop))'"
            )
        }

        // No keystroke in a progressive typing sequence may leave the
        // candidate panel empty while a convertible buffer is still being
        // composed — "window disappeared" bug from the screenshot where
        // `kwyantawk` showed candidates but `kwyantawka` did not.
        runTest("prefixStability_progressiveTyping_neverEmptyCandidates") {
            let progressiveEngine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let keystrokes = [
                "k", "kw", "kwy", "kwya", "kwyan", "kwyant", "kwyanta",
                "kwyantaw", "kwyantawk", "kwyantawka", "kwyantawkah",
                "kwyantawkaht", "kwyantawkahta", "kwyantawkahtam",
                "kwyantawkahtami", "kwyantawkahtamin",
            ]
            var missing: [String] = []
            for stroke in keystrokes {
                let state = progressiveEngine.update(buffer: stroke, context: [])
                if state.candidates.isEmpty { missing.append(stroke) }
            }
            assertTrue(missing.isEmpty,
                "prefixStability_progressiveTyping_neverEmptyCandidates",
                detail: "empty panels at: \(missing)")
        }

        // After a long progressive sequence that naturally resolves to
        // the correct word, extending further must not silently rewrite
        // the rendered prefix into a different decomposition.
        runTest("prefixStability_longInputKeepsCorrectPrefix") {
            let progressiveEngine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let keystrokes = [
                "k", "kw", "kwy", "kwya", "kwyan", "kwyant", "kwyanta",
                "kwyantaw", "kwyantawk", "kwyantawka", "kwyantawkah",
                "kwyantawkaht", "kwyantawkahta", "kwyantawkahtam",
                "kwyantawkahtami", "kwyantawkahtamin",
            ]
            var finalTop = ""
            for stroke in keystrokes {
                let state = progressiveEngine.update(buffer: stroke, context: [])
                finalTop = state.candidates.first?.surface ?? finalTop
            }
            let stripped = finalTop.unicodeScalars
                .filter { $0.value != 0x200B }
                .map { String($0) }
                .joined()
            assertTrue(stripped.hasPrefix("ကျွန်တော်"),
                "prefixStability_longInputKeepsCorrectPrefix",
                detail: "final top='\(escapeUnicode(finalTop))'")
        }

        // Bug: progressive typing with real LM — anchor synthesis from
        // intermediate checkpoints overrides the correct full-buffer parse.
        // At step 11 "kwyantawkah" the anchor records ကအ (k+ah), but
        // step 12 "kwyantawkaht" correctly re-parses to ကထ (ka+hta).
        // When step 13 "kwyantawkahta" arrives, the stale step-11 anchor
        // synthesizes ကအ+တ instead of using the correct parse ကထ.
        // The suffix must be ကထမင် (or ကထမင်း with colon).
        runTest("realLM_progressiveTyping_kwyantawkahtamin_correctSuffix") {
            let progressiveEngine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let keystrokes = Array("kwyantawkahtamin")
            var buffer = ""
            for ch in keystrokes {
                buffer.append(ch)
                _ = progressiveEngine.update(buffer: buffer, context: [])
            }
            let finalState = progressiveEngine.update(buffer: "kwyantawkahtamin", context: [])
            let top = finalState.candidates.first?.surface ?? ""
            let stripped = String(top.unicodeScalars.filter {
                $0.value != 0x200B && $0.value != 0x200C
            })
            assertTrue(stripped.hasSuffix("ကထမင်"),
                "realLM_progressiveTyping_kwyantawkahtamin_correctSuffix",
                detail: "Expected suffix ကထမင်, got \(escapeUnicode(stripped))")
        }

        runTest("realLM_progressiveTyping_kwyantawkahtamin_colon_correctSuffix") {
            let progressiveEngine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let keystrokes = Array("kwyantawkahtamin:")
            var buffer = ""
            for ch in keystrokes {
                buffer.append(ch)
                _ = progressiveEngine.update(buffer: buffer, context: [])
            }
            let finalState = progressiveEngine.update(buffer: "kwyantawkahtamin:", context: [])
            let top = finalState.candidates.first?.surface ?? ""
            let stripped = String(top.unicodeScalars.filter {
                $0.value != 0x200B && $0.value != 0x200C
            })
            assertTrue(stripped.hasSuffix("ကထမင်း"),
                "realLM_progressiveTyping_kwyantawkahtamin_colon_correctSuffix",
                detail: "Expected suffix ကထမင်း, got \(escapeUnicode(stripped))")
        }

        // Bug: long inputs like "kwyantawkahtamin:masar:rathar" produce
        // wrong decomposition for "tha" — it becomes တ+ဟ (ta + ha) instead
        // of သ (tha) when the sliding window splits at an unfortunate boundary.
        // Short inputs like "thar" work correctly.
        runTest("realLM_progressiveTyping_longInput_thaNotSplitAsTaHa") {
            let progressiveEngine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let input = "kwyantawkahtamin:masar:rathar"
            let keystrokes = Array(input)
            var buffer = ""
            for ch in keystrokes {
                buffer.append(ch)
                _ = progressiveEngine.update(buffer: buffer, context: [])
            }
            let finalState = progressiveEngine.update(buffer: input, context: [])
            let top = finalState.candidates.first?.surface ?? ""
            let stripped = String(top.unicodeScalars.filter {
                $0.value != 0x200B && $0.value != 0x200C
            })
            // "tha" should produce သ, not တ+ဟ
            // The suffix "rathar" should end with ရသာ (ra + tha + ar)
            // not ရတဟာ (ra + ta + ha + ar)
            assertFalse(stripped.contains("တဟ"),
                "realLM_progressiveTyping_longInput_thaNotSplitAsTaHa",
                detail: "Found တဟ (ta+ha) split, expected သ (tha). Full: \(escapeUnicode(stripped))")
        }

        // Verify "thar" produces correct output in other long contexts too
        runTest("realLM_progressiveTyping_longInput_thar_variousContexts") {
            // Test several long inputs ending with "thar" to ensure the
            // multi-character onset is never split by the anchor boundary.
            let inputs = [
                "kwyantawkahtamin:thar",
                "kwyantawkahtamin:masar:thar",
            ]
            for input in inputs {
                let progressiveEngine = BurmeseEngine(candidateStore: store, languageModel: lm)
                var buffer = ""
                for ch in Array(input) {
                    buffer.append(ch)
                    _ = progressiveEngine.update(buffer: buffer, context: [])
                }
                let state = progressiveEngine.update(buffer: input, context: [])
                let top = state.candidates.first?.surface ?? ""
                let stripped = String(top.unicodeScalars.filter {
                    $0.value != 0x200B && $0.value != 0x200C
                })
                // Must end with သာ (thar), not တဟာ (ta + ha + ar)
                assertTrue(stripped.hasSuffix("သာ"),
                    "realLM_longInput_thar_\(input.count)chars",
                    detail: "Input '\(input)' should end with သာ, got \(escapeUnicode(stripped))")
            }
        }

        // End-to-end sentence: user types several words letter by letter,
        // commits each, and continues. Exercises the full loop the user
        // sees — anchor reset between words, LM context carry-over,
        // panel continuity mid-word, and the final rendered text. Any
        // empty panel during a word or any mis-rendered word surfaces
        // here.
        runTest("progressiveTyping_fullSentenceSimulation") {
            let progressiveEngine = BurmeseEngine(candidateStore: store, languageModel: lm)
            // Pick common Burmese words. Derive the user-typed form via
            // ReverseRomanizer so the test exercises exactly the input
            // path a real user would produce for these surfaces.
            let targetSurfaces = [
                "မင်္ဂလာပါ",
                "ကျွန်တော်",
                "ထမင်း",
                "စား",
                "ပါ",
            ]
            var context: [String] = []
            var emptyPanels: [String] = []
            var misrenderings: [(String, String, String)] = []
            for surface in targetSurfaces {
                // User-typed form: canonical romanization minus the
                // disambiguation markers they would not type on a plain
                // keyboard (digits, separators, apostrophes).
                let typed = ReverseRomanizer.romanize(surface)
                    .filter { !"23+'".contains($0) }
                // Reset composition at word start (mirrors commit → space → next word).
                _ = progressiveEngine.update(buffer: "", context: context)
                for i in 1...typed.count {
                    let buffer = String(typed.prefix(i))
                    let state = progressiveEngine.update(buffer: buffer, context: context)
                    if state.candidates.isEmpty {
                        emptyPanels.append("word='\(surface)' stroke='\(buffer)'")
                    }
                }
                let finalState = progressiveEngine.update(buffer: typed, context: context)
                // Check top-3 for the target surface. The IME shows a
                // panel and the user picks; as long as the target word
                // is prominent the real UX is fine.
                let top3 = Array(finalState.candidates.prefix(3)).map(\.surface)
                let stripped3 = top3.map { s in
                    s.unicodeScalars.filter { $0.value != 0x200B }
                        .map { String($0) }.joined()
                }
                if !stripped3.contains(surface) {
                    misrenderings.append((typed, surface, "top3=\(stripped3)"))
                }
                // Simulate commit of the user's intended word.
                context.append(surface)
            }
            assertTrue(emptyPanels.isEmpty,
                "progressiveTyping_fullSentenceSimulation_noEmptyPanel",
                detail: "empty at: \(emptyPanels)")
            totalTests += 1
            if misrenderings.isEmpty {
                passedTests += 1
            } else {
                let rendered = misrenderings.map { "'\($0.0)'→expected '\($0.1)': \($0.2)" }
                    .joined(separator: " | ")
                failedTests.append((
                    "progressiveTyping_fullSentenceSimulation_top3ContainsTarget",
                    rendered
                ))
            }
        }

        // Letter-by-letter exercise of the exact screenshot sequence.
        // Once ကျွန်တော် is established as the prefix (after the first
        // word "kwyantaw"), typing "kahtamin:" must extend it — never
        // rewrite it. Emits a per-keystroke trace when the prefix drifts
        // so the failure point is obvious.
        runTest("progressiveTyping_kwyantawkahtamin_traceNoDrift") {
            let progressiveEngine = BurmeseEngine(candidateStore: store, languageModel: lm)
            let letters = Array("kwyantawkahtamin:")
            let expectedPrefixStripped = "ကျွန်တော်"
            var buffer = ""
            var trace: [(String, String)] = []
            var driftAt: String? = nil
            var emptyAt: [String] = []
            var prefixEstablished = false
            for ch in letters {
                buffer.append(ch)
                let state = progressiveEngine.update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                let stripped = top.unicodeScalars
                    .filter { $0.value != 0x200B }
                    .map { String($0) }
                    .joined()
                trace.append((buffer, stripped))
                if state.candidates.isEmpty { emptyAt.append(buffer) }
                // Mark the prefix as "established" the first time it
                // appears; from that point onward every later top must
                // still begin with it.
                if stripped.hasPrefix(expectedPrefixStripped) {
                    prefixEstablished = true
                } else if prefixEstablished && driftAt == nil {
                    driftAt = buffer
                }
            }
            let traceStr = trace.map { "\($0.0)→\(escapeUnicode($0.1))" }.joined(separator: " | ")
            assertTrue(emptyAt.isEmpty,
                "progressiveTyping_kwyantawkahtamin_neverEmpty",
                detail: "empty at \(emptyAt); trace: \(traceStr)")
            assertTrue(prefixEstablished,
                "progressiveTyping_kwyantawkahtamin_prefixReached",
                detail: "never saw '\(expectedPrefixStripped)' as prefix; trace: \(traceStr)")
            assertTrue(driftAt == nil,
                "progressiveTyping_kwyantawkahtamin_noDriftAfterEstablished",
                detail: "drift at '\(driftAt ?? "")'; trace: \(traceStr)")
        }

        // Screenshot scenario: user types keystroke-by-keystroke. Early
        // short buffers (k, kw, kwy) pick weak initial candidates before
        // enough evidence exists to disambiguate medials. Once the full
        // word "kwyantaw" is typed, the top must be ကျွန်တော် — a
        // genuinely better full-buffer parse must overwrite the stale
        // anchor from shorter intermediate buffers.
        runTest("prefixStability_progressiveTyping_reachesCorrectWord") {
            let progressiveEngine = BurmeseEngine(candidateStore: store, languageModel: lm)
            var finalTop = ""
            for prefix in ["k", "kw", "kwy", "kwya", "kwyan", "kwyant", "kwyanta", "kwyantaw"] {
                let state = progressiveEngine.update(buffer: prefix, context: [])
                finalTop = state.candidates.first?.surface ?? ""
            }
            let normalized = finalTop.unicodeScalars
                .filter { $0.value != 0x200B }
                .map { String($0) }
                .joined()
            assertEqual(normalized, "ကျွန်တော်",
                "prefixStability_progressiveTyping_reachesCorrectWord")
        }

        // Concrete per-input expectations for canonical vs medial-fallback
        // disambiguation. The parser has two knobs that interact: 'h' can
        // be a ha-htoe medial prefix ("hk" = က+ှ) OR a bare consonant (ဟ
        // ha). When the 'h' occurs AFTER a fully-formed syllable (e.g. "ka"
        // already consumed), treating it as a medial produces a dangling
        // ှ — that's the bug. It should be parsed as the bare consonant ဟ
        // instead, and only coalesce into a proper onset (e.g. ထ "ht")
        // when the next keystroke makes that onset complete.
        //
        // Typed letter-by-letter so the failure point is visible.
        runTest("progressiveTyping_canonicalVsMedial_expectations") {
            let progressiveEngine = BurmeseEngine(candidateStore: store, languageModel: lm)
            // Each case: (typed input, expected top scalars). ZWSPs
            // stripped before comparison so anchor boundaries don't
            // interfere.
            // Top candidate checks (first candidate must match exactly).
            let topCases: [(input: String, expected: [UInt32])] = [
                ("hsa",  [0x1006]),                 // ဆ — canonical match beats medial fallback
                ("kah",  [0x1000, 0x1021]),          // ကအ
                ("kaht", [0x1000, 0x1011]),          // ကထ
            ]
            // Presence checks (candidate must appear somewhere in the list).
            let containsCases: [(input: String, expected: [UInt32])] = [
                ("hka",  [0x1000, 0x103E]),          // ကှ — may be behind lexicon prefix hits
            ]
            var failures: [String] = []
            for (word, expectedScalars) in topCases {
                _ = progressiveEngine.update(buffer: "", context: [])
                var top = ""
                for i in 1...word.count {
                    let buf = String(word.prefix(i))
                    let state = progressiveEngine.update(buffer: buf, context: [])
                    top = state.candidates.first?.surface ?? ""
                }
                let actualScalars = top.unicodeScalars
                    .filter { $0.value != 0x200B && $0.value != 0x200C }
                    .map { $0.value }
                if actualScalars != expectedScalars {
                    let hex = actualScalars.map { String(format: "%04X", $0) }
                        .joined(separator: " ")
                    let exp = expectedScalars.map { String(format: "%04X", $0) }
                        .joined(separator: " ")
                    failures.append("'\(word)' top→[\(hex)], expected [\(exp)]")
                }
            }
            for (word, expectedScalars) in containsCases {
                _ = progressiveEngine.update(buffer: "", context: [])
                var candidates: [String] = []
                for i in 1...word.count {
                    let buf = String(word.prefix(i))
                    let state = progressiveEngine.update(buffer: buf, context: [])
                    candidates = state.candidates.map(\.surface)
                }
                let found = candidates.contains { surface in
                    let scalars = surface.unicodeScalars
                        .filter { $0.value != 0x200B && $0.value != 0x200C }
                        .map { $0.value }
                    return scalars == expectedScalars
                }
                if !found {
                    let exp = expectedScalars.map { String(format: "%04X", $0) }
                        .joined(separator: " ")
                    failures.append("'\(word)' missing [\(exp)] in candidates")
                }
            }
            assertTrue(failures.isEmpty,
                "progressiveTyping_canonicalVsMedial_expectations",
                detail: failures.joined(separator: " | "))
        }
    }
} else {
    runTest("realLexicon_skipped_noBundledDB") {
        assertTrue(true, "realLexicon_skipped_noBundledDB")
    }
}

// ===================================================================
// Language Model (trigram binary reader)
// ===================================================================

print("=== Language Model Tests ===")

// Fixture builder mirrors the Python side; see FORMAT.md.
func buildLMFixture(
    vocab: [String],
    bos: Int, eos: Int, unk: Int,
    unigrams: [(UInt32, Float, Float)],
    bigrams: [(UInt32, UInt32, Float, Float)],
    trigrams: [(UInt32, UInt32, UInt32, Float)]
) -> Data {
    func appendU32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    func appendF32(_ data: inout Data, _ value: Float) {
        var v = value.bitPattern.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    var out = Data()
    out.append(contentsOf: Array("BURMLM01".utf8))
    appendU32(&out, 1)
    appendU32(&out, 3)
    appendU32(&out, UInt32(vocab.count))
    appendU32(&out, UInt32(unigrams.count))
    appendU32(&out, UInt32(bigrams.count))
    appendU32(&out, UInt32(trigrams.count))
    appendU32(&out, UInt32(bos))
    appendU32(&out, UInt32(eos))
    appendU32(&out, UInt32(unk))
    appendU32(&out, 0)

    var offsets: [(UInt32, UInt32)] = []
    var blob = Data()
    for s in vocab {
        let b = Array(s.utf8)
        offsets.append((UInt32(blob.count), UInt32(b.count)))
        blob.append(contentsOf: b)
    }
    out.append(blob)
    for (off, len) in offsets { appendU32(&out, off); appendU32(&out, len) }
    let sortedIds = (0..<vocab.count)
        .sorted { vocab[$0].utf8.lexicographicallyPrecedes(vocab[$1].utf8) }
        .map { UInt32($0) }
    for id in sortedIds { appendU32(&out, id) }
    for (id, lp, bo) in unigrams.sorted(by: { $0.0 < $1.0 }) {
        appendU32(&out, id); appendF32(&out, lp); appendF32(&out, bo); appendU32(&out, 0)
    }
    for (w1, w2, lp, bo) in bigrams.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) {
        appendU32(&out, w1); appendU32(&out, w2); appendF32(&out, lp); appendF32(&out, bo)
    }
    for (w1, w2, w3, lp) in trigrams.sorted(by: { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }) {
        appendU32(&out, w1); appendU32(&out, w2); appendU32(&out, w3); appendF32(&out, lp)
    }
    return out
}

runTest("lm_null_returnsConstant") {
    let lm = NullLanguageModel(constantLogProb: -7.5)
    doubleEqual(lm.logProb(surface: "သာ", context: []), -7.5, "lm_null_empty")
    doubleEqual(lm.logProb(surface: "သာ", context: ["a", "b"]), -7.5, "lm_null_trigramctx")
}

runTest("lm_reader_unigramLookup") {
    let data = buildLMFixture(
        vocab: ["က", "ကို", "<s>", "</s>", "<unk>"],
        bos: 2, eos: 3, unk: 4,
        unigrams: [(0, -1.0, 0.0), (1, -2.0, 0.0), (4, -5.0, 0.0)],
        bigrams: [], trigrams: []
    )
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lm_uni_\(UUID().uuidString).bin")
    try? data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        let lm = try TrigramLanguageModel(path: url.path)
        doubleEqual(lm.logProb(surface: "က", context: []), -1.0, "lm_reader_unigram_k")
        doubleEqual(lm.logProb(surface: "ကို", context: []), -2.0, "lm_reader_unigram_ko")
        doubleEqual(lm.logProb(surface: "unknown", context: []), -5.0, "lm_reader_oov_routesToUnk")
        assertEqual(lm.wordId(for: "က"), UInt32(0), "lm_reader_surfaceToId")
    } catch {
        failedTests.append(("lm_reader_unigramLookup", "Load failed: \(error)"))
    }
}

runTest("lm_reader_bigramBacksOffToUnigram") {
    let data = buildLMFixture(
        vocab: ["က", "ကို", "<s>", "</s>", "<unk>"],
        bos: 2, eos: 3, unk: 4,
        unigrams: [(0, -1.0, -0.3), (1, -2.0, 0.0), (2, -0.5, -0.2), (4, -5.0, 0.0)],
        bigrams: [(0, 1, -1.5, 0.0)],
        trigrams: []
    )
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lm_bi_\(UUID().uuidString).bin")
    try? data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        let lm = try TrigramLanguageModel(path: url.path)
        doubleEqual(lm.logProb(surface: "ကို", context: ["က"]), -1.5, "lm_reader_bigramDirect")
        doubleEqual(
            lm.logProb(surface: "nope", context: ["<s>"]),
            -5.0 + -0.2,
            "lm_reader_bigramBackoff"
        )
    } catch {
        failedTests.append(("lm_reader_bigramBacksOffToUnigram", "Load failed: \(error)"))
    }
}

runTest("lm_reader_trigramHitBeatsBackoff") {
    let data = buildLMFixture(
        vocab: ["က", "ကို", "<s>", "</s>", "<unk>"],
        bos: 2, eos: 3, unk: 4,
        unigrams: [(0, -1.0, 0.0), (1, -2.0, -0.1), (3, -1.2, 0.0), (4, -5.0, 0.0)],
        bigrams: [(0, 1, -1.5, -0.2), (1, 3, -2.3, 0.0)],
        trigrams: [(0, 1, 3, -0.9)]
    )
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lm_tri_\(UUID().uuidString).bin")
    try? data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        let lm = try TrigramLanguageModel(path: url.path)
        doubleEqual(
            lm.logProb(surface: "</s>", context: ["က", "ကို"]),
            -0.9,
            "lm_reader_trigramDirect"
        )
    } catch {
        failedTests.append(("lm_reader_trigramHitBeatsBackoff", "Load failed: \(error)"))
    }
}

runTest("lm_reader_scoreSurface_decomposesMultiWord") {
    let data = buildLMFixture(
        vocab: ["ကျွန်", "တော်", "<s>", "</s>", "<unk>"],
        bos: 2, eos: 3, unk: 4,
        unigrams: [(0, -2.0, 0.0), (1, -2.5, 0.0), (4, -12.0, 0.0)],
        bigrams: [],
        trigrams: []
    )
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lm_score_\(UUID().uuidString).bin")
    try? data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        let lm = try TrigramLanguageModel(path: url.path)
        let good = lm.scoreSurface("ကျွန်တော်", context: [])
        let bad = lm.scoreSurface("ကျွန်ဈော်", context: [])
        doubleEqual(good, -4.5, "lm_scoreSurface_knownWordsSum")
        if !(bad < good) {
            failedTests.append((
                "lm_reader_scoreSurface_decomposesMultiWord",
                "Expected unknown-piece surface to score lower; good=\(good) bad=\(bad)"
            ))
        }
    } catch {
        failedTests.append(("lm_reader_scoreSurface_decomposesMultiWord", "Load failed: \(error)"))
    }
}

// ===================================================================
// SETTINGS (IMESettings + engine integration)
// ===================================================================

print("=== Settings Tests ===")

func makeFreshSettings() -> (IMESettings, String) {
    let suiteName = "TestRunnerSettings.\(UUID().uuidString)"
    return (IMESettings(suiteName: suiteName), suiteName)
}

runTest("settings_defaultsSeeded") {
    let (settings, suite) = makeFreshSettings()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    assertEqual(settings.candidatePageSize, 9, "settings_defaultPageSize")
    assertTrue(settings.clusterAliasesEnabled, "settings_defaultClusterAliases")
    assertTrue(settings.learningEnabled, "settings_defaultLearning")
    assertFalse(settings.commitOnSpace, "settings_defaultCommitOnSpace")
}

runTest("settings_roundTripThroughSuite") {
    let (settings, suite) = makeFreshSettings()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    settings.candidatePageSize = 5
    settings.lmPruneMargin = 3.5
    settings.anchorCommitThreshold = 12
    let reread = IMESettings(suiteName: suite)
    assertEqual(reread.candidatePageSize, 5, "settings_rt_pageSize")
    assertEqual(reread.anchorCommitThreshold, 12, "settings_rt_anchor")
    assertTrue(abs(reread.lmPruneMargin - 3.5) < 1e-9, "settings_rt_margin")
}

runTest("settings_restoreDefaultsScopedToSection") {
    let (settings, suite) = makeFreshSettings()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    settings.candidatePageSize = 3
    settings.lmPruneMargin = 0.5
    settings.learningEnabled = false

    settings.restoreDefaults(section: .candidateRanking)
    assertTrue(abs(settings.lmPruneMargin - 8.0) < 1e-9, "settings_restore_margin")
    assertEqual(settings.candidatePageSize, 3, "settings_restore_otherSectionsUntouched")
    assertFalse(settings.learningEnabled, "settings_restore_learningUntouched")
}

runTest("settings_engineHonorsCustomPageSize") {
    let (settings, suite) = makeFreshSettings()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    settings.candidatePageSize = 3
    let engine = BurmeseEngine(settings: settings)
    let state = engine.update(buffer: "k", context: [])
    assertTrue(state.candidates.count <= 3,
        "settings_enginePageSizeHonored", detail: "got \(state.candidates.count)")
}

runTest("settings_engineWithoutSettingsUsesDefaults") {
    let engine = BurmeseEngine()
    assertEqual(engine.candidatePageSize, BurmeseEngine.candidatePageSizeDefault, "settings_nil_fallback")
}

runTest("settings_parserClusterAliasesDisabled") {
    let parser = SyllableParser(useClusterAliases: false)
    let parses = parser.parseCandidates("j", maxResults: 8)
    let haveCluster = parses.contains { $0.output == "ကျ" }
    assertFalse(haveCluster, "settings_cluster_disabled_noKaMedial")
}

runTest("settings_parserClusterAliasesEnabled") {
    let parser = SyllableParser(useClusterAliases: true)
    let parses = parser.parseCandidates("j", maxResults: 8)
    let haveCluster = parses.contains { $0.output == "ကျ" }
    assertTrue(haveCluster, "settings_cluster_enabled_hasKaMedial")
}

// Locks in the lazy-rebuild contract relied on by the macOS input controller:
// SyllableParser bakes `useClusterAliases` into its onset lookup at init time,
// so flipping the setting on a live engine does not alter its behaviour. A
// freshly constructed engine must observe the new value.
runTest("settings_clusterAliasesToggleRequiresEngineRebuild") {
    let (settings, suite) = makeFreshSettings()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    settings.clusterAliasesEnabled = true
    let engine = BurmeseEngine(settings: settings)

    let before = engine.update(buffer: "ja", context: [])
    assertTrue(
        before.candidates.map(\.surface).contains { $0.hasPrefix("ကျ") },
        "settings_clusterToggle_preconditionEnabled"
    )

    settings.clusterAliasesEnabled = false
    let afterToggle = engine.update(buffer: "ja", context: [])
    assertTrue(
        afterToggle.candidates.map(\.surface).contains { $0.hasPrefix("ကျ") },
        "settings_clusterToggle_liveEngineUnchanged"
    )

    let rebuilt = BurmeseEngine(settings: settings)
    let afterRebuild = rebuilt.update(buffer: "ja", context: [])
    let rebuiltGrammar = afterRebuild.candidates
        .filter { $0.source == .grammar }
        .map(\.surface)
    assertFalse(
        rebuiltGrammar.contains { $0.hasPrefix("ကျ") },
        "settings_clusterToggle_rebuiltEngineHonorsSetting",
        detail: "\(rebuiltGrammar)"
    )
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

