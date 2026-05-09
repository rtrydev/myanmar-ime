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


def _needs_canonicalization(text: str) -> bool:
    """Quick scan — returns True if any pipeline stage might rewrite
    this string. The fast-path lets identity-preserving callers
    (`assertIs(normalize_text(s), s)`) short-circuit when the input
    is already in NFC and contains no zero-width control marks.

    The check is deliberately conservative: any time we see a tone or
    asat scalar (U+1036/U+1037/U+1038/U+103A) or zero-width controls,
    we run the full pipeline. Plain Burmese text without these marks
    is NFC-stable and short-circuits.
    """
    if _ZWSP in text or _ZWNJ in text or _ZWJ in text:
        return True
    for ch in text:
        cp = ord(ch)
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
