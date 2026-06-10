namespace Myangler.Preferences;

/// <summary>
/// Snapshot of the Hybrid Burmese romanization tables for the Syntax
/// tab. Ported from
/// Packages/BurmeseIMECore/Sources/BurmeseIMECore/Romanization.swift —
/// keeping the data here in C# avoids growing the FFI surface for a
/// purely-static documentation reference.
///
/// When the canonical Swift table changes, mirror the edit here. The
/// tables are intentionally short — long enough to teach typing rules,
/// not exhaustive of every entry.
/// </summary>
internal static class Romanization
{
    public sealed record ConsonantEntry(string Roman, string Myanmar);
    public sealed record MedialEntry(string Roman, string Myanmar);
    public sealed record ClusterAliasEntry(string Roman, string MyanmarCluster, string Canonical);
    public sealed record VowelEntry(string Roman, string MyanmarExample);

    public static readonly ConsonantEntry[] Consonants =
    [
        new("k",   "က"), new("kh", "ခ"), new("g",   "ဂ"), new("gh",  "ဃ"), new("ng",  "င"),
        new("hs",  "ဆ"), new("s",  "စ"), new("z",   "ဇ"), new("zz",  "ဈ"),
        new("ny",  "ည"), new("ny2","ဉ"),
        new("t2",  "ဋ"), new("ht2","ဌ"), new("d2",  "ဍ"), new("dh2", "ဎ"), new("n2", "ဏ"),
        new("t",   "တ"), new("ht", "ထ"), new("d",   "ဒ"), new("dh",  "ဓ"), new("n",  "န"),
        new("p",   "ပ"), new("ph", "ဖ"), new("v",   "ဗ"), new("b",   "ဘ"), new("m",  "မ"),
        new("y",   "ယ"), new("r",  "ရ"), new("l",   "လ"), new("w",   "ဝ"),
        new("th",  "သ"), new("h",  "ဟ"), new("l2",  "ဠ"),
        new("ah",  "အ"), new("ss", "ဿ"),
    ];

    public static readonly MedialEntry[] Medials =
    [
        new("y2", "ျ"),
        new("y",  "ြ"),
        new("w",  "ွ"),
        new("h",  "ှ"),
    ];

    // Examples are visualized as the cluster applied to က (ka) so the
    // user sees a real legal shape. Canonical column documents the
    // structural spelling these aliases shortcut.
    public static readonly ClusterAliasEntry[] ClusterAliases =
    [
        new("j",   "ကျ",   "= ky2"),
        new("jw",  "ကျွ",  "= ky2w"),
        new("ch",  "ချ",   "= khy2"),
        new("chw", "ချွ",  "= khy2w"),
        new("gy",  "ဂျ",   "= gy2"),
        new("gyw", "ဂျွ",  "= gy2w"),
        new("sh",  "ရှ",   "= rh"),
        new("shw", "ရွှ",  "= rwh"),
        new("kr",  "ကြ",   "= ky"),
        new("gr",  "ဂြ",   "= gy"),
        new("pr",  "ပြ",   "= py"),
        new("br",  "ဘြ",   "= by"),
        new("ll",  "ဠ",    "= l2"),
    ];

    public sealed record VowelFamily(string Name, string Title, string Note, VowelEntry[] Entries);

    public static readonly VowelFamily[] VowelFamilies =
    [
        new("a", "Inherent vowel (a)",
            "Implicit after any consonant; type explicitly to end a syllable.",
            [ new("a", "က") ]),
        new("ar", "-ar family",
            "Long /a/. ar uses ာ; ar2 uses ါ (tall aa) on descending consonants.",
            [ new("ar",  "ကာ"),  new("ar.",  "ကာ့"), new("ar:",  "ကား"),
              new("ar2", "ဂါ"),  new("ar2.", "ဂါ့"), new("ar2:", "ဂါး") ]),
        new("i", "-i family",
            "/i/. i2 variants use ည instead of ီ.",
            [ new("i.",  "ကိ"), new("i",   "ကီ"),  new("i:",  "ကီး"),
              new("i2",  "ကည်"), new("i2.", "ကည့်"), new("i2:", "ကည်း") ]),
        new("ii", "-ii family (independent)",
            "Standalone /i/ vowels: ii. → ဣ (short), ii → ဤ (long).",
            [ new("ii.", "ဣ"), new("ii", "ဤ") ]),
        new("u", "-u family",
            "/u/. u2 variants produce the standalone vowel forms ဥ / ဦ.",
            [ new("u.",  "ကု"), new("u",   "ကူ"), new("u:",  "ကူး"),
              new("u2.", "ဥ"),  new("u2",  "ဦ"),  new("u2:", "ဦး") ]),
        new("ay", "-ay family",
            "/e/-like. ay2 is the standalone ဧ.",
            [ new("ay",  "ကေ"), new("ay.", "ကေ့"), new("ay:", "ကေး"),
              new("ay2", "ဧ") ]),
        new("e", "-e family",
            "/ɛ/-like.",
            [ new("e",   "ကယ်"), new("e.", "ကယ့်"), new("e:",  "ကဲ"), new("e2.", "ကဲ့") ]),
        new("aw", "-aw family",
            "/ɔ/. aw2 uses the tall aa shape (ေါ).",
            [ new("aw",   "ကော်"), new("aw.",  "ကော့"), new("aw:",  "ကော်း"),
              new("aw2",  "ဂေါ်"), new("aw2.", "ဂေါ့"), new("aw2:", "ဂေါ်း") ]),
        new("oo", "-oo family (independent)",
            "Standalone /o/ vowels.",
            [ new("oo", "ဩ"), new("oo:", "ဪ") ]),
        new("an", "-an family",
            "Nasal final /-an/. an / an2 / an3 cover န် / မ် / ံ.",
            [ new("an",  "ကန်"), new("an.",  "ကန့်"), new("an:",  "ကန်း"),
              new("an2", "ကမ်"), new("an2.", "ကမ့်"), new("an2:", "ကမ်း"),
              new("an3", "ကံ"),  new("an3.", "ကံ့"),  new("an3:", "ကံး") ]),
        new("o", "-o family",
            "/o/ diphthong (i + u).",
            [ new("o",  "ကို"), new("o.",  "ကို့"), new("o:",  "ကိုး"),
              new("o2", "ကိုယ်"), new("o2.", "ကိုယ့်") ]),
        new("in", "-in family",
            "/-in/ with င.",
            [ new("in", "ကင်"), new("in.", "ကင့်"), new("in:", "ကင်း") ]),
        new("own", "-own family",
            "u + nasal.",
            [ new("own",  "ကုန်"),  new("own.",  "ကုန့်"),  new("own:",  "ကုန်း"),
              new("own2", "ကုမ်"),  new("own2.", "ကုမ့်"),  new("own2:", "ကုမ်း"),
              new("own3", "ကုံ"),   new("own3.", "ကုံ့"),   new("own3:", "ကုံး") ]),
        new("out", "-out family",
            "aw + k stop.",
            [ new("out", "ကောက်"), new("out2", "ဂေါက်") ]),
        new("aung", "-aung family",
            "aw + ng.",
            [ new("aung",  "ကောင်"),  new("aung.",  "ကောင့်"),  new("aung:",  "ကောင်း"),
              new("aung2", "ဂေါင်") ]),
        new("ote", "-ote family",
            "u + stop.",
            [ new("ote", "ကုတ်"), new("ote2", "ကုပ်") ]),
        new("ate", "-ate family",
            "i + stop.",
            [ new("ate", "ကိတ်"), new("ate2", "ကိပ်") ]),
        new("ain", "-ain family",
            "i + nasal.",
            [ new("ain",  "ကိန်"), new("ain.",  "ကိန့်"), new("ain:",  "ကိန်း"),
              new("ain2", "ကိမ်"), new("ain2.", "ကိမ့်"), new("ain2:", "ကိမ်း") ]),
        new("ite", "-ite family",
            "o + k.",
            [ new("ite", "ကိုက်") ]),
        new("ai", "-ai family",
            "o + ng.",
            [ new("ai",  "ကိုင်"),  new("ai.",  "ကိုင့်"),  new("ai:",  "ကိုင်း") ]),
        new("on", "-on family",
            "w + nasal.",
            [ new("on",  "ကွန်"), new("on.",  "ကွန့်"), new("on:",  "ကွန်း"),
              new("on2", "ကွမ်"), new("on2.", "ကွမ့်"), new("on2:", "ကွမ်း"),
              new("on3", "ကွံ"),  new("on3.", "ကွံ့"),  new("on3:", "ကွံး") ]),
        new("ut", "-ut",
            "w + t.",
            [ new("ut", "ကွတ်") ]),
        new("et", "-et",
            "Stop final က်.",
            [ new("et", "ကက်") ]),
        new("at", "-at",
            "Stop final တ်.",
            [ new("at", "ကတ်") ]),
        new("it", "-it",
            "Stop final စ်.",
            [ new("it", "ကစ်") ]),
    ];

    public sealed record SpecialEntry(string Key, string Title, string Detail);

    public static readonly SpecialEntry[] Specials =
    [
        new("+",   "Stacker",
            "Explicitly subscripts the next consonant. Example: min+galarpar → မင်္ဂလာပါ."),
        new("*",   "Asat",
            "Silences the preceding consonant. Usually inserted automatically by a final-family vowel."),
        new("'",   "Syllable separator",
            "Forces a syllable break with no output. Useful when adjacent characters would otherwise merge."),
        new(":",   "Long / heavy tone",
            "Appended to a vowel key: ar → ာ, ar: → ား."),
        new(".",   "Short / creaky tone",
            "Appended to a vowel key: ay → ေ, ay. → ေ့."),
        new("ywe", "Locative / conjunctive ၍",
            "Standalone particle meaning \"and thus\". Type on its own — no consonant needed."),
        new("ei",  "Genitive ၏",
            "Standalone possessive / sentence-ending particle."),
        new("hnite", "Locative ၌",
            "Standalone particle meaning \"at / in\", read နှိုက်. Also composes after a word: rarhnite → ရာ၌."),
    ];

    /// <summary>Worked-example pairs used by the Syntax tab.</summary>
    public static readonly string[] WorkedExamples =
    [
        "မင်္ဂလာပါ",
        "ကျော်",
        "ရွှေ",
        "ခင်",
        "ကျွန်တော်",
        "ဘာသာ",
    ];

    /// <summary>
    /// Strip 2 / 3 disambiguator digits — that's the form a user would
    /// actually type (digits aren't in the compose-mode charset).
    /// </summary>
    public static string StripDisambiguators(string reading) =>
        new string(reading.Where(c => c != '2' && c != '3').ToArray());
}
