"""Pure-Python modified Kneser-Ney trigram trainer.

Counts unigrams/bigrams/trigrams over the segmented token file, then emits
interpolated modified-KN log-probs + backoff weights (natural log),
packaged as the same ``ParsedLM`` struct the packer consumes. Avoids the
KenLM native toolchain entirely.

Reference: Chen & Goodman 1999, "An empirical study of smoothing techniques
for language modeling". Backoff semantics match what Swift's
``TrigramLanguageModel`` expects: unigram.backoff = γ used when backing off
bigram → unigram; bigram.backoff = γ used when backing off trigram →
bigram; trigram.backoff = 0.
"""

from __future__ import annotations

import math
import multiprocessing as mp
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

from tqdm import tqdm

from .vocab import Vocab


@dataclass
class Ngram:
    ids: tuple[int, ...]
    log_prob: float  # natural log
    backoff: float = 0.0  # natural log


@dataclass
class ParsedLM:
    order: int
    unigrams: list[Ngram] = field(default_factory=list)
    bigrams: list[Ngram] = field(default_factory=list)
    trigrams: list[Ngram] = field(default_factory=list)


def _count_batch(
    args: tuple[list[str], dict[str, int], int, int, int],
) -> tuple[Counter, Counter, Counter]:
    """Worker: count uni/bi/trigrams over a batch of already-segmented lines."""
    lines, id_of, bos, eos, unk = args
    c1: Counter[int] = Counter()
    c2: Counter[tuple[int, int]] = Counter()
    c3: Counter[tuple[int, int, int]] = Counter()
    for line in lines:
        words = line.split()
        if not words:
            continue
        ids = [bos, bos] + [id_of.get(w, unk) for w in words] + [eos]
        c1.update(ids)
        c2.update(zip(ids, ids[1:]))
        c3.update(zip(ids, ids[1:], ids[2:]))
    return c1, c2, c3


def _count_ngrams(
    tokens_path: Path,
    vocab: Vocab,
    *,
    workers: int = 1,
    batch_size: int = 5000,
) -> tuple[Counter[int], Counter[tuple[int, int]], Counter[tuple[int, int, int]]]:
    """Count n-grams over `tokens_path`.

    Single-process when `workers <= 1`; otherwise dispatches line batches to
    a `spawn` pool so macOS fork-after-thread pitfalls are avoided.
    """
    bos, eos, unk = vocab.id_bos, vocab.id_eos, vocab.id_unk
    id_of = vocab.id_of

    c1: Counter[int] = Counter()
    c2: Counter[tuple[int, int]] = Counter()
    c3: Counter[tuple[int, int, int]] = Counter()

    def _batches():
        batch: list[str] = []
        with tokens_path.open("r", encoding="utf-8") as f:
            for line in f:
                batch.append(line)
                if len(batch) >= batch_size:
                    yield (batch, id_of, bos, eos, unk)
                    batch = []
        if batch:
            yield (batch, id_of, bos, eos, unk)

    pbar = tqdm(
        desc=f"count[{max(1, workers)}w]",
        unit=" sent",
        unit_scale=True,
        smoothing=0.1,
        dynamic_ncols=True,
    )

    if workers <= 1:
        for args in _batches():
            p1, p2, p3 = _count_batch(args)
            c1.update(p1)
            c2.update(p2)
            c3.update(p3)
            pbar.update(len(args[0]))
    else:
        ctx = mp.get_context("spawn")
        with ctx.Pool(processes=workers) as pool:
            for p1, p2, p3 in pool.imap_unordered(_count_batch, _batches(), chunksize=1):
                c1.update(p1)
                c2.update(p2)
                c3.update(p3)
                # Batches are fixed size except the tail; close enough for a rate display.
                pbar.update(batch_size)
    pbar.close()
    return c1, c2, c3


def _discounts(counts: Counter) -> tuple[float, float, float]:
    """Chen&Goodman D1, D2, D3+ from the count-of-counts over `counts`."""
    coc: Counter[int] = Counter()
    for v in counts.values():
        if v >= 1:
            coc[min(v, 4)] += 1
    n1 = coc.get(1, 0)
    n2 = coc.get(2, 0)
    n3 = coc.get(3, 0)
    n4 = coc.get(4, 0)
    if n1 == 0 or n2 == 0:
        # Fallback when distribution is degenerate; keeps discounts monotone.
        return (0.5, 0.75, 1.0)
    Y = n1 / (n1 + 2 * n2)
    D1 = max(0.0, 1 - 2 * Y * (n2 / n1))
    D2 = max(D1, 2 - 3 * Y * (n3 / n2)) if n3 else D1
    D3 = max(D2, 3 - 4 * Y * (n4 / n3)) if n4 else D2
    return (D1, D2, D3)


def _pick_D(c: int, Ds: tuple[float, float, float]) -> float:
    if c <= 1:
        return Ds[0]
    if c == 2:
        return Ds[1]
    return Ds[2]


def _safe_log(x: float) -> float:
    return math.log(x) if x > 0 else -20.0


def train_kn(
    tokens_path: Path,
    vocab: Vocab,
    *,
    order: int = 3,
    prune: tuple[int, ...] = (0, 0, 0),
    workers: int = 1,
    batch_size: int = 5000,
) -> ParsedLM:
    """Train an interpolated modified-KN trigram LM in id-space."""
    if order != 3:
        raise ValueError("only trigram (order=3) is supported")

    c1, c2, c3 = _count_ngrams(
        tokens_path, vocab, workers=workers, batch_size=batch_size
    )

    # Prune: drop n-grams with count <= prune[k] for order k+1. Prune before
    # computing continuation counts so the pruned mass is redistributed.
    if prune[1] > 0:
        c2 = Counter({k: v for k, v in c2.items() if v > prune[1]})
    if prune[2] > 0:
        c3 = Counter({k: v for k, v in c3.items() if v > prune[2]})

    # Continuation counts.
    # N1p_left[w]        = |{w' : c2(w',w) > 0}|                -> unigram numerator
    # N1p_left_bi[(a,b)] = |{w' : c3(w',a,b) > 0}|              -> bigram numerator
    N1p_left: dict[int, int] = defaultdict(int)
    for (_, w2) in c2:
        N1p_left[w2] += 1
    total_bigram_types = len(c2)

    N1p_left_bi: dict[tuple[int, int], int] = defaultdict(int)
    for (_, w1, w2) in c3:
        N1p_left_bi[(w1, w2)] += 1

    # Right-extension histograms for γ weights.
    # ext_tri[(w1,w2)] = [n1, n2, n3+] over c3 extensions -> γ3 at (w1,w2)
    # ext_bi[w1]       = [n1, n2, n3+] over N1p_left_bi extensions -> γ2 at w1
    ext_tri: dict[tuple[int, int], list[int]] = defaultdict(lambda: [0, 0, 0])
    for (w1, w2, w3), n in c3.items():
        bucket = 0 if n == 1 else (1 if n == 2 else 2)
        ext_tri[(w1, w2)][bucket] += 1

    ext_bi: dict[int, list[int]] = defaultdict(lambda: [0, 0, 0])
    for (w1, w2), n in N1p_left_bi.items():
        bucket = 0 if n == 1 else (1 if n == 2 else 2)
        ext_bi[w1][bucket] += 1

    # Middle-order normalizer: Σ_v N1p_left_bi[(w1,v)].
    denom_bi: dict[int, int] = defaultdict(int)
    for (w1, _), n in N1p_left_bi.items():
        denom_bi[w1] += n

    # Discounts. Top order uses c3's distribution; middle order uses the
    # distribution of continuation counts so low-frequency continuations get
    # the right discount.
    Ds_tri = _discounts(c3)
    Ds_bi = _discounts(Counter(N1p_left_bi))

    # --- Unigram: p_kn(w) = N1p_left[w] / total_bigram_types ---
    uni_logp: dict[int, float] = {}
    words = set(c1.keys()) | {vocab.id_bos, vocab.id_eos, vocab.id_unk}
    for w in words:
        p = N1p_left.get(w, 0) / total_bigram_types if total_bigram_types else 0.0
        uni_logp[w] = _safe_log(p)

    # Unigram backoff = γ2(w) used when bigram → unigram.
    uni_bo: dict[int, float] = {}
    for w in words:
        d = denom_bi.get(w, 0)
        if d == 0:
            uni_bo[w] = 0.0
            continue
        n1, n2, n3p = ext_bi.get(w, [0, 0, 0])
        gamma = (Ds_bi[0] * n1 + Ds_bi[1] * n2 + Ds_bi[2] * n3p) / d
        uni_bo[w] = _safe_log(gamma)

    # --- Bigram: p_kn(w2|w1) over continuation counts ---
    bi_logp: dict[tuple[int, int], float] = {}
    for (w1, w2), n in tqdm(N1p_left_bi.items(), desc="bigram", unit=" ng", unit_scale=True, dynamic_ncols=True):
        d = denom_bi[w1]
        if d == 0:
            continue
        D = _pick_D(n, Ds_bi)
        first = max(n - D, 0.0) / d
        n1, n2, n3p = ext_bi.get(w1, [0, 0, 0])
        gamma = (Ds_bi[0] * n1 + Ds_bi[1] * n2 + Ds_bi[2] * n3p) / d
        p = first + gamma * math.exp(uni_logp.get(w2, -20.0))
        bi_logp[(w1, w2)] = _safe_log(p)

    # Bigram backoff = γ3(w1,w2) used when trigram → bigram.
    bi_bo: dict[tuple[int, int], float] = {}
    for (w1, w2), (n1, n2, n3p) in ext_tri.items():
        d = c2.get((w1, w2), 0)
        if d == 0:
            bi_bo[(w1, w2)] = 0.0
            continue
        gamma = (Ds_tri[0] * n1 + Ds_tri[1] * n2 + Ds_tri[2] * n3p) / d
        bi_bo[(w1, w2)] = _safe_log(gamma)

    # --- Trigram: p_kn(w3|w1,w2) over raw counts ---
    tri_logp: dict[tuple[int, int, int], float] = {}
    for (w1, w2, w3), c in tqdm(c3.items(), desc="trigram", unit=" ng", unit_scale=True, dynamic_ncols=True):
        d = c2.get((w1, w2), 0)
        if d == 0:
            continue
        D = _pick_D(c, Ds_tri)
        first = max(c - D, 0.0) / d
        n1, n2, n3p = ext_tri.get((w1, w2), [0, 0, 0])
        gamma = (Ds_tri[0] * n1 + Ds_tri[1] * n2 + Ds_tri[2] * n3p) / d
        pb = math.exp(bi_logp[(w2, w3)]) if (w2, w3) in bi_logp else math.exp(uni_logp.get(w3, -20.0))
        p = first + gamma * pb
        tri_logp[(w1, w2, w3)] = _safe_log(p)

    lm = ParsedLM(order=order)
    for w, lp in uni_logp.items():
        lm.unigrams.append(Ngram(ids=(w,), log_prob=lp, backoff=uni_bo.get(w, 0.0)))
    for (w1, w2), lp in bi_logp.items():
        lm.bigrams.append(Ngram(ids=(w1, w2), log_prob=lp, backoff=bi_bo.get((w1, w2), 0.0)))
    for (w1, w2, w3), lp in tri_logp.items():
        lm.trigrams.append(Ngram(ids=(w1, w2, w3), log_prob=lp, backoff=0.0))

    lm.unigrams.sort(key=lambda n: n.ids)
    lm.bigrams.sort(key=lambda n: n.ids)
    lm.trigrams.sort(key=lambda n: n.ids)
    return lm
