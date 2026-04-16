#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(cd "$HERE/.." && pwd)"
WORKSPACE="$MACOS_DIR/BurmeseIME.xcworkspace"
BUILD_DIR="$MACOS_DIR/build/installer"
STAGING="$BUILD_DIR/staging"
DERIVED="$BUILD_DIR/DerivedData"
OUT_DIR="$MACOS_DIR/build"
VERSION="${VERSION:-0.1.0}"
PKG_ID="com.myangler.inputmethod.burmese.installer"

rm -rf "$BUILD_DIR"
mkdir -p "$STAGING/Applications"
mkdir -p "$STAGING/private/tmp/BurmeseIME-payload"
mkdir -p "$OUT_DIR"

# Let Xcode's automatic signing (CODE_SIGN_STYLE=Automatic +
# DEVELOPMENT_TEAM=...) sign the bundles. Ad-hoc signing (-) produces a
# new per-build signature, which invalidates TCC's App-Group grant on every
# launch and causes macOS to re-prompt "would like to access data from other
# apps" every time the IME restarts. A stable team-signed bundle persists
# the grant correctly.
XCBUILD_COMMON=(
    -workspace "$WORKSPACE"
    -configuration Release
    -derivedDataPath "$DERIVED"
    SKIP_INSTALL=NO
    MARKETING_VERSION="$VERSION"
    CURRENT_PROJECT_VERSION="$VERSION"
)

echo "==> Building BurmeseIME (headless IME)"
xcodebuild "${XCBUILD_COMMON[@]}" -scheme BurmeseIME clean build

echo "==> Building BurmeseIMEPreferences (SwiftUI app)"
xcodebuild "${XCBUILD_COMMON[@]}" -scheme BurmeseIMEPreferences clean build

IME_BUILT="$DERIVED/Build/Products/Release/BurmeseIME.app"
PREFS_BUILT="$DERIVED/Build/Products/Release/BurmeseIMEPreferences.app"

if [ ! -d "$IME_BUILT" ]; then
    echo "error: $IME_BUILT not found" >&2
    exit 1
fi
if [ ! -d "$PREFS_BUILT" ]; then
    echo "error: $PREFS_BUILT not found" >&2
    exit 1
fi

echo "==> Staging"
cp -R "$IME_BUILT" "$STAGING/private/tmp/BurmeseIME-payload/"
cp -R "$PREFS_BUILT" "$STAGING/Applications/"

echo "==> Building pkg"
pkgbuild \
    --root "$STAGING" \
    --identifier "$PKG_ID" \
    --version "$VERSION" \
    --install-location / \
    --scripts "$HERE/scripts" \
    "$OUT_DIR/BurmeseIME-Install.pkg"

echo "==> Done: $OUT_DIR/BurmeseIME-Install.pkg"
