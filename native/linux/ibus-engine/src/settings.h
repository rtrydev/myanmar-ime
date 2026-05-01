/* SPDX-License-Identifier: same-as-repo */
#ifndef IBUS_MYANGLER_SETTINGS_H
#define IBUS_MYANGLER_SETTINGS_H

#include <gio/gio.h>
#include "ffi.h"

#define MYANGLER_GSCHEMA_ID "com.myangler.inputmethod.burmese"

/*
 * Connect a freshly-constructed engine handle to the GSettings schema.
 * Pushes the current values into the engine via the FFI setters and
 * subscribes `changed::*` so subsequent edits propagate live. Returns
 * the GSettings instance (caller owns the ref; pass to
 * `myangler_settings_disconnect` on disable).
 */
GSettings* myangler_settings_connect(burmese_engine_t* engine);

/* Disconnect signal handlers and drop the GSettings reference. */
void myangler_settings_disconnect(GSettings* settings);

#endif /* IBUS_MYANGLER_SETTINGS_H */
