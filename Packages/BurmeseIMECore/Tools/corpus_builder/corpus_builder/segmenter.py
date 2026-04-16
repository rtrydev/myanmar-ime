"""myWord Viterbi word segmenter for Burmese.

myWord ships a tiny unigram+bigram dictionary plus a CLI. We reimplement the
Viterbi pass in-process so segmentation runs without shelling out per line.

If the `myword` package is not importable, we fall back to syllable-level
segmentation using the Myanmar orthographic syllable regex. That fallback is
only useful for tiny fixture runs; the real pipeline expects myWord to be
installed.
"""

from __future__ import annotations

import math
import os
import re
from functools import lru_cache
from pathlib import Path
from typing import Iterable


_MYANMAR_SYLLABLE_RE = re.compile(
    r"[က-အ႐-႑ဣ-ဧ]"          # consonant / independent vowel
    r"(?:[ါာိီုူဲဳဴဵ]|"       # vowel signs
    r"[ှျြွ]|"                # medials
    r"[်]|"                    # virama
    r"[ံ့း])*"                 # tone / ns marks
)


def _locate_mydict() -> Path | None:
    """Find myWord's dict directory.

    myWord isn't pip-installable — it's a repo of scripts + pickled dicts.
    We locate the dicts via, in order:
      1. `MYWORD_DIR` environment variable pointing at the repo root.
      2. An importable `myword` package (legacy path, rarely used).
    Returns the directory containing `unigram-word.bin` / `bigram-word.bin`.
    """
    env_dir = os.environ.get("MYWORD_DIR")
    if env_dir:
        root = Path(env_dir).expanduser()
        for sub in (root / "dict_ver1", root / "myword" / "dict_ver1", root):
            if (sub / "unigram-word.bin").exists() and (sub / "bigram-word.bin").exists():
                return sub
        return None
    try:
        import myword  # type: ignore

        pkg_dir = Path(myword.__file__).parent / "dict_ver1"
        if (pkg_dir / "unigram-word.bin").exists():
            return pkg_dir
    except ImportError:
        pass
    return None


def _load_mydict() -> tuple[dict[str, float], dict[tuple[str, str], float]] | None:
    """Load myWord's bundled unigram + bigram tables.

    The tables ship as pickled dicts — we read them directly instead of
    going through the myWord CLI.
    """
    dict_dir = _locate_mydict()
    if dict_dir is None:
        return None

    import pickle

    with (dict_dir / "unigram-word.bin").open("rb") as f:
        unigram: dict[str, int] = pickle.load(f)
    with (dict_dir / "bigram-word.bin").open("rb") as f:
        bigram: dict[tuple[str, str], int] = pickle.load(f)

    total_uni = sum(unigram.values()) or 1
    uni_logp = {w: math.log(c / total_uni) for w, c in unigram.items()}
    total_bi = sum(bigram.values()) or 1
    bi_logp = {k: math.log(c / total_bi) for k, c in bigram.items()}
    return uni_logp, bi_logp


class Segmenter:
    """Word-level segmenter. Use `segment(text)` to get a list of words."""

    def __init__(self, *, allow_fallback: bool | None = None) -> None:
        self._mydict = _load_mydict()
        if self._mydict is None:
            if allow_fallback is None:
                allow_fallback = os.environ.get("ALLOW_SYLLABLE_FALLBACK") == "1"
            if not allow_fallback:
                raise RuntimeError(
                    "myWord dicts not found. Clone "
                    "https://github.com/ye-kyaw-thu/myWord and set "
                    "MYWORD_DIR=/path/to/myWord, or export "
                    "ALLOW_SYLLABLE_FALLBACK=1 to accept syllable-level "
                    "segmentation (produces a bad lexicon — dev use only)."
                )

    def segment(self, text: str) -> list[str]:
        if self._mydict is None:
            return self._syllable_fallback(text)
        return self._viterbi(text, *self._mydict)

    @staticmethod
    def _syllable_fallback(text: str) -> list[str]:
        return [m.group(0) for m in _MYANMAR_SYLLABLE_RE.finditer(text) if m.group(0).strip()]

    @staticmethod
    def _viterbi(
        text: str,
        uni_logp: dict[str, float],
        bi_logp: dict[tuple[str, str], float],
    ) -> list[str]:
        n = len(text)
        if n == 0:
            return []
        # best[i] = (score, prev_index, word)
        NEG_INF = -1e18
        best: list[tuple[float, int, str]] = [(NEG_INF, -1, "")] * (n + 1)
        best[0] = (0.0, -1, "")

        # Max word length cap keeps this O(n * k). myWord entries top out around 20 chars.
        MAX_LEN = 20

        for i in range(n):
            if best[i][0] == NEG_INF:
                continue
            prev_word = best[i][2]
            for j in range(i + 1, min(n, i + MAX_LEN) + 1):
                candidate = text[i:j]
                logp = uni_logp.get(candidate)
                if logp is None:
                    # Character fallback: each unknown char gets a heavy penalty.
                    if j - i == 1:
                        logp = -20.0
                    else:
                        continue
                if prev_word:
                    bi = bi_logp.get((prev_word, candidate))
                    if bi is not None:
                        # Interpolate unigram with bigram; KN-ish weighting.
                        logp = 0.25 * logp + 0.75 * bi
                score = best[i][0] + logp
                if score > best[j][0]:
                    best[j] = (score, i, candidate)

        # Backtrace
        out: list[str] = []
        j = n
        while j > 0:
            _, prev, word = best[j]
            if prev < 0:
                break
            out.append(word)
            j = prev
        out.reverse()
        return out


@lru_cache(maxsize=1)
def default_segmenter() -> Segmenter:
    return Segmenter()


def segment_sentences(sentences: Iterable[str]) -> Iterable[list[str]]:
    seg = default_segmenter()
    for sent in sentences:
        words = seg.segment(sent)
        if words:
            yield words


def segment_batch(sentences: list[str]) -> list[list[str]]:
    """Top-level worker entry point for multiprocessing.

    Must be importable as `corpus_builder.segmenter.segment_batch` so that
    `multiprocessing.Pool` on macOS (spawn start method) can pickle it.
    Each worker process lazily loads the myWord dict once via
    `default_segmenter()` and reuses it across batches.
    """
    seg = default_segmenter()
    return [seg.segment(s) for s in sentences]
