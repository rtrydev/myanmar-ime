"""Main window: AdwApplicationWindow with an AdwViewSwitcher tab bar.
Tabs mirror the macOS Preferences app sections.
"""

from __future__ import annotations

from gi.repository import Adw, Gtk

from .tabs.setup import build_setup_page
from .tabs.preferences import build_preferences_page
from .tabs.diagnostics import build_diagnostics_page
from .tabs.convert import build_convert_page
from .tabs.history import build_history_page


class MyanglerPreferencesWindow(Adw.ApplicationWindow):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.set_title("Myangler Preferences")
        self.set_default_size(720, 720)

        toolbar = Adw.ToolbarView()
        header = Adw.HeaderBar()
        switcher_title = Adw.ViewSwitcherTitle()
        header.set_title_widget(switcher_title)
        toolbar.add_top_bar(header)

        view_stack = Adw.ViewStack()
        view_stack.set_vexpand(True)
        switcher_title.set_stack(view_stack)

        # AdwViewSwitcher draws each tab as icon-above-title; without an
        # icon name the switcher falls back to the "missing image"
        # placeholder. Use freedesktop symbolic names that ship in
        # adwaita-icon-theme on every GNOME install.
        for child, name, title, icon in (
            (build_setup_page(),       "setup",       "Setup",       "go-home-symbolic"),
            (build_preferences_page(), "preferences", "Preferences", "preferences-system-symbolic"),
            (build_history_page(),     "history",     "History",     "document-open-recent-symbolic"),
            (build_convert_page(),     "convert",     "Convert",     "edit-find-replace-symbolic"),
            (build_diagnostics_page(), "diagnostics", "Diagnostics", "dialog-information-symbolic"),
        ):
            view_stack.add_titled_with_icon(child, name, title, icon)

        toolbar.set_content(view_stack)
        self.set_content(toolbar)
