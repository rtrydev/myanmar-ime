"""AdwApplication subclass — the Preferences app entry point.

Single window per launch; libadwaita auto-follows the system light/dark
theme and accent colour, so we deliberately avoid any inline CSS.
"""

from __future__ import annotations

import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")

from gi.repository import Adw, Gio  # noqa: E402

from .window import MyanglerPreferencesWindow

APP_ID = "com.myangler.inputmethod.burmese.preferences"


class MyanglerPreferencesApp(Adw.Application):
    def __init__(self) -> None:
        super().__init__(application_id=APP_ID,
                         flags=Gio.ApplicationFlags.DEFAULT_FLAGS)

    def do_activate(self) -> None:  # noqa: N802 (GObject vfunc)
        win = self.props.active_window
        if not win:
            win = MyanglerPreferencesWindow(application=self)
        win.present()


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    app = MyanglerPreferencesApp()
    return app.run(argv)
