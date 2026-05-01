"""Preferences tab — toggles, sliders, and the candidate-page-size
picker. Each control is bound bidirectionally to GSettings via
`Gio.Settings.bind`, so a value change on either side propagates
without an explicit save step.
"""

from __future__ import annotations

from gi.repository import Adw, Gio, Gtk

from ..gsettings import (
    SCHEMA_ID,
    INPUT_BEHAVIOR_KEYS,
    CANDIDATE_RANKING_KEYS,
    TEXT_OUTPUT_KEYS,
    LEARNING_KEYS,
    open_settings,
    reset_section,
)


def _bind_switch(settings: Gio.Settings, key: str, switch_row: Adw.SwitchRow) -> None:
    settings.bind(key, switch_row, "active", Gio.SettingsBindFlags.DEFAULT)


def _bind_spin(settings: Gio.Settings, key: str, spin_row: Adw.SpinRow) -> None:
    settings.bind(key, spin_row, "value", Gio.SettingsBindFlags.DEFAULT)


def _build_input_behavior(settings: Gio.Settings) -> Adw.PreferencesGroup:
    group = Adw.PreferencesGroup()
    group.set_title("Input behavior")

    page_size = Adw.SpinRow.new_with_range(3, 12, 1)
    page_size.set_title("Candidate panel page size")
    page_size.set_subtitle("Recommended: 9. Picker accepts 3–12.")
    _bind_spin(settings, "candidate-page-size", page_size)
    group.add(page_size)

    commit_on_space = Adw.SwitchRow()
    commit_on_space.set_title("Commit on space")
    commit_on_space.set_subtitle(
        "When on, Spacebar commits the highlighted candidate; when off, "
        "Spacebar inserts a literal space and you commit with Return."
    )
    _bind_switch(settings, "commit-on-space", commit_on_space)
    group.add(commit_on_space)

    cluster_aliases = Adw.SwitchRow()
    cluster_aliases.set_title("Enable cluster-sound shortcuts")
    cluster_aliases.set_subtitle("j → ky, ch → kj, gy → ky+s, sh → shy.")
    _bind_switch(settings, "cluster-aliases-enabled", cluster_aliases)
    group.add(cluster_aliases)

    restore = Gtk.Button(label="Restore defaults")
    restore.set_halign(Gtk.Align.END)
    restore.add_css_class("flat")
    restore.connect("clicked",
                    lambda _b: reset_section(settings, INPUT_BEHAVIOR_KEYS))
    group.set_header_suffix(restore)
    return group


def _build_candidate_ranking(settings: Gio.Settings) -> Adw.PreferencesGroup:
    group = Adw.PreferencesGroup()
    group.set_title("Candidate ranking")

    lm_margin = Adw.SpinRow.new_with_range(0.0, 16.0, 0.5)
    lm_margin.set_digits(1)
    lm_margin.set_title("LM prune margin")
    lm_margin.set_subtitle(
        "Maximum log-probability gap a candidate may trail the top "
        "candidate before being dropped (in nats)."
    )
    _bind_spin(settings, "lm-prune-margin", lm_margin)
    group.add(lm_margin)

    anchor = Adw.SpinRow.new_with_range(4, 16, 1)
    anchor.set_title("Anchor commit threshold")
    anchor.set_subtitle(
        "Roman buffer length past which a chosen anchor stops being "
        "re-ranked. Higher = more stable composition."
    )
    _bind_spin(settings, "anchor-commit-threshold", anchor)
    group.add(anchor)

    restore = Gtk.Button(label="Restore defaults")
    restore.set_halign(Gtk.Align.END)
    restore.add_css_class("flat")
    restore.connect("clicked",
                    lambda _b: reset_section(settings, CANDIDATE_RANKING_KEYS))
    group.set_header_suffix(restore)
    return group


def _build_text_output(settings: Gio.Settings) -> Adw.PreferencesGroup:
    group = Adw.PreferencesGroup()
    group.set_title("Text output")

    punct = Adw.SwitchRow()
    punct.set_title("Burmese punctuation auto-mapping")
    punct.set_subtitle(
        "Replaces trailing ASCII . , ! ? ; with Myanmar ။ ၊ after Burmese text."
    )
    _bind_switch(settings, "burmese-punctuation-enabled", punct)
    group.add(punct)

    measure = Adw.SwitchRow()
    measure.set_title("Suggest measure words after numbers")
    measure.set_subtitle(
        "Adds candidates like ၂၀၂၄ ခုနှစ် alongside plain digit output."
    )
    _bind_switch(settings, "number-measure-words-enabled", measure)
    group.add(measure)

    restore = Gtk.Button(label="Restore defaults")
    restore.set_halign(Gtk.Align.END)
    restore.add_css_class("flat")
    restore.connect("clicked",
                    lambda _b: reset_section(settings, TEXT_OUTPUT_KEYS))
    group.set_header_suffix(restore)
    return group


def _build_learning(settings: Gio.Settings, page: Adw.PreferencesPage) -> Adw.PreferencesGroup:
    group = Adw.PreferencesGroup()
    group.set_title("Learning")

    learning = Adw.SwitchRow()
    learning.set_title("Enable learning")
    learning.set_subtitle(
        "Records committed candidates so they rank higher next time. "
        "Off disables both reads and writes."
    )
    _bind_switch(settings, "learning-enabled", learning)
    group.add(learning)

    reset_row = Adw.ActionRow()
    reset_row.set_title("Reset learned history")
    reset_row.set_subtitle(
        "Clears every remembered selection. This cannot be undone."
    )
    reset_btn = Gtk.Button(label="Reset…")
    reset_btn.add_css_class("destructive-action")
    reset_btn.set_valign(Gtk.Align.CENTER)

    def on_reset(_b):
        from ..history import clear_all
        dlg = Adw.MessageDialog.new(
            page.get_root(),
            "Reset learned history?",
            "This clears every remembered candidate selection. This cannot "
            "be undone."
        )
        dlg.add_response("cancel", "Cancel")
        dlg.add_response("reset", "Reset")
        dlg.set_response_appearance("reset", Adw.ResponseAppearance.DESTRUCTIVE)
        dlg.set_default_response("cancel")
        dlg.set_close_response("cancel")

        def handle(_d, response):
            if response == "reset":
                clear_all()
        dlg.connect("response", handle)
        dlg.present()

    reset_btn.connect("clicked", on_reset)
    reset_row.add_suffix(reset_btn)
    group.add(reset_row)

    restore = Gtk.Button(label="Restore defaults")
    restore.set_halign(Gtk.Align.END)
    restore.add_css_class("flat")
    restore.connect("clicked",
                    lambda _b: reset_section(settings, LEARNING_KEYS))
    group.set_header_suffix(restore)
    return group


def build_preferences_page() -> Gtk.Widget:
    page = Adw.PreferencesPage()
    page.set_title("Preferences")

    try:
        settings = open_settings()
    except Exception as exc:  # noqa: BLE001
        # Schema not installed: render a placeholder so the user gets a
        # readable error instead of a crash.
        page.add(_build_missing_schema_group(str(exc)))
        return page

    page.add(_build_input_behavior(settings))
    page.add(_build_candidate_ranking(settings))
    page.add(_build_text_output(settings))
    page.add(_build_learning(settings, page))
    return page


def _build_missing_schema_group(message: str) -> Adw.PreferencesGroup:
    group = Adw.PreferencesGroup()
    group.set_title("GSettings schema not installed")
    row = Adw.ActionRow()
    row.set_title(f"Schema {SCHEMA_ID} could not be opened")
    row.set_subtitle(message)
    group.add(row)
    return group
