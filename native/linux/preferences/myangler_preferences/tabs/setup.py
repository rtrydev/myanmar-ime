"""Setup tab — onboarding instructions for first-run users."""

from __future__ import annotations

from gi.repository import Adw, Gio, Gtk


_STEPS = [
    "Open Settings → Region & Language → Manage Installed Languages.",
    "In the Input Sources panel, click + and choose Burmese (Myanmar).",
    "Pick \"Myangler (Burmese, Romanized)\" from the list.",
    "Use Super+Space (or your configured shortcut) to switch input sources.",
    "Type Burmese romanization and pick from the candidate panel.",
]


def _open_region_panel(_button) -> None:
    # gnome-control-center is a Recommends in debian/control. If absent
    # the button is a no-op — better than crashing.
    try:
        Gio.Subprocess.new(
            ["gnome-control-center", "region"],
            Gio.SubprocessFlags.NONE,
        )
    except Exception:
        # Try KDE's settings as a fallback. Either or neither may exist.
        try:
            Gio.Subprocess.new(
                ["systemsettings", "kcm_keyboard"],
                Gio.SubprocessFlags.NONE,
            )
        except Exception:
            pass


def build_setup_page() -> Gtk.Widget:
    page = Adw.PreferencesPage()
    page.set_title("Setup")

    intro = Adw.PreferencesGroup()
    intro.set_title("Getting started")
    intro.set_description(
        "Myangler is a romanized Burmese input method. Each step "
        "below is required once after installing the package."
    )
    page.add(intro)

    steps = Adw.PreferencesGroup()
    for i, text in enumerate(_STEPS, start=1):
        row = Adw.ActionRow()
        # Adw.PreferencesRow.title is Pango-markup by default. Step 1
        # contains "Region & Language" — a bare ampersand crashes the
        # markup parser and the row renders empty. Disabling markup
        # makes the title plain text and is also defensive against
        # future steps containing <, >, or quotes.
        row.set_use_markup(False)
        row.set_title(f"{i}. {text}")
        steps.add(row)
    page.add(steps)

    actions = Adw.PreferencesGroup()
    open_btn = Gtk.Button(label="Open Region & Language Settings")
    open_btn.set_halign(Gtk.Align.START)
    open_btn.add_css_class("suggested-action")
    open_btn.connect("clicked", _open_region_panel)
    actions.add(open_btn)
    page.add(actions)

    return page
