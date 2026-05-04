"""History tab — list learned (reading, surface) entries with per-row
delete buttons. Reads/writes UserHistory.sqlite directly; no FFI.
"""

from __future__ import annotations

from gi.repository import Adw, Gtk

from ..history import HistoryEntry, clear_all, list_entries, remove_entry


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

    clear = Gtk.Button(label="Clear all")
    clear.add_css_class("destructive-action")
    clear.set_valign(Gtk.Align.CENTER)
    clear.set_tooltip_text("Forget every learned entry")

    refresh = Gtk.Button(label="Refresh")
    refresh.add_css_class("flat")
    refresh.set_valign(Gtk.Align.CENTER)

    # PreferencesGroup.set_header_suffix takes a single widget, so wrap
    # the two buttons in a horizontal box.
    suffix = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
    suffix.set_halign(Gtk.Align.END)
    suffix.append(clear)
    suffix.append(refresh)
    group.set_header_suffix(suffix)

    page.add(group)

    # Adw.PreferencesGroup wraps added rows in an internal listbox, so
    # `get_first_child()` returns a layout container, not the rows. Track
    # what we added and remove each one via the documented `group.remove()`
    # entry point.
    rows: list[Adw.ActionRow] = []

    def repopulate(_btn=None):
        for row in rows:
            group.remove(row)
        rows.clear()

        entries = list_entries()
        if not entries:
            empty = Adw.ActionRow()
            empty.set_title("No learned entries yet")
            empty.set_subtitle("Pick candidates from the panel; they'll appear here.")
            group.add(empty)
            rows.append(empty)
            return

        for entry in entries:
            def remover(e: HistoryEntry):
                remove_entry(e.reading, e.surface)
                repopulate()
            row = _build_row(entry, remover)
            group.add(row)
            rows.append(row)

    def on_clear(_b):
        dlg = Adw.MessageDialog.new(
            page.get_root(),
            "Clear all learned history?",
            "This forgets every remembered candidate selection. "
            "This cannot be undone.",
        )
        dlg.add_response("cancel", "Cancel")
        dlg.add_response("clear", "Clear all")
        dlg.set_response_appearance("clear", Adw.ResponseAppearance.DESTRUCTIVE)
        dlg.set_default_response("cancel")
        dlg.set_close_response("cancel")

        def handle(_d, response):
            if response == "clear":
                clear_all()
                repopulate()
        dlg.connect("response", handle)
        dlg.present()

    clear.connect("clicked", on_clear)
    refresh.connect("clicked", repopulate)
    repopulate()
    return page
