import Foundation
import BurmeseIMECore

/// Coverage for TASK-052: when a `*` (asat marker) sits with a digit
/// (ASCII or Myanmar) as its immediate left context, the engine must
/// not anchor it to a phantom `အ` (U+1021) — the asat needs a
/// consonant base, and digits never serve as one. The pre-fix engine
/// rendered `1*` as `၁အ်` (`1041 1021 103A`) and silently dropped
/// the trailing `*` from `ka1*` (`က၁`). Both paths are structural
/// failures: the first emits an orthographically meaningless cluster,
/// the second loses a typed character from the rank-0 surface.
///
/// Sibling guard for the existing `MidBufferDigitAsatSplitSuite` — which
/// catches the *direct* `<digit><asat>` adjacency — extended here to
/// the indirect `<digit><1021><asat>` shape (the phantom-`အ` injection)
/// and to the trailing-`*`-drop shape.
public enum DigitAsatLiteralSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    /// `<digit><asat>` adjacency — the existing invariant kept here so
    /// every assertion in this suite is self-contained.
    private static func hasDigitBeforeAsat(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 2 else { return false }
        for i in 1..<scalars.count {
            let prev = scalars[i - 1]
            let isAsciiDigit = prev >= 0x30 && prev <= 0x39
            let isMyanmarDigit = prev >= 0x1040 && prev <= 0x1049
            guard isAsciiDigit || isMyanmarDigit else { continue }
            if scalars[i] == 0x103A { return true }
        }
        return false
    }

    /// `<digit><1021>` — the indirect-via-`အ` shape. The engine's
    /// orphan-mark anchor injector inserts U+1021 to satisfy an asat
    /// that has no consonant base; when the asat sits after a digit
    /// the injection produces this signature adjacency.
    private static func hasDigitBeforeIndependentA(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 2 else { return false }
        for i in 1..<scalars.count {
            let prev = scalars[i - 1]
            let isAsciiDigit = prev >= 0x30 && prev <= 0x39
            let isMyanmarDigit = prev >= 0x1040 && prev <= 0x1049
            guard isAsciiDigit || isMyanmarDigit else { continue }
            if scalars[i] == 0x1021 { return true }
        }
        return false
    }

    /// `<digit><1021><103A>` — the full malformed cluster TASK-052
    /// targets. Subset of the previous predicate but called out
    /// separately because it is the exact bug surface.
    private static func hasDigitIndependentAAsat(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        guard scalars.count >= 3 else { return false }
        for i in 2..<scalars.count {
            let prev = scalars[i - 2]
            let isAsciiDigit = prev >= 0x30 && prev <= 0x39
            let isMyanmarDigit = prev >= 0x1040 && prev <= 0x1049
            guard isAsciiDigit || isMyanmarDigit else { continue }
            if scalars[i - 1] == 0x1021 && scalars[i] == 0x103A { return true }
        }
        return false
    }

    /// True iff the surface contains a literal asterisk scalar.
    private static func containsAsterisk(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { $0.value == 0x2A }
    }

    /// Reproduction set from TASK-052 — every input here must clear
    /// the no-`<digit>1021103A` and no-`<digit>1021` invariants on
    /// every candidate.
    static let reproductionInputs: [String] = [
        "1*",      // trailing `*` after single digit
        "1*1",     // `*` between digits
        "12*34",   // multi-digit framing
        "1*2*3",   // multiple `*`s, second silently dropped pre-fix
        "12*",     // multi-digit prefix, trailing `*`
        "1*ka",    // digit, `*`, then letter run
        "ka1*",    // letter, digit, trailing `*` (drop case)
        "ka12*",   // letter, multi-digit, trailing `*` (drop case)
    ]

    /// Inputs whose rank-0 surface should preserve the literal `*`.
    /// Either the literal-fallback (rawBuffer verbatim) is at rank 0,
    /// or the rank-0 surface contains U+002A explicitly somewhere.
    static let trailingAsteriskInputs: [String] = [
        "1*", "12*", "ka1*", "ka12*",
    ]

    /// Regression-guard cases: existing intentional `*`-as-asat paths
    /// that must keep their pre-fix rank-0 surface.
    private static let asatPaths: [(buffer: String, expected: String)] = [
        ("*",   "*"),      // bare `*` → literal asterisk
        ("k*",  "က်"),     // explicit asat on `k` → 1000 103A
        ("kar*", "ကာ်"),   // tall-aa + asat → 1000 102C 103A
        // `ai*` parses as `အိုင်` — the engine prefers the
        // diphthong-reading where the trailing `*` is absorbed as
        // the asat that closes the syllable.
        ("ai*", "အိုင်"),  // 1021 102D 102F 1004 103A
    ]

    public static let suite = TestSuite(name: "DigitAsatLiteral", cases: [

        // Every candidate at every rank must clear the structural
        // invariants. The clean sibling already exists in the panel
        // (the literal-fallback if nothing else); we keep the panel
        // free of the malformed Myanmar shape.
        TestCase("digitAsat_noCandidateContainsDigitIndependentAAsat") { ctx in
            let engine = emptyEngine()
            for input in reproductionInputs {
                let cands = engine.update(buffer: input, context: []).candidates
                ctx.assertTrue(!cands.isEmpty,
                               input,
                               detail: "no candidates returned")
                for (rank, c) in cands.enumerated() {
                    ctx.assertFalse(
                        hasDigitIndependentAAsat(c.surface),
                        input,
                        detail: "candidate #\(rank) '\(c.surface)' contains <digit>1021 103A adjacency"
                    )
                    ctx.assertFalse(
                        hasDigitBeforeIndependentA(c.surface),
                        input,
                        detail: "candidate #\(rank) '\(c.surface)' contains <digit>1021 adjacency"
                    )
                    ctx.assertFalse(
                        hasDigitBeforeAsat(c.surface),
                        input,
                        detail: "candidate #\(rank) '\(c.surface)' contains <digit>103A adjacency"
                    )
                }
            }
        },

        // Trailing-`*` shapes must surface the user's typed asterisk
        // somewhere in the rank-0 candidate (or rank-0 may be the
        // literal-fallback that contains the raw buffer verbatim).
        TestCase("digitAsat_trailingAsterisk_isPreservedAtRank0") { ctx in
            let engine = emptyEngine()
            for input in trailingAsteriskInputs {
                let cands = engine.update(buffer: input, context: []).candidates
                guard let top = cands.first else {
                    ctx.assertTrue(false,
                                   input,
                                   detail: "no rank-0 candidate")
                    continue
                }
                let topHasAsterisk = containsAsterisk(top.surface)
                let topIsRawBuffer = top.surface == input
                ctx.assertTrue(
                    topHasAsterisk || topIsRawBuffer,
                    input,
                    detail: "rank-0 '\(top.surface)' has neither literal '*' nor matches raw buffer"
                )
            }
        },

        // Regression guards: the existing intentional `*`-as-asat
        // paths must keep their pre-fix rank-0 surface exactly.
        TestCase("digitAsat_intentionalAsatPaths_preserved") { ctx in
            let engine = emptyEngine()
            for (input, expected) in asatPaths {
                let top = engine.update(buffer: input, context: [])
                    .candidates.first?.surface ?? ""
                ctx.assertEqual(
                    top,
                    expected,
                    "\(input)_top_hex=\(hex(top))_expectedHex=\(hex(expected))"
                )
            }
        },
    ])

    private static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
    }
}
