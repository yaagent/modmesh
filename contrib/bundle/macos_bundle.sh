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

# All site-packages directories the embedded interpreter would search,
# expanded through .pth files (so packages installed via separate prefixes,
# such as Homebrew's matplotlib keg, are found).  macOS still ships bash
# 3.2, which has no mapfile; read into an array with a loop instead.
SITE_DIRS=()
while IFS= read -r line; do
    SITE_DIRS+=("$line")
done < <(python3 -c "
import site, os
seen, out = set(), []
def add(p):
    p = os.path.realpath(p)
    if p in seen or not os.path.isdir(p):
        return
    seen.add(p); out.append(p)
    for f in sorted(os.listdir(p)):
        if not f.endswith('.pth'):
            continue
        try:
            with open(os.path.join(p, f)) as fp:
                for line in fp:
                    line = line.strip()
                    if line and not line.startswith(('#', 'import ')):
                        add(line if os.path.isabs(line) else os.path.join(p, line))
        except OSError:
            pass
for d in site.getsitepackages():
    add(d)
print('\n'.join(out))
")

echo "==> Build path : $BUILD_PATH"
echo "==> App bundle : $APP"
echo "==> Python fw  : $PY_FW"
for d in "${SITE_DIRS[@]}"; do
    echo "==> site-pkgs  : $d"
done

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
# Step 4: copy every installed Python package the embedded interpreter
#         would normally find into the bundled site-packages.  Without
#         this, `import numpy` (and other modmesh dependencies) fails on
#         a machine that does not have Homebrew's site-packages mounted
#         at /opt/homebrew.
#
#         rsync -L dereferences symlinks because Homebrew exposes most
#         files as symlinks into Cellar.  __pycache__ directories are
#         skipped (they will be regenerated) and *.pth files are skipped
#         because they encode absolute Homebrew paths -- the directories
#         they point at are themselves enumerated above as SITE_DIRS and
#         copied here, so their content is included even though the .pth
#         link is not.
# ---------------------------------------------------------------------------

echo "==> Copying Python packages into bundled site-packages"
for SITE in "${SITE_DIRS[@]}"; do
    rsync -aL \
        --exclude '__pycache__' \
        --exclude '*.pth' \
        "$SITE/" "$BUNDLED_SITE/"
done

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

echo "==> Pulling in transitive Homebrew dependencies"
# Collect every Mach-O in the bundle into a queue, then BFS-walk it.  For
# each unprocessed binary we read its load commands once and any
# /opt/homebrew dependency that is not yet bundled gets copied into
# Contents/Frameworks/ and pushed onto the queue.  Processing only the
# newly-added files (instead of re-walking the entire bundle every pass)
# keeps the cost roughly linear in the number of bundled binaries.

CLOSURE_TMP=$(mktemp -d)
QUEUE="$CLOSURE_TMP/queue"
SEEN_BIN="$CLOSURE_TMP/seen_bin"
SEEN_DYLIB="$CLOSURE_TMP/seen_dylib"
SEEN_FW="$CLOSURE_TMP/seen_fw"
: > "$QUEUE" "$SEEN_BIN" "$SEEN_DYLIB" "$SEEN_FW"

# Index the dylibs and frameworks already present in Contents/Frameworks/
# so we don't try to re-copy them.
for f in "$FW_DIR"/*.dylib; do
    [[ -f "$f" ]] && echo "$(basename "$f")" >> "$SEEN_DYLIB"
done
for f in "$FW_DIR"/*.framework; do
    [[ -d "$f" ]] && echo "$(basename "$f" .framework)" >> "$SEEN_FW"
done

# Seed the queue with every Mach-O already in the bundle.
find "$APP" \( -name '*.dylib' -o -name '*.so' -o -path '*/MacOS/*' \) \
    -type f -print >> "$QUEUE"

while [[ -s "$QUEUE" ]]; do
    BIN=$(head -n 1 "$QUEUE")
    sed -i '' '1d' "$QUEUE"
    grep -qxF "$BIN" "$SEEN_BIN" && continue
    echo "$BIN" >> "$SEEN_BIN"
    while IFS= read -r OLD; do
        case "$OLD" in
        /opt/homebrew/*.framework/Versions/*/*)
            fw=${OLD##*/}
            grep -qxF "$fw" "$SEEN_FW" && continue
            SRC=${OLD%%/Versions/*}
            [[ -d "$SRC" ]] || continue
            # rsync preserves internal symlinks (Headers -> Versions/Current/...)
            # but --copy-unsafe-links materialises the symlinks that point into
            # Homebrew's Cellar (the binary itself), giving us a self-contained
            # framework with its on-disk shape intact.
            mkdir -p "$FW_DIR/$fw.framework"
            if rsync -a --copy-unsafe-links "$SRC/" "$FW_DIR/$fw.framework/" 2>/dev/null; then
                chmod -R u+w "$FW_DIR/$fw.framework"
                echo "$fw" >> "$SEEN_FW"
                find "$FW_DIR/$fw.framework" -type f \
                    \( -name '*.dylib' -o -perm +111 \) >> "$QUEUE"
            fi
            ;;
        /opt/homebrew/*)
            base=${OLD##*/}
            grep -qxF "$base" "$SEEN_DYLIB" && continue
            [[ -f "$OLD" ]] || continue
            if cp -L "$OLD" "$FW_DIR/$base" 2>/dev/null; then
                chmod u+w "$FW_DIR/$base"
                echo "$base" >> "$SEEN_DYLIB"
                echo "$FW_DIR/$base" >> "$QUEUE"
            fi
            ;;
        esac
    done < <(otool -L "$BIN" 2>/dev/null | awk 'NR>1 {print $1}')
done

echo "    bundled $(wc -l < "$SEEN_DYLIB" | tr -d ' ') dylibs and \
$(wc -l < "$SEEN_FW" | tr -d ' ') frameworks"
rm -rf "$CLOSURE_TMP"

echo "==> Redirecting Homebrew load commands to bundled copies"
# Build the final dylib + framework basename indexes after the closure,
# then rewrite every reference whose target is now bundled.  Also
# rewrite @rpath/libfoo references for any libfoo bundled alongside.
INDEX=" "
for f in "$FW_DIR"/*.dylib; do
    [[ -f "$f" ]] && INDEX="${INDEX}$(basename "$f") "
done
qt_index=" "
for fw in "$FW_DIR"/*.framework; do
    [[ -d "$fw" ]] || continue
    name=$(basename "$fw" .framework)
    [[ "$name" == Python ]] && continue
    qt_index="${qt_index}${name} "
done

while IFS= read -r -d '' BIN; do
    while IFS= read -r OLD; do
        case "$OLD" in
        /opt/homebrew/*.framework/Versions/*/*)
            fw=${OLD##*/}
            if [[ "$qt_index" == *" $fw "* ]]; then
                NEW="@executable_path/../Frameworks/${fw}.framework/Versions/A/${fw}"
                install_name_tool -change "$OLD" "$NEW" "$BIN" 2>/dev/null || true
            fi
            ;;
        /opt/homebrew/*)
            base=${OLD##*/}
            if [[ "$INDEX" == *" $base "* ]]; then
                NEW="@executable_path/../Frameworks/$base"
                install_name_tool -change "$OLD" "$NEW" "$BIN" 2>/dev/null || true
            fi
            ;;
        @rpath/lib*.dylib)
            base=${OLD#@rpath/}
            if [[ "$INDEX" == *" $base "* ]]; then
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
# Sign every dylib/.so first; their containing bundles (frameworks,
# nested .app helpers like QtWebEngineProcess) are sealed afterwards.
while IFS= read -r -d '' BIN; do
    codesign --force --sign - "$BIN" 2>/dev/null || true
done < <(find "$APP/Contents" \( -name '*.dylib' -o -name '*.so' \) -print0)

# Sign nested .app bundles inside frameworks (QtWebEngineCore ships
# Helpers/QtWebEngineProcess.app, etc.) before sealing their parent
# framework.  Reverse-sort by path length so the deepest .app signs first.
find "$APP" -name '*.app' -type d -print | awk '{print length($0), $0}' | \
    sort -k1,1nr | cut -d' ' -f2- | while IFS= read -r INNER_APP; do
    [[ "$INNER_APP" == "$APP" ]] && continue
    rm -rf "$INNER_APP/Contents/_CodeSignature"
    codesign --force --sign - "$INNER_APP" 2>/dev/null || true
done

# Re-seal each nested framework (Python.framework, Qt*.framework, ...).
# The framework version directory carries the signature on macOS.
for FW in "$FW_DIR"/*.framework; do
    [[ -d "$FW" ]] || continue
    for VER in "$FW"/Versions/*; do
        [[ -d "$VER" && ! -L "$VER" ]] || continue
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
