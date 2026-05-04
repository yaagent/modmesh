#!/bin/bash
#
# Build pilot and package it as a self-contained macOS .app bundle and DMG.
#
# Usage:
#   ./contrib/bundle/macos_bundle.sh [--skip-build] [--output DIR]
#
#   --skip-build   Skip `make pilot` and use the existing build output.
#   --output DIR   Write pilot.dmg into DIR (default: build/).
#
# Requirements:
#   - Qt (homebrew), macdeployqt in PATH
#   - Python 3 (homebrew), matching the version used to build modmesh
#   - Xcode Command Line Tools (for codesign, hdiutil, install_name_tool)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

SKIP_BUILD=0
OUTPUT_DIR="$REPO_ROOT/build"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1 ; shift ;;
        --output) OUTPUT_DIR="$2" ; shift 2 ;;
        *) echo "Unknown option: $1" >&2 ; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Derive paths
# ---------------------------------------------------------------------------

PY_MINOR=$(python3 -c "import sys; print('%d%d' % sys.version_info[:2])")
BUILD_PATH="build/dev${PY_MINOR}"
APP="$REPO_ROOT/$BUILD_PATH/cpp/binary/pilot/pilot.app"
BINARY="$APP/Contents/MacOS/pilot"

# Locate the Python framework used at build time.
PY_FW=$(python3 -c "
import sys, os, sysconfig
fw = sysconfig.get_config_var('PYTHONFRAMEWORKPREFIX')
if fw:
    print(os.path.join(fw, 'Python.framework'))
else:
    # Homebrew layout: Frameworks/ lives next to lib/
    base = os.path.dirname(os.path.dirname(sys.executable))
    print(os.path.join(base, 'Frameworks', 'Python.framework'))
")

PY_VER=$(python3 -c "import sys; print('%d.%d' % sys.version_info[:2])")
PY_DYLIB="$PY_FW/Versions/$PY_VER/Python"

echo "==> Build path : $BUILD_PATH"
echo "==> App bundle : $APP"
echo "==> Python fw  : $PY_FW"

if [[ ! -f "$PY_DYLIB" ]]; then
    echo "ERROR: Python dylib not found at $PY_DYLIB" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: build
# ---------------------------------------------------------------------------

if [[ $SKIP_BUILD -eq 0 ]]; then
    echo "==> make pilot"
    make pilot
fi

if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: pilot binary not found at $BINARY" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: bundle Qt frameworks with macdeployqt
# ---------------------------------------------------------------------------

echo "==> macdeployqt (Qt frameworks)"
# macdeployqt may print errors about Python — that is expected and handled below.
macdeployqt "$APP" -verbose=1 2>&1 || true

# ---------------------------------------------------------------------------
# Step 3: bundle Python.framework manually
# ---------------------------------------------------------------------------

echo "==> Bundling Python.framework"

DEST_FW="$APP/Contents/Frameworks/Python.framework"
rm -rf "$DEST_FW"
cp -R "$PY_FW" "$DEST_FW"

# Rewrite the binary's Python load path to the bundled copy.
OLD_PATH="$PY_DYLIB"
NEW_PATH="@executable_path/../Frameworks/Python.framework/Versions/$PY_VER/Python"

install_name_tool -change "$OLD_PATH" "$NEW_PATH" "$BINARY"
echo "    load path rewritten: $NEW_PATH"

# ---------------------------------------------------------------------------
# Step 4: re-sign (install_name_tool invalidates the existing signature)
# ---------------------------------------------------------------------------

echo "==> Ad-hoc re-signing"
codesign --force --deep --sign - "$APP"

# ---------------------------------------------------------------------------
# Step 5: create DMG
# ---------------------------------------------------------------------------

mkdir -p "$OUTPUT_DIR"
DMG="$OUTPUT_DIR/pilot.dmg"

echo "==> Creating $DMG"
hdiutil create -volname "modmesh Pilot" \
    -srcfolder "$APP" \
    -ov -format UDZO \
    "$DMG"

SIZE=$(du -sh "$DMG" | cut -f1)
echo ""
echo "Bundle complete: $DMG ($SIZE)"
