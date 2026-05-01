#!/usr/bin/env bash
# Build libBurmeseIMEFFI.so (the Swift shim around BurmeseIMECore).
#
# By default builds release with `-static-stdlib` so the resulting .so
# carries its own Swift runtime — the .deb has no swiftlang dependency.
# Set FAST=1 for a debug build (no static stdlib, much faster link) when
# iterating locally.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
shim_dir="$repo_root/native/linux/swift-shim"

if ! command -v swift >/dev/null 2>&1; then
    echo "error: swift not on PATH (install via swiftly: https://swift.org/install)" >&2
    exit 1
fi

cd "$shim_dir"

if [[ "${FAST:-0}" = "1" ]]; then
    echo "==> swift build (debug)"
    swift build --product BurmeseIMEFFI
    out_dir="$shim_dir/.build/debug"
else
    echo "==> swift build (release, -static-stdlib)"
    # -static-stdlib bundles the Swift runtime into the .so so end users
    # don't need a swiftlang package installed. Costs ~60 MB in the .deb;
    # accepted trade-off (see tasks/linux-ibus-port.md §6).
    swift build -c release \
        -Xswiftc -static-stdlib \
        --product BurmeseIMEFFI
    out_dir="$shim_dir/.build/release"
fi

# Symlink the resulting .so into a stable location for the C engine.
so_path="$out_dir/libBurmeseIMEFFI.so"
if [[ ! -f "$so_path" ]]; then
    echo "error: expected $so_path missing" >&2
    exit 1
fi

mkdir -p "$shim_dir/.build/staging"
ln -sf "$so_path" "$shim_dir/.build/staging/libBurmeseIMEFFI.so"

echo "==> built $so_path"
echo "==> staged at $shim_dir/.build/staging/libBurmeseIMEFFI.so"
