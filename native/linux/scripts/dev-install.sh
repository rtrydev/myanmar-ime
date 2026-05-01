#!/usr/bin/env bash
# dev-install: stage the engine, schema, and shim into ~/.local without
# touching system directories. Pairs with `ibus restart` for a fast
# rebuild loop without dpkg-buildpackage in the middle.
#
# Cleanup: rm -rf the staged paths printed at the end.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
linux_dir="$repo_root/native/linux"

# Local destinations
schema_dir="$HOME/.local/share/glib-2.0/schemas"
component_dir="$HOME/.local/share/ibus/component"
exec_dir="$HOME/.local/lib/ibus-myangler"
data_dir="$HOME/.local/share/myangler"

mkdir -p "$schema_dir" "$component_dir" "$exec_dir" "$data_dir"

# 1. Build Swift shim (debug for fast iteration; release for the .deb).
echo "==> [1/4] building Swift shim"
FAST=1 "$linux_dir/scripts/build-swift-shim.sh"

# 2. Configure + build the C engine if needed.
echo "==> [2/4] configuring + building C engine"
build_dir="$linux_dir/ibus-engine/build"
if [[ ! -f "$build_dir/build.ninja" ]]; then
    meson setup "$build_dir" \
        --prefix="$HOME/.local" \
        -Dshim_dir="$linux_dir/swift-shim/.build/staging"
fi
meson compile -C "$build_dir"

# 3. Install schema + component XML + binary into ~/.local.
echo "==> [3/4] staging files in ~/.local"
cp "$linux_dir/data/com.myangler.inputmethod.burmese.gschema.xml" "$schema_dir/"
glib-compile-schemas "$schema_dir"

# Patch the component XML so it points at the dev binary path.
dev_xml="$(mktemp)"
sed -e "s|/usr/lib/ibus-myangler/ibus-engine-myangler|$exec_dir/ibus-engine-myangler|" \
    "$linux_dir/data/myangler.xml" > "$dev_xml"
mv "$dev_xml" "$component_dir/myangler.xml"

cp "$build_dir/ibus-engine-myangler" "$exec_dir/ibus-engine-myangler"
chmod +x "$exec_dir/ibus-engine-myangler"

# Stage data files. Lexicon + LM live in macOS/Data when built locally;
# fall back to symlink. Users without these files run with Empty/Null
# stores — engine still works for parser-only candidates.
for f in BurmeseLexicon.sqlite BurmeseLM.bin; do
    src="$repo_root/native/macos/Data/$f"
    if [[ -f "$src" ]]; then
        ln -sf "$src" "$data_dir/$f"
    fi
done

echo "==> [4/4] done. Restart IBus to pick up the new engine:"
echo "       ibus restart"
echo "    Then add 'Myangler (Burmese, Romanized)' in"
echo "       Settings → Region & Language → Manage Installed Languages"
echo
echo "    Live overrides applied for this session:"
echo "       MYANGLER_DATA_DIR=$data_dir"
echo "       LD_LIBRARY_PATH=$linux_dir/swift-shim/.build/staging"
echo
echo "    The component XML's <exec> already points at $exec_dir/ibus-engine-myangler."
echo "    LD_LIBRARY_PATH must be exported in the *parent* of ibus-daemon"
echo "    for the shim to load — usually means logging out + back in or"
echo "    starting ibus-daemon manually with the env var set."
