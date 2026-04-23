"""Unified vocabulary: union of corpus-derived counts and hand-curated TSV."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

from .ingest import normalize_text


BOS = "<s>"
EOS = "</s>"
UNK = "<unk>"
SPECIALS = (BOS, EOS, UNK)


@dataclass
class Vocab:
    """Frozen vocabulary: `id_of[word]` and `surfaces[id]` are the source of truth.

    Ids 0..n_lexicon-1 map 1:1 onto SQLite `entries.id - 1` (SQLite ids start
    at 1, so the SQLite id is `word_id + 1`). Specials are appended at the
    end so lexicon ids stay dense.
    """

    surfaces: list[str] = field(default_factory=list)
    id_of: dict[str, int] = field(default_factory=dict)
    id_bos: int = -1
    id_eos: int = -1
    id_unk: int = -1

    @property
    def size(self) -> int:
        return len(self.surfaces)

    @property
    def n_lexicon(self) -> int:
        return self.size - len(SPECIALS)

    def add(self, surface: str) -> int:
        existing = self.id_of.get(surface)
        if existing is not None:
            return existing
        idx = len(self.surfaces)
        self.surfaces.append(surface)
        self.id_of[surface] = idx
        return idx


@dataclass(frozen=True)
class CuratedEntry:
    surface: str
    override_reading: str | None


def read_curated_tsv(path: Path) -> list[CuratedEntry]:
    """Read the current `BurmeseLexiconSource.tsv` for hand-curated overrides.

    We only pull the surface + override_reading columns; corpus frequencies
    replace the legacy frequency field entirely, so it's ignored here.
    """
    out: list[CuratedEntry] = []
    if not path.exists():
        return out
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.lstrip().startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) < 2:
                continue
            surface = normalize_text(fields[0].strip())
            if not surface:
                continue
            override = fields[2].strip() if len(fields) >= 3 and fields[2].strip() else None
            out.append(CuratedEntry(surface=surface, override_reading=override))
    return out


def build_vocab(
    corpus_counts: Counter[str],
    curated: Iterable[CuratedEntry],
    max_corpus_words: int,
) -> Vocab:
    """Build the unified vocabulary.

    Rules:
      1. All curated surfaces survive regardless of corpus count (preserves
         overrides for rare words).
      2. Add the top-N corpus words by count, union-style.
      3. Specials `<s> </s> <unk>` are appended last.
    """
    vocab = Vocab()

    for entry in curated:
        vocab.add(entry.surface)

    for surface, _ in corpus_counts.most_common(max_corpus_words):
        vocab.add(surface)

    vocab.id_bos = vocab.add(BOS)
    vocab.id_eos = vocab.add(EOS)
    vocab.id_unk = vocab.add(UNK)
    return vocab
