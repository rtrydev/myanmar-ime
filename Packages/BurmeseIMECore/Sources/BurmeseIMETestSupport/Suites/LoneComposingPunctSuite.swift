import Foundation
@_spi(Testing) import BurmeseIMECore

/// Coverage for task 04: a buffer containing nothing but composing-
/// punctuation modifier characters (`'`, `+`, `*`, `.`, `:` —
/// individually or repeated) must produce a single literal-passthrough
/// candidate equal to the raw buffer. Empty-surface candidates and
/// empty panels both leave the user with no way to commit the typed
/// character (or, in the empty-surface case, silently commit nothing).
public enum LoneComposingPunctSuite {

    private static func defaultEngine() -> BurmeseEngine {
        BurmeseEngine(candidateStore: EmptyCandidateStore(), languageModel: NullLanguageModel())
    }

    public static let suite = TestSuite(name: "LoneComposingPunct", cases: [

        // Single-character composing-punct buffers must produce a
        // literal-passthrough candidate.
        TestCase("loneComposingPunct_singleCharProducesLiteralPass") { ctx in
            let engine = defaultEngine()
            for buffer in ["'", "+", "*", ".", ":"] {
                let state = engine.update(buffer: buffer, context: [])
                ctx.assertFalse(
                    state.candidates.isEmpty,
                    buffer,
                    detail: "panel is empty; user can't commit '\(buffer)'"
                )
                ctx.assertTrue(
                    state.candidates.contains { $0.surface == buffer },
                    buffer,
                    detail: "no literal-passthrough candidate; got \(state.candidates.map(\.surface))"
                )
            }
        },

        // Empty-surface candidates must NOT exist for these buffers.
        // Committing one would silently emit nothing.
        TestCase("loneComposingPunct_noEmptySurfaceCandidate") { ctx in
            let engine = defaultEngine()
            for buffer in ["'", "+", "*", ".", ":"] {
                let state = engine.update(buffer: buffer, context: [])
                ctx.assertFalse(
                    state.candidates.contains { $0.surface.isEmpty },
                    buffer,
                    detail: "panel contains an empty-surface candidate: \(state.candidates.map(\.surface))"
                )
            }
        },

        // Repeated composing-punct buffers (`''`, `''''`, `..`, `::`,
        // `**`) must also produce literal-passthrough candidates.
        TestCase("loneComposingPunct_repeatedCharsProduceLiteralPass") { ctx in
            let engine = defaultEngine()
            for buffer in ["''", "''''", "..", "::", "**"] {
                let state = engine.update(buffer: buffer, context: [])
                ctx.assertTrue(
                    state.candidates.contains { $0.surface == buffer },
                    buffer,
                    detail: "no literal-passthrough candidate; got \(state.candidates.map(\.surface))"
                )
            }
        },

        // Two-character buffers built on top of a composing-punct char
        // (`'a`, `'thar`) continue to work — the parser consumes the
        // separator and parses the rest.
        TestCase("loneComposingPunct_overlaidContentStillParses") { ctx in
            let engine = defaultEngine()
            for (buffer, expected) in [
                ("'a", "\u{1021}"),                             // အ
                ("'thar", "\u{101E}\u{102C}"),                  // သာ
            ] {
                let top = engine.update(buffer: buffer, context: []).candidates.first?.surface ?? ""
                ctx.assertTrue(
                    top == expected,
                    buffer,
                    detail: "expected top='\(expected)'; got='\(top)'"
                )
            }
        },

        // Regression for engine_connectorOnlyPlus / engine_connectorOnlyApostrophes:
        // the literal-pass candidate must NOT contain a synthetic `အ`
        // (U+1021). The fix path emits the raw buffer, never injects
        // an independent vowel.
        TestCase("loneComposingPunct_noSyntheticIndependentA") { ctx in
            let engine = defaultEngine()
            for buffer in ["'", "+", "*", ".", ":", "'''", "+++", "..."] {
                let state = engine.update(buffer: buffer, context: [])
                for candidate in state.candidates {
                    ctx.assertFalse(
                        candidate.surface.unicodeScalars.contains { $0.value == 0x1021 },
                        buffer,
                        detail: "synthetic U+1021 in surface '\(candidate.surface)'"
                    )
                }
            }
        },
    ])
}
