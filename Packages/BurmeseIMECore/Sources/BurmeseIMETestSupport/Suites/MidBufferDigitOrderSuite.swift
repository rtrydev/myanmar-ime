import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for TASK-001: when a composable buffer contains a run of two
/// or more ASCII digits sandwiched between letter runs
/// (`<letters><digit_run><letters>`), the engine must emit those digits
/// in the same left-to-right order the user typed — both in the
/// Myanmar-digit primary candidate (`U+1040`–`U+1049`) and in the
/// ASCII-digit secondary candidate (`U+0030`–`U+0039`).
///
/// The previous behaviour reversed the run because all insertions for a
/// single digit run share the same scalar splice offset; in-place
/// `Array.insert(at:)` at a fixed position pushes the previously inserted
/// scalar one slot right, so the first scalar inserted ended up rightmost.
public enum MidBufferDigitOrderSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    /// Map an ASCII digit character (`'0'`–`'9'`) to the matching
    /// Myanmar digit scalar (U+1040–U+1049).
    private static func myanmarDigitScalar(for asciiDigit: Character) -> UInt32 {
        let raw = asciiDigit.unicodeScalars.first!.value
        return 0x1040 + (raw - 0x30)
    }

    private static func asciiDigitScalar(for asciiDigit: Character) -> UInt32 {
        asciiDigit.unicodeScalars.first!.value
    }

    /// Returns the scalar values of `surface`.
    private static func scalars(_ surface: String) -> [UInt32] {
        surface.unicodeScalars.map(\.value)
    }

    public static let suite = TestSuite(name: "MidBufferDigitOrder", cases: [

        // For each (left-context, digit-run) shape, the Myanmar-digit
        // primary candidate must contain those digits in left-to-right
        // typed order. Run length spans 2..6 to cover the bug class
        // boundaries; left-context covers consonant + dep-vowel and bare
        // independent vowel anchors.
        TestCase("midBufferDigitRun_myanmarPrimaryPreservesOrder") { ctx in
            let engine = emptyEngine()
            let runs = ["12", "123", "1234", "13579", "246810".prefix(6).description, "987654"]
            // Use both consonant-onset (`kar` / `tar` / `mar`) and bare
            // independent vowel (`a`) left contexts, plus their mirror
            // suffix forms.
            let shapes: [(prefix: String, suffix: String, prefixHex: [UInt32], suffixHex: [UInt32])] = [
                ("kar", "kar", [0x1000, 0x102C], [0x1000, 0x102C]),  // ကာ … ကာ
                ("tar", "tar", [0x1010, 0x102C], [0x1010, 0x102C]),  // တာ … တာ
                ("mar", "mar", [0x1019, 0x102C], [0x1019, 0x102C]),  // မာ … မာ
            ]
            for shape in shapes {
                for run in runs {
                    let buffer = shape.prefix + run + shape.suffix
                    let cands = engine.update(buffer: buffer, context: []).candidates
                    guard let top = cands.first else {
                        ctx.assertTrue(false, buffer, detail: "no candidates")
                        continue
                    }
                    let topScalars = scalars(top.surface)
                    let expectedDigitScalars = run.map(myanmarDigitScalar(for:))
                    let expected = shape.prefixHex + expectedDigitScalars + shape.suffixHex
                    ctx.assertTrue(
                        topScalars == expected,
                        buffer,
                        detail: "top '\(top.surface)' hex=\(topScalars.map { String(format: "%04X", $0) }) expected=\(expected.map { String(format: "%04X", $0) })"
                    )
                }
            }
        },

        // The ASCII-digit secondary candidate must also preserve typed
        // order. The same `insertScalars` path renders it; without an
        // explicit assertion a fix could regress the ASCII path while
        // accidentally repairing the Myanmar path (or vice versa).
        TestCase("midBufferDigitRun_asciiSecondaryPreservesOrder") { ctx in
            let engine = emptyEngine()
            let runs = ["12", "123", "1234", "13579"]
            let shapes: [(prefix: String, suffix: String, prefixHex: [UInt32], suffixHex: [UInt32])] = [
                ("kar", "kar", [0x1000, 0x102C], [0x1000, 0x102C]),
                ("tar", "tar", [0x1010, 0x102C], [0x1010, 0x102C]),
            ]
            for shape in shapes {
                for run in runs {
                    let buffer = shape.prefix + run + shape.suffix
                    let cands = engine.update(buffer: buffer, context: []).candidates
                    let expectedDigitScalars = run.map(asciiDigitScalar(for:))
                    let expected = shape.prefixHex + expectedDigitScalars + shape.suffixHex
                    let found = cands.contains { cand in
                        scalars(cand.surface) == expected
                    }
                    ctx.assertTrue(
                        found,
                        buffer,
                        detail: "no candidate matches expected ASCII-digit hex=\(expected.map { String(format: "%04X", $0) }); got \(cands.map(\.surface))"
                    )
                }
            }
        },

        // Bare independent-vowel left context: `a1234b` must preserve
        // the digit order. The independent vowel `အ` (U+1021) anchors
        // the digit run before the suffix consonant.
        TestCase("midBufferDigitRun_bareVowelLeftContextPreservesOrder") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expectedHex: [UInt32])] = [
                // a + 12 + b → အ + ၁၂ + ဘ
                ("a12b",      [0x1021, 0x1041, 0x1042, 0x1018]),
                // a + 1234 + b → အ + ၁၂၃၄ + ဘ
                ("a1234b",    [0x1021, 0x1041, 0x1042, 0x1043, 0x1044, 0x1018]),
                // a + 13579 + b → အ + ၁၃၅၇၉ + ဘ
                ("a13579b",   [0x1021, 0x1041, 0x1043, 0x1045, 0x1047, 0x1049, 0x1018]),
                // a + 000 + b → အ + ၀၀၀ + ဘ (palindromic — but order
                // assertion still verifies the Myanmar zero scalar is
                // correctly emitted).
                ("a000b",     [0x1021, 0x1040, 0x1040, 0x1040, 0x1018]),
            ]
            for entry in cases {
                let top = engine.update(buffer: entry.buffer, context: []).candidates.first?.surface ?? ""
                let topHex = scalars(top)
                ctx.assertTrue(
                    topHex == entry.expectedHex,
                    entry.buffer,
                    detail: "top '\(top)' hex=\(topHex.map { String(format: "%04X", $0) }) expected=\(entry.expectedHex.map { String(format: "%04X", $0) })"
                )
            }
        },

        // Regression guard: single-digit shapes must still work — the
        // bug only triggered for run length ≥ 2.
        TestCase("midBufferSingleDigit_unchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expectedHex: [UInt32])] = [
                ("a1b",     [0x1021, 0x1041, 0x1018]),                // အ၁ဘ
                ("kar1kar", [0x1000, 0x102C, 0x1041, 0x1000, 0x102C]),// ကာ၁ကာ
                ("tar1tar", [0x1010, 0x102C, 0x1041, 0x1010, 0x102C]),// တာ၁တာ
            ]
            for entry in cases {
                let top = engine.update(buffer: entry.buffer, context: []).candidates.first?.surface ?? ""
                let topHex = scalars(top)
                ctx.assertTrue(
                    topHex == entry.expectedHex,
                    entry.buffer,
                    detail: "top '\(top)' hex=\(topHex.map { String(format: "%04X", $0) }) expected=\(entry.expectedHex.map { String(format: "%04X", $0) })"
                )
            }
        },
    ])
}
