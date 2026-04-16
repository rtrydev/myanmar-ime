"""Streams the Myanmar-C4 corpus and filters Zawgyi-encoded documents.

The HuggingFace dataset is streamed rather than materialised so the pipeline
runs on a laptop without keeping the full corpus on disk.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterator


@dataclass(frozen=True)
class IngestConfig:
    corpus: str = "chuuhtetnaing/myanmar-c4-dataset"
    split: str = "train"
    text_field: str = "text"
    zawgyi_threshold: float = 0.05
    max_docs: int | None = None


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
        yield text
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
