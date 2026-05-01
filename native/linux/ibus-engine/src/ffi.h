/* SPDX-License-Identifier: same-as-repo */
/*
 * Hand-written C header for libBurmeseIMEFFI.so. Mirrors the @_cdecl
 * exports in `native/linux/swift-shim/Sources/BurmeseIMEFFI/FFI.swift`.
 *
 * Lifecycle:
 *   - `burmese_engine_new` returns an opaque handle. The pointer value
 *     is *not* a real Swift object pointer — it's a registry ID
 *     bit-cast into a void*. Never dereference it. Always pass it back
 *     through the API.
 *   - Free the handle with `burmese_engine_free`. After that, all other
 *     calls with this pointer are no-ops (return null / empty JSON).
 *
 * String ownership:
 *   - Every `char*` returned by an `_update`, `_commit`, `_cancel`,
 *     `_diagnostics`, or `_reverse_romanize` call is malloc'd by the
 *     Swift side. The caller MUST free it via
 *     `burmese_engine_string_free`. Do not pass it to libc `free`
 *     directly even though the implementation matches — this stays a
 *     symmetric API in case the Swift-side allocator changes.
 *
 * Threading:
 *   - All entry points are internally locked. Calling concurrently
 *     from multiple threads is safe, but expect serialization.
 */

#ifndef BURMESE_IME_FFI_H
#define BURMESE_IME_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque to C; the handle is a registry ID, not a Swift pointer. */
typedef struct burmese_engine_t burmese_engine_t;

/* --- Lifecycle ------------------------------------------------------ */

/*
 * Construct a new engine. Each parameter may be NULL (or "") to use a
 * no-op default:
 *   - lexicon_sqlite_path → EmptyCandidateStore
 *   - lm_bin_path         → NullLanguageModel
 *   - user_history_path   → EmptyUserHistoryStore
 *   - settings_suite_name → IMESettings.standard fallback (per-process)
 */
burmese_engine_t* burmese_engine_new(
    const char* lexicon_sqlite_path,
    const char* lm_bin_path,
    const char* user_history_sqlite_path,
    const char* settings_suite_name
);

void burmese_engine_free(burmese_engine_t* engine);

/* --- Composition ---------------------------------------------------- */

/*
 * Push a new raw composition buffer into the engine. Returns a
 * malloc'd, NUL-terminated UTF-8 JSON document of the form:
 *
 *   {
 *     "preedit": "minga",
 *     "candidates": [
 *       {"surface":"မင်္ဂ", "reading":"minga",
 *        "source":"lexicon", "score":-3.21}
 *     ],
 *     "selected": 0
 *   }
 *
 * Free with burmese_engine_string_free. Returns "{}" on invalid handle.
 */
char* burmese_engine_update(burmese_engine_t* engine, const char* raw_buffer);

/*
 * Commit the currently-selected candidate. Returns the surface text
 * (UTF-8) and clears the engine's composition state. The empty string
 * is returned when there is no active selection.
 *
 * Free with burmese_engine_string_free.
 */
char* burmese_engine_commit(burmese_engine_t* engine);

/* Record the current selection in user history without committing. */
void burmese_engine_record_selection(burmese_engine_t* engine);

/* Move the in-engine selection cursor to candidate `idx`. */
void burmese_engine_set_selected(burmese_engine_t* engine, int32_t idx);

/*
 * Drop the current composition unconverted. Returns the raw buffer the
 * client should commit verbatim (UTF-8). Free with
 * burmese_engine_string_free.
 */
char* burmese_engine_cancel(burmese_engine_t* engine);

/* Append a just-committed surface to the rolling committed-context tail. */
void burmese_engine_push_committed_context(
    burmese_engine_t* engine, const char* surface
);

/* Clear the committed-context tail (e.g. on focus_out). */
void burmese_engine_clear_committed_context(burmese_engine_t* engine);

/* --- Settings (drive from GSettings change handlers) ---------------- */

void burmese_engine_set_candidate_page_size(burmese_engine_t*, int32_t);
void burmese_engine_set_commit_on_space(burmese_engine_t*, int32_t);
void burmese_engine_set_cluster_aliases_enabled(burmese_engine_t*, int32_t);
void burmese_engine_set_lm_prune_margin(burmese_engine_t*, double);
void burmese_engine_set_anchor_commit_threshold(burmese_engine_t*, int32_t);
void burmese_engine_set_burmese_punctuation_enabled(burmese_engine_t*, int32_t);
void burmese_engine_set_number_measure_words_enabled(burmese_engine_t*, int32_t);
void burmese_engine_set_learning_enabled(burmese_engine_t*, int32_t);

/*
 * Rebuild the underlying parser/engine. Called after toggling
 * cluster_aliases (which is baked into SyllableParser at init time);
 * also useful as a sledgehammer for "re-read everything".
 */
void burmese_engine_reconcile_settings(burmese_engine_t* engine);

/*
 * Empty-buffer ASCII-punctuation auto-mapping. Returns the Myanmar
 * replacement when the policy applies (setting on, buffer empty, prior
 * committed context Myanmar, char is one of '.', ',', ';', '!', '?');
 * NULL otherwise. Free with burmese_engine_string_free.
 */
char* burmese_engine_map_empty_buffer_punctuation(
    burmese_engine_t* engine, int32_t ascii_char
);

/* --- Diagnostics / utility ----------------------------------------- */

/* JSON: lexicon/lm/history paths, sizes, version. */
char* burmese_engine_diagnostics(burmese_engine_t* engine);

/* Pure function: Myanmar text → reverse-romanized reading. */
char* burmese_engine_reverse_romanize(const char* myanmar_utf8);

/* Free any string returned by any of the above. */
void burmese_engine_string_free(char* str);

#ifdef __cplusplus
}
#endif

#endif /* BURMESE_IME_FFI_H */
