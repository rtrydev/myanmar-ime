"""Writes `BurmeseLM.bin` matching FORMAT.md byte-for-byte.

The Swift reader (`TrigramLanguageModel.swift`) and the
`LMFixtureBuilder` in `LanguageModelTests.swift` are the ground truth for
this format; any divergence here breaks round-trip.
"""

from __future__ import annotations

import struct
from pathlib import Path

from .lm import Ngram, ParsedLM
from .vocab import Vocab


MAGIC = b"BURMLM01"
VERSION = 1
HEADER_SIZE = 48


def write_binary(path: Path, vocab: Vocab, lm: ParsedLM) -> int:
    """Serialize `lm` over `vocab` to `path`. Returns the bytes written."""
    path.parent.mkdir(parents=True, exist_ok=True)
    buf = bytearray()

    # --- Header (48 bytes) ---
    buf += MAGIC
    buf += struct.pack(
        "<IIIIIIIIII",
        VERSION,
        3,                              # order
        vocab.size,
        len(lm.unigrams),
        len(lm.bigrams),
        len(lm.trigrams),
        vocab.id_bos,
        vocab.id_eos,
        vocab.id_unk,
        0,                              # reserved
    )
    assert len(buf) == HEADER_SIZE, f"header size mismatch: {len(buf)}"

    # --- Vocab surface blob + id-sorted (offset, length) index ---
    blob = bytearray()
    index: list[tuple[int, int]] = []
    for surface in vocab.surfaces:
        encoded = surface.encode("utf-8")
        index.append((len(blob), len(encoded)))
        blob += encoded
    buf += bytes(blob)
    for offset, length in index:
        buf += struct.pack("<II", offset, length)

    # --- Surface-sorted id table (for binary search by surface bytes) ---
    sorted_ids = sorted(
        range(vocab.size),
        key=lambda i: vocab.surfaces[i].encode("utf-8"),
    )
    for i in sorted_ids:
        buf += struct.pack("<I", i)

    # --- Unigram records (16 bytes each, sorted by word_id) ---
    for ng in sorted(lm.unigrams, key=lambda n: n.ids):
        (wid,) = ng.ids
        buf += struct.pack("<IffI", wid, ng.log_prob, ng.backoff, 0)

    # --- Bigram records (16 bytes each, sorted by (w1, w2)) ---
    for ng in sorted(lm.bigrams, key=lambda n: n.ids):
        w1, w2 = ng.ids
        buf += struct.pack("<IIff", w1, w2, ng.log_prob, ng.backoff)

    # --- Trigram records (16 bytes each, sorted by (w1, w2, w3)) ---
    for ng in sorted(lm.trigrams, key=lambda n: n.ids):
        w1, w2, w3 = ng.ids
        buf += struct.pack("<IIIf", w1, w2, w3, ng.log_prob)

    path.write_bytes(buf)
    return len(buf)
