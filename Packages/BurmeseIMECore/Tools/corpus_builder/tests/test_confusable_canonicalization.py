"""Tests for TASK-037: Myanmar digit / consonant confusable pairs in
the corpus that produce poisoned lexicon entries.

The ingest pipeline applies a context-sensitive rewrite for three
confusable directions:

1. Class 1: leading `၀` (U+1040, digit zero) followed by a Burmese
   consonant or stack mark → `ဝ` (U+101D, wa-consonant). Corpus
   authors typed digit zero where they meant the wa-consonant
   because of font confusion.
2. Class 2: leading `၄င်း` (U+1044 digit four + ng-suffix) →
   `၎င်း` (U+104E aforementioned-symbol). The corpus systematically
   miscodes the very common formal-register `၎င်း` as starting with
   digit four.
3. Class 3: a Myanmar consonant `ဝ` (U+101D) embedded inside an
   otherwise pure-digit numeral run (e.g. `၂ဝ၁၈` for "2018") →
   rewrite the embedded `ဝ` to `၀`. The inverse of Class 1.
"""

from __future__ import annotations

import unittest

from corpus_builder.ingest import normalize_text


class Class1LeadingZeroTests(unittest.TestCase):
    """Leading U+1040 followed by a Burmese consonant / stack mark
    becomes U+101D."""

    def test_zero_before_kya(self) -> None:
        # `၀ကျော်` (poisoned) → `ဝကျော်`
        self.assertEqual(normalize_text("၀ကျော်"), "ဝကျော်")

    def test_zero_before_in(self) -> None:
        # `၀င်ငွေ` (income) → `ဝင်ငွေ`
        self.assertEqual(normalize_text("၀င်ငွေ"), "ဝင်ငွေ")

    def test_zero_before_pork(self) -> None:
        # `၀က်သား` → `ဝက်သား`
        self.assertEqual(normalize_text("၀က်သား"), "ဝက်သား")

    def test_zero_before_clothing(self) -> None:
        # `၀တ်စုံ` → `ဝတ်စုံ`
        self.assertEqual(normalize_text("၀တ်စုံ"), "ဝတ်စုံ")

    def test_zero_before_ministry(self) -> None:
        # `၀န်မလေး` → `ဝန်မလေး`
        self.assertEqual(normalize_text("၀န်မလေး"), "ဝန်မလေး")

    def test_pure_zero_unchanged(self) -> None:
        """A bare U+1040 with no following consonant must NOT be
        rewritten. `၀` alone is a legitimate digit."""
        self.assertEqual(normalize_text("၀"), "၀")

    def test_year_starting_with_zero_unchanged(self) -> None:
        """Year-like strings where U+1040 leads digits stay digits."""
        # `၀၁၂၃` (a sequence that happens to start with zero — not a
        # real year, but still pure-digit shape).
        self.assertEqual(normalize_text("၀၁၂၃"), "၀၁၂၃")

    def test_zero_in_middle_of_digit_run_unchanged(self) -> None:
        """`၁၀` (10) — the zero is correctly a digit because both
        neighbours are digits."""
        self.assertEqual(normalize_text("၁၀"), "၁၀")


class Class2DigitFourAforementionedTests(unittest.TestCase):
    """Leading U+1044 followed by `င်း` becomes U+104E."""

    def test_four_ng_to_aforementioned(self) -> None:
        # `၄င်း` (poisoned) → `၎င်း`
        self.assertEqual(normalize_text("၄င်း"), "၎င်း")

    def test_four_ng_to_compound(self) -> None:
        # `၄င်းတို့` → `၎င်းတို့`
        self.assertEqual(normalize_text("၄င်းတို့"), "၎င်းတို့")

    def test_four_ng_in_genitive(self) -> None:
        # `၄င်းတို့၏` → `၎င်းတို့၏`
        self.assertEqual(normalize_text("၄င်းတို့၏"), "၎င်းတို့၏")

    def test_four_alone_unchanged(self) -> None:
        """A bare U+1044 (digit four) with no `င်း` suffix stays a
        digit."""
        self.assertEqual(normalize_text("၄"), "၄")

    def test_year_with_four_unchanged(self) -> None:
        """Years like `၂၀၁၄` keep the digit four — only the prefix
        `၄` immediately before `င်း` is the bug pattern."""
        self.assertEqual(normalize_text("၂၀၁၄"), "၂၀၁၄")


class Class3WaInDigitRunTests(unittest.TestCase):
    """U+101D (wa-consonant) embedded between two digits in an
    otherwise pure-digit numeral run becomes U+1040."""

    def test_wa_in_year_2018(self) -> None:
        # `၂ဝ၁၈` (poisoned) → `၂၀၁၈`
        self.assertEqual(normalize_text("၂ဝ၁၈"), "၂၀၁၈")

    def test_wa_in_year_2017(self) -> None:
        self.assertEqual(normalize_text("၂ဝ၁၇"), "၂၀၁၇")

    def test_wa_in_year_2019(self) -> None:
        self.assertEqual(normalize_text("၂ဝ၁၉"), "၂၀၁၉")

    def test_two_was_in_2008(self) -> None:
        # `၂ဝဝ၈` → `၂၀၀၈` (both wa's rewrite)
        self.assertEqual(normalize_text("၂ဝဝ၈"), "၂၀၀၈")

    def test_wa_alone_unchanged(self) -> None:
        """Bare U+101D consonant stays a consonant."""
        self.assertEqual(normalize_text("ဝ"), "ဝ")

    def test_wa_in_word_unchanged(self) -> None:
        """`ဝက်သား` (pork — `wa + asat + ...`) is a real word; the
        U+101D is between Burmese marks, not digits, so it stays."""
        self.assertEqual(normalize_text("ဝက်သား"), "ဝက်သား")

    def test_wa_in_mixed_text_with_digits_unchanged(self) -> None:
        """`ဝန်ထမ်း ၁၀ ယောက်` — wa-consonant inside Burmese morpheme
        is preserved; the digit run `၁၀` is separated from `ဝ`."""
        text = "ဝန်ထမ်း ၁၀ ယောက်"
        self.assertEqual(normalize_text(text), text)


class CompositionWithExistingNormalizationTests(unittest.TestCase):
    """The confusable rewrites must compose with ZWSP strip and NFC."""

    def test_zwsp_and_class1(self) -> None:
        """ZWSP at the start should be stripped before the leading-zero
        check fires."""
        # Leading ZWSP, then `၀ကျော်`. The ZWSP strip leaves
        # `၀ကျော်`, which then gets the Class 1 rewrite.
        self.assertEqual(normalize_text("​၀ကျော်"), "ဝကျော်")


if __name__ == "__main__":
    unittest.main()
