"""In-place shrink of an existing BurmeseLM.bin without retraining.

The default trainer build keeps every bigram and every count>=2 trigram,
which for a Myanmar-C4 corpus produces an ~900 MB file dominated by
trigrams. Most of those trigrams encode a probability that's nearly
identical to what the bigram-backoff path would produce on its own —
they cost 16 bytes apiece for almost no extra information.

This shrinker reads the file, drops trigrams whose log-prob is within
``--trigram-redundancy-nats`` of their bigram-backoff prediction (default
0.5 ≈ a factor of 1.65×), then optionally also drops bigrams whose log-
prob is within ``--bigram-redundancy-nats`` of their unigram-backoff
prediction. The remaining n-grams are repacked through ``packer.write_binary``
so the on-disk format matches the trainer output byte-for-byte.

Surviving log-probs are not re-smoothed: pruned trigrams fall through to
the bigram + backoff path that the Swift reader already implements, so
ranking degrades gracefully rather than catastrophically. For IME use the
information lost is well below the LM's noise floor.
"""

from __future__ import annotations

import argparse
import math
import struct
from pathlib import Path

from . import packer
from .lm import Ngram, ParsedLM
from .vocab import BOS, EOS, UNK, Vocab


HEADER_FMT = "<8sIIIIIIIII"
HEADER_SIZE = struct.calcsize(HEADER_FMT) + 4  # +4 for the reserved word
RECORD_SIZE = 16
ID_INDEX_ENTRY = 8
SURFACE_SORTED_ENTRY = 4


def _read_existing(path: Path) -> tuple[Vocab, ParsedLM]:
    raw = path.read_bytes()
    (
        magic, version, order, n_vocab, n_uni, n_bi, n_tri,
        id_bos, id_eos, id_unk, _reserved
    ) = struct.unpack_from(HEADER_FMT + "I", raw, 0)
    if magic != b"BURMLM01":
        raise SystemExit(f"bad magic {magic!r}")
    if version != 1 or order != 3:
        raise SystemExit(f"unsupported version/order {version}/{order}")

    blob_off = HEADER_SIZE
    id_index_size = n_vocab * ID_INDEX_ENTRY
    surface_sorted_size = n_vocab * SURFACE_SORTED_ENTRY
    uni_size = n_uni * RECORD_SIZE
    bi_size = n_bi * RECORD_SIZE
    tri_size = n_tri * RECORD_SIZE
    blob_size = len(raw) - HEADER_SIZE - id_index_size - surface_sorted_size - uni_size - bi_size - tri_size
    if blob_size < 0:
        raise SystemExit("file truncated")

    id_index_off = blob_off + blob_size
    uni_off = id_index_off + id_index_size + surface_sorted_size
    bi_off = uni_off + uni_size
    tri_off = bi_off + bi_size

    surfaces: list[str] = []
    for i in range(n_vocab):
        off, length = struct.unpack_from("<II", raw, id_index_off + i * ID_INDEX_ENTRY)
        surfaces.append(raw[blob_off + off : blob_off + off + length].decode("utf-8"))

    vocab = Vocab(
        surfaces=surfaces,
        id_of={s: i for i, s in enumerate(surfaces)},
        id_bos=id_bos,
        id_eos=id_eos,
        id_unk=id_unk,
    )

    lm = ParsedLM(order=3)
    for i in range(n_uni):
        wid, lp, bo, _pad = struct.unpack_from("<IffI", raw, uni_off + i * RECORD_SIZE)
        lm.unigrams.append(Ngram(ids=(wid,), log_prob=lp, backoff=bo))
    for i in range(n_bi):
        w1, w2, lp, bo = struct.unpack_from("<IIff", raw, bi_off + i * RECORD_SIZE)
        lm.bigrams.append(Ngram(ids=(w1, w2), log_prob=lp, backoff=bo))
    for i in range(n_tri):
        w1, w2, w3, lp = struct.unpack_from("<IIIf", raw, tri_off + i * RECORD_SIZE)
        lm.trigrams.append(Ngram(ids=(w1, w2, w3), log_prob=lp, backoff=0.0))

    return vocab, lm


def _bigram_backoff_score(
    w1: int, w2: int,
    bi_lp: dict[tuple[int, int], float],
    bi_bo: dict[tuple[int, int], float],
    uni_lp: dict[int, float],
    uni_bo: dict[int, float],
    unk_lp: float,
) -> float:
    """LM score for `(w1 w2)` via bigram-or-backoff. Mirrors the Swift reader."""
    key = (w1, w2)
    if key in bi_lp:
        return bi_lp[key]
    return uni_lp.get(w2, unk_lp) + uni_bo.get(w1, 0.0)


def shrink(
    in_path: Path,
    out_path: Path,
    *,
    trigram_redundancy_nats: float,
    bigram_redundancy_nats: float,
    keep_top_trigrams: int | None,
    keep_top_bigrams: int | None,
) -> tuple[int, int, int, int]:
    """Returns (orig_uni, kept_uni, orig_bi+tri, kept_bi+tri)."""
    vocab, lm = _read_existing(in_path)

    uni_lp = {ng.ids[0]: ng.log_prob for ng in lm.unigrams}
    uni_bo = {ng.ids[0]: ng.backoff for ng in lm.unigrams}
    bi_lp = {ng.ids: ng.log_prob for ng in lm.bigrams}
    bi_bo = {ng.ids: ng.backoff for ng in lm.bigrams}
    unk_lp = uni_lp.get(vocab.id_unk, -20.0)

    # --- Trigrams: drop those whose backoff prediction is close enough.
    n_tri_orig = len(lm.trigrams)
    kept_tri: list[Ngram] = []
    for ng in lm.trigrams:
        w1, w2, w3 = ng.ids
        backoff_pred = _bigram_backoff_score(w2, w3, bi_lp, bi_bo, uni_lp, uni_bo, unk_lp) + bi_bo.get((w1, w2), 0.0)
        if abs(ng.log_prob - backoff_pred) > trigram_redundancy_nats:
            kept_tri.append(ng)
    if keep_top_trigrams is not None and len(kept_tri) > keep_top_trigrams:
        kept_tri.sort(key=lambda n: n.log_prob, reverse=True)
        kept_tri = kept_tri[:keep_top_trigrams]
    kept_tri.sort(key=lambda n: n.ids)
    lm.trigrams = kept_tri

    # --- Bigrams: drop those redundant with unigram-backoff.
    n_bi_orig = len(lm.bigrams)
    kept_bi: list[Ngram] = []
    for ng in lm.bigrams:
        w1, w2 = ng.ids
        backoff_pred = uni_lp.get(w2, unk_lp) + uni_bo.get(w1, 0.0)
        if abs(ng.log_prob - backoff_pred) > bigram_redundancy_nats:
            kept_bi.append(ng)
    if keep_top_bigrams is not None and len(kept_bi) > keep_top_bigrams:
        kept_bi.sort(key=lambda n: n.log_prob, reverse=True)
        kept_bi = kept_bi[:keep_top_bigrams]
    kept_bi.sort(key=lambda n: n.ids)
    lm.bigrams = kept_bi

    packer.write_binary(out_path, vocab, lm)
    return n_bi_orig, len(kept_bi), n_tri_orig, len(kept_tri)


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(prog="corpus-shrink", description=__doc__)
    p.add_argument("--in", dest="in_path", type=Path, required=True)
    p.add_argument("--out", dest="out_path", type=Path, required=True)
    p.add_argument("--trigram-redundancy-nats", type=float, default=0.5,
                   help="Drop trigrams whose log-prob differs from the bigram-backoff prediction by less than this many nats.")
    p.add_argument("--bigram-redundancy-nats", type=float, default=0.3,
                   help="Same idea for bigrams vs unigram-backoff.")
    p.add_argument("--keep-top-trigrams", type=int, default=None,
                   help="Hard cap on surviving trigrams (highest log-prob first).")
    p.add_argument("--keep-top-bigrams", type=int, default=None,
                   help="Hard cap on surviving bigrams.")
    args = p.parse_args(argv)

    n_bi_orig, n_bi_kept, n_tri_orig, n_tri_kept = shrink(
        args.in_path,
        args.out_path,
        trigram_redundancy_nats=args.trigram_redundancy_nats,
        bigram_redundancy_nats=args.bigram_redundancy_nats,
        keep_top_trigrams=args.keep_top_trigrams,
        keep_top_bigrams=args.keep_top_bigrams,
    )
    in_size = args.in_path.stat().st_size
    out_size = args.out_path.stat().st_size
    print(f"bigrams:  {n_bi_orig:>10} -> {n_bi_kept:>10}  ({n_bi_kept / max(1, n_bi_orig):.1%})")
    print(f"trigrams: {n_tri_orig:>10} -> {n_tri_kept:>10}  ({n_tri_kept / max(1, n_tri_orig):.1%})")
    print(f"bytes:    {in_size:>10} -> {out_size:>10}  ({out_size / max(1, in_size):.1%})")


if __name__ == "__main__":
    main()
