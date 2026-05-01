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

static void test_bare_modifier_keys(void)
{
    /* Bare Shift / Ctrl / Alt / Super / Caps presses must report
       KEYMAP_MODIFIER, never KEYMAP_IGNORE — KEYMAP_IGNORE forces
       the engine to commit the buffer, which would break ':' (typed
       as Shift+';'), '+', '?', and every other shift-reachable
       character. */
    EXPECT(keymap_map(IBUS_KEY_Shift_L, 0).action == KEYMAP_MODIFIER,
           "bare Shift_L is a modifier press");
    EXPECT(keymap_map(IBUS_KEY_Shift_R, 0).action == KEYMAP_MODIFIER,
           "bare Shift_R is a modifier press");
    EXPECT(keymap_map(IBUS_KEY_Control_L, 0).action == KEYMAP_MODIFIER,
           "bare Control_L is a modifier press");
    EXPECT(keymap_map(IBUS_KEY_Alt_L, 0).action == KEYMAP_MODIFIER,
           "bare Alt_L is a modifier press");
    EXPECT(keymap_map(IBUS_KEY_Super_L, 0).action == KEYMAP_MODIFIER,
           "bare Super_L is a modifier press");
    EXPECT(keymap_map(IBUS_KEY_Caps_Lock, 0).action == KEYMAP_MODIFIER,
           "Caps_Lock is a modifier press");
    EXPECT(keymap_map(IBUS_KEY_ISO_Level3_Shift, 0).action == KEYMAP_MODIFIER,
           "AltGr (ISO_Level3_Shift) is a modifier press");

    /* The shifted character itself is still typeable — only the
       standalone modifier press is special. */
    KeymapResult colon = keymap_map((guint)':', IBUS_SHIFT_MASK);
    EXPECT(colon.action == KEYMAP_TYPEABLE, "Shift+';' → ':' is typeable");
    EXPECT(colon.typed_char == ':',         "':' typed_char preserved");
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
    test_bare_modifier_keys();
    test_navigation();
    test_punctuation();
    if (failures == 0) {
        printf("ALL keymap tests passed\n");
        return 0;
    }
    fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
}
