"""Tests for the non-Myanmar leading-scalar filter in segmenter.py.

Three sibling patterns still leak into the lexicon after the task-01
combining-mark filter landed (task 05):

- Ellipsis prefix (U+2026) anchors `…<word>` compounds at top-1.
- Myanmar / Shan digit + combining mark (e.g. `႐ု`, `၀ီ`) is an
  orphan — digits don't take dep-vowels.
- BOM (U+FEFF) anywhere in the token pollutes the reading.

The filter is enforced at the segmenter, curated-TSV loader, and
lexicon writer so a stale round-trip can't re-poison the vocab.
"""

from __future__ import annotations

import unittest
from collections import Counter
from pathlib import Path
from tempfile import TemporaryDirectory

from corpus_builder.lexicon import write_tsv
from corpus_builder.segmenter import (
    Segmenter,
    _has_non_myanmar_leading_scalar,
)
from corpus_builder.vocab import (
    CuratedEntry,
    Vocab,
    _is_polluted_surface,
    build_vocab,
    read_curated_tsv,
)


class HasNonMyanmarLeadingScalarTests(unittest.TestCase):
    def test_ellipsis_prefix_is_rejected(self) -> None:
        self.assertTrue(_has_non_myanmar_leading_scalar("…ကျွန်တော်"))
        self.assertTrue(_has_non_myanmar_leading_scalar("…"))
        self.assertTrue(_has_non_myanmar_leading_scalar("……"))

    def test_shan_digit_plus_mark_is_rejected(self) -> None:
        self.assertTrue(_has_non_myanmar_leading_scalar("႐ု"))  # ႐ု

    def test_myanmar_digit_plus_mark_is_rejected(self) -> None:
        self.assertTrue(_has_non_myanmar_leading_scalar("၀ီက"))  # ၀ီက

    def test_myanmar_digit_plus_consonant_is_kept(self) -> None:
        # Stylistic ၀/ဝ substitution like `၀တ်စုံ` is intentional
        # (and attested heavily in the corpus) — the filter only
        # rejects digit + combining-mark orphans.
        self.assertFalse(_has_non_myanmar_leading_scalar("၀တ်"))

    def test_bom_anywhere_is_rejected(self) -> None:
        self.assertTrue(_has_non_myanmar_leading_scalar("﻿ကျွန်တော်"))
        self.assertTrue(_has_non_myanmar_leading_scalar("ကျွန်﻿တော်"))

    def test_clean_myanmar_surface_is_kept(self) -> None:
        for surface in ("ကျောင်းသား", "အ", "ဥ", "ကျွန်တော်"):
            self.assertFalse(_has_non_myanmar_leading_scalar(surface))

    def test_zwnj_leading_scalar_is_allowed(self) -> None:
        self.assertFalse(_has_non_myanmar_leading_scalar("‌ကျ"))

    def test_empty_token_is_rejected(self) -> None:
        self.assertTrue(_has_non_myanmar_leading_scalar(""))


class SegmenterLeadingScalarTests(unittest.TestCase):
    def setUp(self) -> None:
        self.seg = Segmenter(allow_fallback=True, merge_curated=False)

    def test_ellipsis_prefix_dropped_from_pieces(self) -> None:
        pieces = self.seg.segment("… ကျောင်း")
        for p in pieces:
            self.assertFalse(
                _has_non_myanmar_leading_scalar(p),
                f"polluted surface {p!r} survived segmentation",
            )

    def test_digit_plus_mark_dropped_from_pieces(self) -> None:
        pieces = self.seg.segment("႐ု ကျောင်း")
        for p in pieces:
            self.assertFalse(_has_non_myanmar_leading_scalar(p))


class CuratedLoaderFilterTests(unittest.TestCase):
    def test_polluted_rows_filtered_from_curated(self) -> None:
        with TemporaryDirectory() as d:
            path = Path(d) / "curated.tsv"
            path.write_text(
                "\n".join(
                    [
                        "# header",
                        "ကျွန်တော်\t100",
                        "…ကျွန်တော်\t741",
                        "႐ု\t1",
                        "﻿ကျွန်တော်\t5",
                        "၀ီ\t3",
                        "၀တ်\t10",  # ၀တ် — kept
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            entries = read_curated_tsv(path)
            surfaces = [e.surface for e in entries]
            self.assertIn("ကျွန်တော်", surfaces)
            self.assertIn("၀တ်", surfaces)
            self.assertNotIn("…ကျွန်တော်", surfaces)
            self.assertNotIn("႐ု", surfaces)
            self.assertNotIn("﻿ကျွန်တော်", surfaces)
            self.assertNotIn("၀ီ", surfaces)


class VocabBuildFilterTests(unittest.TestCase):
    def test_polluted_surfaces_excluded_from_vocab(self) -> None:
        counts: Counter[str] = Counter(
            {
                "ကျောင်း": 100,
                "…ကျောင်း": 10,
                "႐ု": 5,
            }
        )
        curated = [
            CuratedEntry(surface="ကျွန်တော်", override_reading=None),
            CuratedEntry(surface="…ကျွန်တော်", override_reading=None),
        ]
        vocab = build_vocab(counts, curated, max_corpus_words=100)
        self.assertIn("ကျောင်း", vocab.id_of)
        self.assertIn("ကျွန်တော်", vocab.id_of)
        self.assertNotIn("…ကျောင်း", vocab.id_of)
        self.assertNotIn("…ကျွန်တော်", vocab.id_of)
        self.assertNotIn("႐ု", vocab.id_of)


class LexiconWriterAssertionTests(unittest.TestCase):
    def test_polluted_surface_raises(self) -> None:
        vocab = Vocab()
        vocab.add("…ကျွန်တော်")
        vocab.add("<s>")
        vocab.add("</s>")
        vocab.add("<unk>")
        with TemporaryDirectory() as d:
            out = Path(d) / "out.tsv"
            with self.assertRaises(ValueError):
                write_tsv(out, vocab, Counter(), [], min_frequency=1.0)


class IsPollutedSurfaceTests(unittest.TestCase):
    def test_is_polluted_surface_detects_both_patterns(self) -> None:
        self.assertTrue(_is_polluted_surface("ါ"))  # orphan mark
        self.assertTrue(_is_polluted_surface("…ကျ"))
        self.assertTrue(_is_polluted_surface("႐ု"))
        self.assertFalse(_is_polluted_surface("ကျောင်း"))


if __name__ == "__main__":
    unittest.main()
