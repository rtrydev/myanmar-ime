/// Surfaces that LexiconBuilder injects into the SQLite lexicon
/// *without* a matching LM vocab entry. These are valid Burmese words
/// that fell below the 80k vocab cap (or were segmented away) but are
/// kept reachable in the candidate panel per CLAUDE.md §7. At runtime
/// they receive the LM `<unk>`-floor log-probability, which is
/// acceptable for panel presence.
///
/// The drift assertions in `LexiconLMDriftSuite` consult this set to
/// distinguish *intentional* OOV (these surfaces) from accidental
/// pollution (the failure mode the suite was designed to catch).
public enum CuratedLexicon {
    public static let oovAllowedSurfaces: Set<String> = [
        "\u{1021}\u{1036}\u{1038}",  // အံး — anusvara + visarga (TASK-074)
        "\u{1000}\u{103C}\u{102E}",  // ကြီ — bare ya-yit + long-i (TASK-075)
    ]
}
