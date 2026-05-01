/* SPDX-License-Identifier: same-as-repo */
#include "keymap.h"

#include <ibus.h>
#include <ctype.h>

KeymapResult keymap_map(uint32_t keyval, uint32_t modifiers)
{
    KeymapResult r = { KEYMAP_IGNORE, 0, false };

    /* Defer to the client whenever Ctrl/Alt/Super are involved. The
       macOS controller is similarly conservative: it only handles
       bare shifted/un-shifted keystrokes itself. */
    const uint32_t suppress_mask =
        IBUS_CONTROL_MASK | IBUS_MOD1_MASK | IBUS_SUPER_MASK |
        IBUS_HYPER_MASK | IBUS_META_MASK;
    if (modifiers & suppress_mask) {
        return r;
    }

    /* Bare modifier presses arrive as standalone key events on
       IBus/X11 (unlike AppKit, which folds them into the next
       character event). Treat them as a distinct action so the
       caller doesn't commit a half-typed buffer when the user
       presses Shift to reach ':' or '+'. */
    switch (keyval) {
    case IBUS_KEY_Shift_L:
    case IBUS_KEY_Shift_R:
    case IBUS_KEY_Control_L:
    case IBUS_KEY_Control_R:
    case IBUS_KEY_Caps_Lock:
    case IBUS_KEY_Shift_Lock:
    case IBUS_KEY_Meta_L:
    case IBUS_KEY_Meta_R:
    case IBUS_KEY_Alt_L:
    case IBUS_KEY_Alt_R:
    case IBUS_KEY_Super_L:
    case IBUS_KEY_Super_R:
    case IBUS_KEY_Hyper_L:
    case IBUS_KEY_Hyper_R:
    case IBUS_KEY_ISO_Level3_Shift:
    case IBUS_KEY_ISO_Level5_Shift:
    case IBUS_KEY_Num_Lock:
        r.action = KEYMAP_MODIFIER;
        return r;
    default:
        break;
    }

    switch (keyval) {
    case IBUS_KEY_BackSpace:
        r.action = KEYMAP_BACKSPACE;
        return r;
    case IBUS_KEY_Escape:
        r.action = KEYMAP_CANCEL;
        return r;
    case IBUS_KEY_Return:
    case IBUS_KEY_KP_Enter:
        r.action = KEYMAP_COMMIT;
        return r;
    case IBUS_KEY_space:
        r.action = KEYMAP_COMMIT;
        r.is_space = true;
        return r;
    case IBUS_KEY_Up:
    case IBUS_KEY_KP_Up:
        r.action = KEYMAP_NAV_UP;
        return r;
    case IBUS_KEY_Down:
    case IBUS_KEY_KP_Down:
        r.action = KEYMAP_NAV_DOWN;
        return r;
    case IBUS_KEY_Page_Up:
    case IBUS_KEY_KP_Page_Up:
        r.action = KEYMAP_NAV_PAGE_UP;
        return r;
    case IBUS_KEY_Page_Down:
    case IBUS_KEY_KP_Page_Down:
        r.action = KEYMAP_NAV_PAGE_DOWN;
        return r;
    case IBUS_KEY_Home:
    case IBUS_KEY_KP_Home:
        r.action = KEYMAP_NAV_HOME;
        return r;
    case IBUS_KEY_End:
    case IBUS_KEY_KP_End:
        r.action = KEYMAP_NAV_END;
        return r;
    case IBUS_KEY_Tab:
        /* Mirror macOS: Tab steps the cursor down one row in the
           candidate list (Shift-Tab steps up). */
        r.action = (modifiers & IBUS_SHIFT_MASK)
            ? KEYMAP_NAV_UP : KEYMAP_NAV_DOWN;
        return r;
    default:
        break;
    }

    /* Printable ASCII range: 0x21..0x7E. Lowercase per the engine's
       expectation (composing buffer is always normalized lowercase). */
    if (keyval >= 0x21 && keyval <= 0x7E) {
        r.action = KEYMAP_TYPEABLE;
        r.typed_char = (char)tolower((int)keyval);
        return r;
    }
    return r;
}
