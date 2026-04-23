# corpus_builder

Offline data pipeline that feeds the Burmese IME runtime with two artefacts:

1. `Packages/BurmeseIMECore/Data/BurmeseLexiconSource.tsv` — lexicon TSV with
   corpus-derived unigram frequencies. Consumed by `LexiconBuilder` to produce
   `BurmeseLexicon.sqlite`.
2. `native/macos/Data/BurmeseLM.bin` — compact trigram LM consumed by
   `TrigramLanguageModel` at runtime (see
   `Packages/BurmeseIMECore/Sources/BurmeseIMECore/LanguageModel/FORMAT.md`).

Both artefacts share a single vocabulary and a single segmentation pass so
that `entries.id` in the SQLite is the same as the `word_id` in the LM.

## Pipeline

```
Myanmar-C4 ──▶ Zawgyi filter ──▶ myWord segmenter ──▶ counts
                                                     │
                              hand-curated TSV ──────┴──▶ unified vocab
                                                     │
                                    ┌────────────────┼──────────────────┐
                                    ▼                                    ▼
                         BurmeseLexiconSource.tsv              modified Kneser-Ney
                         (surface, count, override?)              trigram trainer
                                    │                                    │
                                    ▼                                    ▼
                              LexiconBuilder                      BurmeseLM.bin
                                    │                             (mmap-friendly)
                                    │
                                    ▼
                          BurmeseLexicon.sqlite
```

## Install

```bash
cd Packages/BurmeseIMECore/Tools/corpus_builder
python -m venv .venv && source .venv/bin/activate
pip install -e .
source prepare.sh     # clones myWord into ./myWord, exports MYWORD_DIR
```

`prepare.sh` is idempotent; the `myWord/` clone is gitignored. The
segmenter reads its pickled unigram/bigram dicts via `MYWORD_DIR`.

No native toolchain required — the trigram trainer is pure Python
(modified Kneser-Ney, `corpus_builder/lm.py`).

## Run

One-shot:

```bash
python -m corpus_builder.build all \
    --corpus chuuhtetnaing/myanmar-c4-dataset \
    --tsv-out ../../Data/BurmeseLexiconSource.tsv \
    --lm-out  ../../../../native/macos/Data/BurmeseLM.bin \
    --vocab-size 80000 \
    --prune 0 10 20
```

Subcommands:

- `ingest`    — stream corpus, Zawgyi-filter, segment, emit token stream.
- `vocab`     — build unified vocabulary from corpus + hand-curated TSV.
- `lexicon`   — write the new lexicon TSV.
- `lm`        — train modified-KN trigram LM and pack to `BurmeseLM.bin`.
- `all`       — run the full pipeline end-to-end.

Each stage writes an intermediate under `--work-dir` (default `./build/`)
so a re-run only redoes what the CLI flags actually invalidate.

### Sizing the LM

`--prune` accepts three integers `[unigram_min, bigram_min, trigram_min]`
and drops n-grams whose counts fall at or below the threshold. On the
Myanmar-C4 corpus (34M sentences, 557M tokens) the cutoffs scale
roughly as:

| `--prune`  | Trigrams kept | LM size    |
|------------|--------------:|-----------:|
| `0 0 1`    | ~40M          | ~750 MB    |
| `0 2 3`    | ~17.5M        | ~340 MB    |
| `0 5 10`   | ~4–6M         | 100–140 MB |
| `0 10 20`  | ~1.5–2.5M     | 50–70 MB (shipping default) |
| `0 20 40`  | ~600k–900k    | 25–40 MB   |

The IME ranker only consults trigrams whose context actually surfaces
during typing, so the long tail mostly acts as dead weight at inference.
Start at `0 10 20`; loosen to `0 5 10` or `0 2 3` only if sentence-level
regression tests fall out of top-k for want of broader context.

## Layout

- `corpus_builder/build.py`       — CLI entry point.
- `corpus_builder/ingest.py`      — HuggingFace stream + Zawgyi filter.
- `corpus_builder/segmenter.py`   — thin wrapper over myWord Viterbi.
- `corpus_builder/vocab.py`       — vocab union + id assignment.
- `corpus_builder/lexicon.py`     — TSV writer preserving hand-curated overrides.
- `corpus_builder/lm.py`          — pure-Python modified Kneser-Ney trainer.
- `corpus_builder/packer.py`      — binary writer matching FORMAT.md.
- `corpus_builder/shrink.py`      — in-place shrink of BurmeseLM.bin without retraining.
