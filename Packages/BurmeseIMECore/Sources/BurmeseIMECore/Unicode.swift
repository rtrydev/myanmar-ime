/// Burmese Unicode block constants and character classification.
/// Reference: Unicode 15.1, Myanmar block U+1000–U+109F.
public enum Myanmar {
    // MARK: - Consonants (U+1000–U+1021)

    public static let ka: Character    = "\u{1000}"  // က
    public static let kha: Character   = "\u{1001}"  // ခ
    public static let ga: Character    = "\u{1002}"  // ဂ
    public static let gha: Character   = "\u{1003}"  // ဃ
    public static let nga: Character   = "\u{1004}"  // င
    public static let ca: Character    = "\u{1005}"  // စ  (sa in romanization)
    public static let cha: Character   = "\u{1006}"  // ဆ  (hsa)
    public static let ja: Character    = "\u{1007}"  // ဇ  (za)
    public static let jha: Character   = "\u{1008}"  // ဈ  (zza)
    public static let nya: Character   = "\u{1009}"  // ည
    public static let nnya: Character  = "\u{100A}"  // ဉ
    public static let tta: Character   = "\u{100B}"  // ဋ  (t2a)
    public static let ttha: Character  = "\u{100C}"  // ဌ  (ht2a)
    public static let dda: Character   = "\u{100D}"  // ဍ  (d2a)
    public static let ddha: Character  = "\u{100E}"  // ဎ  (dh2a)
    public static let nna: Character   = "\u{100F}"  // ဏ  (n2a)
    public static let ta: Character    = "\u{1010}"  // တ
    public static let tha: Character   = "\u{1011}"  // ထ  (hta)
    public static let da: Character    = "\u{1012}"  // ဒ
    public static let dha: Character   = "\u{1013}"  // ဓ
    public static let na: Character    = "\u{1014}"  // န
    public static let pa: Character    = "\u{1015}"  // ပ
    public static let pha: Character   = "\u{1016}"  // ဖ
    public static let ba: Character    = "\u{1017}"  // ဗ  (va)
    public static let bha: Character   = "\u{1018}"  // ဘ
    public static let ma: Character    = "\u{1019}"  // မ
    public static let ya: Character    = "\u{101A}"  // ယ
    public static let ra: Character    = "\u{101B}"  // ရ
    public static let la: Character    = "\u{101C}"  // လ
    public static let wa: Character    = "\u{101D}"  // ဝ
    public static let sa: Character    = "\u{101E}"  // သ  (tha in romanization)
    public static let ha: Character    = "\u{101F}"  // ဟ
    public static let lla: Character   = "\u{1020}"  // ဠ  (l2a)
    public static let ah: Character    = "\u{1021}"  // အ
    public static let greatSa: Character = "\u{103F}"  // ဿ  (ss) — doubled-sa consonant

    // MARK: - Independent Vowels (U+1023–U+1029)

    public static let ii: Character    = "\u{1023}"  // ဣ
    public static let iiii: Character  = "\u{1024}"  // ဤ
    public static let uu: Character    = "\u{1025}"  // ဥ  (u2.)
    public static let uuu: Character   = "\u{1026}"  // ဦ  (u2)
    public static let ee: Character    = "\u{1027}"  // ဧ  (ay2)
    public static let oo: Character    = "\u{1029}"  // ဩ
    public static let ooo: Character   = "\u{102A}"  // ဪ

    // MARK: - Dependent Vowel Signs

    public static let tallAa: Character    = "\u{102B}"  // ါ
    public static let aa: Character        = "\u{102C}"  // ာ
    public static let signI: Character     = "\u{102D}"  // ိ
    public static let signIi: Character    = "\u{102E}"  // ီ
    public static let signU: Character     = "\u{102F}"  // ု
    public static let signUu: Character    = "\u{1030}"  // ူ
    public static let signE: Character     = "\u{1031}"  // ေ
    public static let signAi: Character    = "\u{1032}"  // ဲ

    // MARK: - Various Signs

    public static let anusvara: Character  = "\u{1036}"  // ံ (anusvara / kinzi marker)
    public static let dotBelow: Character  = "\u{1037}"  // ့ (aukmyit)
    public static let visarga: Character   = "\u{1038}"  // း (visarga)
    public static let virama: Character    = "\u{1039}"  // ္ (virama / killer, for stacking)
    public static let asat: Character      = "\u{103A}"  // ် (asat / final marker)

    // MARK: - Medial Consonants

    public static let medialYa: Character  = "\u{103B}"  // ျ (ya-pin)
    public static let medialRa: Character  = "\u{103C}"  // ြ (ya-yit / ra)
    public static let medialWa: Character  = "\u{103D}"  // ွ (wa-hswe)
    public static let medialHa: Character  = "\u{103E}"  // ှ (ha-htoe)

    // MARK: - Digits (U+1040–U+1049)

    public static let digit0: Character = "\u{1040}"  // ၀
    public static let digit1: Character = "\u{1041}"  // ၁
    public static let digit2: Character = "\u{1042}"  // ၂
    public static let digit3: Character = "\u{1043}"  // ၃
    public static let digit4: Character = "\u{1044}"  // ၄
    public static let digit5: Character = "\u{1045}"  // ၅
    public static let digit6: Character = "\u{1046}"  // ၆
    public static let digit7: Character = "\u{1047}"  // ၇
    public static let digit8: Character = "\u{1048}"  // ၈
    public static let digit9: Character = "\u{1049}"  // ၉

    // MARK: - Symbols

    public static let locativeMark: Character = "\u{104D}"  // ၍ conjunctive/locative particle
    public static let genitiveMark: Character = "\u{104F}"  // ၏ possessive particle

    // MARK: - Special

    public static let zwnj: Character = "\u{200C}"  // Zero-width non-joiner

    // MARK: - Character Sets

    /// All 33 base consonants used in standard Burmese.
    public static let consonants: [Character] = [
        ka, kha, ga, gha, nga,
        cha, ca, ja, jha, nya,
        tta, ttha, dda, ddha, nna,
        ta, tha, da, dha, na,
        pa, pha, ba, bha, ma,
        ya, ra, la, wa, sa, ha, lla, ah,
    ]

    /// Scalar values for the Myanmar consonant range.
    /// U+103F (ဿ, great sa) sits outside the contiguous block but behaves
    /// as a consonant — it can carry an inherent vowel or vowel suffix.
    public static func isConsonant(_ scalar: Unicode.Scalar) -> Bool {
        (0x1000...0x1021).contains(scalar.value) || scalar.value == 0x103F
    }

    /// Check if a scalar is a Myanmar medial consonant sign.
    public static func isMedial(_ scalar: Unicode.Scalar) -> Bool {
        (0x103B...0x103E).contains(scalar.value)
    }

    /// Check if a scalar is a Myanmar dependent vowel sign.
    public static func isDependentVowel(_ scalar: Unicode.Scalar) -> Bool {
        (0x102B...0x1032).contains(scalar.value)
    }

    /// Check if a scalar is in the Myanmar block.
    public static func isMyanmar(_ scalar: Unicode.Scalar) -> Bool {
        (0x1000...0x109F).contains(scalar.value)
    }

    /// Check if a scalar is a Myanmar digit.
    public static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        (0x1040...0x1049).contains(scalar.value)
    }
}
