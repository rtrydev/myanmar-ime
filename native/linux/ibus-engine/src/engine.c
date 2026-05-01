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
 */
struct _IBusMyanglerEngine {
    IBusEngine parent;

    burmese_engine_t* handle;
    GSettings* settings;

    /* Roman composition buffer (lowercased, ASCII-only). Owned. */
    GString* buffer;

    /* Most recent JSON snapshot from the FFI. Owned. The candidate
       array is rebuilt on every keystroke; we cache it here so cursor
       moves don't need a re-parse. */
    JsonNode* last_snapshot;
    int last_candidate_count;

    /* IBus surfaces. Owned by the parent class once installed; we hold
       weak refs for refresh. */
    IBusLookupTable* lookup_table;

    /* Compose / Roman toggle (in-engine bypass). When FALSE, every
       printable character is committed verbatim instead of going into
       the buffer — matches the macOS Compose/Roman menubar toggle. */
    gboolean compose_enabled;
    IBusProperty* compose_property;
    IBusPropList* prop_list;
};

G_DEFINE_TYPE(IBusMyanglerEngine, ibus_myangler_engine, IBUS_TYPE_ENGINE)

/* ------------------------------------------------------------------ */
/* Resource path resolution                                            */
/* ------------------------------------------------------------------ */

/* Pick the first existing path from the candidate list, or NULL. */
static gchar* resolve_data_file(const char* basename)
{
    const gchar* env = g_getenv("MYANGLER_DATA_DIR");
    const gchar* candidates[] = {
        env,
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
}

static void render_from_snapshot(IBusMyanglerEngine* self, const char* json_str)
{
    clear_snapshot(self);
    if (!json_str || !*json_str) return;

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

    /* Snapshot survives the parser; copy it. */
    self->last_snapshot = json_node_copy(root);
    g_object_unref(parser);

    JsonObject* obj = json_node_get_object(self->last_snapshot);
    const gchar* preedit = json_object_has_member(obj, "preedit")
        ? json_object_get_string_member(obj, "preedit") : "";
    JsonArray* candidates = json_object_has_member(obj, "candidates")
        ? json_object_get_array_member(obj, "candidates") : NULL;
    int selected = json_object_has_member(obj, "selected")
        ? (int)json_object_get_int_member(obj, "selected") : 0;
    self->last_candidate_count =
        candidates ? (int)json_array_get_length(candidates) : 0;

    /* Update preedit */
    {
        IBusText* text = ibus_text_new_from_string(preedit ? preedit : "");
        ibus_text_append_attribute(text, IBUS_ATTR_TYPE_UNDERLINE,
                                   IBUS_ATTR_UNDERLINE_SINGLE,
                                   0, -1);
        gboolean visible = (preedit && *preedit);
        ibus_engine_update_preedit_text(IBUS_ENGINE(self),
                                        text,
                                        visible ? g_utf8_strlen(preedit, -1) : 0,
                                        visible);
    }

    /* Update lookup table */
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
}

static void clear_ime_state(IBusMyanglerEngine* self)
{
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

static void push_buffer_to_engine(IBusMyanglerEngine* self)
{
    if (!self->handle) return;
    char* json = burmese_engine_update(self->handle, self->buffer->str);
    if (!json) return;
    render_from_snapshot(self, json);
    burmese_engine_string_free(json);
}

/* ------------------------------------------------------------------ */
/* Commit + cancel                                                     */
/* ------------------------------------------------------------------ */

static void commit_selected(IBusMyanglerEngine* self)
{
    if (!self->handle) return;
    /* Sync the selection cursor back to the engine before committing —
       arrow keys edit the IBus lookup-table cursor only, the Swift
       side hasn't seen the move yet. */
    int idx = (int)ibus_lookup_table_get_cursor_pos(self->lookup_table);
    burmese_engine_set_selected(self->handle, (int32_t)idx);

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
           non-NULL return. */
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
        push_buffer_to_engine(self);
        return TRUE;
    }
    case KEYMAP_BACKSPACE: {
        if (self->buffer->len == 0) return FALSE;
        g_string_truncate(self->buffer, self->buffer->len - 1);
        push_buffer_to_engine(self);
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
       drops it on focus_out → focus_in. */
    if (self->buffer->len > 0) {
        push_buffer_to_engine(self);
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
    if (self->handle) {
        burmese_engine_free(self->handle);
        self->handle = NULL;
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
}

static void ibus_myangler_engine_finalize(GObject* object)
{
    IBusMyanglerEngine* self = IBUS_MYANGLER_ENGINE(object);
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
