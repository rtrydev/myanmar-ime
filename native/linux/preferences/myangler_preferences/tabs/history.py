"""History tab — list learned (reading, surface) entries with per-row
delete buttons. Reads/writes UserHistory.sqlite directly; no FFI.
"""

from __future__ import annotations

from gi.repository import Adw, Gtk

from ..history import HistoryEntry, list_entries, remove_entry


def _build_row(entry: HistoryEntry, on_remove) -> Adw.ActionRow:
    row = Adw.ActionRow()
    # History rows surface user data straight from UserHistory.sqlite.
    # Adw treats title/subtitle as Pango markup by default; an entry
    # containing `&` or `<` would silently render empty.
    row.set_use_markup(False)
    row.set_title(entry.surface)
    row.set_subtitle(f"{entry.reading} · ×{entry.count}")

    btn = Gtk.Button()
    btn.set_icon_name("edit-delete-symbolic")
    btn.set_valign(Gtk.Align.CENTER)
    btn.add_css_class("flat")
    btn.set_tooltip_text("Forget this entry")
    btn.connect("clicked", lambda _b: on_remove(entry))
    row.add_suffix(btn)
    return row


def build_history_page() -> Gtk.Widget:
    page = Adw.PreferencesPage()
    page.set_title("History")

    group = Adw.PreferencesGroup()
    group.set_title("Learned entries")
    group.set_description(
        "Selections the IME has remembered. Removing one stops it from "
        "ranking above other candidates for the same input."
    )

    refresh = Gtk.Button(label="Refresh")
    refresh.set_halign(Gtk.Align.END)
    refresh.add_css_class("flat")
    group.set_header_suffix(refresh)

    page.add(group)

    def repopulate(_btn=None):
        # Clear existing rows
        child = group.get_first_child()
        while child:
            next_child = child.get_next_sibling()
            if isinstance(child, Adw.ActionRow):
                group.remove(child)
            child = next_child

        entries = list_entries()
        if not entries:
            empty = Adw.ActionRow()
            empty.set_title("No learned entries yet")
            empty.set_subtitle("Pick candidates from the panel; they'll appear here.")
            group.add(empty)
            return

        for entry in entries:
            def remover(e: HistoryEntry):
                remove_entry(e.reading, e.surface)
                repopulate()
            group.add(_build_row(entry, remover))

    refresh.connect("clicked", repopulate)
    repopulate()
    return page
