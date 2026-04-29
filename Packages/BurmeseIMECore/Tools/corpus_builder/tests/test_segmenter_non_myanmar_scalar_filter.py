"""Tests for the broader non-Myanmar scalar filter in segmenter.py.

The original `_has_non_myanmar_leading_scalar` only inspected the leading
scalar, so tokens with ASCII punctuation appended (e.g. `ဗျာ..`,
`တယ်...`, `လား?`) survived segmentation and propagated into the
lexicon as separate high-frequency entries that pollute the candidate
panel. `_has_non_myanmar_scalar` rejects any token containing a scalar
outside the Myanmar block (with ZWNJ / ZWJ allowed).
"""

from __future__ import annotations

import unittest
from collections import Counter
from pathlib import Path
from tempfile import TemporaryDirectory

from corpus_builder.lexicon import write_tsv
from corpus_builder.segmenter import (
    Segmenter,
    _has_non_myanmar_scalar,
)
from corpus_builder.vocab import (
    CuratedEntry,
    Vocab,
    _is_polluted_surface,
    build_vocab,
    read_curated_tsv,
)


class HasNonMyanmarScalarTests(unittest.TestCase):
    def test_trailing_ascii_dot_is_rejected(self) -> None:
        self.assertTrue(_has_non_myanmar_scalar("ဗျာ."))
        self.assertTrue(_has_non_myanmar_scalar("ဗျာ.."))
        self.assertTrue(_has_non_myanmar_scalar("ဗျာ..."))
        self.assertTrue(_has_non_myanmar_scalar("တယ်...."))

    def test_trailing_ascii_punct_variants_are_rejected(self) -> None:
        for token in ("လား?", "ပါ!", "သည်,", "ပအိုဝ်;", "၁:", "တယ်'", "သည်\""):
            self.assertTrue(
                _has_non_myanmar_scalar(token),
                f"expected reject for {token!r}",
            )

    def test_embedded_ascii_is_rejected(self) -> None:
        self.assertTrue(_has_non_myanmar_scalar("ကျောင်းသား/သူ"))
        self.assertTrue(_has_non_myanmar_scalar("၄၀x၆၀"))
        self.assertTrue(_has_non_myanmar_scalar("အမှတ်("))

    def test_ellipsis_and_curly_quotes_are_rejected(self) -> None:
        self.assertTrue(_has_non_myanmar_scalar("ပေါ့…"))
        self.assertTrue(_has_non_myanmar_scalar("တယ်’"))
        self.assertTrue(_has_non_myanmar_scalar("တယ်”"))

    def test_emoji_is_rejected(self) -> None:
        self.assertTrue(_has_non_myanmar_scalar("တာ😁"))
        self.assertTrue(_has_non_myanmar_scalar("ပါစေ🙏"))

    def test_bom_anywhere_is_rejected(self) -> None:
        self.assertTrue(_has_non_myanmar_scalar("﻿ကျွန်တော်"))
        self.assertTrue(_has_non_myanmar_scalar("ကျွန်﻿တော်"))

    def test_clean_myanmar_surface_is_kept(self) -> None:
        for surface in (
            "ကျောင်းသား",
            "အ",
            "ဥ",
            "ကျွန်တော်",
            "ဗျာ",
            "တယ်",
            "လား",
        ):
            self.assertFalse(
                _has_non_myanmar_scalar(surface),
                f"clean Myanmar token {surface!r} was rejected",
            )

    def test_zwnj_and_zwj_are_allowed(self) -> None:
        # ZWNJ / ZWJ appear inside legitimate orthographic clusters.
        self.assertFalse(_has_non_myanmar_scalar("‌ကျ"))
        self.assertFalse(_has_non_myanmar_scalar("ကျ‍က"))

    def test_empty_token_is_rejected(self) -> None:
        self.assertTrue(_has_non_myanmar_scalar(""))


class SegmenterTrailingPunctTests(unittest.TestCase):
    def setUp(self) -> None:
        self.seg = Segmenter(allow_fallback=True, merge_curated=False)

    def test_trailing_dots_dropped_from_pieces(self) -> None:
        # The syllable-fallback splitter does not append ASCII punct
        # to its pieces, so we feed it raw and verify nothing with
        # trailing `.` survives. Real myWord runs see far worse
        # pollution from sentences ending with `..` / `...` —
        # `_has_non_myanmar_scalar` is the safety net regardless of
        # which segmenter ran.
        for raw in ("ဗျာ..", "ဗျာ...", "တယ်...."):
            self.assertTrue(_has_non_myanmar_scalar(raw))


class CuratedLoaderRejectsTrailingPunct(unittest.TestCase):
    def test_trailing_dot_rows_filtered_from_curated(self) -> None:
        with TemporaryDirectory() as d:
            path = Path(d) / "curated.tsv"
            path.write_text(
                "\n".join(
                    [
                        "# header",
                        "ကျွန်တော်\t100",
                        "ဗျာ..\t12085",
                        "ဗျာ...\t6611",
                        "တယ်...\t32420",
                        "လား?\t11043",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            entries = read_curated_tsv(path)
            surfaces = [e.surface for e in entries]
            self.assertIn("ကျွန်တော်", surfaces)
            self.assertNotIn("ဗျာ..", surfaces)
            self.assertNotIn("ဗျာ...", surfaces)
            self.assertNotIn("တယ်...", surfaces)
            self.assertNotIn("လား?", surfaces)


class VocabExcludesTrailingPunct(unittest.TestCase):
    def test_polluted_surfaces_excluded_from_vocab(self) -> None:
        counts: Counter[str] = Counter(
            {
                "ဗျာ": 100,
                "ဗျာ..": 12085,
                "ဗျာ...": 6611,
                "တယ်": 50,
                "တယ်...": 32420,
            }
        )
        vocab = build_vocab(counts, [], max_corpus_words=100)
        self.assertIn("ဗျာ", vocab.id_of)
        self.assertIn("တယ်", vocab.id_of)
        self.assertNotIn("ဗျာ..", vocab.id_of)
        self.assertNotIn("ဗျာ...", vocab.id_of)
        self.assertNotIn("တယ်...", vocab.id_of)


class LexiconWriterRejectsTrailingPunct(unittest.TestCase):
    def test_polluted_surface_raises(self) -> None:
        vocab = Vocab()
        vocab.add("ဗျာ..")
        vocab.add("<s>")
        vocab.add("</s>")
        vocab.add("<unk>")
        with TemporaryDirectory() as d:
            out = Path(d) / "out.tsv"
            with self.assertRaises(ValueError):
                write_tsv(out, vocab, Counter(), [], min_frequency=1.0)


class IsPollutedSurfaceCoversTrailingPunct(unittest.TestCase):
    def test_is_polluted_surface_detects_trailing_punct(self) -> None:
        self.assertTrue(_is_polluted_surface("ဗျာ.."))
        self.assertTrue(_is_polluted_surface("ဗျာ..."))
        self.assertTrue(_is_polluted_surface("လား?"))
        self.assertTrue(_is_polluted_surface("ပေါ့…"))
        self.assertFalse(_is_polluted_surface("ဗျာ"))
        self.assertFalse(_is_polluted_surface("ကျောင်းသား"))


if __name__ == "__main__":
    unittest.main()
