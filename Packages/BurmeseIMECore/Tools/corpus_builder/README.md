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
    --prune 0 0 1
```

Subcommands:

- `ingest`    — stream corpus, Zawgyi-filter, segment, emit token stream.
- `vocab`     — build unified vocabulary from corpus + hand-curated TSV.
- `lexicon`   — write the new lexicon TSV.
- `lm`        — train modified-KN trigram LM and pack to `BurmeseLM.bin`.
- `all`       — run the full pipeline end-to-end.

Each stage writes an intermediate under `--work-dir` (default `./build/`)
so a re-run only redoes what the CLI flags actually invalidate.

## Layout

- `corpus_builder/build.py`       — CLI entry point.
- `corpus_builder/ingest.py`      — HuggingFace stream + Zawgyi filter.
- `corpus_builder/segmenter.py`   — thin wrapper over myWord Viterbi.
- `corpus_builder/vocab.py`       — vocab union + id assignment.
- `corpus_builder/lexicon.py`     — TSV writer preserving hand-curated overrides.
- `corpus_builder/lm.py`          — pure-Python modified Kneser-Ney trainer.
- `corpus_builder/packer.py`      — binary writer matching FORMAT.md.
- `corpus_builder/shrink.py`      — in-place shrink of BurmeseLM.bin without retraining.
