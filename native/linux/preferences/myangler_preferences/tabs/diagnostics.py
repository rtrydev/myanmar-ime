"""Diagnostics tab — version, file paths/sizes, IBus status.

Calls `ibus-engine-myangler --diagnostics` and renders the JSON
result. The path is resolved at runtime so a dev-install tree is
recognised when /usr/lib isn't populated yet.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess

from gi.repository import Adw, Gtk

ENGINE_BINARY_CANDIDATES = (
    "/usr/lib/ibus-myangler/ibus-engine-myangler",
    "/usr/local/lib/ibus-myangler/ibus-engine-myangler",
    os.path.expanduser("~/.local/lib/ibus-myangler/ibus-engine-myangler"),
)


def _resolve_engine() -> str | None:
    env_override = os.environ.get("MYANGLER_ENGINE_BIN")
    candidates = (env_override,) + ENGINE_BINARY_CANDIDATES
    for path in candidates:
        if path and os.access(path, os.X_OK):
            return path
    return shutil.which("ibus-engine-myangler")


def _format_bytes(n: int) -> str:
    if n <= 0:
        return "—"
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024:
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024
    return f"{n:.1f} TiB"


def _read_diagnostics() -> dict:
    binary = _resolve_engine()
    if not binary:
        return {"error": "engine binary not found"}
    try:
        proc = subprocess.run(
            [binary, "--diagnostics"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"error": f"engine call failed: {exc}"}
    if proc.returncode != 0:
        return {"error": proc.stderr.strip() or "engine returned non-zero"}
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        return {"error": f"invalid JSON: {exc}"}


def build_diagnostics_page() -> Gtk.Widget:
    page = Adw.PreferencesPage()
    page.set_title("Diagnostics")

    info_group = Adw.PreferencesGroup()
    info_group.set_title("Engine")
    page.add(info_group)

    files_group = Adw.PreferencesGroup()
    files_group.set_title("Resources")
    page.add(files_group)

    refresh_btn = Gtk.Button(label="Refresh")
    refresh_btn.set_halign(Gtk.Align.END)
    refresh_btn.add_css_class("flat")
    info_group.set_header_suffix(refresh_btn)

    def populate(_btn=None):
        # Clear old rows
        for group in (info_group, files_group):
            child = group.get_first_child()
            while child:
                next_child = child.get_next_sibling()
                # Only remove ActionRows; keep header_suffix etc.
                if isinstance(child, Adw.ActionRow):
                    group.remove(child)
                child = next_child

        diag = _read_diagnostics()
        if "error" in diag:
            row = Adw.ActionRow()
            row.set_title("Error")
            row.set_subtitle(diag["error"])
            info_group.add(row)
            return

        version_row = Adw.ActionRow()
        version_row.set_title("Engine version")
        version_row.set_subtitle(diag.get("version", "—"))
        info_group.add(version_row)

        for label, path_key, size_key in [
            ("Lexicon", "lexicon_path", "lexicon_bytes"),
            ("Trigram LM", "lm_path", "lm_bytes"),
            ("User history", "history_path", "history_bytes"),
        ]:
            row = Adw.ActionRow()
            row.set_title(label)
            path = diag.get(path_key) or "(not bundled)"
            size = int(diag.get(size_key) or 0)
            row.set_subtitle(f"{path}\n{_format_bytes(size)}")
            files_group.add(row)

    refresh_btn.connect("clicked", populate)
    populate()
    return page
