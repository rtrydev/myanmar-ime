#!/usr/bin/env bash
# Prepares the corpus_builder environment:
#   1. Clones ye-kyaw-thu/myWord into ./myWord (gitignored) if missing.
#   2. Runs combine-all-splitted-files.sh to merge the 24 MB dict chunks.
#   3. Exports MYWORD_DIR so the segmenter can find the pickled dicts.
#
# Source this script (don't execute it) so MYWORD_DIR persists in your shell:
#     source prepare.sh
#
# Re-running is idempotent — an existing clone is left untouched.

# Detect sourcing so we `return` rather than `exit` on failure; exiting
# would kill the user's shell when they `source` this script.
_prep_bail() {
    echo "prepare.sh: $1" >&2
    if (return 0 2>/dev/null); then
        return 1
    else
        exit 1
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MYWORD_REPO="https://github.com/ye-kyaw-thu/myWord.git"
MYWORD_PATH="$SCRIPT_DIR/myWord"
DICT_DIR="$MYWORD_PATH/dict_ver1"

if [ ! -d "$MYWORD_PATH/.git" ]; then
    echo "==> Cloning myWord into $MYWORD_PATH"
    if ! git clone --depth=1 "$MYWORD_REPO" "$MYWORD_PATH"; then
        _prep_bail "git clone failed"
        return 1 2>/dev/null || exit 1
    fi
else
    echo "==> myWord already present at $MYWORD_PATH"
fi

# The bigram dict files are split into 24 MB chunks on GitHub. Merge them
# into `bigram-word.bin` (and siblings) if that hasn't happened yet.
if [ ! -f "$DICT_DIR/bigram-word.bin" ] && ls "$DICT_DIR"/bigram-word.bin.small.* >/dev/null 2>&1; then
    echo "==> Merging split bigram dicts"
    if ! (cd "$DICT_DIR" && bash combine-all-splitted-files.sh); then
        _prep_bail "merge script failed"
        return 1 2>/dev/null || exit 1
    fi
fi

if [ ! -f "$DICT_DIR/unigram-word.bin" ] || [ ! -f "$DICT_DIR/bigram-word.bin" ]; then
    _prep_bail "myWord dicts missing under $DICT_DIR (expected unigram-word.bin + bigram-word.bin)"
    return 1 2>/dev/null || exit 1
fi

export MYWORD_DIR="$MYWORD_PATH"
echo "==> MYWORD_DIR=$MYWORD_DIR"
echo "==> Ready. Run: corpus-build all --tsv-out ... --lm-out ..."
