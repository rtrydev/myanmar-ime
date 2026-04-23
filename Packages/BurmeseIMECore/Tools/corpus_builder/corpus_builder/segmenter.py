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


def _is_combining_mark_only(token: str) -> bool:
    """True if `token` consists exclusively of Myanmar combining marks.

    Myanmar dependent vowels, medials, virama/asat, and tone marks
    (U+102B–U+103E) attach to a consonant base; a token made up solely
    of these scalars is an orphan that has no meaningful frequency — it
    is a segmenter artefact, not a word. Without this filter the
    standalone marks leak into the lexicon at high unigram scores and
    beat the independent-vowel forms (ဥ, ဧ, အိ…) for bare-vowel inputs.
    """
    if not token:
        return True
    for ch in token:
        cp = ord(ch)
        if cp < 0x102B or cp > 0x103E:
            return False
    return True


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


# Curated entries longer than this are dropped from the merge set. The
# tail (≥99.8% of the TSV is ≤ this threshold) is mostly noise / super-
# long compounds that myWord rarely splits anyway, and keeping them
# inflates the prefix set without buying additional merges.
_CURATED_MAX_LEN = 50


def _load_curated_compounds(
    tsv_path: Path | None = None,
    *,
    min_pieces: int = 2,
    max_chars_cap: int = _CURATED_MAX_LEN,
) -> tuple[frozenset[str], frozenset[str], int]:
    """Load curated surfaces eligible to trigger the compound merge pass.

    Returns ``(compounds, prefixes, max_chars)``:

    - ``compounds`` — full surfaces, the set the merger probes for hits.
    - ``prefixes`` — every non-empty proper prefix of every compound.
      Used by the merger to bail early once the accumulator can no
      longer be extended into any compound (constant-time set lookup).
    - ``max_chars`` — the longest compound's char length, capped to
      ``max_chars_cap`` so the inner accumulator loop stays bounded.

    Source of truth is `BurmeseLexiconSource.tsv`. We keep only surfaces
    whose naive syllable split has ≥ `min_pieces` pieces — single-syllable
    surfaces can never benefit from re-merging a segmentation that was
    never split in the first place. Empty values when the TSV is missing
    or `tsv_path` is `None` and no env var is set.
    """
    if tsv_path is None:
        env = os.environ.get("CURATED_TSV")
        if not env:
            return frozenset(), frozenset(), 0
        tsv_path = Path(env)
    if not tsv_path.exists():
        return frozenset(), frozenset(), 0
    compounds: set[str] = set()
    prefixes: set[str] = set()
    max_chars = 0
    with tsv_path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.lstrip().startswith("#"):
                continue
            surface = line.split("\t", 1)[0].strip()
            if not surface:
                continue
            if len(surface) > max_chars_cap:
                continue
            if len(_MYANMAR_SYLLABLE_RE.findall(surface)) >= min_pieces:
                compounds.add(surface)
                if len(surface) > max_chars:
                    max_chars = len(surface)
                # Record proper prefixes so the merger can fail-fast.
                for k in range(1, len(surface)):
                    prefixes.add(surface[:k])
    return frozenset(compounds), frozenset(prefixes), max_chars


def _merge_curated(
    pieces: list[str],
    curated: frozenset[str],
    prefixes: frozenset[str],
    max_chars: int,
) -> list[str]:
    """Greedy longest-match re-merge.

    For each position, accumulate the joined string left-to-right and
    record the longest prefix that lands in ``curated``. Two cuts keep
    the inner loop O(1) on average:

    - Bounded by ``max_chars`` so it never extends past the longest
      possible compound.
    - Stops as soon as the accumulator is no longer a prefix of any
      curated entry (``accum not in prefixes``) — this is the dominant
      speedup on real corpora where most positions don't start a
      compound.
    """
    if not curated or max_chars <= 0:
        return pieces
    out: list[str] = []
    n = len(pieces)
    i = 0
    while i < n:
        best_j = i + 1
        accum = pieces[i]
        if len(accum) <= max_chars and accum in prefixes:
            j = i + 2
            while j <= n:
                accum = accum + pieces[j - 1]
                if len(accum) > max_chars:
                    break
                if accum in curated:
                    best_j = j
                if accum not in prefixes:
                    break
                j += 1
        if best_j == i + 1:
            out.append(pieces[i])
        else:
            out.append("".join(pieces[i:best_j]))
        i = best_j
    return out


class Segmenter:
    """Word-level segmenter. Use `segment(text)` to get a list of words."""

    def __init__(
        self,
        *,
        allow_fallback: bool | None = None,
        merge_curated: bool | None = None,
        curated: frozenset[str] | None = None,
    ) -> None:
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
        if merge_curated is None:
            merge_curated = os.environ.get("MERGE_CURATED", "1") != "0"
        if merge_curated:
            if curated is not None:
                self._curated = curated
                self._curated_max_chars = max((len(s) for s in curated), default=0)
                # Build prefix set on the fly when curated is supplied
                # explicitly (test path); production loads it from disk.
                self._curated_prefixes = frozenset(
                    s[:k] for s in curated for k in range(1, len(s))
                )
            else:
                (
                    self._curated,
                    self._curated_prefixes,
                    self._curated_max_chars,
                ) = _load_curated_compounds()
        else:
            self._curated = frozenset()
            self._curated_prefixes = frozenset()
            self._curated_max_chars = 0

    def segment(self, text: str) -> list[str]:
        if self._mydict is None:
            pieces = self._syllable_fallback(text)
        else:
            pieces = self._viterbi(text, *self._mydict)
        if self._curated and len(pieces) > 1:
            pieces = _merge_curated(
                pieces,
                self._curated,
                self._curated_prefixes,
                self._curated_max_chars,
            )
        return [p for p in pieces if not _is_combining_mark_only(p)]

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
