#!/usr/bin/env bash
# Produce ibus-myangler_<version>_<arch>.deb in native/linux/.
# Run on a build host that has Swift on PATH (via swiftly) and the
# Debian build deps from debian/control. See README.md.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
linux_dir="$repo_root/native/linux"

# Sanity checks.
if ! command -v swift >/dev/null 2>&1; then
    echo "error: swift not on PATH (install via swiftly)" >&2
    exit 1
fi
if ! command -v dpkg-buildpackage >/dev/null 2>&1; then
    echo "error: dpkg-buildpackage missing — run:" >&2
    echo "    sudo apt install debhelper devscripts dpkg-dev fakeroot" >&2
    exit 1
fi

cd "$linux_dir"

# Optional: copy lexicon + LM from native/macos/Data into staging so
# they ship in the .deb. Build still succeeds if they're absent
# (engine runs in fallback mode).
mkdir -p data/staging
for f in BurmeseLexicon.sqlite BurmeseLM.bin; do
    src="$repo_root/native/macos/Data/$f"
    if [[ -f "$src" ]]; then
        cp -u "$src" "data/staging/$f"
    fi
done

# dpkg-buildpackage wants the source root to be the directory
# containing debian/. That's native/linux/. It writes the .deb,
# .changes, and .buildinfo to `..` (i.e. native/) by convention; we
# relocate them under native/linux/build/ once the build finishes so
# the repo's top-level stays tidy.
dpkg-buildpackage -us -uc -b "$@"

out_dir="$linux_dir/build"
mkdir -p "$out_dir"
moved_any=0
for f in "$repo_root/native/"ibus-myangler_*.deb \
         "$repo_root/native/"ibus-myangler_*.changes \
         "$repo_root/native/"ibus-myangler_*.buildinfo; do
    [[ -f "$f" ]] || continue
    mv -f "$f" "$out_dir/"
    moved_any=1
done

echo
echo "==> built artifact(s):"
if [[ "$moved_any" = "1" ]]; then
    ls -lh "$out_dir"/ibus-myangler_*.deb 2>/dev/null || true
else
    echo "    (no fresh .deb produced)"
fi
