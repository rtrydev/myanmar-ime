"""Curated override-reading table for irregular surfaces.

Some surfaces' canonical reverse-romanized reading does not line up with
what a typist actually types, because Burmese tones (`*`, `.`, `:`) are
carried as reading suffixes and loan-coda alternations (Pali `-p` asat
for an English-derived `-t` reading) are orthographic conventions the
grammar parser cannot invert.

Each row forces `LexiconBuilder` to use the stamped reading instead of
reverse-romanizing the surface; task 03's zero-penalty digit-less alias
then makes the surface reachable by the exact bare buffer the user
types. The map is small, hand-curated, and lives in-tree so corpus
rebuilds inherit it (task 06).
"""

from __future__ import annotations


# `surface → override_reading`. The keys are surfaces; values are the
# internal reading-key form (with `2`/`3` variant suffixes) the
# LexiconBuilder should associate with the surface. Digit-less bare
# readings are derived automatically downstream by stripping suffixes.
CURATED_OVERRIDE_READINGS: dict[str, str] = {
    # Ya-pin surfaces whose tone (`:`) or coda (`-p` for a typed `-t`)
    # drift from the bare buffer a user types. Without the override,
    # their canonical readings (`ky2in:`, `ky2ay:zu:`, `ky2ap*`) never
    # match the digit-less bare input (`kyin`, `kyayzu`, `kyat`).
    "ကျပ်":    "ky2at",   # kyat (currency) — typed `-t`, coda is `-p`
    "ကျင်း":   "ky2in",   # large / broad — bare buffer drops `:` tone
    "ကျေးဇူး": "ky2ayzu", # thanks — bare buffer drops both `:` tones
}


def override_reading_for(surface: str) -> str | None:
    """Return the curated override reading for `surface`, or None."""
    return CURATED_OVERRIDE_READINGS.get(surface)
