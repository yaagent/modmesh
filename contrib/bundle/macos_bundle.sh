#!/bin/bash
#
# Build pilot and package it as a macOS .app bundle and DMG.
#
# macdeployqt bundles Qt plugins and non-Qt system libraries, but Qt
# frameworks themselves are NOT bundled. The pilot binary embeds Python
# which loads PySide6; having two separate Qt copies (bundled + Homebrew)
# causes duplicate Objective-C class registration and a crash at startup.
# Instead, all Qt references across the entire bundle are rewritten back
# to Homebrew absolute paths so that every component uses a single Qt.
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
FW_DIR="$APP/Contents/Frameworks"

# Locate the Python framework used at build time.
PY_FW=$(python3 -c "
import sys, os, sysconfig
fw = sysconfig.get_config_var('PYTHONFRAMEWORKPREFIX')
if fw:
    print(os.path.join(fw, 'Python.framework'))
else:
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
# Step 2: bundle plugins and non-Qt libraries with macdeployqt.
#
#         macdeployqt rewrites every Qt and PySide6 reference inside the
#         bundle to @executable_path/../Frameworks/. We then rewrite them
#         back to Homebrew absolute paths and delete the bundled copies.
#         Because the embedded Python loads PySide6 from Homebrew's
#         site-packages at runtime, the pilot binary, its plugins, and
#         PySide6 must all resolve to the same Homebrew Qt and the same
#         Homebrew libpyside6/libshiboken6; otherwise duplicate
#         Objective-C class registration crashes the process and the
#         Shiboken type registries diverge so QMenu* return values cannot
#         be converted to Python QMenu objects.
# ---------------------------------------------------------------------------

echo "==> macdeployqt (bundles plugins and non-Qt libraries)"
macdeployqt "$APP" -verbose=1 2>&1 || true

# Rewrite a single bundled load path back to its Homebrew counterpart in
# every binary inside the bundle.
revert_to_homebrew()
{
    local bundled="$1"
    local hb_path="$2"
    while IFS= read -r -d '' bin; do
        if otool -L "$bin" 2>/dev/null | grep -qF "$bundled"; then
            install_name_tool -change "$bundled" "$hb_path" "$bin" 2>/dev/null || true
        fi
    done < <(find "$APP" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) -print0)
}

# Locate a framework or dylib by name under /opt/homebrew/opt/*/lib.
find_homebrew_path()
{
    local name="$1" kind="$2" keg
    for keg in /opt/homebrew/opt/*/lib; do
        if [[ "$kind" == framework ]]; then
            local candidate="$keg/${name}.framework/Versions/A/${name}"
        else
            local candidate="$keg/${name}"
        fi
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

echo "==> Reverting Qt frameworks to Homebrew paths in all bundle binaries"
for FW_PATH in "$FW_DIR"/Qt*.framework; do
    [[ -d "$FW_PATH" ]] || continue
    FW_NAME=$(basename "$FW_PATH" .framework)
    BUNDLED="@executable_path/../Frameworks/${FW_NAME}.framework/Versions/A/${FW_NAME}"
    HB_PATH=$(find_homebrew_path "$FW_NAME" framework) || HB_PATH=""
    if [[ -z "$HB_PATH" ]]; then
        echo "    WARNING: Homebrew path not found for $FW_NAME, skipping"
        continue
    fi
    revert_to_homebrew "$BUNDLED" "$HB_PATH"
    echo "    $FW_NAME -> $HB_PATH"
    rm -rf "$FW_PATH"
done

echo "==> Reverting bundled dylibs (PySide6, Shiboken6, ...) to Homebrew paths"
for DYLIB_PATH in "$FW_DIR"/lib*.dylib; do
    [[ -f "$DYLIB_PATH" ]] || continue
    DYLIB_NAME=$(basename "$DYLIB_PATH")
    BUNDLED="@executable_path/../Frameworks/${DYLIB_NAME}"
    HB_PATH=$(find_homebrew_path "$DYLIB_NAME" dylib) || HB_PATH=""
    if [[ -z "$HB_PATH" ]]; then
        echo "    WARNING: Homebrew path not found for $DYLIB_NAME, skipping"
        continue
    fi
    revert_to_homebrew "$BUNDLED" "$HB_PATH"
    echo "    $DYLIB_NAME -> $HB_PATH"
    rm -f "$DYLIB_PATH"
done

echo "    Removed bundled Qt + PySide6 copies; using Homebrew at runtime."

# ---------------------------------------------------------------------------
# Step 3: bundle Python.framework
# ---------------------------------------------------------------------------

echo "==> Bundling Python.framework"

DEST_FW="$FW_DIR/Python.framework"
rm -rf "$DEST_FW"
cp -R "$PY_FW" "$DEST_FW"

OLD_PY_PATH="$PY_DYLIB"
NEW_PY_PATH="@executable_path/../Frameworks/Python.framework/Versions/$PY_VER/Python"

install_name_tool -change "$OLD_PY_PATH" "$NEW_PY_PATH" "$BINARY"
echo "    Python -> $NEW_PY_PATH"

# The bundled Python.framework resolves sys.prefix to inside the app bundle,
# so site.py does not find packages installed in Homebrew's shared
# site-packages (e.g. PySide6, shiboken6). Add a .pth file so that
# site.py appends the Homebrew site-packages directory to sys.path.
HB_SITE=$(python3 -c "import site; print([p for p in site.getsitepackages() if 'homebrew' in p or 'site-packages' in p][0])")
BUNDLED_SITE="$DEST_FW/Versions/$PY_VER/lib/python${PY_VER}/site-packages"
# site-packages inside the framework is a symlink to Cellar; replace with a real dir.
rm -rf "$BUNDLED_SITE"
mkdir -p "$BUNDLED_SITE"
echo "$HB_SITE" > "$BUNDLED_SITE/homebrew-site.pth"
echo "    Added site-packages pth: $HB_SITE"

# Copy the modmesh Python package into the bundled site-packages so the
# embedded interpreter can `import modmesh.system` regardless of the
# current working directory.  Skip __pycache__ and the _modmesh extension
# .so (the C++ side of modmesh is statically embedded in the pilot binary
# via PYBIND11_EMBEDDED_MODULE).
echo "==> Copying modmesh package into bundled site-packages"
rsync -a \
    --exclude '__pycache__' \
    --exclude '_modmesh*.so' \
    "$REPO_ROOT/modmesh" "$BUNDLED_SITE/"
echo "    modmesh -> $BUNDLED_SITE/modmesh"

# ---------------------------------------------------------------------------
# Step 4: re-sign
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
