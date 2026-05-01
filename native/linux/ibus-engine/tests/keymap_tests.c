/* SPDX-License-Identifier: same-as-repo */
#include "../src/keymap.h"

#include <ibus.h>
#include <glib.h>
#include <stdio.h>

static int failures = 0;

#define EXPECT(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); \
        failures++; \
    } \
} while (0)

static void test_typeable(void)
{
    KeymapResult r = keymap_map(IBUS_KEY_a, 0);
    EXPECT(r.action == KEYMAP_TYPEABLE, "lowercase 'a' is typeable");
    EXPECT(r.typed_char == 'a',         "typed_char preserved");

    /* Shift-A still produces lowercase 'a' — engine buffer is always
       lowercased. */
    r = keymap_map(IBUS_KEY_A, IBUS_SHIFT_MASK);
    EXPECT(r.action == KEYMAP_TYPEABLE, "shifted 'A' is typeable");
    EXPECT(r.typed_char == 'a',         "shifted 'A' lowercases to 'a'");
}

static void test_modifiers_pass_through(void)
{
    /* Ctrl-anything: defer to client. */
    KeymapResult r = keymap_map(IBUS_KEY_a, IBUS_CONTROL_MASK);
    EXPECT(r.action == KEYMAP_IGNORE, "Ctrl-A passes through");

    r = keymap_map(IBUS_KEY_a, IBUS_MOD1_MASK);
    EXPECT(r.action == KEYMAP_IGNORE, "Alt-A passes through");
}

static void test_navigation(void)
{
    EXPECT(keymap_map(IBUS_KEY_BackSpace, 0).action == KEYMAP_BACKSPACE,
           "BackSpace");
    EXPECT(keymap_map(IBUS_KEY_Escape, 0).action == KEYMAP_CANCEL,
           "Escape");
    EXPECT(keymap_map(IBUS_KEY_Return, 0).action == KEYMAP_COMMIT,
           "Return commits");
    KeymapResult sp = keymap_map(IBUS_KEY_space, 0);
    EXPECT(sp.action == KEYMAP_COMMIT && sp.is_space,
           "Space commits and flags is_space");
    EXPECT(keymap_map(IBUS_KEY_Up, 0).action == KEYMAP_NAV_UP, "Up");
    EXPECT(keymap_map(IBUS_KEY_Down, 0).action == KEYMAP_NAV_DOWN, "Down");
    EXPECT(keymap_map(IBUS_KEY_Page_Up, 0).action == KEYMAP_NAV_PAGE_UP,
           "PageUp");
    EXPECT(keymap_map(IBUS_KEY_Page_Down, 0).action == KEYMAP_NAV_PAGE_DOWN,
           "PageDown");

    /* Tab → Down, Shift-Tab → Up. */
    EXPECT(keymap_map(IBUS_KEY_Tab, 0).action == KEYMAP_NAV_DOWN,
           "Tab steps down");
    EXPECT(keymap_map(IBUS_KEY_Tab, IBUS_SHIFT_MASK).action == KEYMAP_NAV_UP,
           "Shift-Tab steps up");
}

static void test_punctuation(void)
{
    /* Punctuation in printable ASCII range is typeable. */
    KeymapResult r = keymap_map((guint)'.', 0);
    EXPECT(r.action == KEYMAP_TYPEABLE, "'.' is typeable");
    EXPECT(r.typed_char == '.',         "'.' typed_char");

    r = keymap_map((guint)'+', 0);
    EXPECT(r.action == KEYMAP_TYPEABLE, "'+' is typeable");
    EXPECT(r.typed_char == '+',         "'+' typed_char");
}

int main(void)
{
    test_typeable();
    test_modifiers_pass_through();
    test_navigation();
    test_punctuation();
    if (failures == 0) {
        printf("ALL keymap tests passed\n");
        return 0;
    }
    fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
}
