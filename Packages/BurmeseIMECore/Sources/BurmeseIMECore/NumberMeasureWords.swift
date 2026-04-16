import Foundation

/// Loader for `Data/NumberMeasureWords.tsv`, consulted by `BurmeseEngine`
/// when the composition buffer is pure ASCII digits and
/// `IMESettings.numberMeasureWordsEnabled` is on. Entries are cached after
/// the first load; the file is bundled as a Swift package resource.
///
/// TSV format: `measure_word<TAB>score<TAB>match_pattern`. Lines starting
/// with `#` and empty lines are ignored. Unknown patterns are silently
/// skipped so the TSV can evolve without a Swift release.
public final class NumberMeasureWords: @unchecked Sendable {

    /// Predicate that decides whether an entry applies to a given digit
    /// string. `any` always fires; the others inspect the numeric value.
    public enum Pattern: String, Sendable {
        case any
        case currencyGe100  = "currency_ge_100"
        case year4digit     = "year_4digit"
        case hourGe1Le24    = "hour_ge_1_le_24"
        case minuteGe0Le59  = "minute_ge_0_le_59"
        case dayGe1Le31     = "day_ge_1_le_31"

        public func matches(_ digits: String) -> Bool {
            switch self {
            case .any:
                return true
            case .year4digit:
                // Plausible 4-digit Gregorian year: 1000–2999.
                guard digits.count == 4, let first = digits.first else { return false }
                return first == "1" || first == "2"
            case .currencyGe100:
                guard let n = Int(digits) else { return false }
                return n >= 100
            case .hourGe1Le24:
                guard let n = Int(digits) else { return false }
                return n >= 1 && n <= 24
            case .minuteGe0Le59:
                guard let n = Int(digits) else { return false }
                return n >= 0 && n <= 59
            case .dayGe1Le31:
                guard let n = Int(digits) else { return false }
                return n >= 1 && n <= 31
            }
        }
    }

    public struct Entry: Sendable, Equatable {
        public let measureWord: String
        public let score: Int
        public let pattern: Pattern
    }

    public static let shared = NumberMeasureWords()

    private let lock = NSLock()
    private var loadedEntries: [Entry]?
    private let resourceName: String
    private let resourceExtension: String
    private let bundle: Bundle

    /// Default instance loads from the package resource bundle. Tests can
    /// inject an explicit bundle + resource name to exercise fallback
    /// behavior by passing `bundle:` explicitly.
    public init(
        bundle: Bundle? = nil,
        resourceName: String = "NumberMeasureWords",
        resourceExtension: String = "tsv"
    ) {
        self.bundle = bundle ?? Bundle.module
        self.resourceName = resourceName
        self.resourceExtension = resourceExtension
    }

    /// Return up to `limit` measure-word candidates that apply to `digits`,
    /// sorted by descending score. `digits` must be ASCII `0-9` only;
    /// non-digit input yields an empty list.
    public func candidates(forDigits digits: String, limit: Int) -> [Entry] {
        guard limit > 0,
              !digits.isEmpty,
              digits.allSatisfy({ ("0"..."9").contains($0) })
        else { return [] }
        let all = entries()
        var applicable = all.filter { $0.pattern.matches(digits) }
        applicable.sort { $0.score > $1.score }
        if applicable.count > limit {
            applicable = Array(applicable.prefix(limit))
        }
        return applicable
    }

    /// All loaded entries (cached after first call). Public mostly for tests.
    public func entries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = loadedEntries { return cached }
        let parsed = Self.load(bundle: bundle, name: resourceName, ext: resourceExtension)
        loadedEntries = parsed
        return parsed
    }

    private static func load(bundle: Bundle, name: String, ext: String) -> [Entry] {
        guard let url = bundle.url(forResource: name, withExtension: ext),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        var out: [Entry] = []
        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.components(separatedBy: "\t")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard parts.count >= 3,
                  let score = Int(parts[1]),
                  let pattern = Pattern(rawValue: parts[2])
            else { continue }
            out.append(Entry(measureWord: parts[0], score: score, pattern: pattern))
        }
        return out
    }
}
