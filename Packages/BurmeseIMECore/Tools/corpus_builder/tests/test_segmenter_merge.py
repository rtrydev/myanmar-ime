"""Tests for the curated-compound merge pass in segmenter.py.

Runs under `python -m unittest discover -s tests` or pytest — assertions
are stdlib, no extra deps required.
"""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from corpus_builder.segmenter import _load_curated_compounds, _merge_curated


def _build(curated):
    max_chars = max((len(s) for s in curated), default=0)
    prefixes = frozenset(s[:k] for s in curated for k in range(1, len(s)))
    return curated, prefixes, max_chars


class MergeCuratedTests(unittest.TestCase):
    def _merge(self, pieces, curated):
        c, p, mc = _build(curated)
        return _merge_curated(pieces, c, p, mc)

    def test_compound_in_curated_set_is_merged(self) -> None:
        pieces = ["က", "ျောင်း"]
        curated = frozenset({"ကျောင်း"})
        self.assertEqual(self._merge(pieces, curated), ["ကျောင်း"])

    def test_compound_not_in_curated_set_is_left_alone(self) -> None:
        pieces = ["က", "ျောင်း"]
        curated = frozenset({"ချင်"})
        self.assertEqual(self._merge(pieces, curated), pieces)

    def test_longest_match_wins_among_overlapping_candidates(self) -> None:
        pieces = ["က", "ျေး", "ဇူး"]
        curated = frozenset({"ကျေး", "ကျေးဇူး"})
        self.assertEqual(self._merge(pieces, curated), ["ကျေးဇူး"])

    def test_merge_applies_mid_sentence(self) -> None:
        pieces = ["ငါ", "က", "ျောင်း", "သွား"]
        curated = frozenset({"ကျောင်း"})
        self.assertEqual(
            self._merge(pieces, curated),
            ["ငါ", "ကျောင်း", "သွား"],
        )

    def test_empty_curated_set_is_identity(self) -> None:
        pieces = ["ငါ", "က", "ျောင်း"]
        self.assertEqual(_merge_curated(pieces, frozenset(), frozenset(), 0), pieces)

    def test_oversize_first_piece_skips_inner_loop(self) -> None:
        """Oversize start piece can't be a curated prefix — bail without scanning."""
        curated = frozenset({"ကျောင်း"})
        c, p, mc = _build(curated)
        pieces = ["X" * (mc + 5), "က", "ျောင်း"]
        self.assertEqual(_merge_curated(pieces, c, p, mc), [pieces[0], "ကျောင်း"])

    def test_prefix_miss_breaks_early(self) -> None:
        """When accum stops being a curated prefix, inner loop exits."""
        curated = frozenset({"ကျောင်း"})
        c, p, mc = _build(curated)
        # "က" is a prefix; "ကXXX" is not — so the loop bails immediately
        # after extending past "က".
        pieces = ["က", "XXX", "more"]
        self.assertEqual(_merge_curated(pieces, c, p, mc), pieces)


class LoadCuratedCompoundsTests(unittest.TestCase):
    def _write_tsv(self, rows: list[str]) -> Path:
        fd, path = tempfile.mkstemp(suffix=".tsv")
        os.close(fd)
        Path(path).write_text("\n".join(rows) + "\n", encoding="utf-8")
        self.addCleanup(lambda: Path(path).unlink(missing_ok=True))
        return Path(path)

    def test_loads_multi_syllable_surfaces_and_drops_single_syllable(self) -> None:
        tsv = self._write_tsv(
            [
                "# surface<TAB>frequency",
                "ကျောင်း\t100",
                "ပါ\t10",
                "မင်္ဂလာပါ\t5\tmin+galarpar2",
            ]
        )
        compounds, prefixes, max_chars = _load_curated_compounds(tsv)
        self.assertIn("ကျောင်း", compounds)
        self.assertIn("မင်္ဂလာပါ", compounds)
        self.assertNotIn("ပါ", compounds)
        self.assertEqual(max_chars, len("မင်္ဂလာပါ"))
        # First Myanmar character of each compound should appear as a prefix.
        self.assertIn("က", prefixes)
        self.assertIn("မ", prefixes)

    def test_oversize_entry_capped(self) -> None:
        """Surfaces longer than max_chars_cap are dropped."""
        tsv = self._write_tsv(["X" * 200 + "\t1", "ကျောင်း\t1"])
        compounds, _, max_chars = _load_curated_compounds(tsv, max_chars_cap=50)
        self.assertNotIn("X" * 200, compounds)
        self.assertIn("ကျောင်း", compounds)
        self.assertLessEqual(max_chars, 50)

    def test_missing_path_returns_empty(self) -> None:
        c, p, mc = _load_curated_compounds(Path("/nonexistent/path.tsv"))
        self.assertEqual(c, frozenset())
        self.assertEqual(p, frozenset())
        self.assertEqual(mc, 0)

    def test_env_var_fallback(self) -> None:
        tsv = self._write_tsv(["ကျောင်း\t100"])
        prev = os.environ.get("CURATED_TSV")
        os.environ["CURATED_TSV"] = str(tsv)
        try:
            compounds, _, _ = _load_curated_compounds()
            self.assertIn("ကျောင်း", compounds)
        finally:
            if prev is None:
                os.environ.pop("CURATED_TSV", None)
            else:
                os.environ["CURATED_TSV"] = prev


if __name__ == "__main__":
    unittest.main()
