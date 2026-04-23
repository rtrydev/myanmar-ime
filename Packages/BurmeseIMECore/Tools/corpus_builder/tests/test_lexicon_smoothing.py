"""Tests for the Dirichlet-smoothed frequency floor in lexicon.py."""

from __future__ import annotations

import os
import tempfile
import unittest
from collections import Counter
from pathlib import Path

from corpus_builder import lexicon
from corpus_builder.vocab import SPECIALS, CuratedEntry, Vocab


def _vocab(surfaces: list[str]) -> Vocab:
    v = Vocab()
    for s in surfaces:
        v.add(s)
    v.id_bos = v.add(SPECIALS[0])
    v.id_eos = v.add(SPECIALS[1])
    v.id_unk = v.add(SPECIALS[2])
    return v


class CuratedSmoothingTests(unittest.TestCase):
    def setUp(self) -> None:
        fd, path = tempfile.mkstemp(suffix=".tsv")
        os.close(fd)
        self.path = Path(path)
        self.addCleanup(lambda: self.path.unlink(missing_ok=True))

    def _read_rows(self) -> dict[str, tuple[float, str | None]]:
        rows: dict[str, tuple[float, str | None]] = {}
        for line in self.path.read_text(encoding="utf-8").splitlines():
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            surface = parts[0]
            freq = float(parts[1])
            override = parts[2] if len(parts) >= 3 else None
            rows[surface] = (freq, override)
        return rows

    def test_absent_curated_surface_with_peers_gets_kappa_times_peer_avg(self) -> None:
        """The scenario the task's acceptance criterion spells out.

        Curated surface A is absent from corpus (count=0). Peers B and C
        share the digit-stripped reading and have corpus counts averaging
        10 000. At κ=0.1, A's floor should be ≈ 1 000.
        """
        surfaces = ["A", "B", "C"]
        curated = [
            CuratedEntry(surface="A", override_reading="r2"),
            CuratedEntry(surface="B", override_reading="r"),
            CuratedEntry(surface="C", override_reading="r"),
        ]
        counts = Counter({"B": 10_000, "C": 10_000})  # A absent
        lexicon.write_tsv(
            self.path,
            _vocab(surfaces),
            counts,
            curated,
            curated_smoothing=0.1,
        )
        rows = self._read_rows()
        freq_a, _ = rows["A"]
        self.assertAlmostEqual(freq_a, 1_000.0, delta=1.0)

    def test_natural_rows_unaffected(self) -> None:
        """Rows without override_reading keep the max(count, min_frequency) floor."""
        surfaces = ["N1", "N2"]
        curated = [
            CuratedEntry(surface="N1", override_reading=None),
            CuratedEntry(surface="N2", override_reading=None),
        ]
        counts = Counter({"N1": 500, "N2": 0})
        lexicon.write_tsv(
            self.path,
            _vocab(surfaces),
            counts,
            curated,
            curated_smoothing=0.5,
        )
        rows = self._read_rows()
        self.assertEqual(rows["N1"][0], 500.0)
        self.assertEqual(rows["N2"][0], 1.0)  # min_frequency floor

    def test_singleton_peer_group_falls_back_to_min_frequency(self) -> None:
        """A curated row whose peer group has no other members gets the standard floor."""
        surfaces = ["Solo"]
        curated = [CuratedEntry(surface="Solo", override_reading="alone")]
        counts = Counter()  # Solo absent
        lexicon.write_tsv(
            self.path,
            _vocab(surfaces),
            counts,
            curated,
            curated_smoothing=0.1,
        )
        rows = self._read_rows()
        self.assertEqual(rows["Solo"][0], 1.0)

    def test_kappa_zero_is_identity(self) -> None:
        """κ=0 reproduces the pre-smoothing behaviour exactly."""
        surfaces = ["A", "B"]
        curated = [
            CuratedEntry(surface="A", override_reading="r"),
            CuratedEntry(surface="B", override_reading="r"),
        ]
        counts = Counter({"A": 100, "B": 200})
        lexicon.write_tsv(
            self.path,
            _vocab(surfaces),
            counts,
            curated,
            curated_smoothing=0.0,
        )
        rows = self._read_rows()
        self.assertEqual(rows["A"][0], 100.0)
        self.assertEqual(rows["B"][0], 200.0)

    def test_peer_key_strips_digit_variants(self) -> None:
        """`r` and `r2` share a peer group (digit-stripped reading)."""
        surfaces = ["A", "B"]
        curated = [
            CuratedEntry(surface="A", override_reading="r2"),
            CuratedEntry(surface="B", override_reading="r"),
        ]
        counts = Counter({"A": 0, "B": 1_000})
        lexicon.write_tsv(
            self.path,
            _vocab(surfaces),
            counts,
            curated,
            curated_smoothing=0.2,
        )
        rows = self._read_rows()
        # A's avg_peer (excl self) = B's count = 1000 → 0 + 0.2*1000 = 200
        self.assertAlmostEqual(rows["A"][0], 200.0, delta=1.0)


if __name__ == "__main__":
    unittest.main()
