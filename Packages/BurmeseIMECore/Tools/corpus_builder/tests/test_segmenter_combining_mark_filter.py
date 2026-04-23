"""Tests for the orphan combining-mark filter in segmenter.py.

Standalone Myanmar dependent vowels, medials, virama/asat, and tone
marks (U+102B–U+103E) must never survive segmentation as tokens — they
are not words, they are combining marks that require a consonant base.
Without this filter they leak into the lexicon at high unigram scores
and beat the independent-vowel forms for bare-vowel buffers (task 01).
"""

from __future__ import annotations

import unittest

from corpus_builder.segmenter import Segmenter, _is_combining_mark_only


class IsCombiningMarkOnlyTests(unittest.TestCase):
    def test_dependent_vowels_are_combining_only(self) -> None:
        for scalar in (0x102B, 0x102C, 0x102D, 0x102E, 0x102F, 0x1030, 0x1031, 0x1032):
            self.assertTrue(
                _is_combining_mark_only(chr(scalar)),
                f"U+{scalar:04X} should be flagged as combining-mark only",
            )

    def test_medials_and_virama_are_combining_only(self) -> None:
        for scalar in (0x1039, 0x103A, 0x103B, 0x103C, 0x103D, 0x103E):
            self.assertTrue(
                _is_combining_mark_only(chr(scalar)),
                f"U+{scalar:04X} should be flagged as combining-mark only",
            )

    def test_consonants_and_independent_vowels_are_not_combining_only(self) -> None:
        for surface in ("က", "အ", "ဥ", "ဧ", "ကျောင်း"):
            self.assertFalse(
                _is_combining_mark_only(surface),
                f"{surface!r} must not be flagged as combining-mark only",
            )

    def test_combining_run_without_base_is_still_orphan(self) -> None:
        # Multiple marks strung together with no base consonant are
        # still not a word. Covered as a defensive guard.
        self.assertTrue(_is_combining_mark_only("ိ္"))

    def test_empty_token_is_treated_as_orphan(self) -> None:
        self.assertTrue(_is_combining_mark_only(""))


class SegmenterFilterTests(unittest.TestCase):
    """End-to-end: combining-mark-only pieces must be dropped before
    `segment()` returns even when they reach the post-merge stage."""

    def setUp(self) -> None:
        # Use the syllable fallback to keep the test hermetic — we are
        # testing the filter, not the myWord Viterbi.
        self.seg = Segmenter(allow_fallback=True, merge_curated=False)

    def test_no_orphan_marks_survive_segmentation(self) -> None:
        # The syllable fallback never emits a bare dep-vowel, but the
        # myWord Viterbi can — simulate the post-split list by running
        # segment() on inputs that include orphan combining marks.
        pieces = self.seg.segment("က ေ ျ ်")
        for p in pieces:
            self.assertFalse(
                _is_combining_mark_only(p),
                f"orphan combining mark {p!r} must not survive",
            )

    def test_no_filter_regression_on_clean_tokens(self) -> None:
        pieces = self.seg.segment("ကျောင်းသား")
        for p in pieces:
            self.assertFalse(_is_combining_mark_only(p))


if __name__ == "__main__":
    unittest.main()
