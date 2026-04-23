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

        Curated surface `က` is absent from corpus (count=0). Peers `ခ`
        and `ဂ` share the digit-stripped reading and have corpus counts
        averaging 10 000. At κ=0.1, `က`'s floor should be ≈ 1 000.
        """
        surfaces = ["က", "ခ", "ဂ"]
        curated = [
            CuratedEntry(surface="က", override_reading="r2"),
            CuratedEntry(surface="ခ", override_reading="r"),
            CuratedEntry(surface="ဂ", override_reading="r"),
        ]
        counts = Counter({"ခ": 10_000, "ဂ": 10_000})  # က absent
        lexicon.write_tsv(
            self.path,
            _vocab(surfaces),
            counts,
            curated,
            curated_smoothing=0.1,
        )
        rows = self._read_rows()
        freq, _ = rows["က"]
        self.assertAlmostEqual(freq, 1_000.0, delta=1.0)

    def test_natural_rows_unaffected(self) -> None:
        """Rows without override_reading keep the max(count, min_frequency) floor."""
        surfaces = ["က", "ခ"]
        curated = [
            CuratedEntry(surface="က", override_reading=None),
            CuratedEntry(surface="ခ", override_reading=None),
        ]
        counts = Counter({"က": 500, "ခ": 0})
        lexicon.write_tsv(
            self.path,
            _vocab(surfaces),
            counts,
            curated,
            curated_smoothing=0.5,
        )
        rows = self._read_rows()
        self.assertEqual(rows["က"][0], 500.0)
        self.assertEqual(rows["ခ"][0], 1.0)  # min_frequency floor

    def test_singleton_peer_group_falls_back_to_min_frequency(self) -> None:
        """A curated row whose peer group has no other members gets the standard floor."""
        surfaces = ["က"]
        curated = [CuratedEntry(surface="က", override_reading="alone")]
        counts = Counter()  # က absent
        lexicon.write_tsv(
            self.path,
            _vocab(surfaces),
            counts,
            curated,
            curated_smoothing=0.1,
        )
        rows = self._read_rows()
        self.assertEqual(rows["က"][0], 1.0)

    def test_kappa_zero_is_identity(self) -> None:
        """κ=0 reproduces the pre-smoothing behaviour exactly."""
        surfaces = ["က", "ခ"]
        curated = [
            CuratedEntry(surface="က", override_reading="r"),
            CuratedEntry(surface="ခ", override_reading="r"),
        ]
        counts = Counter({"က": 100, "ခ": 200})
        lexicon.write_tsv(
            self.path,
            _vocab(surfaces),
            counts,
            curated,
            curated_smoothing=0.0,
        )
        rows = self._read_rows()
        self.assertEqual(rows["က"][0], 100.0)
        self.assertEqual(rows["ခ"][0], 200.0)

    def test_peer_key_strips_digit_variants(self) -> None:
        """`r` and `r2` share a peer group (digit-stripped reading)."""
        surfaces = ["က", "ခ"]
        curated = [
            CuratedEntry(surface="က", override_reading="r2"),
            CuratedEntry(surface="ခ", override_reading="r"),
        ]
        counts = Counter({"က": 0, "ခ": 1_000})
        lexicon.write_tsv(
            self.path,
            _vocab(surfaces),
            counts,
            curated,
            curated_smoothing=0.2,
        )
        rows = self._read_rows()
        # က's avg_peer (excl self) = ခ's count = 1000 → 0 + 0.2*1000 = 200
        self.assertAlmostEqual(rows["က"][0], 200.0, delta=1.0)


if __name__ == "__main__":
    unittest.main()
