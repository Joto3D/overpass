#!/bin/bash
# Builds Overpass in release mode, assembles it into a proper macOS .app
# bundle, ad-hoc codesigns it, and installs it to ~/Applications.
#
# It installs by default on purpose. For most of 29 October 2026 this
# script only wrote build/Overpass.app and stopped there, so the copy in
# ~/Applications stayed hours out of date while work continued, and every
# run also left a second bundle that Finder and Spotlight list as another
# application. Both of those were the same missing step.
#
# Pass --no-install to build without installing. Set OVERPASS_INSTALL_DIR
# to install somewhere other than ~/Applications.
#
# No Xcode is required (or used) — this is plain `swift build` plus
# manual bundle assembly, since this machine only has the Command Line
# Tools.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DO_INSTALL=1
for arg in "$@"; do
    case "$arg" in
        --no-install) DO_INSTALL=0 ;;
        *) echo "unknown option: $arg (expected --no-install)" >&2; exit 2 ;;
    esac
done

APP_NAME="Overpass"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Building $APP_NAME (release)"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"

echo "==> Cleaning previous bundle"
rm -rf "$APP_BUNDLE"

# Keep the build output out of Spotlight. Without this, build/Overpass.app
# is indexed as a second installed application and shows up alongside the
# real copy in ~/Applications every time you search for "Overpass".
mkdir -p "$BUILD_DIR"
touch "$BUILD_DIR/.metadata_never_index"

echo "==> Assembling $APP_NAME.app"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp "$BIN_PATH/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

# The GPL requires the licence text to travel with the binary, and the
# .app is how Overpass is actually distributed — a LICENSE sitting only in
# the source tree does not reach someone handed the app. LICENSE-FIXES
# goes along for the same reason: the built-in fix data is compiled into
# that binary, and its CC0 dedication is what tells a recipient they may
# reuse it.
cp "$ROOT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE"
cp "$ROOT_DIR/LICENSE-FIXES" "$RESOURCES_DIR/LICENSE-FIXES"

# Copy any other resources (icon assets, etc.) besides Info.plist itself.
for item in "$ROOT_DIR"/Resources/*; do
    name="$(basename "$item")"
    if [ "$name" != "Info.plist" ]; then
        cp -R "$item" "$RESOURCES_DIR/$name"
    fi
done

# Generate an .icns from Resources/icon.png if present. Skipped gracefully
# otherwise, since there's no app icon yet.
ICON_PNG="$ROOT_DIR/Resources/icon.png"
if [ -f "$ICON_PNG" ]; then
    echo "==> Generating app icon"
    ICONSET_DIR="$BUILD_DIR/Overpass.iconset"
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"

    sips -z 16 16     "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png"      >/dev/null
    sips -z 32 32     "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png"  >/dev/null
    sips -z 32 32     "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png"     >/dev/null
    sips -z 64 64     "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png"  >/dev/null
    sips -z 128 128   "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png"   >/dev/null
    sips -z 256 256   "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png"   >/dev/null
    sips -z 512 512   "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png"   >/dev/null
    sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

    iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
    rm -rf "$ICONSET_DIR"
else
    echo "==> No Resources/icon.png found, skipping app icon generation"
fi

# Frame-counter shim (Shim/fgshim.m -> Contents/Resources/libfgshim.dylib).
# A Metal present-hook that WineRunner injects into a bottle's Wine
# processes via DYLD_INSERT_LIBRARIES when that bottle's "Frame counter"
# diagnostic is on. Universal (x86_64 + arm64) because Wine runs under
# Rosetta, so the injected image must have an x86_64 slice. Same build line
# as the proven prototype. It lives in Shim/ (not Sources/) so SwiftPM does
# not try to build it as a target.
#
# This step is best-effort ON PURPOSE: the shim is a diagnostic, so if
# clang is missing or the compile fails we warn and carry on rather than
# breaking the app build. The app copes with the dylib being absent (the
# toggle then does nothing; see `FrameCounterShim.dylibURL`).
SHIM_SRC="$ROOT_DIR/Shim/fgshim.m"
SHIM_OUT="$RESOURCES_DIR/libfgshim.dylib"
if [ -f "$SHIM_SRC" ]; then
    echo "==> Building frame-counter shim (libfgshim.dylib)"
    if clang -dynamiclib -fobjc-arc -O2 -Wall -arch x86_64 -arch arm64 \
        -framework Foundation -framework Metal -framework QuartzCore \
        -install_name @rpath/libfgshim.dylib -o "$SHIM_OUT" "$SHIM_SRC"; then
        echo "    shim architectures: $(lipo -archs "$SHIM_OUT")"
    else
        echo "warning: frame-counter shim failed to build; continuing without libfgshim.dylib" >&2
        rm -f "$SHIM_OUT"
    fi
else
    echo "warning: $SHIM_SRC not found; skipping frame-counter shim" >&2
fi

echo "==> Ad-hoc codesigning $APP_NAME.app"
codesign --force -s - "$APP_BUNDLE"

if [ "$DO_INSTALL" -eq 0 ]; then
    echo "==> Done (not installed): $APP_BUNDLE"
    exit 0
fi

INSTALL_DIR="${OVERPASS_INSTALL_DIR:-$HOME/Applications}"
INSTALLED="$INSTALL_DIR/$APP_NAME.app"
mkdir -p "$INSTALL_DIR"

# Replacing a running app does not disturb the running copy — it keeps the
# old bundle open by inode — so it carries on working while no longer being
# what is on disk. That is precisely how a stale build goes unnoticed, so
# say it out loud rather than failing or silently quitting the user's app.
if pgrep -f "$INSTALLED/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    echo "    note: $APP_NAME is running — quit and reopen it to pick up this build"
fi

echo "==> Installing to $INSTALLED"
# Stage beside the target and swap, rather than deleting first. An
# interrupted copy then costs a rebuild, not the user's installed app.
STAGE="$INSTALL_DIR/.$APP_NAME.app.incoming"
rm -rf "$STAGE"
cp -R "$APP_BUNDLE" "$STAGE"
rm -rf "$INSTALLED"
mv "$STAGE" "$INSTALLED"

# Leave no second bundle behind: a copy under build/ gets listed as its own
# application next to the real one, which is the duplicate this script used
# to create on every run. build/ itself stays, with its Spotlight marker.
rm -rf "$APP_BUNDLE"

echo "==> Installed: $INSTALLED"
