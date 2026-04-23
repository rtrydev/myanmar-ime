"""CLI entry point for the corpus builder.

Subcommands:
  ingest   — stream + Zawgyi-filter + segment → counts + tokens file
  vocab    — build unified vocabulary from counts + curated TSV
  lexicon  — write new BurmeseLexiconSource.tsv
  lm       — train KenLM ARPA and repack to BurmeseLM.bin
  all      — run everything end-to-end

Intermediate artefacts land in `--work-dir` (default `./build/`) so
re-running a later stage does not redo ingest.
"""

from __future__ import annotations

import argparse
import json
import multiprocessing as mp
import os
import pickle
from collections import Counter
from pathlib import Path
from typing import Iterator

from tqdm import tqdm

from . import ingest, lexicon, lm, packer, segmenter, vocab
from .segmenter import _is_combining_mark_only


def _default_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="corpus-build")
    sub = p.add_subparsers(dest="cmd", required=True)

    for name in ("ingest", "normalize", "vocab", "lexicon", "lm", "all"):
        sp = sub.add_parser(name)
        sp.add_argument("--work-dir", type=Path, default=Path("build"))
        sp.add_argument("--corpus", default="chuuhtetnaing/myanmar-c4-dataset")
        sp.add_argument("--max-docs", type=int, default=None)
        sp.add_argument(
            "--curated-tsv",
            type=Path,
            default=Path("../../Data/BurmeseLexiconSource.tsv"),
            help="Existing lexicon TSV (source of hand-curated overrides).",
        )
        sp.add_argument(
            "--tsv-out",
            type=Path,
            default=Path("../../Data/BurmeseLexiconSource.tsv"),
        )
        sp.add_argument(
            "--lm-out",
            type=Path,
            default=Path("../../../../native/macos/Data/BurmeseLM.bin"),
        )
        sp.add_argument("--vocab-size", type=int, default=40_000)
        # Default prune: keep all unigrams, drop bigrams with count <= 10
        # and trigrams with count <= 20. Measured on the Myanmar-C4
        # corpus (34M sentences / 557M tokens) the LM scales roughly
        # as: `0 0 1` → ~750 MB, `0 2 3` → ~340 MB, `0 5 10` →
        # 100–140 MB, `0 10 20` → 50–70 MB, `0 20 40` → ~30 MB. IME
        # ranking only consults a thin slice of the trigram space per
        # keystroke, so the long tail mostly acts as dead weight at
        # inference — `0 10 20` retains the high-frequency continuations
        # the ranker actually touches. Loosen to `0 5 10` or `0 2 3` if
        # sentence-level regression tests need broader context.
        sp.add_argument("--prune", type=int, nargs="+", default=[0, 10, 20])
        sp.add_argument(
            "--workers",
            type=int,
            default=max(1, (os.cpu_count() or 2) - 1),
            help="Parallel segmentation workers. Default: cpu_count - 1.",
        )
        sp.add_argument(
            "--batch-size",
            type=int,
            default=512,
            help="Sentences dispatched per worker batch.",
        )
        sp.add_argument(
            "--no-merge-curated",
            dest="merge_curated",
            action="store_false",
            default=True,
            help="Disable the post-segmentation curated-compound merge "
            "pass. Default is on — the merge pass re-joins myWord splits "
            "whose concatenation is a curated TSV surface.",
        )
        sp.add_argument(
            "--curated-smoothing",
            type=float,
            default=0.1,
            help="Dirichlet smoothing coefficient (κ) for curated rows. "
            "Floor applied to rows with an override_reading is "
            "count + κ · avg_peer_count_excluding_self, where peers are "
            "grouped by digit-stripped reading. Set to 0.0 to disable.",
        )
    return p


def _iter_sentences(cfg: ingest.IngestConfig) -> Iterator[str]:
    """Flatten the corpus to a stream of sentence strings.

    Document counting is still needed for metadata; we leak it through a
    shared list so the caller can read it after the iterator is drained.
    """
    for doc in ingest.iter_documents(cfg):
        yield from ingest.split_sentences(doc)


def _batched(it: Iterator[str], n: int) -> Iterator[list[str]]:
    batch: list[str] = []
    for item in it:
        batch.append(item)
        if len(batch) >= n:
            yield batch
            batch = []
    if batch:
        yield batch


def cmd_ingest(args: argparse.Namespace) -> None:
    args.work_dir.mkdir(parents=True, exist_ok=True)
    counts: Counter[str] = Counter()
    tokens_path = args.work_dir / "tokens.txt"
    sent_count = 0

    # Spawned workers inherit env vars on macOS — this is how the curated
    # merge set reaches `default_segmenter()` in each worker process.
    # `CURATED_TSV` points at the source TSV; `MERGE_CURATED=0` disables
    # the merge pass for ablation runs.
    os.environ["CURATED_TSV"] = str(args.curated_tsv)
    os.environ["MERGE_CURATED"] = "1" if args.merge_curated else "0"

    cfg = ingest.IngestConfig(
        corpus=args.corpus,
        max_docs=args.max_docs,
        curated_tsv=args.curated_tsv,
        merge_curated_compounds=args.merge_curated,
    )
    sentences = _iter_sentences(cfg)
    batches = _batched(sentences, args.batch_size)

    # Single-worker path avoids the pool overhead and makes tiny runs
    # (e.g. --max-docs 10) trivial to debug.
    workers = max(1, args.workers)

    # Progress bar: unit is sentences; total is unknown for a streaming
    # corpus, so tqdm shows rate + elapsed instead of ETA. `--max-docs` runs
    # still don't expose a sentence total, but rate alone is informative.
    pbar = tqdm(
        desc=f"ingest[{workers}w]",
        unit=" sent",
        unit_scale=True,
        smoothing=0.1,
        dynamic_ncols=True,
    )

    with tokens_path.open("w", encoding="utf-8") as f:
        if workers == 1:
            seg = segmenter.default_segmenter()
            for batch in batches:
                for sent in batch:
                    words = seg.segment(sent)
                    if not words:
                        continue
                    counts.update(words)
                    f.write(" ".join(words))
                    f.write("\n")
                    sent_count += 1
                pbar.update(len(batch))
                pbar.set_postfix(types=len(counts), refresh=False)
        else:
            # `spawn` is the safe default on macOS and avoids fork-after-thread
            # issues from the HuggingFace / arrow stack. Each worker boots fresh
            # and lazily loads the myWord dict once via default_segmenter().
            ctx = mp.get_context("spawn")
            with ctx.Pool(processes=workers) as pool:
                # imap_unordered keeps memory flat: we feed batches as fast as
                # workers drain them, and writes stream out as results arrive.
                results = pool.imap_unordered(
                    segmenter.segment_batch, batches, chunksize=1
                )
                for segmented_batch in results:
                    for words in segmented_batch:
                        if not words:
                            continue
                        counts.update(words)
                        f.write(" ".join(words))
                        f.write("\n")
                        sent_count += 1
                    pbar.update(len(segmented_batch))
                    pbar.set_postfix(types=len(counts), refresh=False)

    pbar.close()

    (args.work_dir / "counts.pkl").write_bytes(pickle.dumps(counts))
    meta = {"sentences": sent_count, "types": len(counts), "workers": workers}
    (args.work_dir / "ingest_meta.json").write_text(json.dumps(meta, indent=2))
    print(f"ingest: {meta}")


def _load_counts(work_dir: Path) -> Counter[str]:
    counts_path = work_dir / "counts.pkl"
    if not counts_path.exists():
        raise SystemExit(f"missing {counts_path} — run `ingest` first")
    return pickle.loads(counts_path.read_bytes())


def cmd_normalize(args: argparse.Namespace) -> None:
    """Rewrite tokens.txt with U+200B and orphan combining-mark tokens
    stripped, then rebuild counts.pkl.

    Salvage path for the case where `ingest` already ran but produced
    tokens containing U+200B (prior pipeline bug) or standalone dependent-
    vowel / medial / virama tokens (task 01). Much faster than re-running
    `ingest`: one streaming pass over tokens.txt plus a counter update.
    Safe to run idempotently — clean tokens are unchanged.
    """
    tokens_path = args.work_dir / "tokens.txt"
    if not tokens_path.exists():
        raise SystemExit(f"missing {tokens_path} — run `ingest` first")
    tmp_path = tokens_path.with_suffix(".txt.normalizing")
    counts: Counter[str] = Counter()
    stripped_tokens = 0
    dropped_orphan_marks = 0
    kept_tokens = 0
    sent_count = 0
    with tokens_path.open("r", encoding="utf-8") as fi, tmp_path.open(
        "w", encoding="utf-8"
    ) as fo:
        for line in fi:
            in_tokens = line.split()
            if not in_tokens:
                continue
            out_tokens: list[str] = []
            for t in in_tokens:
                if "​" in t:
                    t = t.replace("​", "")
                    stripped_tokens += 1
                if not t:
                    continue
                if _is_combining_mark_only(t):
                    dropped_orphan_marks += 1
                    continue
                out_tokens.append(t)
                kept_tokens += 1
            if out_tokens:
                counts.update(out_tokens)
                fo.write(" ".join(out_tokens))
                fo.write("\n")
                sent_count += 1
    tmp_path.replace(tokens_path)
    (args.work_dir / "counts.pkl").write_bytes(pickle.dumps(counts))
    meta = {
        "sentences": sent_count,
        "types": len(counts),
        "zwsp_tokens_stripped": stripped_tokens,
        "orphan_combining_marks_dropped": dropped_orphan_marks,
        "tokens_kept": kept_tokens,
    }
    (args.work_dir / "normalize_meta.json").write_text(json.dumps(meta, indent=2))
    print(f"normalize: {meta}")


def _build_vocab(args: argparse.Namespace) -> vocab.Vocab:
    counts = _load_counts(args.work_dir)
    curated = vocab.read_curated_tsv(args.curated_tsv)
    v = vocab.build_vocab(counts, curated, max_corpus_words=args.vocab_size)
    (args.work_dir / "vocab.json").write_text(
        json.dumps(
            {
                "size": v.size,
                "n_lexicon": v.n_lexicon,
                "id_bos": v.id_bos,
                "id_eos": v.id_eos,
                "id_unk": v.id_unk,
            },
            indent=2,
        )
    )
    (args.work_dir / "vocab.pkl").write_bytes(pickle.dumps(v))
    return v


def cmd_vocab(args: argparse.Namespace) -> None:
    v = _build_vocab(args)
    print(f"vocab: size={v.size} (lexicon={v.n_lexicon})")


def _load_vocab(work_dir: Path) -> vocab.Vocab:
    p = work_dir / "vocab.pkl"
    if not p.exists():
        raise SystemExit(f"missing {p} — run `vocab` first")
    return pickle.loads(p.read_bytes())


def cmd_lexicon(args: argparse.Namespace) -> None:
    v = _load_vocab(args.work_dir)
    counts = _load_counts(args.work_dir)
    curated = vocab.read_curated_tsv(args.curated_tsv)
    rows = lexicon.write_tsv(
        args.tsv_out,
        v,
        counts,
        curated,
        curated_smoothing=args.curated_smoothing,
    )
    print(f"lexicon: wrote {rows} rows to {args.tsv_out}")


def cmd_lm(args: argparse.Namespace) -> None:
    v = _load_vocab(args.work_dir)
    tokens_path = args.work_dir / "tokens.txt"
    if not tokens_path.exists():
        raise SystemExit(f"missing {tokens_path} — run `ingest` first")
    parsed = lm.train_kn(
        tokens_path,
        v,
        order=3,
        prune=tuple(args.prune),
        workers=max(1, args.workers),
        batch_size=max(1, args.batch_size * 10),
    )
    n = packer.write_binary(args.lm_out, v, parsed)
    print(
        f"lm: unigrams={len(parsed.unigrams)} bigrams={len(parsed.bigrams)} "
        f"trigrams={len(parsed.trigrams)} bytes={n} → {args.lm_out}"
    )


def cmd_all(args: argparse.Namespace) -> None:
    cmd_ingest(args)
    _build_vocab(args)
    cmd_lexicon(args)
    cmd_lm(args)


_DISPATCH = {
    "ingest": cmd_ingest,
    "normalize": cmd_normalize,
    "vocab": cmd_vocab,
    "lexicon": cmd_lexicon,
    "lm": cmd_lm,
    "all": cmd_all,
}


def main(argv: list[str] | None = None) -> None:
    args = _default_parser().parse_args(argv)
    _DISPATCH[args.cmd](args)


if __name__ == "__main__":
    main()
