import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for task 04: a mid-buffer digit's splice position must
/// never land between a consonant base and one of its medial scalars
/// (U+103B–U+103E). The medial physically attaches to the base in
/// Unicode storage order — splitting them produces a structurally
/// illegal `<C><digit><medial>` shape.
///
/// Two trigger paths cover all four medials:
/// - Post-aspirated `h` folded into the next consonant's medial-Ha
///   (`hm` → `မှ` etc.). When a digit lands between the `h` and
///   the following base (`h1ma`), the prefix-only parse counts the
///   `h` as a standalone consonant; the full-buffer parse re-attributes
///   it as a medial-Ha — the splice position is now off by one and
///   detaches `103E`.
/// - Single base + medial-trigger letter (`y`/`r`/`w`). When a digit
///   sits between (`k1ya`), the prefix parse counts `1` scalar but
///   the full parse adds the medial as scalar 2 — the digit detaches
///   the medial.
public enum MidBufferDigitMedialSplitSuite {

    private static func emptyEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func topSurface(_ engine: BurmeseEngine, _ input: String) -> String {
        engine.update(buffer: input, context: []).candidates.first?.surface ?? ""
    }

    /// Returns true when the surface contains any `<digit><medial>`
    /// adjacency — the exact orphan-medial signature.
    private static func hasDetachedMedialAfterDigit(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        for i in 1..<scalars.count {
            let prev = scalars[i - 1]
            let isAsciiDigit = prev >= 0x30 && prev <= 0x39
            let isMyanmarDigit = prev >= 0x1040 && prev <= 0x1049
            guard isAsciiDigit || isMyanmarDigit else { continue }
            let cur = scalars[i]
            if cur >= 0x103B && cur <= 0x103E { return true }
        }
        return false
    }

    /// True when the surface contains any orphan medial — a medial
    /// scalar (`103B…103E`) whose preceding scalar is not a consonant
    /// base (`1000…1021`) or another medial.
    private static func hasOrphanMedial(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars).map(\.value)
        for i in scalars.indices {
            let v = scalars[i]
            guard v >= 0x103B && v <= 0x103E else { continue }
            guard i > 0 else { return true }
            let prev = scalars[i - 1]
            let isBase = prev >= 0x1000 && prev <= 0x1021
            let isMedial = prev >= 0x103B && prev <= 0x103E
            if !isBase && !isMedial { return true }
        }
        return false
    }

    public static let suite = TestSuite(name: "MidBufferDigitMedialSplit", cases: [

        // Post-aspirated h-fold cases — the digit sits between `h`
        // and the following base. The full-buffer parse folds `h`
        // into the base's medial-Ha (103E); the splice must not
        // detach it.
        TestCase("postAspiratedH_digitDoesNotDetachMedialHa") { ctx in
            let engine = emptyEngine()
            let cases = [
                "h1ma", "h1na", "h1la", "h1nga", "h1nya",
                "kah1na", "brah1ma",
            ]
            for input in cases {
                let top = topSurface(engine, input)
                ctx.assertFalse(
                    hasDetachedMedialAfterDigit(top),
                    input,
                    detail: "top '\(top)' has digit followed by medial"
                )
                ctx.assertFalse(
                    hasOrphanMedial(top),
                    input,
                    detail: "top '\(top)' has orphan medial"
                )
            }
        },

        // Base + y/r/w medial-trigger cases — the digit must not
        // sit between the base and the medial.
        TestCase("baseMedialTrigger_digitDoesNotDetachMedial") { ctx in
            let engine = emptyEngine()
            let cases = ["k1ya", "p1ra", "t1wa"]
            for input in cases {
                let top = topSurface(engine, input)
                ctx.assertFalse(
                    hasDetachedMedialAfterDigit(top),
                    input,
                    detail: "top '\(top)' has digit followed by medial"
                )
                ctx.assertFalse(
                    hasOrphanMedial(top),
                    input,
                    detail: "top '\(top)' has orphan medial"
                )
            }
        },

        // Sibling cases that already work — digit at a clean boundary
        // (after the medial, at end of syllable, after a complete
        // `<C>+medial` syllable). These must stay clean.
        TestCase("digitAtCleanBoundary_unchanged") { ctx in
            let engine = emptyEngine()
            let cases: [(buffer: String, expectedHex: [UInt32])] = [
                ("hm1a",   [0x1019, 0x103E, 0x1041]),                          // မှ၁
                ("hma1",   [0x1019, 0x103E, 0x1041]),                          // မှ၁
                ("kya1ya", [0x1000, 0x103B, 0x1041, 0x101A]),                  // ကျ၁ယ
                ("kyaw1",  [0x1000, 0x103B, 0x1031, 0x102C, 0x103A, 0x1041]),  // ကျော်၁
                ("pya1ka", [0x1015, 0x103C, 0x1041, 0x1000]),                  // ပြ၁က
            ]
            for entry in cases {
                let top = topSurface(engine, entry.buffer)
                let hex = top.unicodeScalars.map(\.value)
                ctx.assertTrue(
                    hex == entry.expectedHex,
                    entry.buffer,
                    detail: "top '\(top)' hex=\(hex.map { String(format: "%04X", $0) }) expected=\(entry.expectedHex.map { String(format: "%04X", $0) })"
                )
            }
        },
    ])
}
