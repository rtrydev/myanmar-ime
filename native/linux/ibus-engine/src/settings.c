/* SPDX-License-Identifier: same-as-repo */
#include "settings.h"

#include <string.h>

/*
 * GSettings keys must match the schema XML at
 * data/com.myangler.inputmethod.burmese.gschema.xml. Any drift here is
 * caught at engine startup: opening a non-existent key aborts with a
 * GLib critical, so a typo = immediate visible failure.
 */
#define KEY_PAGE_SIZE         "candidate-page-size"
#define KEY_COMMIT_ON_SPACE   "commit-on-space"
#define KEY_CLUSTER_ALIASES   "cluster-aliases-enabled"
#define KEY_LM_PRUNE_MARGIN   "lm-prune-margin"
#define KEY_ANCHOR_THRESHOLD  "anchor-commit-threshold"
#define KEY_BURMESE_PUNCT     "burmese-punctuation-enabled"
#define KEY_NUMBER_MEASURE    "number-measure-words-enabled"
#define KEY_LEARNING          "learning-enabled"

static void apply_all(GSettings* gs, burmese_engine_t* engine)
{
    burmese_engine_set_candidate_page_size(
        engine, g_settings_get_int(gs, KEY_PAGE_SIZE));
    burmese_engine_set_commit_on_space(
        engine, g_settings_get_boolean(gs, KEY_COMMIT_ON_SPACE) ? 1 : 0);
    burmese_engine_set_cluster_aliases_enabled(
        engine, g_settings_get_boolean(gs, KEY_CLUSTER_ALIASES) ? 1 : 0);
    burmese_engine_set_lm_prune_margin(
        engine, g_settings_get_double(gs, KEY_LM_PRUNE_MARGIN));
    burmese_engine_set_anchor_commit_threshold(
        engine, g_settings_get_int(gs, KEY_ANCHOR_THRESHOLD));
    burmese_engine_set_burmese_punctuation_enabled(
        engine, g_settings_get_boolean(gs, KEY_BURMESE_PUNCT) ? 1 : 0);
    burmese_engine_set_number_measure_words_enabled(
        engine, g_settings_get_boolean(gs, KEY_NUMBER_MEASURE) ? 1 : 0);
    burmese_engine_set_learning_enabled(
        engine, g_settings_get_boolean(gs, KEY_LEARNING) ? 1 : 0);
}

static void on_changed(GSettings* gs, const gchar* key, gpointer user_data)
{
    burmese_engine_t* engine = (burmese_engine_t*)user_data;
    if (!key) {
        apply_all(gs, engine);
        return;
    }
    if (g_strcmp0(key, KEY_PAGE_SIZE) == 0) {
        burmese_engine_set_candidate_page_size(
            engine, g_settings_get_int(gs, key));
    } else if (g_strcmp0(key, KEY_COMMIT_ON_SPACE) == 0) {
        burmese_engine_set_commit_on_space(
            engine, g_settings_get_boolean(gs, key) ? 1 : 0);
    } else if (g_strcmp0(key, KEY_CLUSTER_ALIASES) == 0) {
        /* The Swift FFI rebuilds the parser when this flag flips. */
        burmese_engine_set_cluster_aliases_enabled(
            engine, g_settings_get_boolean(gs, key) ? 1 : 0);
    } else if (g_strcmp0(key, KEY_LM_PRUNE_MARGIN) == 0) {
        burmese_engine_set_lm_prune_margin(
            engine, g_settings_get_double(gs, key));
    } else if (g_strcmp0(key, KEY_ANCHOR_THRESHOLD) == 0) {
        burmese_engine_set_anchor_commit_threshold(
            engine, g_settings_get_int(gs, key));
    } else if (g_strcmp0(key, KEY_BURMESE_PUNCT) == 0) {
        burmese_engine_set_burmese_punctuation_enabled(
            engine, g_settings_get_boolean(gs, key) ? 1 : 0);
    } else if (g_strcmp0(key, KEY_NUMBER_MEASURE) == 0) {
        burmese_engine_set_number_measure_words_enabled(
            engine, g_settings_get_boolean(gs, key) ? 1 : 0);
    } else if (g_strcmp0(key, KEY_LEARNING) == 0) {
        burmese_engine_set_learning_enabled(
            engine, g_settings_get_boolean(gs, key) ? 1 : 0);
    }
}

GSettings* myangler_settings_connect(burmese_engine_t* engine)
{
    GSettingsSchemaSource* source = g_settings_schema_source_get_default();
    GSettingsSchema* schema = source
        ? g_settings_schema_source_lookup(source, MYANGLER_GSCHEMA_ID, TRUE)
        : NULL;
    if (!schema) {
        g_warning("myangler: GSettings schema '%s' not installed; "
                  "running with compiled-in defaults",
                  MYANGLER_GSCHEMA_ID);
        return NULL;
    }
    g_settings_schema_unref(schema);

    GSettings* gs = g_settings_new(MYANGLER_GSCHEMA_ID);
    apply_all(gs, engine);
    g_signal_connect(gs, "changed", G_CALLBACK(on_changed), engine);
    return gs;
}

void myangler_settings_disconnect(GSettings* settings)
{
    if (!settings) return;
    g_signal_handlers_disconnect_by_data(settings, NULL);
    g_object_unref(settings);
}
