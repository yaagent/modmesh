#!/bin/bash
#
# Build pilot and package it as a self-contained macOS .app bundle and DMG.
#
# Strategy:
#   1. macdeployqt copies Qt frameworks, Qt plugins, libpyside6, libshiboken6,
#      and other transitive dylibs into Contents/Frameworks/ and rewrites
#      every reference inside the bundle to use @executable_path.
#   2. Python.framework is copied into the bundle and the pilot binary is
#      relinked to load it from @executable_path.
#   3. The PySide6 and shiboken6 Python packages are copied into the
#      bundled site-packages, and every Qt and @rpath/libpyside6 reference
#      inside their .so files is rewritten to @executable_path so that
#      PySide6 loads the same Qt + libpyside6 as the pilot binary. Without
#      this rewrite the embedded Python would resolve PySide6 against
#      Homebrew Qt, ending up with two distinct Qt instances and crashing
#      with duplicate Objective-C class registrations or making QMenu*
#      return values unconvertible to Python QMenu objects.
#   4. The modmesh Python package is copied into the bundled site-packages
#      so `import modmesh` works regardless of the launch directory.
#
# Usage:
#   ./contrib/bundle/macos_bundle.sh [--skip-build] [--output DIR]
#
#   --skip-build   Skip `make pilot` and use the existing build output.
#   --output DIR   Write pilot.dmg into DIR (default: build/).
#
# Requirements:
#   - Qt (homebrew), macdeployqt in PATH
#   - PySide6 (homebrew) installed for the active python3
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
PYSIDE_DIR=$(python3 -c "import PySide6, os; print(os.path.dirname(PySide6.__file__))")
SHIBOKEN_DIR=$(python3 -c "import shiboken6, os; print(os.path.dirname(shiboken6.__file__))")

echo "==> Build path : $BUILD_PATH"
echo "==> App bundle : $APP"
echo "==> Python fw  : $PY_FW"
echo "==> PySide6    : $PYSIDE_DIR"
echo "==> shiboken6  : $SHIBOKEN_DIR"

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
# Step 2: bundle Qt frameworks, plugins, and transitive dylibs.
# ---------------------------------------------------------------------------

echo "==> macdeployqt (bundles Qt frameworks, plugins, transitive dylibs)"
macdeployqt "$APP" -verbose=1 2>&1 || true

# ---------------------------------------------------------------------------
# Step 3: bundle Python.framework and replace its site-packages symlink
#         with a real, empty directory so we can drop our packages in.
# ---------------------------------------------------------------------------

echo "==> Bundling Python.framework"

DEST_FW="$FW_DIR/Python.framework"
rm -rf "$DEST_FW"
cp -R "$PY_FW" "$DEST_FW"

NEW_PY_PATH="@executable_path/../Frameworks/Python.framework/Versions/$PY_VER/Python"
install_name_tool -change "$PY_DYLIB" "$NEW_PY_PATH" "$BINARY"
echo "    Python -> $NEW_PY_PATH"

BUNDLED_SITE="$DEST_FW/Versions/$PY_VER/lib/python${PY_VER}/site-packages"
# site-packages inside the framework is a symlink to Cellar; replace with a real dir.
rm -rf "$BUNDLED_SITE"
mkdir -p "$BUNDLED_SITE"

# ---------------------------------------------------------------------------
# Step 4: copy PySide6 and shiboken6 into the bundled site-packages, then
#         rewrite their Qt and @rpath references to point at the bundled
#         dylibs so they share Qt + libpyside6/libshiboken6 with the pilot
#         binary.
# ---------------------------------------------------------------------------

echo "==> Copying PySide6 and shiboken6 into bundled site-packages"
# -L dereferences symlinks; Homebrew exposes PySide6 files as symlinks into
# Cellar, and we need real files inside the bundle.
cp -RL "$PYSIDE_DIR" "$BUNDLED_SITE/PySide6"
cp -RL "$SHIBOKEN_DIR" "$BUNDLED_SITE/shiboken6"

# Drop bytecode caches and source-only helpers we cannot rewrite.
find "$BUNDLED_SITE/PySide6" "$BUNDLED_SITE/shiboken6" \
    -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

# Rewrite a single binary's load commands: replace any /opt/homebrew Qt
# framework path or @rpath/libpyside6/libshiboken6 with the bundled
# @executable_path equivalent.
rewrite_pyside_so()
{
    local bin="$1" old new fw
    while IFS= read -r old; do
        case "$old" in
        /opt/homebrew/*/Qt*.framework/Versions/*/*)
            fw=${old##*/}
            new="@executable_path/../Frameworks/${fw}.framework/Versions/A/${fw}"
            install_name_tool -change "$old" "$new" "$bin" 2>/dev/null || true
            ;;
        @rpath/libpyside6.abi3.*.dylib|@rpath/libshiboken6.abi3.*.dylib)
            new="@executable_path/../Frameworks/${old#@rpath/}"
            install_name_tool -change "$old" "$new" "$bin" 2>/dev/null || true
            ;;
        esac
    done < <(otool -L "$bin" 2>/dev/null | awk 'NR>1 {print $1}')
}

echo "==> Rewriting PySide6/shiboken6 .so dependencies to bundled paths"
while IFS= read -r -d '' SO; do
    rewrite_pyside_so "$SO"
done < <(find "$BUNDLED_SITE/PySide6" "$BUNDLED_SITE/shiboken6" \
    \( -name '*.so' -o -name '*.dylib' \) -print0)

# ---------------------------------------------------------------------------
# Step 5: copy the modmesh Python package into the bundled site-packages
#         so the embedded interpreter can `import modmesh` regardless of
#         the current working directory.  Skip __pycache__ and the
#         _modmesh extension .so (the C++ side of modmesh is statically
#         embedded in the pilot binary via PYBIND11_EMBEDDED_MODULE).
# ---------------------------------------------------------------------------

echo "==> Copying modmesh package into bundled site-packages"
rsync -a \
    --exclude '__pycache__' \
    --exclude '_modmesh*.so' \
    "$REPO_ROOT/modmesh" "$BUNDLED_SITE/"
echo "    modmesh -> $BUNDLED_SITE/modmesh"

# ---------------------------------------------------------------------------
# Step 5b: redirect every remaining /opt/homebrew reference whose target
#          basename is bundled in Contents/Frameworks/ to the bundled copy.
#
#          macdeployqt does not visit Python.framework's lib-dynload .so
#          files (libcrypto/libssl/libsqlite/libmpdec/...) or some
#          inter-library references such as libpyside6qml -> libshiboken6,
#          so they would still resolve to /opt/homebrew at runtime and
#          fail to load on a machine without Homebrew.  Build an index of
#          the bundled dylib basenames and rewrite any matching Homebrew
#          load command across every Mach-O in the bundle.  Also rewrite
#          each bundled dylib's own LC_ID_DYLIB so dyld deduplicates load
#          commands by install name.
# ---------------------------------------------------------------------------

echo "==> Redirecting remaining Homebrew references to bundled copies"
declare bundled_index=""
for f in "$FW_DIR"/*.dylib; do
    [[ -f "$f" ]] || continue
    bundled_index="$bundled_index $(basename "$f")"
done

is_bundled_dylib()
{
    local needle=" $1 "
    case "$bundled_index " in
        *"$needle"*) return 0 ;;
        *) return 1 ;;
    esac
}

while IFS= read -r -d '' BIN; do
    while IFS= read -r OLD; do
        case "$OLD" in
        /opt/homebrew/*)
            base=${OLD##*/}
            if is_bundled_dylib "$base"; then
                NEW="@executable_path/../Frameworks/$base"
                install_name_tool -change "$OLD" "$NEW" "$BIN" 2>/dev/null || true
            fi
            ;;
        esac
    done < <(otool -L "$BIN" 2>/dev/null | awk 'NR>1 {print $1}')
done < <(find "$APP" \( -name '*.dylib' -o -name '*.so' -o -path '*/MacOS/*' \) -type f -print0)

# Each bundled dylib's own install name (LC_ID_DYLIB) usually still points
# at /opt/homebrew; rewrite it so dyld treats the bundled copy and any
# other reference to the same basename as the same image.
for f in "$FW_DIR"/*.dylib; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f")
    install_name_tool -id "@executable_path/../Frameworks/$base" "$f" 2>/dev/null || true
done

# Re-export stubs inside Python.framework (lib/libpython3.14.dylib and
# lib/python3.14/config-3.14-darwin/libpython3.14.dylib) link against the
# original Homebrew Python by absolute path; redirect them to the bundled
# Python framework binary.
for f in \
    "$DEST_FW/Versions/$PY_VER/lib/libpython${PY_VER}.dylib" \
    "$DEST_FW/Versions/$PY_VER/lib/python${PY_VER}/config-${PY_VER}-darwin/libpython${PY_VER}.dylib"
do
    [[ -f "$f" ]] || continue
    install_name_tool -change "$PY_DYLIB" "$NEW_PY_PATH" "$f" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# Step 6: re-sign every nested Mach-O bottom-up, then the app bundle.
#
#         `codesign --deep` does not visit content we added to
#         Python.framework's Resources after it was first signed (the
#         CodeResources seal still references the original file list), so
#         macOS kills the process at launch with a code-signing failure.
#         Sign individual binaries and the framework first, then the app.
# ---------------------------------------------------------------------------

echo "==> Ad-hoc re-signing all bundled Mach-O files"
# Sign every dylib/.so first; their containing bundles (frameworks) are sealed
# afterwards.  Use a leaf-first ordering by sorting by depth descending.
while IFS= read -r -d '' BIN; do
    codesign --force --sign - "$BIN" 2>/dev/null || true
done < <(find "$APP/Contents" \( -name '*.dylib' -o -name '*.so' \) -print0)

# Re-seal each nested framework (Python.framework, Qt*.framework, ...).
# The framework version directory carries the signature on macOS.
for FW in "$FW_DIR"/*.framework; do
    [[ -d "$FW" ]] || continue
    for VER in "$FW"/Versions/*; do
        [[ -d "$VER" ]] || continue
        rm -rf "$VER/_CodeSignature"
        codesign --force --sign - "$VER" 2>/dev/null || true
    done
done

echo "==> Ad-hoc re-signing the app bundle"
codesign --force --sign - "$BINARY"
codesign --force --sign - "$APP"

# ---------------------------------------------------------------------------
# Step 7: create DMG
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
