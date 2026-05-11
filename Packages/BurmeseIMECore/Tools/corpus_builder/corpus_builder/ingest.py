"""Streams the Myanmar-C4 corpus and filters Zawgyi-encoded documents.

The HuggingFace dataset is streamed rather than materialised so the pipeline
runs on a laptop without keeping the full corpus on disk.
"""

from __future__ import annotations

import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator


# U+200B (ZERO WIDTH SPACE) is a soft-break hint with no graphical effect
# in Myanmar and no orthographic meaning. It must be stripped before
# segmentation because:
#   - It splits counts of real words across ghost variants
#     ("ကောင်း" vs "ကောင်း​" as two distinct vocab ids).
#   - Swift's `CharacterSet.whitespaces` DOES include U+200B (contrary to
#     its docs), so `LexiconBuilder` trims leading ZWSP from TSV lines
#     but preserves trailing ZWSP before the tab, producing surfaces
#     that disagree with the LM vocab — a guaranteed drift failure.
# U+200C (ZWNJ) and U+200D (ZWJ) are legitimate in Myanmar — they
# control cluster formation between adjacent Myanmar scalars. We do
# strip them when they sit at a token boundary (leading / trailing /
# between non-Myanmar context) where they can't be cluster-formation
# controls — see `_strip_orphan_zwnj`.
_ZWSP = "​"
_ZWNJ = "‌"
_ZWJ = "‍"

# Myanmar block: U+1000..U+109F. Digits live in U+1040..U+1049
# (canonical) plus U+104E (aforementioned-symbol); the non-digit
# Myanmar consonants and dependent marks fall within U+1000..U+103F
# and U+104A..U+105F.
def _is_myanmar_digit(ch: str) -> bool:
    """True for U+1040..U+1049 (the Myanmar digit block)."""
    if not ch:
        return False
    cp = ord(ch)
    return 0x1040 <= cp <= 0x1049


def _is_myanmar_consonant_or_mark(ch: str) -> bool:
    """True for any Myanmar block scalar that is not a digit / not
    punctuation. Used by the confusable-pair rewrite to decide whether
    a U+1040 leading the token is followed by something that looks
    like part of a Burmese morpheme (consonants, dependent vowels,
    medials, virama/asat, tone marks)."""
    if not ch:
        return False
    cp = ord(ch)
    # Consonants & independent vowels, dep vowels, medials, virama,
    # asat, tone, anusvara: U+1000..U+103F. Plus U+104E
    # (aforementioned-symbol) and U+103F (great sa). Exclude digits
    # (U+1040..U+1049) and punctuation (U+104A pote-ma-tin,
    # U+104B ga-nga-ma-tin, U+104C, U+104D ywe, U+104F ei).
    if 0x1000 <= cp <= 0x103F:
        return True
    return False


# TASK-038: doubled tone-marker collapse. NFC reorders scalars by
# Combining Class but does NOT collapse duplicates. Corpus surfaces
# of the form `<X> 1037 1037` (creaky written twice) — and the
# anusvara / visarga equivalents — must collapse so duplicate-looking
# entries don't fragment the lexicon.
_TONE_SCALARS = ("ံ", "့", "း")


def _collapse_doubled_tones(text: str) -> str:
    """Collapse runs of identical tone scalars (U+1036 / U+1037 /
    U+1038) to a single scalar."""
    out: list[str] = []
    last: str | None = None
    for ch in text:
        if ch in _TONE_SCALARS and ch == last:
            continue
        out.append(ch)
        last = ch
    return "".join(out)


def _strip_orphan_zwnj(text: str) -> str:
    """Strip U+200C / U+200D when they appear at a position where
    they cannot be cluster-formation controls — i.e., at the very
    start or end of the token, or surrounded by non-Myanmar context.

    A legitimate ZWNJ sits between two Myanmar scalars where it
    explicitly suppresses (or, for ZWJ, forces) cluster formation.
    Any other position is corpus noise: trailing ZWNJ is invisible
    and orthographically inert, leading ZWNJ has no preceding base
    to attach to.
    """
    if _ZWNJ not in text and _ZWJ not in text:
        return text
    chars = list(text)
    n = len(chars)
    keep = [True] * n
    for i, ch in enumerate(chars):
        if ch != _ZWNJ and ch != _ZWJ:
            continue
        prev_ch = chars[i - 1] if i > 0 else ""
        next_ch = chars[i + 1] if i + 1 < n else ""

        def _is_myanmar(c: str) -> bool:
            if not c:
                return False
            cp = ord(c)
            return 0x1000 <= cp <= 0x109F

        # Strip when the ZW* sits outside a Myanmar-Myanmar context.
        if not (_is_myanmar(prev_ch) and _is_myanmar(next_ch)):
            keep[i] = False
    return "".join(c for c, k in zip(chars, keep) if k)


# TASK-037: confusable scalar pairs. Three rewrite directions are
# needed:
#
# Class 1: U+1040 (digit zero) sitting in a non-numeric context
# (adjacent to a Burmese consonant / stack mark, or after a Burmese
# consonant at end-of-word) → U+101D (wa-consonant). Corpus authors
# typed `၀` for `ဝ`.
#
# Class 2: leading U+1044 (digit four) immediately before `င်း`
# (U+1004 U+103A U+1038) → U+104E (aforementioned-symbol). Corpus
# miscodes the formal-register `၎င်း` as `၄င်း`.
#
# Class 3: U+101D (wa-consonant) sitting in a numeric context
# (between two Myanmar digits, or adjacent to a Myanmar digit at
# word boundary with no consonant on the other side) → U+1040
# (digit zero). Inverse of Class 1, common in date strings
# (`၂ဝ၁၈` → `၂၀၁၈`) and at end-of-word numbers (`၁ဝ` → `၁၀`).
#
# TASK-059 extends Classes 1 and 3 to cover the word-boundary
# cases the original TASK-037 rewriter missed:
#   - `ဘ၀` (consonant + zero, end-of-word) → `ဘဝ` (Class 1).
#   - `၁ဝ` (digit + wa, end-of-word) → `၁၀` (Class 3).
#   - `ဝ၁` (wa + digit, start-of-word) → `၀၁` (Class 3).
# Without these extensions, lexicon entries like `ဘ၀` and `၁ဝ`
# carry readings (`ba` / `wa`) that promote spurious year / `Bhava`
# surfaces above the bare consonants the user actually typed.
_NG_SUFFIX = "င်း"  # င်း


def _canonicalize_confusables(text: str) -> str:
    """Apply the three confusable-pair rewrites described in TASK-037."""
    if not text:
        return text

    # Class 2 first: `၄င်း` → `၎င်း`. Done as a substring scan rather
    # than a positional rewrite because the bug pattern is the
    # specific sequence (U+1044 U+1004 U+103A U+1038), not "any
    # leading U+1044".
    text = text.replace("၄" + _NG_SUFFIX, "၎" + _NG_SUFFIX)

    # Classes 1 and 3 are positional and depend on neighbours, so we
    # walk the string and rewrite per-character.
    chars = list(text)
    n = len(chars)
    for i, ch in enumerate(chars):
        if ch == "၀":
            # Class 1: a U+1040 in a non-numeric context is a
            # confusable for `ဝ`. Two firing shapes:
            #   (a) The `၀` is followed by a Burmese consonant /
            #       stack mark / dependent vowel AND the previous
            #       character is NOT a Myanmar digit — the original
            #       leading-position case (`၀က` → `ဝက`).
            #   (b) TASK-059: the `၀` is preceded by a Burmese
            #       consonant / mark AND the following character is
            #       not a Myanmar digit (end of word, punctuation,
            #       another non-digit). The `၀` sits as the trailing
            #       coda-position character of a syllable cluster
            #       — corpus authors typed `၀` for `ဝ` here too
            #       (`ဘ၀` → `ဘဝ`).
            prev_ch = chars[i - 1] if i > 0 else ""
            next_ch = chars[i + 1] if i + 1 < n else ""
            prev_is_digit = _is_myanmar_digit(prev_ch)
            next_is_digit = _is_myanmar_digit(next_ch)
            prev_is_consonant_or_mark = _is_myanmar_consonant_or_mark(prev_ch)
            next_is_consonant_or_mark = _is_myanmar_consonant_or_mark(next_ch)
            # Shape (a): leading-position rewrite (preserved).
            if not prev_is_digit and next_is_consonant_or_mark:
                chars[i] = "ဝ"
            # Shape (b): trailing-position rewrite (TASK-059). The
            # `prev_is_consonant_or_mark` gate is symmetric with
            # shape (a)'s `next_is_consonant_or_mark`. The
            # `not next_is_digit` gate keeps the rewrite from
            # firing inside numeric runs (`၂၀` should remain `၂၀`,
            # not become `၂ဝ`).
            elif prev_is_consonant_or_mark and not next_is_digit:
                chars[i] = "ဝ"
        elif ch == "ဝ":
            # Class 3: a wa-consonant in a numeric context is a
            # confusable for `၀`. Three firing shapes:
            #   (a) Original: `ဝ` between two Myanmar digits in an
            #       otherwise pure-digit numeral run (`၂ဝ၁၈`).
            #   (b) TASK-059: `ဝ` after a digit at end-of-word /
            #       before a non-consonant (`၁ဝ` → `၁၀`).
            #   (c) TASK-059: `ဝ` before a digit at start-of-word /
            #       after a non-consonant (`ဝ၁` → `၀၁`).
            prev_ch = chars[i - 1] if i > 0 else ""
            next_ch = chars[i + 1] if i + 1 < n else ""
            # Walk the local wa run on both sides. The wa-rewrite
            # fires when the wa run's left and right "anchors" are
            # both compatible with the digit interpretation. An
            # anchor is "digit-compatible" when it is either a
            # Myanmar digit OR end-of-string AND the OTHER anchor is
            # a Myanmar digit (so a wa-run flanked by `<digit>...end`
            # rewrites to `0...0`, but a free-floating wa-run with
            # no digit anywhere stays consonants).
            left_anchor: str | None
            right_anchor: str | None
            # Walk left through wa run.
            if prev_ch == "ဝ":
                j = i - 1
                while j > 0 and chars[j] == "ဝ":
                    j -= 1
                left_anchor = chars[j] if chars[j] != "ဝ" else None
            else:
                left_anchor = prev_ch if prev_ch else None
            # Walk right through wa run.
            if next_ch == "ဝ":
                j = i + 1
                while j + 1 < n and chars[j] == "ဝ":
                    j += 1
                right_anchor = chars[j] if chars[j] != "ဝ" else None
            else:
                right_anchor = next_ch if next_ch else None
            left_digit = left_anchor is not None and _is_myanmar_digit(left_anchor)
            right_digit = right_anchor is not None and _is_myanmar_digit(right_anchor)
            left_consonant = left_anchor is not None and _is_myanmar_consonant_or_mark(left_anchor)
            right_consonant = right_anchor is not None and _is_myanmar_consonant_or_mark(right_anchor)
            # Shape (a): both anchors are digits — pure digit run
            # with embedded wa(s). Rewrite every wa to `၀`.
            if left_digit and right_digit:
                chars[i] = "၀"
            # Shape (b) (TASK-059): one anchor is a digit, the
            # other is end-of-word AND not a Burmese consonant/mark.
            # The wa run is being used as the trailing/leading
            # zeros of a number. Rewrite.
            elif left_digit and right_anchor is None:
                chars[i] = "၀"
            elif right_digit and left_anchor is None:
                chars[i] = "၀"
            # Shape (b'): one anchor is a digit, the other is a
            # non-Myanmar character (whitespace, punctuation,
            # Latin). Same numeric-context interpretation.
            elif left_digit and not right_consonant and not right_digit:
                chars[i] = "၀"
            elif right_digit and not left_consonant and not left_digit:
                chars[i] = "၀"
    return "".join(chars)


def _needs_canonicalization(text: str) -> bool:
    """Quick scan — returns True if any pipeline stage might rewrite
    this string. The fast-path lets identity-preserving callers
    (`assertIs(normalize_text(s), s)`) short-circuit when the input
    is already in NFC and contains no confusable / zero-width / digit
    scalars.

    The check is deliberately conservative: any time we see a tone or
    asat scalar (U+1036/U+1037/U+1038/U+103A), or any of the
    confusable-class scalars (`၀`/`၄`/`ဝ`), or zero-width controls,
    we run the full pipeline. Plain Burmese text without these marks
    is NFC-stable and short-circuits.
    """
    if _ZWSP in text or _ZWNJ in text or _ZWJ in text:
        return True
    for ch in text:
        cp = ord(ch)
        # Confusable-class scalars trigger Class 1/2/3 rewrites.
        if cp == 0x101D or cp == 0x1044:
            return True
        if 0x1040 <= cp <= 0x1049:
            return True
        # Tone / asat scalars participate in NFC reorder and the
        # doubled-tone collapse. Any string containing them must
        # round-trip through the pipeline.
        if cp == 0x1036 or cp == 0x1037 or cp == 0x1038 or cp == 0x103A:
            return True
    return False


def normalize_text(text: str) -> str:
    """Canonicalize a corpus string for ingest.

    Pipeline (in order):

    1. Strip U+200B (ZERO WIDTH SPACE) — soft-break hint with no
       orthographic effect; would otherwise split counts across
       ghost variants and trip Swift's whitespace trimming.
    2. NFC-normalize. The Myanmar Combining Class table puts U+1037
       (CCC=7) before U+103A (CCC=9), so `<C> 103A 1037` sorts to
       canonical `<C> 1037 103A`. NFC handles tone-vs-asat reorder
       without an explicit pass (TASK-038).
    3. Collapse doubled tone markers (`<X> 1037 1037` → `<X> 1037`,
       likewise for U+1036 / U+1038). NFC does not collapse
       duplicate scalars (TASK-038).
    4. Strip orphan U+200C / U+200D — only when they sit outside a
       Myanmar-Myanmar context where they could control cluster
       formation (TASK-038).
    5. Apply Myanmar digit / consonant confusable rewrites: leading
       `၀` before a consonant becomes `ဝ`; leading `၄င်း` becomes
       `၎င်း`; `ဝ` embedded in a pure-digit run becomes `၀`
       (TASK-037).

    Identity preservation: when no pipeline stage rewrites the
    string, `normalize_text` returns the input unchanged (same
    object). This keeps the hot path on streamed corpus documents
    allocation-free and matches the historical contract checked by
    `test_fastpath_on_zwsp_free_text`.
    """
    if not text:
        return text
    if not _needs_canonicalization(text):
        return text
    original = text
    if _ZWSP in text:
        text = text.replace(_ZWSP, "")
    text = unicodedata.normalize("NFC", text)
    text = _collapse_doubled_tones(text)
    text = _strip_orphan_zwnj(text)
    text = _canonicalize_confusables(text)
    # Identity preservation when the pipeline made no actual change.
    return original if text == original else text


@dataclass(frozen=True)
class IngestConfig:
    corpus: str = "chuuhtetnaing/myanmar-c4-dataset"
    split: str = "train"
    text_field: str = "text"
    zawgyi_threshold: float = 0.05
    max_docs: int | None = None
    curated_tsv: Path | None = None
    merge_curated_compounds: bool = True


def iter_documents(cfg: IngestConfig) -> Iterator[str]:
    """Yield Unicode-cleaned Burmese documents from the streaming corpus.

    Documents whose Zawgyi probability exceeds `cfg.zawgyi_threshold` are
    dropped — Myanmar-C4 is nominally Unicode but has a long tail of mixed
    encoding we do not want the segmenter to see.
    """
    try:
        from datasets import load_dataset
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(
            "`datasets` is required — run `pip install -e .` in corpus_builder."
        ) from exc

    try:
        from myanmartools import ZawgyiDetector
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(
            "`myanmar-tools` is required — run `pip install -e .` in corpus_builder."
        ) from exc

    detector = ZawgyiDetector()
    ds = load_dataset(cfg.corpus, split=cfg.split, streaming=True)

    emitted = 0
    for row in ds:
        text = row.get(cfg.text_field)
        if not text:
            continue
        if detector.get_zawgyi_probability(text) > cfg.zawgyi_threshold:
            continue
        yield normalize_text(text)
        emitted += 1
        if cfg.max_docs is not None and emitted >= cfg.max_docs:
            return


# Burmese sentence terminators: pote-ma-tin (၊) and ga-nga-ma-tin (။).
# We split on these so the LM sees real sentence boundaries and can learn
# `<s>` / `</s>` contexts correctly.
_SENTENCE_BREAKS = ("။", "၊", "\n")


def split_sentences(doc: str) -> Iterator[str]:
    buf: list[str] = []
    for ch in doc:
        if ch in _SENTENCE_BREAKS:
            if buf:
                text = "".join(buf).strip()
                if text:
                    yield text
                buf.clear()
        else:
            buf.append(ch)
    if buf:
        text = "".join(buf).strip()
        if text:
            yield text
