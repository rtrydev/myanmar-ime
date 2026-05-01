/* SPDX-License-Identifier: same-as-repo */
#ifndef IBUS_MYANGLER_KEYMAP_H
#define IBUS_MYANGLER_KEYMAP_H

#include <stdint.h>
#include <stdbool.h>

/*
 * Outcome of mapping an IBus keysym + modifier mask to engine action.
 * Mirrors the switch in
 * native/macos/BurmeseIME/BurmeseInputController.swift line 106 forward
 * — keep the two in sync when adding new key shapes.
 */
typedef enum {
    KEYMAP_IGNORE,           /* Pass through to the client unmodified. */
    KEYMAP_MODIFIER,         /* Bare modifier press (Shift, Ctrl, …). Pass
                                through, but unlike KEYMAP_IGNORE the
                                caller must NOT commit the buffer — the
                                user is mid-chord (e.g. Shift before ':'). */
    KEYMAP_TYPEABLE,         /* Append `typed_char` to the buffer. */
    KEYMAP_BACKSPACE,        /* Shrink the buffer by one char. */
    KEYMAP_COMMIT,           /* Commit selected candidate (Space, Return). */
    KEYMAP_CANCEL,           /* Drop the buffer back as raw Latin (Escape). */
    KEYMAP_NAV_UP,
    KEYMAP_NAV_DOWN,
    KEYMAP_NAV_PAGE_UP,
    KEYMAP_NAV_PAGE_DOWN,
    KEYMAP_NAV_HOME,
    KEYMAP_NAV_END,
} KeymapAction;

typedef struct {
    KeymapAction action;
    /* Valid only when action == KEYMAP_TYPEABLE; lowercased ASCII. */
    char typed_char;
    /* True when the key was pressed with Space or Return (used by the
       caller to decide whether to fall through to client when buffer
       empty). */
    bool is_space;
} KeymapResult;

/*
 * Pure function. `keyval` is an IBus keysym (e.g. IBUS_KEY_a, 0x61).
 * `modifiers` is the IBusModifierType mask. The function ignores the
 * key entirely (returns IGNORE) when Ctrl or Alt are held, so user
 * shortcuts stay untouched — this matches the macOS controller, which
 * defers to AppKit for command-modified keys.
 */
KeymapResult keymap_map(uint32_t keyval, uint32_t modifiers);

#endif /* IBUS_MYANGLER_KEYMAP_H */
