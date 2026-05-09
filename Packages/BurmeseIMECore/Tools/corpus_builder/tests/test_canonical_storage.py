"""Tests for TASK-038: corpus surfaces with non-canonical Unicode storage
order produce duplicate lexicon entries with divergent readings.

The ingest pipeline normalises:
- NFC (handles tone-vs-asat reorder via Combining Class).
- U+200B strip (already covered in test_zwsp_normalization).
- Doubled tone-marker collapse (`<X> 1037 1037` → `<X> 1037`,
  same for U+1036 / U+1038).
- Orphan U+200C / U+200D strip when not at a legal cluster
  boundary.
"""

from __future__ import annotations

import unicodedata
import unittest

from corpus_builder.ingest import normalize_text


class NfcNormalizationTests(unittest.TestCase):
    def test_nfc_reorders_asat_then_tone_to_tone_then_asat(self) -> None:
        """`<C> 103A 1037` non-canonical storage must NFC-reorder to
        `<C> 1037 103A` because U+1037 has CCC=7, U+103A has CCC=9."""
        # `နှင့်` non-canonical: 1014 103E 1004 103A 1037
        non_canonical = "နှင့်"
        # Canonical: 1014 103E 1004 1037 103A
        canonical = "နှင့်"
        self.assertEqual(normalize_text(non_canonical), canonical)

    def test_nfc_stable_on_already_canonical_surface(self) -> None:
        """Surfaces already in canonical storage order must round-trip
        unchanged through `normalize_text`."""
        canonical = "နှင့်"
        self.assertEqual(normalize_text(canonical), canonical)

    def test_nfc_stable_on_common_burmese_words(self) -> None:
        """Common surfaces are NFC-stable; `normalize_text` must not
        rewrite them."""
        for word in [
            "ကြောင်း",
            "ပြည်",
            "သင့်",
            "မင်္ဂလာပါ",
            "သာ",
            "ကြ",
        ]:
            with self.subTest(word=word):
                self.assertEqual(normalize_text(word), word)


class DoubledToneCollapseTests(unittest.TestCase):
    def test_doubled_creaky_tone_collapses(self) -> None:
        """`<X> 1037 1037` collapses to `<X> 1037`. NFC alone does NOT
        collapse duplicated tone scalars; an explicit pass is required."""
        # `<C> <vowel> 1037 1037` shape — corpus has e.g.
        # `1014 103E 1004 1037 103A 1037` (the asat is between the two
        # creakies after NFC). The collapse must happen before or after
        # NFC, but the post-`normalize_text` result must contain only
        # one U+1037.
        surface = "နှင့့်"
        result = normalize_text(surface)
        creaky_count = result.count("့")
        self.assertEqual(creaky_count, 1, repr(result))

    def test_doubled_anusvara_collapses(self) -> None:
        # `<C> 1036 1036` — doubled anusvara.
        surface = "ပံံ"
        result = normalize_text(surface)
        self.assertEqual(result.count("ံ"), 1)

    def test_doubled_visarga_collapses(self) -> None:
        # `<C> 1038 1038` — doubled visarga.
        surface = "ပးး"
        result = normalize_text(surface)
        self.assertEqual(result.count("း"), 1)

    def test_single_tone_marker_preserved(self) -> None:
        """Single tone markers must not be collapsed."""
        for tone in ["ံ", "့", "း"]:
            with self.subTest(tone=tone):
                surface = f"ပ{tone}"
                self.assertEqual(normalize_text(surface), surface)


class StrayZwnjStripTests(unittest.TestCase):
    def test_trailing_zwnj_stripped(self) -> None:
        """A U+200C at the end of a surface has no orthographic effect
        and must be stripped."""
        surface = "နှင့်‌"
        result = normalize_text(surface)
        self.assertNotIn("‌", result)
        # Body must round-trip.
        self.assertEqual(result, "နှင့်")

    def test_zwnj_at_start_stripped(self) -> None:
        """A leading U+200C with no following dependent-vowel onset is
        an orphan and must be stripped."""
        surface = "‌ပာ"
        result = normalize_text(surface)
        self.assertNotIn("‌", result)


class CombinedNormalizationTests(unittest.TestCase):
    def test_zwsp_and_nfc_compose(self) -> None:
        """Both ZWSP strip and NFC normalization must apply in one
        pass."""
        # Surface has ZWSP at the boundary AND non-canonical storage.
        non_canonical = "နှင့်​"
        result = normalize_text(non_canonical)
        # ZWSP gone, asat+tone reordered.
        self.assertNotIn("​", result)
        self.assertEqual(result, "နှင့်")

    def test_doubled_tone_after_nfc_reorder(self) -> None:
        """When NFC reorder produces a doubled-tone shape, the collapse
        pass must still run."""
        # `<C> 103A 1037 1037` → after NFC `<C> 1037 1037 103A` →
        # after collapse `<C> 1037 103A`.
        surface = "နှင့့်"
        result = normalize_text(surface)
        self.assertEqual(result, "နှင့်")


if __name__ == "__main__":
    unittest.main()
