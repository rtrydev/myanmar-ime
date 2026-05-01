/* SPDX-License-Identifier: same-as-repo */
#ifndef IBUS_MYANGLER_ENGINE_H
#define IBUS_MYANGLER_ENGINE_H

#include <ibus.h>

G_BEGIN_DECLS

#define IBUS_TYPE_MYANGLER_ENGINE (ibus_myangler_engine_get_type())
#define IBUS_MYANGLER_ENGINE(obj) \
    (G_TYPE_CHECK_INSTANCE_CAST((obj), IBUS_TYPE_MYANGLER_ENGINE, IBusMyanglerEngine))
#define IBUS_MYANGLER_ENGINE_CLASS(klass) \
    (G_TYPE_CHECK_CLASS_CAST((klass), IBUS_TYPE_MYANGLER_ENGINE, IBusMyanglerEngineClass))
#define IBUS_IS_MYANGLER_ENGINE(obj) \
    (G_TYPE_CHECK_INSTANCE_TYPE((obj), IBUS_TYPE_MYANGLER_ENGINE))

/*
 * IBusEngine doesn't define G_DEFINE_AUTOPTR_CLEANUP_FUNC, which means
 * G_DECLARE_FINAL_TYPE doesn't compile against it. Declare the type
 * manually instead — same effect, no autoptr machinery.
 */
typedef struct _IBusMyanglerEngine      IBusMyanglerEngine;
typedef struct _IBusMyanglerEngineClass IBusMyanglerEngineClass;

struct _IBusMyanglerEngineClass {
    IBusEngineClass parent;
};

GType ibus_myangler_engine_get_type(void) G_GNUC_CONST;

/* Construct/teardown registered with the IBus factory in main.c. */
void ibus_myangler_engine_register_factory(IBusBus* bus);

G_END_DECLS

#endif /* IBUS_MYANGLER_ENGINE_H */
