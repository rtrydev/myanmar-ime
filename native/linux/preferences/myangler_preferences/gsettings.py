"""Thin wrapper around `Gio.Settings` so the rest of the app gets an
explicit list of writable keys + a single place to change the schema
ID. Mirrors `IMESettings.Key` in BurmeseIMECore.
"""

from __future__ import annotations

from gi.repository import Gio

SCHEMA_ID = "com.myangler.inputmethod.burmese"

# Section grouping mirrors macOS IMESettings.Section.
INPUT_BEHAVIOR_KEYS = (
    "candidate-page-size",
    "commit-on-space",
    "cluster-aliases-enabled",
)
CANDIDATE_RANKING_KEYS = (
    "lm-prune-margin",
    "anchor-commit-threshold",
)
TEXT_OUTPUT_KEYS = (
    "burmese-punctuation-enabled",
    "number-measure-words-enabled",
)
LEARNING_KEYS = (
    "learning-enabled",
)


def open_settings() -> Gio.Settings:
    """Open the schema or raise GLib.Error if it isn't installed."""
    return Gio.Settings.new(SCHEMA_ID)


def reset_section(settings: Gio.Settings, keys: tuple[str, ...]) -> None:
    """Reset every key in `keys` to its compiled-in default."""
    for key in keys:
        settings.reset(key)
