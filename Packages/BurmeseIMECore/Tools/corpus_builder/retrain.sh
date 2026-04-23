#!/usr/bin/env bash
# retrain.sh — the task-13 pipeline: rebuild LM + sqlite from the current TSV.
#
# Runs end-to-end:
#   1. source prepare.sh                       (set MYWORD_DIR)
#   2. corpus-build ingest | normalize         (~40-60 min | ~1-2 min)
#   3. corpus-build vocab                      (~1 min)
#   4. corpus-build lexicon                    (~1 min — overwrites BurmeseLexiconSource.tsv)
#   5. corpus-build lm                         (~3-5 min — writes BurmeseLM.bin)
#   6. swift run LexiconBuilder                (writes sqlite; auto-drift-check against LM)
#   7. swift run TestRunner                    (regression sweep)
#   8. swift run -c release BurmeseBench       (perf regression check)
#
# Usage:
#   ./retrain.sh [mode] [--curated-smoothing κ] [--vocab-size N] [--prune a b c]
#
# Stage-2 modes (pick one):
#   (default)       Run full ingest. Slow. Use on first run or when the
#                   corpus itself changed.
#   --normalize     Skip ingest; run `corpus-build normalize` instead to
#                   scrub U+200B from the existing build/tokens.txt and
#                   rebuild counts.pkl. Fast salvage when a prior ingest
#                   produced zero-width-space pollution.
#   --skip-ingest   Skip stage 2 entirely. Use when tokens.txt is already
#                   clean and you just need to re-run stages 3+.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

STAGE2_MODE="ingest"
CURATED_SMOOTHING=0.1
VOCAB_SIZE=80000
# `0 10 20` keeps the LM around 50–70 MB on the Myanmar-C4 corpus;
# see build.py for the full sizing table. Override with --prune a b c
# to trade file size for coverage (e.g. `--prune 0 2 3` ≈ 340 MB).
PRUNE=(0 10 20)

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-ingest) STAGE2_MODE="skip"; shift ;;
        --normalize)   STAGE2_MODE="normalize"; shift ;;
        --curated-smoothing) CURATED_SMOOTHING="$2"; shift 2 ;;
        --vocab-size) VOCAB_SIZE="$2"; shift 2 ;;
        --prune) PRUNE=("$2" "$3" "$4"); shift 4 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

log() { printf '\n==> %s\n' "$1"; }

cd "$SCRIPT_DIR"

log "Stage 1/8: sourcing prepare.sh (sets MYWORD_DIR)"
# shellcheck disable=SC1091
source "./prepare.sh"

case "$STAGE2_MODE" in
    ingest)
        log "Stage 2/8: corpus-build ingest (~40-60 min)"
        corpus-build ingest
        ;;
    normalize)
        log "Stage 2/8: corpus-build normalize (salvage existing tokens.txt)"
        corpus-build normalize
        ;;
    skip)
        log "Stage 2/8: SKIPPED (--skip-ingest) — reusing existing build/tokens.txt"
        ;;
esac

log "Stage 3/8: corpus-build vocab --vocab-size $VOCAB_SIZE"
corpus-build vocab --vocab-size "$VOCAB_SIZE"

log "Stage 4/8: corpus-build lexicon (curated smoothing κ=$CURATED_SMOOTHING)"
corpus-build lexicon \
    --tsv-out ../../Data/BurmeseLexiconSource.tsv \
    --curated-smoothing "$CURATED_SMOOTHING"

log "Stage 5/8: corpus-build lm --prune ${PRUNE[*]}"
corpus-build lm --prune "${PRUNE[@]}"

cd "$PACKAGE_DIR"

log "Stage 6/8: swift run LexiconBuilder (drift check fires vs sibling BurmeseLM.bin)"
swift run LexiconBuilder \
    Data/BurmeseLexiconSource.tsv \
    ../../native/macos/Data/BurmeseLexicon.sqlite

log "Stage 7/8: swift run TestRunner"
swift run TestRunner

log "Stage 8/8: swift run -c release BurmeseBench --check Tests/Benchmarks/baseline.json"
swift run -c release BurmeseBench --check Tests/Benchmarks/baseline.json

cat <<EOF

All stages green. To commit the regenerated artefacts:

    git add native/macos/Data/BurmeseLexicon.sqlite \\
            native/macos/Data/BurmeseLM.bin
    git commit

Then ping the agent to land tasks 14-18 (override removal + composite score).
EOF
