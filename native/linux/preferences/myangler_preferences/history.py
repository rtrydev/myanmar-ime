"""Direct sqlite3 access to ~/.local/share/myangler/UserHistory.sqlite.

Uses Python's stdlib instead of the FFI: this is read-mostly UI, the
schema is documented (see SQLiteUserHistoryStore.swift), and avoiding
the FFI keeps the GUI process free of the Swift runtime.
"""

from __future__ import annotations

import os
import sqlite3
from dataclasses import dataclass
from typing import Iterator


def history_db_path() -> str:
    base = os.environ.get("XDG_DATA_HOME") \
        or os.path.expanduser("~/.local/share")
    return os.path.join(base, "myangler", "UserHistory.sqlite")


@dataclass(frozen=True)
class HistoryEntry:
    reading: str
    surface: str
    count: int
    last_picked_at: float


def list_entries() -> list[HistoryEntry]:
    path = history_db_path()
    if not os.path.exists(path):
        return []
    conn = sqlite3.connect(path)
    try:
        rows = conn.execute(
            "SELECT reading, surface, count, last_picked_at "
            "FROM selections ORDER BY last_picked_at DESC"
        ).fetchall()
    except sqlite3.DatabaseError:
        # Schema mismatch (no selections table yet): treat as empty.
        return []
    finally:
        conn.close()
    return [HistoryEntry(r[0], r[1], int(r[2]), float(r[3])) for r in rows]


def remove_entry(reading: str, surface: str) -> None:
    path = history_db_path()
    if not os.path.exists(path):
        return
    conn = sqlite3.connect(path)
    try:
        conn.execute(
            "DELETE FROM selections WHERE reading = ? AND surface = ?",
            (reading, surface),
        )
        conn.commit()
    finally:
        conn.close()


def clear_all() -> None:
    path = history_db_path()
    if not os.path.exists(path):
        return
    conn = sqlite3.connect(path)
    try:
        conn.execute("DELETE FROM selections")
        conn.commit()
    finally:
        conn.close()


def iter_paged(page_size: int = 200) -> Iterator[list[HistoryEntry]]:
    """Generator that returns entries in `page_size` chunks. Used by
    the history table when the DB is large; the UI binds this to a
    Gtk.ListView model so scrolling stays responsive."""
    entries = list_entries()
    for i in range(0, len(entries), page_size):
        yield entries[i:i + page_size]
