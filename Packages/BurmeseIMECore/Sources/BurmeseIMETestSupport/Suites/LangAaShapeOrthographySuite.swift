import Foundation
import BurmeseIMECore

/// Step 4 / Tier 1 — C3 (tall vs round aa orthography).
///
/// Burmese uses tall-aa (◌ါ U+102B) on the six descender bases
/// {ခ ဂ င ဒ ပ ဝ} and round-aa (◌ာ U+102C) on every other base.
/// The rule survives the tonal modifier suffixes (`ar.` / `ar:`)
/// and the -aw / -aung compound rimes that bake an aa-shape into
/// their canonical surface.
public enum LangAaShapeOrthographySuite {

    private static let descenderBases: [(input: String, base: UInt32)] = [
        ("kha", 0x1001),
        ("ga",  0x1002),
        ("nga", 0x1004),
        ("da",  0x1012),
        ("pa",  0x1015),
        ("wa",  0x101D),
    ]

    private static let nonDescenderBases: [(input: String, base: UInt32)] = [
        ("ka",  0x1000),
        ("ma",  0x1019),
        ("ta",  0x1010),
        ("na",  0x1014),
        ("la",  0x101C),
        ("ya",  0x101A),
    ]

    private static func bareEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    private static func rank0(_ buffer: String) -> String {
        bareEngine().update(buffer: buffer, context: []).candidates.first?.surface ?? ""
    }

    public static let suite = TestSuite(name: "LangAaShapeOrthography", cases: [

        // Descender bases — rank-0 surface contains tall-aa U+102B
        // and not round-aa U+102C.
        TestCase("descender_tallAa_bareAa") { ctx in
            for entry in descenderBases {
                let input = entry.input + "r"  // e.g. "par"
                let surface = rank0(input)
                ctx.assertTrue(
                    surface.unicodeScalars.contains(Unicode.Scalar(0x102B)!),
                    input,
                    detail: "rank-0 lacks U+102B for descender base \(input): '\(surface)'"
                )
                ctx.assertFalse(
                    surface.unicodeScalars.contains(Unicode.Scalar(0x102C)!),
                    input,
                    detail: "rank-0 wrongly contains U+102C for descender base \(input): '\(surface)'"
                )
            }
        },

        TestCase("descender_tallAa_creakyTone") { ctx in
            for entry in descenderBases {
                let input = entry.input + "r."
                let surface = rank0(input)
                ctx.assertTrue(
                    surface.unicodeScalars.contains(Unicode.Scalar(0x102B)!),
                    input,
                    detail: "rank-0 lacks U+102B for creaky-tone descender \(input): '\(surface)'"
                )
            }
        },

        TestCase("descender_tallAa_heavyTone") { ctx in
            for entry in descenderBases {
                let input = entry.input + "r:"
                let surface = rank0(input)
                ctx.assertTrue(
                    surface.unicodeScalars.contains(Unicode.Scalar(0x102B)!),
                    input,
                    detail: "rank-0 lacks U+102B for heavy-tone descender \(input): '\(surface)'"
                )
            }
        },

        TestCase("descender_tallAa_awCompound") { ctx in
            for entry in descenderBases {
                let input = entry.input + "w"  // -aw rime
                let surface = rank0(input)
                ctx.assertTrue(
                    surface.unicodeScalars.contains(Unicode.Scalar(0x102B)!),
                    input,
                    detail: "rank-0 lacks U+102B for -aw on descender \(input): '\(surface)'"
                )
            }
        },

        TestCase("descender_tallAa_aungCompound") { ctx in
            for entry in descenderBases {
                let input = entry.input + "ung"
                let surface = rank0(input)
                ctx.assertTrue(
                    surface.unicodeScalars.contains(Unicode.Scalar(0x102B)!),
                    input,
                    detail: "rank-0 lacks U+102B for -aung on descender \(input): '\(surface)'"
                )
            }
        },

        // Non-descender bases — rank-0 surface contains round-aa U+102C
        // and not tall-aa U+102B.
        TestCase("nonDescender_roundAa_bareAa") { ctx in
            for entry in nonDescenderBases {
                let input = entry.input + "r"
                let surface = rank0(input)
                ctx.assertTrue(
                    surface.unicodeScalars.contains(Unicode.Scalar(0x102C)!),
                    input,
                    detail: "rank-0 lacks U+102C for non-descender base \(input): '\(surface)'"
                )
                ctx.assertFalse(
                    surface.unicodeScalars.contains(Unicode.Scalar(0x102B)!),
                    input,
                    detail: "rank-0 wrongly contains U+102B for non-descender base \(input): '\(surface)'"
                )
            }
        },

        TestCase("nonDescender_roundAa_heavyTone") { ctx in
            for entry in nonDescenderBases {
                let input = entry.input + "r:"
                let surface = rank0(input)
                ctx.assertTrue(
                    surface.unicodeScalars.contains(Unicode.Scalar(0x102C)!),
                    input,
                    detail: "rank-0 lacks U+102C for heavy-tone non-descender \(input): '\(surface)'"
                )
            }
        },
    ])
}
