import BurmeseIMECore

public enum TripleMedialLegalitySuite {

    private static let tripleBasePrefixes = ["k", "kh", "g", "p", "m", "d", "s"]
    private static let forbiddenVowels = ["i", "ay", "u", "aw", "in", "o", "e"]

    private static func hasAsciiSurfaceScalar(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7E
        }
    }

    private static func hasTripleMedialRun(_ surface: String) -> Bool {
        let scalars = Array(surface.unicodeScalars.map(\.value))
        guard scalars.count >= 3 else { return false }
        for i in 0...(scalars.count - 3) {
            if (scalars[i] == 0x103B || scalars[i] == 0x103C)
                && scalars[i + 1] == 0x103D
                && scalars[i + 2] == 0x103E {
                return true
            }
        }
        return false
    }

    private static func candidateSummary(_ candidates: [Candidate]) -> String {
        String(describing: candidates.prefix(6).map { "\($0.surface)/\($0.reading)" })
    }

    public static let suite = TestSuite(name: "TripleMedialLegality", cases: [
        TestCase("permittedVowelsRemainTripleMedialTop") { ctx in
            for buffer in ["kywh", "kywha", "kywhar", "kywhar:"] {
                let state = BurmeseEngine().update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertTrue(
                    hasTripleMedialRun(top),
                    "\(buffer).tripleMedial",
                    detail: "\(buffer) top=\(top) candidates=\(candidateSummary(state.candidates))"
                )
                ctx.assertFalse(
                    hasAsciiSurfaceScalar(top),
                    "\(buffer).noAscii",
                    detail: "\(buffer) top=\(top)"
                )
            }
        },

        TestCase("forbiddenVowelsDoNotTopPureTripleMedial") { ctx in
            for base in tripleBasePrefixes {
                for vowel in forbiddenVowels {
                    let buffer = base + "ywh" + vowel
                    let state = BurmeseEngine().update(buffer: buffer, context: [])
                    let top = state.candidates.first?.surface ?? ""
                    let isPureTripleMedialSurface = hasTripleMedialRun(top)
                        && !hasAsciiSurfaceScalar(top)
                    ctx.assertFalse(
                        isPureTripleMedialSurface,
                        buffer,
                        detail: "\(buffer) top=\(top) candidates=\(candidateSummary(state.candidates))"
                    )
                }
            }
        },
    ])
}
