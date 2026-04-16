# BurmeseLM.bin — binary format (v1)

Compact, mmap-friendly, little-endian trigram language model.

The Python `corpus_builder` emits this file; Swift's `TrigramLanguageModel`
reads it by `mmap`-ing the file and doing pure binary search — zero
allocation on the hot path, no external format dependency (i.e. not KenLM's
binary), no variable-width records.

All multi-byte fields are **little-endian**. All offsets are byte offsets
from the start of the file unless noted.

## Layout

```
+-----------------------------+
|  Header (48 bytes)          |
+-----------------------------+
|  Vocab surface blob         |
+-----------------------------+
|  Vocab index (n_vocab * 8)  |   sorted-by-id array of surface offsets
+-----------------------------+
|  Vocab surface-sorted table |   sorted-by-surface for surface→id lookup
|  (n_vocab * 8)              |
+-----------------------------+
|  Unigram records            |   n_1 * UnigramRecord
+-----------------------------+
|  Bigram records             |   n_2 * BigramRecord, sorted by (w1, w2)
+-----------------------------+
|  Trigram records            |   n_3 * TrigramRecord, sorted by (w1, w2, w3)
+-----------------------------+
```

## Header (48 bytes, offset 0)

| Offset | Size | Field                    | Notes                              |
|-------:|-----:|--------------------------|------------------------------------|
|      0 |    8 | `magic`                  | ASCII `"BURMLM01"`                 |
|      8 |    4 | `version`                | u32, `1`                           |
|     12 |    4 | `order`                  | u32, `3` (trigram)                 |
|     16 |    4 | `n_vocab`                | u32, total vocab size incl. specials |
|     20 |    4 | `n_unigram`              | u32                                |
|     24 |    4 | `n_bigram`               | u32                                |
|     28 |    4 | `n_trigram`              | u32                                |
|     32 |    4 | `id_bos`                 | u32, id of `<s>`                   |
|     36 |    4 | `id_eos`                 | u32, id of `</s>`                  |
|     40 |    4 | `id_unk`                 | u32, id of `<unk>`                 |
|     44 |    4 | `reserved`               | u32, zero                          |

## Vocab

Word ids are `u32` in `[0, n_vocab)`. For lexicon entries the id **equals
the SQLite `entries.id`** so the Swift runtime can cross-index the two
stores without a lookup table. Specials (`<s>`, `</s>`, `<unk>`) get ids
above `max(entries.id)`.

- **Vocab surface blob**: concatenated UTF-8 surface strings, no separators,
  no null terminators. The blob starts immediately after the header.
- **Vocab index (sorted by id)**: `n_vocab` × `(u32 offset, u32 length)`
  records, 8 bytes each. `index[id]` gives the byte offset and length of
  that word's surface in the blob. The length is in bytes (UTF-8).
- **Vocab surface-sorted table**: `n_vocab` × `u32 id` entries, sorted by
  the bytewise order of the referenced surface string. Used by
  `wordId(for:)` — binary search over this array compares against the
  surface blob via the main index.

## N-gram records

All record arrays are sorted lexicographically by context then word, so
lookup is pure binary search.

### UnigramRecord (16 bytes)

| Size | Field       | Notes                                          |
|-----:|-------------|------------------------------------------------|
|    4 | `word_id`   | u32                                            |
|    4 | `log_prob`  | f32, natural log                               |
|    4 | `backoff`   | f32, natural log; 0.0 if no backoff            |
|    4 | `_pad`      | zero                                           |

Array is sorted by `word_id` ascending. Because `word_id` ranges over
`[0, n_vocab)`, this is typically dense — lookup may elect to index
directly rather than binary search.

### BigramRecord (16 bytes)

| Size | Field       |
|-----:|-------------|
|    4 | `w1`        |
|    4 | `w2`        |
|    4 | `log_prob`  |
|    4 | `backoff`   |

Sorted by `(w1, w2)`.

### TrigramRecord (16 bytes)

| Size | Field       |
|-----:|-------------|
|    4 | `w1`        |
|    4 | `w2`        |
|    4 | `w3`        |
|    4 | `log_prob`  |

No backoff at the highest order. Sorted by `(w1, w2, w3)`.

## Scoring semantics

Standard Katz/KN-style backoff. To score `P(w | w1, w2)`:

1. Look up `(w1, w2, w)` in trigrams. If found, return its `log_prob`.
2. Else look up `(w2, w)` in bigrams and `(w1, w2)` in bigrams (for the
   backoff weight). Return `bigram.log_prob + bigram_context.backoff`.
3. Else return `unigram(w).log_prob + unigram(w2).backoff +
   bigram(w1, w2)?.backoff`.
4. OOV: treat missing word as `id_unk`.

Empty context (no prior words) scores via unigram directly.

## Forward compatibility

Bumping `version` is the signal to the reader to reject the file. Fields
may only be appended to the end of the header (within the 48-byte budget)
or via new sections following the existing layout. Never reorder or resize
existing record types without a version bump.

## Reference fixture

The tests ship a hand-written `TestFixture.bin` (a few words, a handful of
n-grams) plus a matching expected-log-prob table. The Python builder emits
the same bytes when run against the matching input, giving bidirectional
verification.
