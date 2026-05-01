"""Convert tab — Myanmar text → romanized input. Mirrors the macOS
MyanmarToInputView.

Spawns the engine binary with `--reverse-romanize` and pipes the input
in. Could call the FFI directly via ctypes, but subprocess keeps the
GUI process free of the Swift runtime — startup is ~30 ms, fine for
on-demand conversion.
"""

from __future__ import annotations

import os
import shutil
import subprocess

from gi.repository import Adw, GLib, Gtk

from .diagnostics import _resolve_engine  # path resolution shared


def _convert(myanmar: str) -> str:
    if not myanmar:
        return ""
    binary = _resolve_engine()
    if not binary:
        return "(engine binary not found)"
    try:
        proc = subprocess.run(
            [binary, "--reverse-romanize", myanmar],
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return f"(convert failed: {exc})"
    return proc.stdout.strip() or "(no output)"


def build_convert_page() -> Gtk.Widget:
    page = Adw.PreferencesPage()
    page.set_title("Convert")

    intro = Adw.PreferencesGroup()
    intro.set_title("Myanmar → input")
    intro.set_description(
        "Paste Myanmar text on the left and the equivalent romanized "
        "input appears on the right. Useful for figuring out how to "
        "type a word you've seen elsewhere."
    )
    page.add(intro)

    box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12,
                  margin_start=12, margin_end=12, margin_bottom=12)

    left_scroll = Gtk.ScrolledWindow()
    left_scroll.set_min_content_height(180)
    left_scroll.set_hexpand(True)
    left_view = Gtk.TextView()
    left_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
    left_view.set_top_margin(8)
    left_view.set_bottom_margin(8)
    left_view.set_left_margin(8)
    left_view.set_right_margin(8)
    left_scroll.set_child(left_view)
    box.append(left_scroll)

    right_scroll = Gtk.ScrolledWindow()
    right_scroll.set_min_content_height(180)
    right_scroll.set_hexpand(True)
    right_view = Gtk.TextView()
    right_view.set_editable(False)
    right_view.set_monospace(True)
    right_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
    right_view.set_top_margin(8)
    right_view.set_bottom_margin(8)
    right_view.set_left_margin(8)
    right_view.set_right_margin(8)
    right_scroll.set_child(right_view)
    box.append(right_scroll)

    # Debounce conversions so we don't spawn a subprocess per keystroke.
    pending_handle = {"id": 0}

    def schedule_convert(_buffer):
        if pending_handle["id"]:
            GLib.source_remove(pending_handle["id"])
        pending_handle["id"] = GLib.timeout_add(220, run_convert)

    def run_convert():
        pending_handle["id"] = 0
        buffer = left_view.get_buffer()
        text = buffer.get_text(buffer.get_start_iter(),
                               buffer.get_end_iter(), False)
        right_view.get_buffer().set_text(_convert(text))
        return False

    left_view.get_buffer().connect("changed", schedule_convert)

    wrapper = Adw.PreferencesGroup()
    wrapper.add(box)
    page.add(wrapper)
    return page
