import BurmeseIMECore

public enum MedialHaForbiddenVowelsSuite {

    private static let buffers = [
        "hmi:", "hmi2:", "hmu:", "hmu2:",
        "khi:", "khi2:", "khu:", "khu2:",
        "phi:", "phi2:", "phu:", "phu2:",
    ]

    private static func hasAsciiSurfaceScalar(_ surface: String) -> Bool {
        surface.unicodeScalars.contains { scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7E
        }
    }

    private static func hasMedialHaForbiddenLongVowel(_ surface: String) -> Bool {
        let scalars = surface.unicodeScalars.map(\.value)
        return scalars.contains(0x103E)
            && (scalars.contains(0x102E) || scalars.contains(0x1030))
            && !hasAsciiSurfaceScalar(surface)
    }

    private static func candidateSummary(_ candidates: [Candidate]) -> String {
        String(describing: candidates.prefix(6).map { "\($0.surface)/\($0.reading)" })
    }

    public static let suite = TestSuite(name: "MedialHaForbiddenVowels", cases: [
        TestCase("forbiddenLongIAndLongUDoNotTopPureHaHtoeSurface") { ctx in
            for buffer in buffers {
                let state = BurmeseEngine().update(buffer: buffer, context: [])
                let top = state.candidates.first?.surface ?? ""
                ctx.assertFalse(
                    hasMedialHaForbiddenLongVowel(top),
                    buffer,
                    detail: "\(buffer) top=\(top) candidates=\(candidateSummary(state.candidates))"
                )
            }
        },
    ])
}
