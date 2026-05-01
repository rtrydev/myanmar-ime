/* SPDX-License-Identifier: same-as-repo */
/*
 * ibus-engine-myangler bootstrap.
 *
 * Two run modes selected by argv:
 *   --xml         Print the IBus component descriptor and exit.
 *                 ibus-daemon invokes this once per startup to learn
 *                 about the engine without spawning it.
 *   --ibus        Connect to ibus-daemon and serve key events. This is
 *                 the long-running mode invoked by ibus-daemon when an
 *                 input source switches to "myangler".
 *   (no args)     Same as --ibus.
 *
 * The component XML is checked in at
 *   native/linux/data/myangler.xml
 * and installed to /usr/share/ibus/component/. Printing it from
 * --xml as a fallback lets `ibus-engine-myangler --xml` validate the
 * descriptor matches the binary.
 */

#include <ibus.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "engine.h"
#include "ffi.h"

/* Fallback XML used by --xml when no installed copy is found. Kept in
   sync by hand with data/myangler.xml. */
static const char* kFallbackComponentXML =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<component>\n"
    "  <name>org.freedesktop.IBus.Myangler</name>\n"
    "  <description>Myangler Burmese (Romanized) Input Method</description>\n"
    "  <exec>/usr/lib/ibus-myangler/ibus-engine-myangler --ibus</exec>\n"
    "  <version>0.1.0</version>\n"
    "  <author>rtrydev &lt;r.kulka44@gmail.com&gt;</author>\n"
    "  <license>MIT</license>\n"
    "  <homepage>https://github.com/rtrydev/myanmar-ime</homepage>\n"
    "  <textdomain>ibus-myangler</textdomain>\n"
    "  <engines>\n"
    "    <engine>\n"
    "      <name>myangler</name>\n"
    "      <longname>Myangler (Burmese, Romanized)</longname>\n"
    "      <description>Romanized Burmese input</description>\n"
    "      <language>my</language>\n"
    "      <license>MIT</license>\n"
    "      <author>rtrydev &lt;r.kulka44@gmail.com&gt;</author>\n"
    "      <icon>myangler</icon>\n"
    "      <layout>us</layout>\n"
    "      <rank>50</rank>\n"
    "      <symbol>က</symbol>\n"
    "    </engine>\n"
    "  </engines>\n"
    "</component>\n";

static int run_xml_mode(void)
{
    /* Prefer the installed XML (path resolved at runtime so packagers
       can override). */
    const gchar* candidates[] = {
        "/usr/share/ibus/component/myangler.xml",
        "/usr/local/share/ibus/component/myangler.xml",
        NULL,
    };
    for (int i = 0; candidates[i]; ++i) {
        gchar* contents = NULL;
        gsize len = 0;
        if (g_file_get_contents(candidates[i], &contents, &len, NULL)) {
            fwrite(contents, 1, len, stdout);
            g_free(contents);
            return 0;
        }
    }
    fputs(kFallbackComponentXML, stdout);
    return 0;
}

/* Locate the bundled data files. Mirrors engine.c's resolve_data_file. */
static gchar* find_data_file(const char* basename)
{
    const gchar* env = g_getenv("MYANGLER_DATA_DIR");
    const gchar* candidates[] = {
        env, "/usr/share/myangler", "/usr/local/share/myangler", NULL,
    };
    for (int i = 0; candidates[i]; ++i) {
        gchar* path = g_build_filename(candidates[i], basename, NULL);
        if (g_file_test(path, G_FILE_TEST_EXISTS)) return path;
        g_free(path);
    }
    return NULL;
}

static int run_diagnostics_mode(void)
{
    gchar* lexicon = find_data_file("BurmeseLexicon.sqlite");
    gchar* lm      = find_data_file("BurmeseLM.bin");
    gchar* history = g_build_filename(g_get_user_data_dir(),
                                       "myangler", "UserHistory.sqlite", NULL);

    burmese_engine_t* eng = burmese_engine_new(lexicon, lm, history, NULL);
    if (!eng) {
        fputs("{\"error\":\"engine init failed\"}\n", stderr);
        g_free(lexicon); g_free(lm); g_free(history);
        return 1;
    }
    char* json = burmese_engine_diagnostics(eng);
    if (json) {
        fputs(json, stdout);
        fputc('\n', stdout);
        burmese_engine_string_free(json);
    }
    burmese_engine_free(eng);
    g_free(lexicon); g_free(lm); g_free(history);
    return 0;
}

static int run_reverse_romanize_mode(int argc, char** argv, int start_idx)
{
    /* Read either from argv tail or stdin. argv tail: each arg is one
       Myanmar string; results are emitted one per line. Stdin: read
       whole input, emit single result. */
    if (start_idx < argc) {
        for (int i = start_idx; i < argc; ++i) {
            char* out = burmese_engine_reverse_romanize(argv[i]);
            if (out) {
                fputs(out, stdout);
                fputc('\n', stdout);
                burmese_engine_string_free(out);
            }
        }
    } else {
        gchar* contents = NULL;
        gsize len = 0;
        GError* err = NULL;
        if (!g_file_get_contents("/dev/stdin", &contents, &len, &err)) {
            fprintf(stderr, "read stdin: %s\n", err ? err->message : "?");
            if (err) g_error_free(err);
            return 1;
        }
        /* Strip trailing newline. */
        while (len > 0 && (contents[len-1] == '\n' || contents[len-1] == '\r')) {
            contents[--len] = 0;
        }
        char* out = burmese_engine_reverse_romanize(contents);
        if (out) {
            fputs(out, stdout);
            fputc('\n', stdout);
            burmese_engine_string_free(out);
        }
        g_free(contents);
    }
    return 0;
}

static int run_ibus_mode(gboolean by_ibus)
{
    ibus_init();
    IBusBus* bus = ibus_bus_new();
    if (!ibus_bus_is_connected(bus)) {
        g_critical("myangler: cannot connect to ibus-daemon");
        return 1;
    }
    g_signal_connect(bus, "disconnected",
                     G_CALLBACK(ibus_quit), NULL);
    ibus_myangler_engine_register_factory(bus);
    (void)by_ibus;
    ibus_main();
    return 0;
}

int main(int argc, char** argv)
{
    gboolean want_xml = FALSE;
    gboolean by_ibus = FALSE;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--xml") == 0) {
            want_xml = TRUE;
        } else if (strcmp(argv[i], "--ibus") == 0 ||
                   strcmp(argv[i], "-i") == 0) {
            by_ibus = TRUE;
        } else if (strcmp(argv[i], "--diagnostics") == 0) {
            return run_diagnostics_mode();
        } else if (strcmp(argv[i], "--reverse-romanize") == 0) {
            return run_reverse_romanize_mode(argc, argv, i + 1);
        } else if (strcmp(argv[i], "--version") == 0 ||
                   strcmp(argv[i], "-v") == 0) {
            puts("ibus-engine-myangler 0.1.0");
            return 0;
        } else if (strcmp(argv[i], "--help") == 0 ||
                   strcmp(argv[i], "-h") == 0) {
            puts("Usage: ibus-engine-myangler [--xml | --ibus | --diagnostics |\n"
                 "                              --reverse-romanize [text...] | --version]");
            return 0;
        } else {
            fprintf(stderr, "ibus-engine-myangler: unknown argument '%s'\n",
                    argv[i]);
            return 64;
        }
    }
    if (want_xml) return run_xml_mode();
    return run_ibus_mode(by_ibus);
}
