"""Tests for the encoding-invalid surface filter (TASK-081 follow-up).

The shipped lexicon carried a residue of corpus segmentation / typo
artefacts whose surfaces violate Unicode storage order — shapes no
Burmese orthography, regular or irregular, can produce:

- surface-initial dependent mark  (`့က`, `ိုယ်`, `ေသည်`)
- dangling virama U+1039          (`တင္`, `ဗုဒ္`, `ဋ္`)
- e-vowel U+1031 not after a base (`ေကြး` — also surface-initial)
- 102D+1030 typo cluster          (`မျိူး`, `လိူ့`)

The engine filtered them at load time (`SurfaceSanitizers.
isEncodingInvalidSurface`, commit 2d071ec); this filter excludes them
at the source so they never enter the TSV / SQLite / LM. The predicate
is mirrored byte-for-byte from the Swift side and is enforced at the
segmenter, curated-TSV loader, vocab builder, and the lexicon writer's
defensive assertion.

Crucially the filter is NARROWER than a legality scan: lexicalised
irregular spellings that fail the grammar's legality check but are valid
Unicode (`ယောက်ျား`, `ကျွန်ုပ်`, `ရှ်`) must keep their attested-surface
exemption, so they must NOT be flagged here.
"""

from __future__ import annotations

import unittest
from collections import Counter
from pathlib import Path
from tempfile import TemporaryDirectory

from corpus_builder.lexicon import write_tsv
from corpus_builder.segmenter import _is_encoding_invalid_surface
from corpus_builder.vocab import (
    CuratedEntry,
    Vocab,
    _is_polluted_surface,
    build_vocab,
    read_curated_tsv,
)


# Real surfaces that leaked into the shipped TSV (verified against the
# committed BurmeseLexiconSource.tsv), one per storage-order class.
ENCODING_INVALID = {
    "ဋ္": "dangling virama (100B 1039)",
    "တင္": "dangling virama (1010 1004 1039)",
    "ဗုဒ္": "dangling virama (1017 102F 1012 1039)",
    "့က": "surface-initial dot-below (1037 1000)",
    "ိုယ်": "surface-initial i-vowel (102D 102F 101A 103A)",
    "ေသည်": "surface-initial e-vowel (1031 101E 100A 103A)",
    "ေကြး": "surface-initial e-vowel (1031 1000 103C 1038)",
    "မျိူး": "102D+1030 typo (1019 103B 102D 1030 1038)",
    "လိူ့": "102D+1030 typo (101C 102D 1030 1037)",
}

# Valid surfaces that must NOT be flagged — ordinary words, Pali virama
# stacks, kinzi, and the lexicalised irregulars that survive on the
# attested-surface exemption.
ENCODING_VALID = [
    "ကျား",          # ordinary ya-pin word
    "မြန်မာ",         # ordinary word
    "သိက္ခာ",         # Pali virama stack (1039 followed by a base)
    "စန္ဒာ",          # Pali virama stack
    "အင်္ဂါ",         # kinzi (1004 103A 1039 followed by a base)
    "ကိုယ်",          # legal 102D 102F (i + u), NOT 102D 1030
    "ယောက်ျား",       # lexicalised irregular — legality fail, valid Unicode
    "ကျွန်ုပ်",       # lexicalised irregular
    "ရှ်",            # lexicalised irregular
    "ကျောင်း",        # e-vowel correctly after a base
]


class EncodingInvalidPredicateTests(unittest.TestCase):
    def test_invalid_surfaces_are_flagged(self) -> None:
        for surface, why in ENCODING_INVALID.items():
            with self.subTest(surface=surface, why=why):
                self.assertTrue(
                    _is_encoding_invalid_surface(surface),
                    f"{surface!r} should be flagged: {why}",
                )

    def test_valid_surfaces_are_not_flagged(self) -> None:
        for surface in ENCODING_VALID:
            with self.subTest(surface=surface):
                self.assertFalse(
                    _is_encoding_invalid_surface(surface),
                    f"{surface!r} must not be flagged (no storage-order "
                    f"violation)",
                )

    def test_empty_string_is_not_flagged(self) -> None:
        self.assertFalse(_is_encoding_invalid_surface(""))

    def test_dangling_virama_only_when_no_stackable_base(self) -> None:
        # 1039 followed by a base consonant is a legal stack, not dangling.
        self.assertFalse(_is_encoding_invalid_surface("က္ခ"))
        # 1039 at end (nothing follows) is dangling.
        self.assertTrue(_is_encoding_invalid_surface("က္"))
        # 1039 followed by a non-base (dep vowel) is dangling.
        self.assertTrue(_is_encoding_invalid_surface("က္ာ"))

    def test_e_vowel_position(self) -> None:
        # 1031 after a base is fine.
        self.assertFalse(_is_encoding_invalid_surface("ကေ"))
        # 1031 after a medial is fine.
        self.assertFalse(_is_encoding_invalid_surface("ကြေ"))
        # 1031 after a dependent vowel is invalid.
        self.assertTrue(_is_encoding_invalid_surface("ကာေ"))


class IsPollutedSurfaceTests(unittest.TestCase):
    def test_polluted_includes_encoding_invalid(self) -> None:
        for surface in ENCODING_INVALID:
            with self.subTest(surface=surface):
                self.assertTrue(_is_polluted_surface(surface))

    def test_valid_surfaces_not_polluted(self) -> None:
        for surface in ENCODING_VALID:
            with self.subTest(surface=surface):
                self.assertFalse(_is_polluted_surface(surface))


class BuildVocabDropsEncodingInvalidTests(unittest.TestCase):
    def test_corpus_counts_path_drops_invalid(self) -> None:
        counts: Counter[str] = Counter(
            {**{s: 9999 for s in ENCODING_INVALID}, "ကျား": 5, "မြန်မာ": 5}
        )
        v = build_vocab(counts, curated=[], max_corpus_words=10_000)
        for surface in ENCODING_INVALID:
            self.assertNotIn(surface, v.id_of)
        self.assertIn("ကျား", v.id_of)
        self.assertIn("မြန်မာ", v.id_of)

    def test_curated_path_drops_invalid(self) -> None:
        curated = [CuratedEntry(surface=s, override_reading=None) for s in ENCODING_INVALID]
        curated.append(CuratedEntry(surface="ကျား", override_reading=None))
        v = build_vocab(Counter(), curated=curated, max_corpus_words=10_000)
        for surface in ENCODING_INVALID:
            self.assertNotIn(surface, v.id_of)
        self.assertIn("ကျား", v.id_of)


class ReadCuratedTsvDropsEncodingInvalidTests(unittest.TestCase):
    def test_round_trip_drops_invalid(self) -> None:
        with TemporaryDirectory() as d:
            tsv = Path(d) / "lex.tsv"
            with tsv.open("w", encoding="utf-8") as f:
                f.write("# header\n")
                for s in ENCODING_INVALID:
                    f.write(f"{s}\t100\n")
                f.write("ကျား\t100\n")
            surfaces = {e.surface for e in read_curated_tsv(tsv)}
            for s in ENCODING_INVALID:
                self.assertNotIn(s, surfaces)
            self.assertIn("ကျား", surfaces)


class WriteTsvDefensiveAssertionTests(unittest.TestCase):
    def test_write_tsv_raises_on_forced_invalid_surface(self) -> None:
        # Bypass the vocab gate by injecting a bad surface straight into a
        # Vocab; the writer's defensive assertion must still catch it.
        v = Vocab()
        v.add("တင္")  # dangling virama
        with TemporaryDirectory() as d:
            out = Path(d) / "out.tsv"
            with self.assertRaises(ValueError):
                write_tsv(out, v, Counter({"တင္": 5}), curated=[])

    def test_write_tsv_accepts_clean_surface(self) -> None:
        v = Vocab()
        v.add("ကျား")
        with TemporaryDirectory() as d:
            out = Path(d) / "out.tsv"
            rows = write_tsv(out, v, Counter({"ကျား": 5}), curated=[])
            self.assertEqual(rows, 1)


if __name__ == "__main__":
    unittest.main()
