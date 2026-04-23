"""Tests for U+200B (ZWSP) normalization in the ingest pipeline.

ZWSP must be stripped before segmentation so vocab keys and LM surfaces
never contain the invisible char. Without this, Swift's LexiconBuilder
(whose `.whitespaces` trim includes U+200B) disagrees with Python's
unstripped vocab → drift check failure.
"""

from __future__ import annotations

import unittest

from corpus_builder.ingest import normalize_text


class NormalizeTextTests(unittest.TestCase):
    def test_strips_zwsp_in_all_positions(self) -> None:
        self.assertEqual(normalize_text("​ကောင်း"), "ကောင်း")
        self.assertEqual(normalize_text("ကောင်း​"), "ကောင်း")
        self.assertEqual(normalize_text("​ကောင်း​"), "ကောင်း")
        self.assertEqual(normalize_text("အ​ကောင်းဆုံး"), "အကောင်းဆုံး")

    def test_preserves_zwnj_and_zwj(self) -> None:
        """U+200C / U+200D are legitimate in Myanmar; never strip them."""
        zwnj = "‌"
        zwj = "‍"
        self.assertEqual(normalize_text(f"က{zwnj}ျ"), f"က{zwnj}ျ")
        self.assertEqual(normalize_text(f"က{zwj}ျ"), f"က{zwj}ျ")

    def test_fastpath_on_zwsp_free_text(self) -> None:
        """When no ZWSP is present, the input string should be returned as-is."""
        s = "ကောင်းသော"
        self.assertIs(normalize_text(s), s)


if __name__ == "__main__":
    unittest.main()
