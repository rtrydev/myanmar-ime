/* SPDX-License-Identifier: same-as-repo */
#include "engine.h"

#include <gio/gio.h>
#include <glib.h>
#include <json-glib/json-glib.h>
#include <stdlib.h>
#include <string.h>

#include "ffi.h"
#include "keymap.h"
#include "settings.h"

/*
 * Per-window engine instance. The Swift handle is allocated on `enable`
 * and freed on `disable`. IBus may instantiate multiple engines for
 * different focus contexts simultaneously, so `current_handle` must
 * never be a process-global.
 *
 * Threading:
 *   - process_key_event, focus_*, reset, enable/disable, property
 *     activations, and GSettings callbacks all run on the IBus
 *     main-loop thread. `buffer`, `lookup_table`, `last_snapshot`,
 *     and `last_rendered_buffer` are touched only from that thread.
 *   - `worker_thread` runs `burmese_engine_update` calls off the
 *     keystroke path so a slow per-keystroke parse never blocks key
 *     event handling. The worker coordinates with the main thread via
 *     `worker_mutex` + two condition variables.
 *   - Results from the worker are posted back via
 *     `g_main_context_invoke` so all preedit / lookup-table mutations
 *     stay on the IBus thread.
 *   - Coalescing on the main side guarantees only the *latest* buffer
 *     ever reaches the engine after a typing burst — three keystrokes
 *     during a 60ms engine call produce at most two engine runs (the
 *     in-flight one, then one for the final buffer).
 *   - Commit / cancel / clear paths drain `pending_has_work` and wait
 *     for `in_flight` to clear before issuing synchronous engine
 *     calls, so engine state is never accessed concurrently from main
 *     and worker.
 */
struct _IBusMyanglerEngine {
    IBusEngine parent;

    burmese_engine_t* handle;
    GSettings* settings;

    /* Roman composition buffer (lowercased, ASCII-only). Owned. This
       always reflects the user's keystrokes immediately; the engine's
       view of the buffer (mirrored by `last_rendered_buffer`) lags
       behind by up to one async update. */
    GString* buffer;

    /* Most recent JSON snapshot from the FFI. Owned. The candidate
       array is rebuilt on every keystroke; we cache it here so cursor
       moves don't need a re-parse. */
    JsonNode* last_snapshot;
    int last_candidate_count;

    /* The buffer that produced the snapshot currently visible in the
       lookup table. Used by commit to decide whether the in-engine
       state matches what the user is looking at (cursor index is
       meaningful) versus whether the engine is still behind (must
       re-update synchronously and commit candidate 0). Owned. */
    GString* last_rendered_buffer;

    /* IBus surfaces. Owned by the parent class once installed; we hold
       weak refs for refresh. */
    IBusLookupTable* lookup_table;

    /* Compose / Roman toggle (in-engine bypass). When FALSE, every
       printable character is committed verbatim instead of going into
       the buffer — matches the macOS Compose/Roman menubar toggle. */
    gboolean compose_enabled;
    IBusProperty* compose_property;
    IBusPropList* prop_list;

    /* --- Async engine coordination -------------------------------- */
    GThread* worker_thread;
    GMutex worker_mutex;
    GCond  worker_cond;  /* signaled when pending arrives or shutting down */
    GCond  idle_cond;    /* signaled when in_flight transitions to FALSE */
    GMainContext* main_context;  /* captured at init for posting results */

    /* All four fields below are protected by worker_mutex. */
    gboolean worker_shutdown;
    gboolean pending_has_work;
    GString* pending_buffer;
    gboolean in_flight;
};

G_DEFINE_TYPE(IBusMyanglerEngine, ibus_myangler_engine, IBUS_TYPE_ENGINE)

/* ------------------------------------------------------------------ */
/* Resource path resolution                                            */
/* ------------------------------------------------------------------ */

/* Pick the first existing path from the candidate list, or NULL. */
static gchar* resolve_data_file(const char* basename)
{
    const gchar* env = g_getenv("MYANGLER_DATA_DIR");
    if (env && *env) {
        gchar* path = g_build_filename(env, basename, NULL);
        if (g_file_test(path, G_FILE_TEST_EXISTS)) {
            return path;
        }
        g_free(path);
    }

    const gchar* candidates[] = {
        "/usr/share/myangler",
        "/usr/local/share/myangler",
        NULL,
    };
    for (int i = 0; candidates[i]; ++i) {
        gchar* path = g_build_filename(candidates[i], basename, NULL);
        if (g_file_test(path, G_FILE_TEST_EXISTS)) {
            return path;
        }
        g_free(path);
    }
    return NULL;
}

static gchar* resolve_user_history_path(void)
{
    const gchar* base = g_get_user_data_dir();
    return g_build_filename(base, "myangler", "UserHistory.sqlite", NULL);
}

/* ------------------------------------------------------------------ */
/* Snapshot rendering                                                  */
/* ------------------------------------------------------------------ */

static void clear_snapshot(IBusMyanglerEngine* self)
{
    if (self->last_snapshot) {
        json_node_free(self->last_snapshot);
        self->last_snapshot = NULL;
    }
    self->last_candidate_count = 0;
    g_string_truncate(self->last_rendered_buffer, 0);
}

/* Update the inline preedit to the user's raw buffer. Runs on the IBus
   main thread on every keystroke so the user always sees their typing
   land immediately, independent of how long the async engine call
   takes. Mirrors the macOS controller's `setMarkedText(display:)` —
   the Linux FFI also emits `preedit == rawBuffer` in its snapshot, so
   nothing about the rendered string is engine-dependent. */
static void update_preedit_from_buffer(IBusMyanglerEngine* self)
{
    if (self->buffer->len == 0) {
        ibus_engine_hide_preedit_text(IBUS_ENGINE(self));
        return;
    }
    IBusText* text = ibus_text_new_from_string(self->buffer->str);
    ibus_text_append_attribute(text, IBUS_ATTR_TYPE_UNDERLINE,
                               IBUS_ATTR_UNDERLINE_SINGLE,
                               0, -1);
    ibus_engine_update_preedit_text(
        IBUS_ENGINE(self),
        text,
        g_utf8_strlen(self->buffer->str, -1),
        TRUE);
}

/* Render the lookup table from a fresh JSON snapshot. Preedit is NOT
   touched here — the keystroke path already updated it from the raw
   buffer. Stores the snapshot for later reads (commit, cursor moves)
   and remembers which buffer it came from in `last_rendered_buffer`
   so commit can tell whether the in-engine state matches what the
   user is looking at. */
static void render_lookup_from_snapshot(IBusMyanglerEngine* self,
                                        const char* source_buffer,
                                        const char* json_str)
{
    /* Drop the previous snapshot first; we'll repopulate below. */
    if (self->last_snapshot) {
        json_node_free(self->last_snapshot);
        self->last_snapshot = NULL;
    }
    self->last_candidate_count = 0;

    if (!json_str || !*json_str) {
        ibus_lookup_table_clear(self->lookup_table);
        ibus_engine_hide_lookup_table(IBUS_ENGINE(self));
        g_string_truncate(self->last_rendered_buffer, 0);
        return;
    }

    JsonParser* parser = json_parser_new();
    GError* err = NULL;
    if (!json_parser_load_from_data(parser, json_str, -1, &err)) {
        g_warning("myangler: snapshot parse failed: %s",
                  err ? err->message : "unknown");
        if (err) g_error_free(err);
        g_object_unref(parser);
        return;
    }
    JsonNode* root = json_parser_get_root(parser);
    if (!root || !JSON_NODE_HOLDS_OBJECT(root)) {
        g_object_unref(parser);
        return;
    }

    self->last_snapshot = json_node_copy(root);
    g_object_unref(parser);

    JsonObject* obj = json_node_get_object(self->last_snapshot);
    JsonArray* candidates = json_object_has_member(obj, "candidates")
        ? json_object_get_array_member(obj, "candidates") : NULL;
    int selected = json_object_has_member(obj, "selected")
        ? (int)json_object_get_int_member(obj, "selected") : 0;
    self->last_candidate_count =
        candidates ? (int)json_array_get_length(candidates) : 0;

    ibus_lookup_table_clear(self->lookup_table);
    if (candidates) {
        guint n = json_array_get_length(candidates);
        for (guint i = 0; i < n; ++i) {
            JsonObject* c = json_array_get_object_element(candidates, i);
            const gchar* surface = json_object_has_member(c, "surface")
                ? json_object_get_string_member(c, "surface") : "";
            IBusText* item = ibus_text_new_from_string(surface);
            ibus_lookup_table_append_candidate(self->lookup_table, item);
        }
        if (selected >= 0 && selected < (int)n) {
            ibus_lookup_table_set_cursor_pos(self->lookup_table,
                                             (guint)selected);
        }
    }
    gboolean show_table = self->last_candidate_count > 0;
    ibus_engine_update_lookup_table_fast(IBUS_ENGINE(self),
                                         self->lookup_table,
                                         show_table);

    g_string_assign(self->last_rendered_buffer,
                    source_buffer ? source_buffer : "");
}

/* ------------------------------------------------------------------ */
/* Async engine coordination                                          */
/* ------------------------------------------------------------------ */

/* Result envelope produced on the worker thread and consumed on the
   IBus main thread via g_main_context_invoke. Owned by the consumer. */
typedef struct {
    IBusMyanglerEngine* self;  /* strong ref */
    gchar* buffer;             /* the buffer the engine ran against */
    char* json;                /* malloc'd by FFI; free with
                                  burmese_engine_string_free */
} EngineResult;

static gboolean deliver_engine_result(gpointer data)
{
    EngineResult* r = (EngineResult*)data;
    IBusMyanglerEngine* self = r->self;

    /* The user may have typed further or committed since this call
       started — only apply the result if the buffer still matches.
       Otherwise the panel would flash an out-of-date candidate set. */
    if (self->handle != NULL
        && g_strcmp0(r->buffer, self->buffer->str) == 0) {
        render_lookup_from_snapshot(self, r->buffer, r->json);
    }

    if (r->json) burmese_engine_string_free(r->json);
    g_free(r->buffer);
    g_object_unref(r->self);
    g_free(r);
    return G_SOURCE_REMOVE;
}

static gpointer engine_worker_thread(gpointer data)
{
    IBusMyanglerEngine* self = (IBusMyanglerEngine*)data;

    for (;;) {
        g_mutex_lock(&self->worker_mutex);
        while (!self->worker_shutdown && !self->pending_has_work) {
            g_cond_wait(&self->worker_cond, &self->worker_mutex);
        }
        if (self->worker_shutdown) {
            g_mutex_unlock(&self->worker_mutex);
            break;
        }
        gchar* buf = g_strdup(self->pending_buffer->str);
        self->pending_has_work = FALSE;
        self->in_flight = TRUE;
        burmese_engine_t* handle_snapshot = self->handle;
        /* Hold a ref on `self` for the duration of this work cycle so
           the engine cannot be disposed while we're calling into the
           FFI or constructing an EngineResult below. Released after
           we transition back to in_flight=FALSE. Without this ref,
           IBus dropping its ref while we're mid-update would let
           dispose race the worker's `g_object_ref` call (which would
           "resurrect" a refcount-0 object). */
        g_object_ref(self);
        g_mutex_unlock(&self->worker_mutex);

        /* Run the (possibly slow) engine call without holding any
           lock — the FFI is internally locked, so commit/cancel paths
           on the main thread that take h->lock won't be reordered
           with this update. */
        char* json = NULL;
        if (handle_snapshot) {
            json = burmese_engine_update(handle_snapshot, buf);
        }

        /* Marshal the result back to the IBus main thread. */
        EngineResult* r = g_new0(EngineResult, 1);
        r->self = g_object_ref(self);
        r->buffer = buf;        /* takes ownership */
        r->json = json;         /* takes ownership */
        g_main_context_invoke(self->main_context, deliver_engine_result, r);

        g_mutex_lock(&self->worker_mutex);
        self->in_flight = FALSE;
        g_cond_broadcast(&self->idle_cond);
        g_mutex_unlock(&self->worker_mutex);
        g_object_unref(self);  /* balances ref taken at cycle start */
    }
    return NULL;
}

/* Queue the latest buffer for async processing. Repeated calls during
   a typing burst simply overwrite `pending_buffer`, so only the most
   recent buffer the user has typed reaches the engine once it becomes
   idle. Must be called from the IBus main thread. */
static void schedule_engine_update(IBusMyanglerEngine* self)
{
    g_mutex_lock(&self->worker_mutex);
    g_string_assign(self->pending_buffer, self->buffer->str);
    self->pending_has_work = TRUE;
    g_cond_signal(&self->worker_cond);
    g_mutex_unlock(&self->worker_mutex);
}

/* Discard any queued work and block until the worker is idle. After
   this returns the main thread holds exclusive logical access to the
   engine: no FFI call is in flight, no further worker call will start
   until schedule_engine_update is called again. Any result already
   marshalled back to the main loop will still fire, but the stale-
   buffer guard in deliver_engine_result drops it. Must be called from
   the IBus main thread. */
static void drain_and_wait_idle(IBusMyanglerEngine* self)
{
    g_mutex_lock(&self->worker_mutex);
    self->pending_has_work = FALSE;
    while (self->in_flight) {
        g_cond_wait(&self->idle_cond, &self->worker_mutex);
    }
    g_mutex_unlock(&self->worker_mutex);
}

static void clear_ime_state(IBusMyanglerEngine* self)
{
    drain_and_wait_idle(self);
    g_string_truncate(self->buffer, 0);
    if (self->handle) {
        char* json = burmese_engine_update(self->handle, "");
        if (json) burmese_engine_string_free(json);
    }
    clear_snapshot(self);
    ibus_engine_hide_preedit_text(IBUS_ENGINE(self));
    ibus_lookup_table_clear(self->lookup_table);
    ibus_engine_hide_lookup_table(IBUS_ENGINE(self));
}

/* ------------------------------------------------------------------ */
/* Commit + cancel                                                     */
/* ------------------------------------------------------------------ */

static void commit_selected(IBusMyanglerEngine* self)
{
    if (!self->handle) return;

    /* Drain any queued typing work and wait for an in-flight update
       to finish so the engine isn't being touched from the worker
       while we run the commit sequence below. */
    drain_and_wait_idle(self);

    /* If the engine is still behind the user's buffer (a slow update
       was in flight or coalesced away), refresh the engine state to
       match the latest typed buffer before committing. In that case
       the visible lookup table is from an older buffer and any cursor
       navigation was made against stale candidates, so we commit
       candidate 0 of the fresh state — same trade-off as the macOS
       controller in this race. When the engine is already caught up,
       respect the user's arrow-key navigation by syncing the cursor
       index into the engine before committing. */
    gboolean engine_caught_up =
        (g_strcmp0(self->last_rendered_buffer->str, self->buffer->str) == 0)
        && self->last_candidate_count > 0;

    if (!engine_caught_up) {
        char* json = burmese_engine_update(self->handle, self->buffer->str);
        if (json) burmese_engine_string_free(json);
        burmese_engine_set_selected(self->handle, 0);
    } else {
        int idx = (int)ibus_lookup_table_get_cursor_pos(self->lookup_table);
        burmese_engine_set_selected(self->handle, (int32_t)idx);
    }

    char* surface = burmese_engine_commit(self->handle);
    if (surface && *surface) {
        IBusText* text = ibus_text_new_from_string(surface);
        ibus_engine_commit_text(IBUS_ENGINE(self), text);
        burmese_engine_push_committed_context(self->handle, surface);
    }
    if (surface) burmese_engine_string_free(surface);
    g_string_truncate(self->buffer, 0);
    clear_snapshot(self);
    ibus_engine_hide_preedit_text(IBUS_ENGINE(self));
    ibus_lookup_table_clear(self->lookup_table);
    ibus_engine_hide_lookup_table(IBUS_ENGINE(self));
}

static void cancel_buffer(IBusMyanglerEngine* self)
{
    if (!self->handle) return;
    /* Drop any queued typing work — we're about to commit the buffer
       verbatim, the engine result wouldn't reach the panel anyway. */
    drain_and_wait_idle(self);
    char* raw = burmese_engine_cancel(self->handle);
    if (raw && *raw) {
        IBusText* text = ibus_text_new_from_string(raw);
        ibus_engine_commit_text(IBUS_ENGINE(self), text);
    }
    if (raw) burmese_engine_string_free(raw);
    g_string_truncate(self->buffer, 0);
    clear_snapshot(self);
    ibus_engine_hide_preedit_text(IBUS_ENGINE(self));
    ibus_lookup_table_clear(self->lookup_table);
    ibus_engine_hide_lookup_table(IBUS_ENGINE(self));
}

/* ------------------------------------------------------------------ */
/* IBusEngine vfunc overrides                                          */
/* ------------------------------------------------------------------ */

static gboolean ibus_myangler_engine_process_key_event(IBusEngine* engine,
                                                       guint keyval,
                                                       guint keycode,
                                                       guint modifiers)
{
    (void)keycode;
    IBusMyanglerEngine* self = IBUS_MYANGLER_ENGINE(engine);

    /* IBus calls process_key_event for both press and release; the
       release event has IBUS_RELEASE_MASK set. We only care about
       press to avoid double-handling. */
    if (modifiers & IBUS_RELEASE_MASK) return FALSE;

    KeymapResult km = keymap_map(keyval, modifiers);
    if (km.action == KEYMAP_MODIFIER) {
        /* Bare modifier press (Shift, Ctrl, …). The user is in the
           middle of forming a chord — e.g. Shift before ':' — so we
           must NOT commit the buffer. Just let it pass through. */
        return FALSE;
    }
    if (km.action == KEYMAP_IGNORE) {
        /* Don't consume keys we have no mapping for — let the client
           handle them. If the buffer is non-empty, commit it first so
           the just-typed key inserts at the right place. */
        if (self->buffer->len > 0) {
            commit_selected(self);
        }
        return FALSE;
    }

    /* Compose-disabled mode: every typeable character commits raw,
       every other action is ignored. Mirrors macOS "Roman" mode. */
    if (!self->compose_enabled) {
        if (km.action == KEYMAP_TYPEABLE) {
            char ch[2] = { km.typed_char, 0 };
            IBusText* text = ibus_text_new_from_string(ch);
            ibus_engine_commit_text(engine, text);
            return TRUE;
        }
        return FALSE;
    }

    switch (km.action) {
    case KEYMAP_TYPEABLE: {
        /* Empty-buffer punctuation auto-mapping: when the previous
           committed token is Myanmar and the user types one of
           '.', ',', '!', '?', ';', insert the Myanmar equivalent
           directly. Mirrors BurmeseInputController.swift:178. The
           Swift FFI checks settings + context tail; we only act on a
           non-NULL return.

           The map call is synchronous because the result is needed
           before deciding whether to commit immediately versus
           appending to the buffer. It's cheap (a settings + tail
           check) and only runs when the buffer is empty, so it
           doesn't interact with the async update path. */
        if (self->buffer->len == 0 && self->handle) {
            char* mapped = burmese_engine_map_empty_buffer_punctuation(
                self->handle, (int32_t)(unsigned char)km.typed_char);
            if (mapped) {
                IBusText* text = ibus_text_new_from_string(mapped);
                ibus_engine_commit_text(engine, text);
                burmese_engine_push_committed_context(self->handle, mapped);
                burmese_engine_string_free(mapped);
                return TRUE;
            }
        }
        g_string_append_c(self->buffer, km.typed_char);
        /* Show the user's typing immediately; the engine runs async. */
        update_preedit_from_buffer(self);
        schedule_engine_update(self);
        return TRUE;
    }
    case KEYMAP_BACKSPACE: {
        if (self->buffer->len == 0) return FALSE;
        g_string_truncate(self->buffer, self->buffer->len - 1);
        if (self->buffer->len == 0) {
            /* Whole composition gone. Discard any pending engine work
               and reset the engine state immediately so the next
               keystroke starts clean — no need to wait for a worker
               round trip that would only land an empty snapshot. */
            drain_and_wait_idle(self);
            if (self->handle) {
                char* json = burmese_engine_update(self->handle, "");
                if (json) burmese_engine_string_free(json);
            }
            clear_snapshot(self);
            ibus_engine_hide_preedit_text(IBUS_ENGINE(self));
            ibus_lookup_table_clear(self->lookup_table);
            ibus_engine_hide_lookup_table(IBUS_ENGINE(self));
        } else {
            update_preedit_from_buffer(self);
            schedule_engine_update(self);
        }
        return TRUE;
    }
    case KEYMAP_COMMIT: {
        if (self->buffer->len == 0) {
            /* Space/Return with empty buffer: pass through so the
               client handles it normally. */
            return FALSE;
        }
        commit_selected(self);
        return TRUE;
    }
    case KEYMAP_CANCEL: {
        if (self->buffer->len == 0) return FALSE;
        cancel_buffer(self);
        return TRUE;
    }
    case KEYMAP_NAV_UP:
        if (self->last_candidate_count == 0) return FALSE;
        ibus_lookup_table_cursor_up(self->lookup_table);
        ibus_engine_update_lookup_table_fast(engine, self->lookup_table, TRUE);
        return TRUE;
    case KEYMAP_NAV_DOWN:
        if (self->last_candidate_count == 0) return FALSE;
        ibus_lookup_table_cursor_down(self->lookup_table);
        ibus_engine_update_lookup_table_fast(engine, self->lookup_table, TRUE);
        return TRUE;
    case KEYMAP_NAV_PAGE_UP:
        if (self->last_candidate_count == 0) return FALSE;
        ibus_lookup_table_page_up(self->lookup_table);
        ibus_engine_update_lookup_table_fast(engine, self->lookup_table, TRUE);
        return TRUE;
    case KEYMAP_NAV_PAGE_DOWN:
        if (self->last_candidate_count == 0) return FALSE;
        ibus_lookup_table_page_down(self->lookup_table);
        ibus_engine_update_lookup_table_fast(engine, self->lookup_table, TRUE);
        return TRUE;
    case KEYMAP_NAV_HOME:
    case KEYMAP_NAV_END:
        /* No-op; IBus's lookup table doesn't expose direct seek
           helpers and these keys aren't part of the macOS UX. */
        return FALSE;
    default:
        return FALSE;
    }
}

static void ibus_myangler_engine_focus_in(IBusEngine* engine)
{
    IBusMyanglerEngine* self = IBUS_MYANGLER_ENGINE(engine);
    if (self->prop_list) {
        ibus_engine_register_properties(engine, self->prop_list);
    }
    /* Re-show the preedit if we still have a buffer. IBus sometimes
       drops it on focus_out → focus_in. The preedit is the raw
       buffer (no engine call), and a fresh async update repopulates
       the lookup table without blocking focus restoration. */
    if (self->buffer->len > 0) {
        update_preedit_from_buffer(self);
        schedule_engine_update(self);
    }
}

static void ibus_myangler_engine_focus_out(IBusEngine* engine)
{
    IBusMyanglerEngine* self = IBUS_MYANGLER_ENGINE(engine);
    /* macOS commits the active composition on focus loss
       (commitComposition). Mirror that: a half-typed buffer would
       otherwise be dropped silently when the user clicks away. */
    if (self->buffer->len > 0) {
        commit_selected(self);
    }
}

static void ibus_myangler_engine_reset(IBusEngine* engine)
{
    clear_ime_state(IBUS_MYANGLER_ENGINE(engine));
}

static void ibus_myangler_engine_enable(IBusEngine* engine)
{
    IBusMyanglerEngine* self = IBUS_MYANGLER_ENGINE(engine);
    if (self->handle) return;

    gchar* lexicon  = resolve_data_file("BurmeseLexicon.sqlite");
    gchar* lm       = resolve_data_file("BurmeseLM.bin");
    gchar* history  = resolve_user_history_path();

    self->handle = burmese_engine_new(lexicon, lm, history, NULL);
    if (!self->handle) {
        g_warning("myangler: burmese_engine_new failed (lexicon=%s lm=%s)",
                  lexicon ? lexicon : "<null>",
                  lm ? lm : "<null>");
    }
    g_free(lexicon);
    g_free(lm);
    g_free(history);

    if (self->handle) {
        self->settings = myangler_settings_connect(self->handle);
    }
}

static void ibus_myangler_engine_disable(IBusEngine* engine)
{
    IBusMyanglerEngine* self = IBUS_MYANGLER_ENGINE(engine);
    clear_ime_state(self);
    if (self->settings) {
        myangler_settings_disconnect(self->settings);
        self->settings = NULL;
    }
    /* clear_ime_state already drained pending work and waited for any
       in-flight update; null out the handle under the worker mutex so
       a result still en route to the main loop, or a follow-up
       schedule_engine_update before re-enable, can't reach a freed
       engine. */
    g_mutex_lock(&self->worker_mutex);
    burmese_engine_t* to_free = self->handle;
    self->handle = NULL;
    g_mutex_unlock(&self->worker_mutex);
    if (to_free) {
        burmese_engine_free(to_free);
    }
}

static void ibus_myangler_engine_property_activate(IBusEngine* engine,
                                                   const gchar* prop_name,
                                                   guint prop_state)
{
    IBusMyanglerEngine* self = IBUS_MYANGLER_ENGINE(engine);
    if (g_strcmp0(prop_name, "myangler.compose") == 0) {
        self->compose_enabled = (prop_state == PROP_STATE_CHECKED);
        if (!self->compose_enabled && self->buffer->len > 0) {
            commit_selected(self);
        }
        ibus_property_set_state(self->compose_property,
                                self->compose_enabled
                                  ? PROP_STATE_CHECKED
                                  : PROP_STATE_UNCHECKED);
        ibus_engine_update_property(engine, self->compose_property);
    }
}

/* ------------------------------------------------------------------ */
/* Lifecycle                                                           */
/* ------------------------------------------------------------------ */

static void ibus_myangler_engine_init(IBusMyanglerEngine* self)
{
    self->handle = NULL;
    self->settings = NULL;
    self->buffer = g_string_new(NULL);
    self->last_snapshot = NULL;
    self->last_candidate_count = 0;
    self->last_rendered_buffer = g_string_new(NULL);
    self->compose_enabled = TRUE;

    /* Default page size is 9 (matches macOS); GSettings will override
       the moment myangler_settings_connect runs. */
    self->lookup_table = ibus_lookup_table_new(9, 0, TRUE, TRUE);
    g_object_ref_sink(self->lookup_table);

    /* Compose/Roman toggle */
    IBusText* label = ibus_text_new_from_string("Compose");
    IBusText* tip = ibus_text_new_from_string(
        "Convert romanized input to Burmese. Off = pass-through.");
    self->compose_property = ibus_property_new(
        "myangler.compose",
        PROP_TYPE_TOGGLE,
        label, NULL, tip,
        TRUE, TRUE,
        PROP_STATE_CHECKED, NULL);
    self->prop_list = ibus_prop_list_new();
    g_object_ref_sink(self->prop_list);
    ibus_prop_list_append(self->prop_list, self->compose_property);

    /* Async engine coordination. The worker thread is spun up here
       and lives until finalize. It runs idle (blocked in g_cond_wait)
       when there's no pending work or no handle yet. We capture the
       main context so results posted from the worker land on the
       IBus main thread regardless of which context happens to be
       default when g_main_context_invoke is called. */
    g_mutex_init(&self->worker_mutex);
    g_cond_init(&self->worker_cond);
    g_cond_init(&self->idle_cond);
    self->worker_shutdown = FALSE;
    self->pending_has_work = FALSE;
    self->pending_buffer = g_string_new(NULL);
    self->in_flight = FALSE;
    self->main_context = g_main_context_ref(g_main_context_default());
    self->worker_thread = g_thread_new(
        "myangler-engine", engine_worker_thread, self);
}

/* GObject dispose runs at the first refcount-0 transition, before
   finalize, and is the appropriate place to release refs to other
   objects and stop background work. The worker thread holds a ref on
   `self` whenever it's processing an update, so dispose can only be
   reached when the worker is idle (waiting on its condition). We tell
   it to exit and join it here so finalize can free state without any
   live thread that might still touch it. Dispose is allowed to run
   more than once; the worker_thread NULL-check makes that safe. */
static void ibus_myangler_engine_dispose(GObject* object)
{
    IBusMyanglerEngine* self = IBUS_MYANGLER_ENGINE(object);

    if (self->worker_thread) {
        g_mutex_lock(&self->worker_mutex);
        self->worker_shutdown = TRUE;
        self->pending_has_work = FALSE;
        g_cond_broadcast(&self->worker_cond);
        g_mutex_unlock(&self->worker_mutex);
        g_thread_join(self->worker_thread);
        self->worker_thread = NULL;
    }

    G_OBJECT_CLASS(ibus_myangler_engine_parent_class)->dispose(object);
}

static void ibus_myangler_engine_finalize(GObject* object)
{
    IBusMyanglerEngine* self = IBUS_MYANGLER_ENGINE(object);

    /* Worker thread has already been joined in dispose. Free the
       coordination primitives now that nothing is using them. */
    g_mutex_clear(&self->worker_mutex);
    g_cond_clear(&self->worker_cond);
    g_cond_clear(&self->idle_cond);
    if (self->main_context) {
        g_main_context_unref(self->main_context);
        self->main_context = NULL;
    }
    if (self->pending_buffer) {
        g_string_free(self->pending_buffer, TRUE);
        self->pending_buffer = NULL;
    }

    if (self->settings) {
        myangler_settings_disconnect(self->settings);
        self->settings = NULL;
    }
    if (self->handle) {
        burmese_engine_free(self->handle);
        self->handle = NULL;
    }
    clear_snapshot(self);
    if (self->buffer) {
        g_string_free(self->buffer, TRUE);
        self->buffer = NULL;
    }
    if (self->last_rendered_buffer) {
        g_string_free(self->last_rendered_buffer, TRUE);
        self->last_rendered_buffer = NULL;
    }
    if (self->lookup_table) {
        g_object_unref(self->lookup_table);
        self->lookup_table = NULL;
    }
    if (self->prop_list) {
        g_object_unref(self->prop_list);
        self->prop_list = NULL;
    }
    G_OBJECT_CLASS(ibus_myangler_engine_parent_class)->finalize(object);
}

static void ibus_myangler_engine_class_init(IBusMyanglerEngineClass* klass)
{
    GObjectClass* gobject_class = G_OBJECT_CLASS(klass);
    IBusEngineClass* engine_class = IBUS_ENGINE_CLASS(klass);

    gobject_class->dispose          = ibus_myangler_engine_dispose;
    gobject_class->finalize         = ibus_myangler_engine_finalize;

    engine_class->process_key_event = ibus_myangler_engine_process_key_event;
    engine_class->focus_in          = ibus_myangler_engine_focus_in;
    engine_class->focus_out         = ibus_myangler_engine_focus_out;
    engine_class->reset             = ibus_myangler_engine_reset;
    engine_class->enable            = ibus_myangler_engine_enable;
    engine_class->disable           = ibus_myangler_engine_disable;
    engine_class->property_activate = ibus_myangler_engine_property_activate;
}

/* ------------------------------------------------------------------ */
/* Factory registration                                                */
/* ------------------------------------------------------------------ */

void ibus_myangler_engine_register_factory(IBusBus* bus)
{
    IBusFactory* factory = ibus_factory_new(ibus_bus_get_connection(bus));
    g_object_ref_sink(factory);
    ibus_factory_add_engine(factory, "myangler", IBUS_TYPE_MYANGLER_ENGINE);
    if (!ibus_bus_request_name(bus, "org.freedesktop.IBus.Myangler", 0)) {
        g_critical("myangler: failed to request bus name");
    }
}
