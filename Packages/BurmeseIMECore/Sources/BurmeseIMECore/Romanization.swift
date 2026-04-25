/// Maps between Hybrid Burmese romanization and Myanmar Unicode.
///
/// This replaces the flat rule table from the legacy web engine with explicit,
/// structured mappings that the grammar can validate for legality.
public enum Romanization {

    // MARK: - Consonant Mappings

    /// Each entry: (romanKey, myanmarCharacter, aliasCost).
    /// aliasCost = 0 for canonical, >0 for alternates.
    public struct ConsonantEntry: Sendable {
        public let roman: String
        public let myanmar: Character
        public let aliasCost: Int

        public init(_ roman: String, _ myanmar: Character, _ aliasCost: Int = 0) {
            self.roman = roman
            self.myanmar = myanmar
            self.aliasCost = aliasCost
        }
    }

    /// The 33 base consonants with their romanization.
    /// The roman key here is the "base" form (without trailing 'a').
    public static let consonants: [ConsonantEntry] = [
        .init("k", Myanmar.ka),
        .init("kh", Myanmar.kha),
        .init("g", Myanmar.ga),
        .init("gh", Myanmar.gha),
        .init("ng", Myanmar.nga),
        .init("hs", Myanmar.cha),       // ဆ = hsa → base "hs"
        .init("s", Myanmar.ca),          // စ = sa → base "s"
        .init("z", Myanmar.ja),          // ဇ = za → base "z"
        .init("zz", Myanmar.jha),        // ဈ = zza → base "zz"
        .init("ny", Myanmar.nnya),       // ည = nnya → base "ny" (common curly form)
        .init("ny2", Myanmar.nya),       // ဉ = nya → base "ny2" (rare flat form)
        .init("t2", Myanmar.tta),        // ဋ = t2a → base "t2"
        .init("ht2", Myanmar.ttha),      // ဌ = ht2a → base "ht2"
        .init("d2", Myanmar.dda),        // ဍ = d2a → base "d2"
        .init("dh2", Myanmar.ddha),      // ဎ = dh2a → base "dh2"
        .init("n2", Myanmar.nna),        // ဏ = n2a → base "n2"
        .init("t", Myanmar.ta),
        .init("ht", Myanmar.tha),        // ထ = hta → base "ht"
        .init("d", Myanmar.da),
        .init("dh", Myanmar.dha),
        .init("n", Myanmar.na),
        .init("p", Myanmar.pa),
        .init("ph", Myanmar.pha),
        .init("v", Myanmar.ba),          // ဗ = va → base "v"
        .init("b", Myanmar.bha),         // ဘ = ba → base "b"
        .init("m", Myanmar.ma),
        .init("y", Myanmar.ya),
        .init("r", Myanmar.ra),
        .init("l", Myanmar.la),
        .init("w", Myanmar.wa),          // ဝ
        .init("th", Myanmar.sa),         // သ = tha → base "th"
        .init("h", Myanmar.ha),          // ဟ = ha → base "h"
        .init("l2", Myanmar.lla),        // ဠ = l2a → base "l2"
        .init("ah", Myanmar.ah),         // အ = ah (no trailing 'a' removal)
        .init("ss", Myanmar.greatSa),    // ဿ = great sa (doubled-s mnemonic)
    ]

    /// Lookup: roman base → myanmar consonant.
    public static let romanToConsonant: [String: Character] = {
        var dict: [String: Character] = [:]
        for entry in consonants {
            dict[entry.roman] = entry.myanmar
        }
        return dict
    }()

    /// Lookup: myanmar consonant → roman base.
    public static let consonantToRoman: [Character: String] = {
        var dict: [Character: String] = [:]
        for entry in consonants {
            dict[entry.myanmar] = entry.roman
        }
        return dict
    }()

    // MARK: - Medial Mappings

    /// Medial consonant signs with their roman key.
    public struct MedialEntry: Sendable {
        public let roman: String
        public let myanmar: Character

        public init(_ roman: String, _ myanmar: Character) {
            self.roman = roman
            self.myanmar = myanmar
        }
    }

    /// The four medial consonant signs.
    /// Order: ya-pin (ျ), ya-yit (ြ), wa-hswe (ွ), ha-htoe (ှ).
    public static let medials: [MedialEntry] = [
        .init("y2", Myanmar.medialYa),   // ျ (ya-pin)
        .init("y",  Myanmar.medialRa),    // ြ (ya-yit)
        .init("w",  Myanmar.medialWa),    // ွ (wa-hswe)
        .init("h",  Myanmar.medialHa),    // ှ (ha-htoe)
    ]

    // MARK: - Cluster-sound shortcut aliases
    //
    // Phonetic shortcuts for common consonant+medial clusters. These coexist
    // with the structural romanization (`ky2`, `khy2`, `gy2`, `hr`, …) —
    // canonical typing is unchanged; these just offer extra keys that produce
    // the same onset.

    public struct ClusterAliasEntry: Sendable {
        public let roman: String
        public let consonant: Character
        public let medials: [Character]
        public let aliasCost: Int

        public init(roman: String, consonant: Character, medials: [Character], aliasCost: Int = 50) {
            self.roman = roman
            self.consonant = consonant
            self.medials = medials
            self.aliasCost = aliasCost
        }
    }

    /// Phonetically, "kya"/"cha"/"gya" can be spelled with either ya-pin (ျ) or
    /// ya-yit (ြ). The canonical structural scheme exposes both — "kya" yields
    /// both ကြ (canonical "ky") and ကျ (digit-stripped alias of "ky2"). The
    /// cluster aliases below mirror that behaviour: each ya-pin shortcut gets
    /// a ya-yit twin at a slight alias-cost bump so users typing "jar" see
    /// ကြာ in the candidate list alongside ကျာ.
    ///
    /// The medial preference for `ky` / `khy` / `gy` / `ghy` is handled at
    /// the engine layer (`BurmeseEngine.yaPinPreferredOnsetClusters`,
    /// task 02), not here — keeping the cluster table parser-symmetric
    /// preserves the reverse-romanizer round-trip (`ကြောင်း` ↔
    /// `kyaung:`) that several test suites and lexicon offline tools
    /// rely on. Lexicon evidence shows ya-pin dominates these clusters
    /// (`ကျ` 1.95M vs `ကြ` 531k, `ဂျပန်` 87k vs `ဂြပန်` 0, …); the
    /// engine-level promotion runs after parsing and surfaces the
    /// ya-pin sibling on top while the structural ya-yit form stays
    /// reachable as a lower-ranked candidate.
    public static let clusterAliases: [ClusterAliasEntry] = [
        .init(roman: "j",   consonant: Myanmar.ka,  medials: [Myanmar.medialYa], aliasCost: 0),
        .init(roman: "j",   consonant: Myanmar.ka,  medials: [Myanmar.medialRa], aliasCost: 1),
        .init(roman: "jw",  consonant: Myanmar.ka,  medials: [Myanmar.medialYa, Myanmar.medialWa], aliasCost: 0),
        .init(roman: "jw",  consonant: Myanmar.ka,  medials: [Myanmar.medialRa, Myanmar.medialWa], aliasCost: 1),
        .init(roman: "ch",  consonant: Myanmar.kha, medials: [Myanmar.medialYa], aliasCost: 0),
        .init(roman: "ch",  consonant: Myanmar.kha, medials: [Myanmar.medialRa], aliasCost: 1),
        .init(roman: "chw", consonant: Myanmar.kha, medials: [Myanmar.medialYa, Myanmar.medialWa], aliasCost: 0),
        .init(roman: "chw", consonant: Myanmar.kha, medials: [Myanmar.medialRa, Myanmar.medialWa], aliasCost: 1),
        .init(roman: "gy",  consonant: Myanmar.ga,  medials: [Myanmar.medialYa]),
        .init(roman: "gyw", consonant: Myanmar.ga,  medials: [Myanmar.medialYa, Myanmar.medialWa]),
        .init(roman: "sh",  consonant: Myanmar.ra,  medials: [Myanmar.medialHa], aliasCost: 0),
        .init(roman: "shw", consonant: Myanmar.ra,  medials: [Myanmar.medialWa, Myanmar.medialHa], aliasCost: 0),
        // Pali/Sanskrit transliteration aliases: users often type `Cr`
        // where Burmese orthography writes C + ya-yit (ြ). Keep these
        // as moderate-cost aliases so structural `Cy` remains canonical
        // while loanword spellings like `brahma` / `pray` are reachable.
        .init(roman: "kr",  consonant: Myanmar.ka,  medials: [Myanmar.medialRa], aliasCost: 10),
        .init(roman: "gr",  consonant: Myanmar.ga,  medials: [Myanmar.medialRa], aliasCost: 10),
        .init(roman: "sr",  consonant: Myanmar.ca,  medials: [Myanmar.medialRa], aliasCost: 10),
        .init(roman: "tr",  consonant: Myanmar.ta,  medials: [Myanmar.medialRa], aliasCost: 10),
        .init(roman: "dr",  consonant: Myanmar.da,  medials: [Myanmar.medialRa], aliasCost: 10),
        .init(roman: "pr",  consonant: Myanmar.pa,  medials: [Myanmar.medialRa], aliasCost: 10),
        .init(roman: "br",  consonant: Myanmar.ba,  medials: [Myanmar.medialRa], aliasCost: 10),
        .init(roman: "vr",  consonant: Myanmar.ba,  medials: [Myanmar.medialRa], aliasCost: 10),
        .init(roman: "khr", consonant: Myanmar.kha, medials: [Myanmar.medialRa], aliasCost: 10),
        .init(roman: "ghr", consonant: Myanmar.gha, medials: [Myanmar.medialRa], aliasCost: 10),
        .init(roman: "thr", consonant: Myanmar.tha, medials: [Myanmar.medialRa], aliasCost: 10),
        .init(roman: "dhr", consonant: Myanmar.dha, medials: [Myanmar.medialRa], aliasCost: 10),
        .init(roman: "phr", consonant: Myanmar.pha, medials: [Myanmar.medialRa], aliasCost: 10),
        .init(roman: "bhr", consonant: Myanmar.bha, medials: [Myanmar.medialRa], aliasCost: 10),
        // Doubled consonant shortcut: `ll` surfaces ဠ (retroflex la) as
        // an alternative to the rank-1 `la la` literal pair. Users who
        // type `lla` expecting a single retroflex consonant then pick
        // it from the panel; user-history promotes it over the literal
        // pair after that first pick.
        .init(roman: "ll",  consonant: Myanmar.lla, medials: []),
    ]

    /// Lookup: roman → medial character.
    public static let romanToMedial: [String: Character] = {
        var dict: [String: Character] = [:]
        for entry in medials {
            dict[entry.roman] = entry.myanmar
        }
        return dict
    }()

    // MARK: - Vowel / Final Mappings

    /// Each vowel/final entry maps a roman suffix to Myanmar output.
    /// `standalone` indicates whether this can appear without a consonant onset
    /// (e.g., standalone vowels like ဧ).
    public struct VowelEntry: Sendable {
        public let roman: String
        public let myanmar: String
        public let isStandalone: Bool
        public let aliasCost: Int

        public init(_ roman: String, _ myanmar: String, standalone: Bool = false, aliasCost: Int = 0) {
            self.roman = roman
            self.myanmar = myanmar
            self.isStandalone = standalone
            self.aliasCost = aliasCost
        }
    }

    /// All vowel and final suffixes.
    /// The order matters for matching: longer keys must be checked before shorter ones.
    public static let vowels: [VowelEntry] = [
        // Special: stacker and asat (standalone: legal without consonant onset)
        .init("+", "\u{1039}", standalone: true),  // ္ virama (stacking)
        .init("+", "", standalone: true),  // soft boundary fallback — gated by DP
        .init("*", "\u{103A}", standalone: true),  // ် asat

        // Null vowels (inherent 'a') — standalone: legal as connectors
        .init("'", "", standalone: true),           // explicit separator, no output
        .init("a", "", standalone: true),           // inherent vowel, no output

        // -ar family
        .init("ar2:", "\u{102B}\u{1038}"),  // ါး
        .init("ar:", "\u{102C}\u{1038}"),   // ား
        .init("ar2.", "\u{102B}\u{1037}"),  // ါ့
        .init("ar.", "\u{102C}\u{1037}"),   // ာ့
        .init("ar2", "\u{102B}"),           // ါ
        .init("ar", "\u{102C}"),            // ာ

        // -i family
        .init("i2:", "\u{100A}\u{103A}\u{1038}"),  // ည်း
        .init("i2.", "\u{100A}\u{1037}\u{103A}"),   // ည့်
        .init("i2", "\u{100A}\u{103A}"),            // ည်
        .init("i:", "\u{102E}\u{1038}"),            // ီး
        .init("i.", "\u{102D}"),                    // ိ
        .init("i", "\u{102E}"),                     // ီ

        // -ii family (independent vowels, standalone)
        .init("ii.", "\u{1023}", standalone: true),  // ဣ short independent i
        .init("ii",  "\u{1024}", standalone: true),  // ဤ long independent i

        // -u family
        .init("u2:", "\u{1026}\u{1038}", standalone: true),  // ဦး
        .init("u2.", "\u{1025}", standalone: true),           // ဥ
        .init("u2", "\u{1026}", standalone: true),            // ဦ
        .init("u:", "\u{1030}\u{1038}"),                     // ူး
        .init("u.", "\u{102F}"),                             // ု
        .init("u", "\u{1030}"),                              // ူ

        // -ay family
        .init("ay:", "\u{1031}\u{1038}"),           // ေး
        .init("ay.", "\u{1031}\u{1037}"),           // ေ့
        .init("ay2", "\u{1027}", standalone: true), // ဧ
        .init("ay", "\u{1031}"),                    // ေ

        // -e family
        .init("e2.", "\u{1032}\u{1037}"),           // ဲ့
        .init("e.", "\u{101A}\u{1037}\u{103A}"),    // ယ့်
        .init("e:", "\u{1032}"),                    // ဲ
        .init("e", "\u{101A}\u{103A}"),             // ယ်

        // -aw family
        .init("aw2:", "\u{1031}\u{102B}"),          // ေါ
        .init("aw2.", "\u{1031}\u{102B}\u{1037}"),  // ေါ့
        .init("aw2", "\u{1031}\u{102B}\u{103A}"),   // ေါ်
        .init("aw:", "\u{1031}\u{102C}"),           // ော  (note: tall aa vs short)
        .init("aw.", "\u{1031}\u{102C}\u{1037}"),   // ော့
        .init("aw", "\u{1031}\u{102C}\u{103A}"),    // ော်

        // -oo family (independent vowels, standalone)
        .init("oo:", "\u{102A}", standalone: true),  // ဪ long/tonal independent o
        .init("oo",  "\u{1029}", standalone: true),  // ဩ independent o

        // -an family
        .init("an3:", "\u{1036}\u{1038}"),           // ံး (non-standard but in table)
        .init("an3.", "\u{1036}\u{1037}"),           // ံ့
        .init("an3", "\u{1036}"),                    // ံ
        .init("an2:", "\u{1019}\u{103A}\u{1038}"),   // မ်း
        .init("an2.", "\u{1019}\u{1037}\u{103A}"),   // မ့်
        .init("an2", "\u{1019}\u{103A}"),            // မ်
        .init("an:", "\u{1014}\u{103A}\u{1038}"),    // န်း
        .init("an.", "\u{1014}\u{1037}\u{103A}"),    // န့်
        .init("an", "\u{1014}\u{103A}"),             // န်

        // -o family
        .init("o2.", "\u{102D}\u{102F}\u{101A}\u{1037}\u{103A}"), // ိုယ့်
        .init("o2", "\u{102D}\u{102F}\u{101A}\u{103A}"),          // ိုယ်
        .init("o:", "\u{102D}\u{102F}\u{1038}"),                   // ိုး
        .init("o.", "\u{102D}\u{102F}\u{1037}"),                   // ို့
        .init("o", "\u{102D}\u{102F}"),                            // ို

        // Stops
        .init("et", "\u{1000}\u{103A}"),            // က်
        .init("at", "\u{1010}\u{103A}"),            // တ်
        .init("it", "\u{1005}\u{103A}"),            // စ်

        // -in family
        .init("in:", "\u{1004}\u{103A}\u{1038}"),   // င်း
        .init("in.", "\u{1004}\u{1037}\u{103A}"),    // င့်
        .init("in", "\u{1004}\u{103A}"),             // င်

        // -own family
        .init("own3:", "\u{102F}\u{1036}\u{1038}"),               // ုံး
        .init("own3.", "\u{102F}\u{1036}\u{1037}"),               // ုံ့
        .init("own3", "\u{102F}\u{1036}"),                        // ုံ
        .init("own2:", "\u{102F}\u{1019}\u{103A}\u{1038}"),       // ုမ်း
        .init("own2.", "\u{102F}\u{1019}\u{1037}\u{103A}"),       // ုမ့်
        .init("own2", "\u{102F}\u{1019}\u{103A}"),                // ုမ်
        .init("own:", "\u{102F}\u{1014}\u{103A}\u{1038}"),        // ုန်း
        .init("own.", "\u{102F}\u{1014}\u{1037}\u{103A}"),        // ုန့်
        .init("own", "\u{102F}\u{1014}\u{103A}"),                 // ုန်

        // -out family
        .init("out2", "\u{1031}\u{102B}\u{1000}\u{103A}"),       // ေါက်
        .init("out", "\u{1031}\u{102C}\u{1000}\u{103A}"),        // ောက်

        // -aung family
        .init("aung2:", "\u{1031}\u{102B}\u{1004}\u{103A}\u{1038}"), // ေါင်း
        .init("aung2.", "\u{1031}\u{102B}\u{1004}\u{1037}\u{103A}"), // ေါင့်
        .init("aung2", "\u{1031}\u{102B}\u{1004}\u{103A}"),          // ေါင်
        .init("aung:", "\u{1031}\u{102C}\u{1004}\u{103A}\u{1038}"),  // ောင်း
        .init("aung.", "\u{1031}\u{102C}\u{1004}\u{1037}\u{103A}"),  // ောင့်
        .init("aung", "\u{1031}\u{102C}\u{1004}\u{103A}"),           // ောင်

        // -ote family
        .init("ote2", "\u{102F}\u{1015}\u{103A}"),  // ုပ်
        .init("ote", "\u{102F}\u{1010}\u{103A}"),   // ုတ်

        // -ate family
        .init("ate2", "\u{102D}\u{1015}\u{103A}"),  // ိပ်
        .init("ate", "\u{102D}\u{1010}\u{103A}"),   // ိတ်

        // -ain family
        .init("ain2:", "\u{102D}\u{1019}\u{103A}\u{1038}"),  // ိမ်း
        .init("ain2.", "\u{102D}\u{1019}\u{1037}\u{103A}"),   // ိမ့်
        .init("ain2", "\u{102D}\u{1019}\u{103A}"),            // ိမ်
        .init("ain:", "\u{102D}\u{1014}\u{103A}\u{1038}"),    // ိန်း
        .init("ain.", "\u{102D}\u{1014}\u{1037}\u{103A}"),    // ိန့်
        .init("ain", "\u{102D}\u{1014}\u{103A}"),             // ိန်

        // -ite, -ai family
        .init("ite", "\u{102D}\u{102F}\u{1000}\u{103A}"),    // ိုက်
        .init("ai:", "\u{102D}\u{102F}\u{1004}\u{103A}\u{1038}"),  // ိုင်း
        .init("ai.", "\u{102D}\u{102F}\u{1004}\u{1037}\u{103A}"),  // ိုင့်
        .init("ai", "\u{102D}\u{102F}\u{1004}\u{103A}"),           // ိုင်

        // -on family
        .init("on3:", "\u{103D}\u{1036}\u{1038}"),               // ွံး
        .init("on3.", "\u{103D}\u{1036}\u{1037}"),               // ွံ့
        .init("on3", "\u{103D}\u{1036}"),                        // ွံ
        .init("on2:", "\u{103D}\u{1019}\u{103A}\u{1038}"),       // ွမ်း
        .init("on2.", "\u{103D}\u{1019}\u{1037}\u{103A}"),       // ွမ့်
        .init("on2", "\u{103D}\u{1019}\u{103A}"),                // ွမ်
        .init("on:", "\u{103D}\u{1014}\u{103A}\u{1038}"),        // ွန်း
        .init("on.", "\u{103D}\u{1014}\u{1037}\u{103A}"),        // ွန့်
        .init("on", "\u{103D}\u{1014}\u{103A}"),                 // ွန်

        // -ut
        .init("ut", "\u{103D}\u{1010}\u{103A}"),    // ွတ်

        // Standalone symbols. No digit disambiguator: these keys don't collide
        // with any dependent-vowel sibling, and the alias-penalty from a "2"
        // form would let the onset+medial+vowel parse of "ywe" (ယွယ်) out-rank
        // the standalone ၍ on ties.
        .init("ywe", "\u{104D}", standalone: true), // ၍ locative/conjunctive particle
        .init("ei",  "\u{104F}", standalone: true), // ၏ genitive/possessive particle
    ]

    /// Sorted vowel keys by descending length for longest-match.
    public static let vowelKeysByLength: [String] = {
        vowels.map(\.roman).sorted { $0.count > $1.count }
    }()

    /// Lookup: roman vowel suffix → VowelEntry.
    public static let romanToVowel: [String: VowelEntry] = {
        var dict: [String: VowelEntry] = [:]
        for entry in vowels {
            if dict[entry.roman] == nil {
                dict[entry.roman] = entry
            }
        }
        return dict
    }()

    // MARK: - Alias Keys

    private static let numericAliasMarkers: Set<Character> = ["2", "3"]
    private static let composeSeparators: Set<Character> = ["+", "'"]

    package static func isNumericAliasMarker(_ character: Character) -> Bool {
        numericAliasMarkers.contains(character)
    }

    /// Strip numeric disambiguation markers used by canonical readings.
    package static func aliasReading(_ canonical: String) -> String {
        String(canonical.filter { !numericAliasMarkers.contains($0) })
    }

    /// Tiny tie-breaker for the digit-stripped alias of a canonical
    /// reading. Digit input was removed from compose mode, so users can
    /// only produce the digitless form — but at the parser level, when
    /// the same surface input matches both a canonical rule (e.g. "kya"
    /// → ကြ via ya-yit) and the digit-stripped alias of another (e.g.
    /// "kya" via "ky2a" → ကျ ya-pin), we still want the canonical to
    /// win when no other signal differentiates them. The earlier 1000
    /// blew past the LM signal and dropped legitimate picks; 1 is small
    /// enough that any nat-scale LM evidence dominates, while still
    /// breaking parser-only ties (which is what the rule-shape tests
    /// rely on).
    static func aliasPenalty(for canonical: String) -> Int {
        canonical.contains(where: { numericAliasMarkers.contains($0) }) ? 1 : 0
    }

    package static func aliasPenaltyCount(for canonical: String) -> Int {
        canonical.reduce(into: 0) { count, character in
            if numericAliasMarkers.contains(character) {
                count += 1
            }
        }
    }

    /// Compose-mode lookup key used for lexicon prefix search.
    /// This strips numeric disambiguators and optional syllable separators so
    /// `mingalarpar` can match canonical readings like `min+galarpar2`.
    package static func composeLookupKey(_ canonical: String) -> String {
        String(canonical.filter { !numericAliasMarkers.contains($0) && !composeSeparators.contains($0) })
    }

    package static func composeSeparatorPenaltyCount(for canonical: String) -> Int {
        canonical.reduce(into: 0) { penalty, character in
            if composeSeparators.contains(character) {
                penalty += 1
            }
        }
    }

    package struct IndexedAliasReading: Sendable, Equatable {
        package let aliasReading: String
        package let aliasPenalty: Int
    }

    package struct IndexedComposeReading: Sendable, Equatable {
        package let composeReading: String
        package let aliasPenalty: Int
        package let separatorPenalty: Int
    }

    package static func indexedAliasReadings(for canonical: String) -> [IndexedAliasReading] {
        let base = IndexedAliasReading(
            aliasReading: aliasReading(canonical),
            aliasPenalty: aliasPenaltyCount(for: canonical)
        )
        return loanwordClusterAliasVariants(for: base)
    }

    package static func indexedComposeReadings(for canonical: String) -> [IndexedComposeReading] {
        indexedAliasReadings(for: canonical).map { variant in
            IndexedComposeReading(
                composeReading: composeLookupKey(variant.aliasReading),
                aliasPenalty: variant.aliasPenalty,
                separatorPenalty: composeSeparatorPenaltyCount(for: variant.aliasReading)
            )
        }
    }

    private struct LoanwordClusterAliasRule: Sendable {
        let canonical: String
        let aliases: [String]
    }

    private static let loanwordClusterAliasPenalty = 10

    private static let loanwordClusterAliasRules: [LoanwordClusterAliasRule] = [
        // Longest canonical onsets first so `khy` becomes `khr` before
        // the shorter `ky` rule can see it.
        .init(canonical: "khy", aliases: ["khr"]),
        .init(canonical: "ghy", aliases: ["ghr"]),
        .init(canonical: "hty", aliases: ["thr"]),
        .init(canonical: "dhy", aliases: ["dhr"]),
        .init(canonical: "phy", aliases: ["phr"]),
        .init(canonical: "by", aliases: ["bhr"]),
        .init(canonical: "ky", aliases: ["kr"]),
        .init(canonical: "gy", aliases: ["gr"]),
        .init(canonical: "sy", aliases: ["sr"]),
        .init(canonical: "ty", aliases: ["tr"]),
        .init(canonical: "dy", aliases: ["dr"]),
        .init(canonical: "py", aliases: ["pr"]),
        .init(canonical: "vy", aliases: ["br", "vr"]),
    ]

    private static func loanwordClusterAliasVariants(
        for base: IndexedAliasReading
    ) -> [IndexedAliasReading] {
        var variants = [base]
        var seen: Set<String> = [base.aliasReading]

        for rule in loanwordClusterAliasRules {
            let snapshot = variants
            for variant in snapshot where variant.aliasReading.contains(rule.canonical) {
                for alias in rule.aliases {
                    let rewritten = variant.aliasReading.replacingOccurrences(
                        of: rule.canonical,
                        with: alias
                    )
                    guard rewritten != variant.aliasReading,
                          seen.insert(rewritten).inserted else { continue }
                    variants.append(IndexedAliasReading(
                        aliasReading: rewritten,
                        aliasPenalty: variant.aliasPenalty + loanwordClusterAliasPenalty
                    ))
                }
            }
        }

        return variants
    }

    static func aliasVariants(for canonical: String, baseAliasCost: Int = 0) -> [(key: String, aliasCost: Int)] {
        var variants: [(String, Int)] = [(canonical, baseAliasCost)]
        let alias = aliasReading(canonical)
        if alias != canonical {
            variants.append((alias, baseAliasCost + aliasPenalty(for: canonical)))
        }
        return variants
    }

    // MARK: - Composing Character Set

    /// Characters accepted in the composing buffer.
    /// Digits are intentionally excluded — they are emitted as literal text
    /// rather than consumed as vowel-variant disambiguators.
    public static let composingCharacters: Set<Character> = Set(
        "abcdefghijklmnopqrstuvwxyz+*':.".map { $0 }
    )

    /// Normalize input to lowercase ASCII composing characters.
    public static func normalize(_ input: String) -> String {
        String(input.lowercased().filter { composingCharacters.contains($0) })
    }
}
