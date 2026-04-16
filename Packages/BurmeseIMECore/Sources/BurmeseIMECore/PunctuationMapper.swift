import Foundation

/// ASCII → Myanmar punctuation mapping, applied at commit time by the IMK
/// controller. Consulted only when `IMESettings.burmesePunctuationEnabled`
/// is on and the surrounding context is Myanmar (active composition, or
/// the previously committed token contains Myanmar text). Bilingual and
/// ASCII-only contexts pass through untouched — see `BurmeseInputController`.
public enum PunctuationMapper: Sendable {

    /// ASCII punctuation → its Myanmar equivalent. `.`, `!`, `?` all fold
    /// to the full-stop sign ။ (U+104B); `,` and `;` fold to the minor
    /// phrase separator ၊ (U+104A).
    public static let mapping: [Character: String] = [
        ".": "\u{104B}",
        "!": "\u{104B}",
        "?": "\u{104B}",
        ",": "\u{104A}",
        ";": "\u{104A}",
    ]

    /// Returns the Myanmar replacement for `c`, or nil if `c` has no mapping.
    public static func mapped(_ c: Character) -> String? {
        mapping[c]
    }

    /// True when `c` is one of the ASCII punctuation characters we map.
    public static func isMappable(_ c: Character) -> Bool {
        mapping[c] != nil
    }

    /// True when `s` contains at least one Myanmar-script scalar
    /// (U+1000–U+109F). Used to gate punctuation mapping on "the previous
    /// token is Myanmar" — keeps `.` inside `e.g.` or URLs literal.
    public static func isMyanmar(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x1000...0x109F).contains($0.value) }
    }
}
