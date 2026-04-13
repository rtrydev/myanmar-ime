/// Standalone test runner for BurmeseIMECore.
/// Runs without Xcode/XCTest — usable with Command Line Tools only.

import Foundation
import BurmeseIMECore

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
    assertEqual(Romanization.normalize("thar2"), "thar2", "normalize_keepsDigits")
    assertEqual(Romanization.normalize("min+galar"), "min+galar", "normalize_keepsSpecials")
    assertEqual(Romanization.normalize("hello!@#"), "hello", "normalize_stripsInvalid")
}

runTest("composingChars") {
    for ch: Character in Array("abcdefghijklmnopqrstuvwxyz0123456789+*':.") {
        assertTrue(Romanization.composingCharacters.contains(ch),
                   "composingChar_\(ch)", detail: "Missing: \(ch)")
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

// ===================================================================
// KNOWN-GOOD LEGACY FIXTURE TESTS
// ===================================================================

print("=== Known-Good Legacy Fixtures ===")

runTest("thar") { assertEqual(parse("thar"), "သာ", "knownGood_thar") }
runTest("thar2") { assertEqual(parse("thar2"), "သါ", "knownGood_thar2") }
runTest("kyaw") { assertEqual(parse("kyaw"), "ကြော်", "knownGood_kyaw") }
runTest("kyaw2") { assertEqual(parse("kyaw2"), "ကြေါ်", "knownGood_kyaw2") }
runTest("min+galarpar2") { assertEqual(parse("min+galarpar2"), "မင်္ဂလာပါ", "knownGood_minGalarPar2") }
runTest("ahin+gar2gyoh*") { assertEqual(parse("ahin+gar2gyoh*"), "အင်္ဂါဂြိုဟ်", "knownGood_ahinGar2GyoH") }
runTest("hran2:khout2hswe:") { assertEqual(parse("hran2:khout2hswe:"), "ရှမ်းခေါက်ဆွဲ", "knownGood_shanNoodles") }
runTest("rway:khy2e") { assertEqual(parse("rway:khy2e"), "ရွေးချယ်", "knownGood_choose") }

// ===================================================================
// ADDITIONAL LEGACY FIXTURES
// ===================================================================

print("=== Additional Legacy Fixtures ===")

runTest("mingalarpar2") {
    // Without explicit '+', the common phrase parses differently — the legacy engine
    // produces "မီငလာပါ" which is incorrect. Our engine should produce a reasonable
    // Myanmar-only output (no mixed script), but it won't match the '+' version.
    let result = parse("mingalarpar2")
    for scalar in result.unicodeScalars {
        let isOk = Myanmar.isMyanmar(scalar) || scalar.value == 0x200C
        assertTrue(isOk, "mingalarpar2_noLatinLeakage",
                   detail: "Found non-Myanmar U+\(String(scalar.value, radix: 16)) in: \(escapeUnicode(result))")
    }
}

runTest("nay2") {
    // Legacy engine produces "နဧ" — numeric alternate over-applies.
    // Our engine should produce Myanmar-only output.
    let result = parse("nay2")
    for scalar in result.unicodeScalars {
        let isOk = Myanmar.isMyanmar(scalar) || scalar.value == 0x200C
        assertTrue(isOk, "nay2_noLatinLeakage",
                   detail: "Found non-Myanmar U+\(String(scalar.value, radix: 16)) in: \(escapeUnicode(result))")
    }
}

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

runTest("kya2_noLatinLeakage") {
    let result = parse("kya2")
    for scalar in result.unicodeScalars {
        let isOk = Myanmar.isMyanmar(scalar) || scalar.value == 0x200C
        assertTrue(isOk, "knownBad_kya2_noLatinLeakage",
                   detail: "Found non-Myanmar U+\(String(scalar.value, radix: 16))")
    }
}

// ===================================================================
// LEADING-VOWEL / U+200C TESTS
// ===================================================================

print("=== Leading-Vowel / U+200C Tests ===")

runTest("leadingVowel_u") { assertEqual(parse("u"), "\u{200C}\u{1030}", "leadingVowel_u") }
runTest("leadingVowel_ay") { assertEqual(parse("ay"), "\u{200C}\u{1031}", "leadingVowel_ay") }
runTest("leadingVowel_aw") { assertEqual(parse("aw"), "\u{200C}\u{1031}\u{102C}\u{103A}", "leadingVowel_aw") }
runTest("leadingVowel_aw2") { assertEqual(parse("aw2"), "\u{200C}\u{1031}\u{102B}\u{103A}", "leadingVowel_aw2") }
runTest("leadingVowel_aw:") { assertEqual(parse("aw:"), "\u{200C}\u{1031}\u{102C}", "leadingVowel_aw_colon") }
runTest("leadingVowel_aw2:") { assertEqual(parse("aw2:"), "\u{200C}\u{1031}\u{102B}", "leadingVowel_aw2_colon") }
runTest("leadingVowel_own") { assertEqual(parse("own"), "\u{200C}\u{102F}\u{1014}\u{103A}", "leadingVowel_own") }
runTest("leadingVowel_own2") { assertEqual(parse("own2"), "\u{200C}\u{102F}\u{1019}\u{103A}", "leadingVowel_own2") }
runTest("leadingVowel_own3") { assertEqual(parse("own3"), "\u{200C}\u{102F}\u{1036}", "leadingVowel_own3") }

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
