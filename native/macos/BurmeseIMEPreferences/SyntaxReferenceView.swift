import SwiftUI
import BurmeseIMECore

/// A read-only reference of the Hybrid Burmese romanization scheme the
/// IME uses. Sourced directly from `Romanization.*` tables so it stays
/// in sync whenever the engine's rules change.
struct SyntaxReferenceView: View {
    @ObservedObject var vm: IMESettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                IntroSection()
                Divider()
                ConsonantsSection()
                Divider()
                MedialsSection()
                Divider()
                ClusterAliasesSection(enabled: vm.clusterAliasesEnabled)
                Divider()
                VowelsSection()
                Divider()
                SpecialCharactersSection()
                Divider()
                ExamplesSection()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Intro

private struct IntroSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How input works")
                .font(.headline)
            Text("Type a rough Latin spelling and the IME shows Myanmar candidates in a small window near the cursor. Pick one with the arrow keys or a number and press space or return to commit.")
                .font(.callout)
            Text("Some keys map to more than one Myanmar character — typing ta, for example, can produce either တ or ဋ. The IME ranks candidates by context, and you pick the intended one from the candidate window.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Consonants

private struct ConsonantsSection: View {
    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Consonants")
                .font(.headline)
            Text("Type the key plus a vowel; the trailing 'a' is the inherent vowel and is implicit when no vowel follows.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Romanization.consonants, id: \.roman) { entry in
                    GlyphCard(
                        glyph: String(entry.myanmar),
                        primary: stripDisambiguators(entry.roman)
                    )
                }
            }
        }
    }
}

// MARK: - Medials

private struct MedialsSection: View {
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]
    private let sampleConsonant: Character = "က"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Medials")
                .font(.headline)
            Text("Add after a consonant: k + y → ကြ. Canonical order is ြ, ျ, ွ, ှ — the engine enforces it automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Romanization.medials, id: \.roman) { entry in
                    GlyphCard(
                        glyph: String(sampleConsonant) + String(entry.myanmar),
                        primary: stripDisambiguators(entry.roman)
                    )
                }
            }
        }
    }
}

// MARK: - Cluster aliases

private struct ClusterAliasesSection: View {
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cluster-sound shortcuts")
                .font(.headline)
            if enabled {
                Text("Optional phonetic shortcuts for common consonant + medial clusters. Spelling out the consonant and medial still works.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Romanization.clusterAliases, id: \.roman) { entry in
                        let glyph = String(entry.consonant) + String(entry.medials)
                        GlyphCard(
                            glyph: glyph,
                            primary: entry.roman,
                            secondary: stripDisambiguators(canonicalExpansion(for: entry))
                        )
                    }
                }
            } else {
                Text("Shortcuts are currently disabled. Enable them in the Preferences tab to use keys like j, ch, gy, sh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func canonicalExpansion(for entry: Romanization.ClusterAliasEntry) -> String {
        let consonantRoman = Romanization.consonantToRoman[entry.consonant] ?? ""
        let medialRomans = entry.medials.compactMap { medialChar in
            Romanization.medials.first(where: { $0.myanmar == medialChar })?.roman
        }
        return "= " + consonantRoman + medialRomans.joined()
    }
}

// MARK: - Vowels

private struct VowelsSection: View {
    private let sampleConsonant: Character = "က"

    private let familyOrder: [(name: String, title: String, note: String?)] = [
        ("a",    "Inherent vowel (a)",  "Implicit after any consonant; type explicitly to end a syllable."),
        ("ar",   "-ar family",          "Long /a/. ar uses ာ; ar2 uses ါ (tall aa) on descending consonants — the engine picks the right shape automatically."),
        ("i",    "-i family",           "/i/. i2 variants use ည instead of ီ."),
        ("ii",   "-ii family (independent)", "Standalone /i/ vowels: ii. → ဣ (short), ii → ဤ (long). Typed by themselves, no consonant needed."),
        ("u",    "-u family",           "/u/. u2 variants produce the standalone vowel forms ဥ / ဦ."),
        ("ay",   "-ay family",          "/e/-like. ay2 is the standalone ဧ."),
        ("e",    "-e family",           "/ɛ/-like."),
        ("aw",   "-aw family",          "/ɔ/. aw2 uses the tall aa shape (ေါ)."),
        ("oo",   "-oo family (independent)", "Standalone /o/ vowels: oo → ဩ, oo: → ဪ."),
        ("an",   "-an family",          "Nasal final /-an/. an / an2 / an3 cover န် / မ် / ံ."),
        ("o",    "-o family",           "/o/ diphthong (i + u)."),
        ("in",   "-in family",          "/-in/ with င."),
        ("own",  "-own family",         "u + nasal."),
        ("out",  "-out family",         "aw + k stop."),
        ("aung", "-aung family",        "aw + ng."),
        ("ote",  "-ote family",         "u + stop (-t / -p)."),
        ("ate",  "-ate family",         "i + stop."),
        ("ain",  "-ain family",         "i + nasal."),
        ("ite",  "-ite family",         "o + k."),
        ("ai",   "-ai family",          "o + ng."),
        ("on",   "-on family",          "w + nasal."),
        ("ut",   "-ut family",          "w + t."),
        ("et",   "-et",                 "Stop final က်."),
        ("at",   "-at",                 "Stop final တ်."),
        ("it",   "-it",                 "Stop final စ်."),
        ("h",    "Standalone ha-htoe (h)", "ှ attached alone as a vowel-like mark."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vowels & finals")
                .font(.headline)
            Text("Suffixes attach to a consonant or onset. Within a family, . marks a short/creaky tone, : marks a long/heavy tone, and bare keys are the default.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(familyOrder, id: \.name) { group in
                let entries = entriesForFamily(group.name)
                if !entries.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        if let note = group.note {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        VowelFamilyGrid(entries: entries, sampleConsonant: sampleConsonant)
                    }
                }
            }
        }
    }

    private func entriesForFamily(_ name: String) -> [Romanization.VowelEntry] {
        Romanization.vowels.filter { family(of: $0.roman) == name }
    }

    private func family(of roman: String) -> String {
        let alpha = roman.prefix { $0.isLetter }
        return alpha.isEmpty ? "__special__" : String(alpha)
    }
}

private struct VowelFamilyGrid: View {
    let entries: [Romanization.VowelEntry]
    let sampleConsonant: Character

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(entries, id: \.roman) { entry in
                GlyphCard(
                    glyph: exampleGlyph(for: entry),
                    primary: stripDisambiguators(entry.roman)
                )
            }
        }
    }

    private func exampleGlyph(for entry: Romanization.VowelEntry) -> String {
        if entry.myanmar.isEmpty {
            return String(sampleConsonant)
        }
        if let first = entry.myanmar.unicodeScalars.first,
           (0x1023...0x102A).contains(first.value) {
            return entry.myanmar
        }
        return String(sampleConsonant) + entry.myanmar
    }
}

// MARK: - Special characters

private struct SpecialCharactersSection: View {
    private let entries: [(key: String, title: String, detail: String)] = [
        ("+", "Stacker", "Explicitly subscripts the next consonant. Example: min+galarpar → မင်္ဂလာပါ."),
        ("*", "Asat", "Silences the preceding consonant. Usually inserted automatically by a final-family vowel."),
        ("'", "Syllable separator", "Forces a syllable break with no output. Useful when adjacent characters would otherwise merge."),
        (":", "Long / heavy tone", "Appended to a vowel key: ar → ာ, ar: → ား."),
        (".", "Short / creaky tone", "Appended to a vowel key: ay → ေ, ay. → ေ့."),
        ("ywe", "Locative / conjunctive ၍", "Standalone particle meaning \"and thus\". Type on its own — no consonant needed."),
        ("ei", "Genitive ၏", "Standalone possessive / sentence-ending particle."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Special characters")
                .font(.headline)
            ForEach(entries, id: \.key) { entry in
                HStack(alignment: .top, spacing: 12) {
                    Text(entry.key)
                        .font(.system(.title3, design: .monospaced))
                        .frame(width: 36, alignment: .center)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(.callout)
                            .fontWeight(.semibold)
                        Text(entry.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Worked examples

private struct ExamplesSection: View {
    private let samples: [String] = [
        "မင်္ဂလာပါ",
        "ကျော်",
        "ရွှေ",
        "ခင်",
        "ကျွန်တော်",
        "ဘာသာ",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Worked examples")
                .font(.headline)
            Text("Computed live from the engine's reverse-romanizer.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(samples, id: \.self) { sample in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(stripDisambiguators(ReverseRomanizer.romanize(sample)))
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 160, alignment: .leading)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(sample)
                            .font(.system(size: 18))
                    }
                }
            }
        }
    }
}

// MARK: - Shared helpers

private struct GlyphCard: View {
    let glyph: String
    let primary: String
    let secondary: String?

    init(glyph: String, primary: String, secondary: String? = nil) {
        self.glyph = glyph
        self.primary = primary
        self.secondary = secondary
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(glyph)
                .font(.system(size: 24))
                .frame(height: 32)
            Text(primary)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
            if let secondary, secondary != primary {
                Text(secondary)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Strip 2 / 3 disambiguation markers so the reading becomes the form a
/// user would actually type — digits aren't in the compose-mode charset.
func stripDisambiguators(_ reading: String) -> String {
    String(reading.filter { $0 != "2" && $0 != "3" })
}
