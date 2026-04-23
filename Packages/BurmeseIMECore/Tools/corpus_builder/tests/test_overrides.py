"""Tests for the in-tree curated override-reading table (task 06)."""

from __future__ import annotations

import unittest
from collections import Counter
from pathlib import Path
from tempfile import TemporaryDirectory

from corpus_builder import lexicon
from corpus_builder.build import _apply_curated_overrides
from corpus_builder.overrides import (
    CURATED_OVERRIDE_READINGS,
    override_reading_for,
)
from corpus_builder.vocab import SPECIALS, CuratedEntry, Vocab


def _vocab(surfaces: list[str]) -> Vocab:
    v = Vocab()
    for s in surfaces:
        v.add(s)
    v.id_bos = v.add(SPECIALS[0])
    v.id_eos = v.add(SPECIALS[1])
    v.id_unk = v.add(SPECIALS[2])
    return v


class OverrideLookupTests(unittest.TestCase):
    def test_irregular_yapin_surfaces_have_overrides(self) -> None:
        # Task 06 calls out these three surfaces by name.
        self.assertEqual(override_reading_for("ကျပ်"), "ky2at")
        self.assertEqual(override_reading_for("ကျင်း"), "ky2in")
        self.assertEqual(override_reading_for("ကျေးဇူး"), "ky2ayzu")

    def test_unmapped_surface_returns_none(self) -> None:
        self.assertIsNone(override_reading_for("ကျား"))


class ApplyCuratedOverridesTests(unittest.TestCase):
    def test_overrides_injected_when_missing_from_curated(self) -> None:
        base = [CuratedEntry(surface="ကျား", override_reading=None)]
        merged = _apply_curated_overrides(base)
        by_surface = {e.surface: e for e in merged}
        for surface, reading in CURATED_OVERRIDE_READINGS.items():
            self.assertIn(surface, by_surface)
            self.assertEqual(by_surface[surface].override_reading, reading)

    def test_overrides_wins_over_prior_tsv_value(self) -> None:
        base = [
            CuratedEntry(surface="ကျပ်", override_reading="stale_reading"),
        ]
        merged = _apply_curated_overrides(base)
        by_surface = {e.surface: e for e in merged}
        self.assertEqual(by_surface["ကျပ်"].override_reading, "ky2at")


class LexiconWriterStampsOverrideColumnTests(unittest.TestCase):
    def test_override_column_appears_for_irregular_yapin(self) -> None:
        surfaces = list(CURATED_OVERRIDE_READINGS.keys())
        curated_with_overrides = _apply_curated_overrides([])
        counts: Counter[str] = Counter({s: 1000 for s in surfaces})
        with TemporaryDirectory() as d:
            path = Path(d) / "out.tsv"
            lexicon.write_tsv(
                path,
                _vocab(surfaces),
                counts,
                curated_with_overrides,
                curated_smoothing=0.0,
            )
            rows = {}
            for line in path.read_text(encoding="utf-8").splitlines():
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                rows[parts[0]] = parts[2] if len(parts) >= 3 else None
        for surface, expected in CURATED_OVERRIDE_READINGS.items():
            self.assertEqual(
                rows.get(surface), expected,
                f"{surface} should have override_reading={expected}",
            )


if __name__ == "__main__":
    unittest.main()
