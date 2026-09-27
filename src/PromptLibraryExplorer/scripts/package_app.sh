#!/usr/bin/env bash
# Build PromptLibraryExplorer (release) and assemble "PromptLibrary Explorer.app"
# in the package root from scratch, so a clean checkout reproduces the bundle.
#
# Usage:
#   scripts/package_app.sh            # build + assemble + sign + register
#   scripts/package_app.sh --launch   # ...then kill running instances and open the new build
#
# Notes:
#   - The Command Line Tools toolchain can't evaluate SwiftPM manifests on this
#     machine; the Xcode toolchain works, so DEVELOPER_DIR defaults to Xcode.
#   - The bundle's Info.plist is sourced from Resources/Info.plist (tracked in git).
#     The .app itself is git-ignored (*.app) and is fully regenerated here.
set -euo pipefail

LAUNCH=0
for arg in "$@"; do
    case "$arg" in
        --launch) LAUNCH=1 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PromptLibrary Explorer.app"
APP="$ROOT/$APP_NAME"
EXEC_NAME="PromptLibraryExplorer"
RES="$ROOT/Resources"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cd "$ROOT"

echo "==> Building ($EXEC_NAME, release) with DEVELOPER_DIR=$DEVELOPER_DIR"
swift build -c release --product "$EXEC_NAME"
# Quick Look extensions (Extensions/README.md): plain executables linked with
# -e _NSExtensionMain, wrapped into PLX*.appex bundles below.
QL_EXTENSIONS=(PLXQuickLookPreview PLXQuickLookThumbnail)
for ext in "${QL_EXTENSIONS[@]}"; do
    echo "==> Building ($ext, release)"
    swift build -c release --product "$ext"
done
BUILD_DIR="$(swift build -c release --show-bin-path)"

plutil -lint "$RES/Info.plist" >/dev/null

# Assemble in a temp dir next to the target (same volume, so the final mv is a rename).
STAGE="$(mktemp -d "$ROOT/.package_app.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
STAGED_APP="$STAGE/$APP_NAME"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

echo "==> Assembling bundle"
cp "$RES/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$BUILD_DIR/$EXEC_NAME" "$STAGED_APP/Contents/MacOS/$EXEC_NAME"
# Existing convention: a second copy named after the display name. Keep both.
cp "$BUILD_DIR/$EXEC_NAME" "$STAGED_APP/Contents/MacOS/PromptLibrary Explorer"
cp "$RES/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"

# SwiftPM resource bundles (none today; appear if a target declares `resources:`).
# Bundle.module looks for them next to the executable's bundle Resources.
shopt -s nullglob
for b in "$BUILD_DIR"/*.bundle; do
    echo "    resource bundle: $(basename "$b")"
    cp -R "$b" "$STAGED_APP/Contents/Resources/"
done

# ---------------------------------------------------------------------------
# Quick Look app extensions -> Contents/PlugIns/<Name>.appex
#   Contents/Info.plist     <- Extensions/<Name>/Info.plist (XPC!, NSExtension dict)
#   Contents/MacOS/<Name>   <- SwiftPM executable product
# Any prebuilt PLX*.appex dropped in $BUILD_DIR or Extensions/ is embedded too.
# ---------------------------------------------------------------------------
mkdir -p "$STAGED_APP/Contents/PlugIns"
for ext in "${QL_EXTENSIONS[@]}"; do
    SRC="$ROOT/Extensions/$ext"
    plutil -lint "$SRC/Info.plist" >/dev/null
    plutil -lint "$SRC/$ext.entitlements" >/dev/null
    APPEX="$STAGED_APP/Contents/PlugIns/$ext.appex"
    mkdir -p "$APPEX/Contents/MacOS"
    cp "$SRC/Info.plist" "$APPEX/Contents/Info.plist"
    cp "$BUILD_DIR/$ext" "$APPEX/Contents/MacOS/$ext"
    echo "    plugin: $ext.appex"
done
APPEXES=("$BUILD_DIR"/PLX*.appex "$ROOT"/Extensions/*.appex)
shopt -u nullglob
if (( ${#APPEXES[@]} > 0 )); then
    for ext in "${APPEXES[@]}"; do
        echo "    plugin (prebuilt): $(basename "$ext")"
        cp -R "$ext" "$STAGED_APP/Contents/PlugIns/"
    done
fi

echo "==> Ad-hoc signing"
# Nested code first (inside-out), then the app.
if [[ -d "$STAGED_APP/Contents/PlugIns" ]]; then
    for ext in "$STAGED_APP/Contents/PlugIns"/*.appex; do
        # Quick Look only loads sandboxed extensions; sign each with its entitlements.
        name="$(basename "$ext" .appex)"
        ENT="$ROOT/Extensions/$name/$name.entitlements"
        if [[ -f "$ENT" ]]; then
            codesign --force --sign - --entitlements "$ENT" --generate-entitlement-der "$ext"
        else
            codesign --force --sign - "$ext"
        fi
    done
fi
codesign --force --sign - "$STAGED_APP/Contents/MacOS/PromptLibrary Explorer"
codesign --force --sign - "$STAGED_APP"

# Swap the new bundle into place.
if [[ -e "$APP" ]]; then
    mv "$APP" "$STAGE/old.app"
fi
mv "$STAGED_APP" "$APP"

codesign --verify --deep --strict "$APP"
echo "==> Signature OK"

"$LSREGISTER" -f "$APP"
echo "==> Registered with LaunchServices: $APP"

# Register the embedded extensions with PlugInKit right away (LaunchServices would
# pick them up eventually) and drop stale Quick Look thumbnails.
for ext in "$APP/Contents/PlugIns"/*.appex; do
    pluginkit -a "$ext" 2>/dev/null || echo "    pluginkit -a failed for $(basename "$ext")" >&2
done
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true
echo "==> Registered Quick Look extensions (pluginkit -mAvvv -p com.apple.quicklook.preview)"

if (( LAUNCH )); then
    echo "==> Relaunching"
    for pid in $(pgrep -f "${EXEC_NAME}\$" || true); do
        kill -9 "$pid" 2>/dev/null || true
    done
    for _ in $(seq 1 20); do
        pgrep -f "${EXEC_NAME}\$" >/dev/null || break
        sleep 0.25
    done
    if pgrep -f "${EXEC_NAME}\$" >/dev/null; then
        echo "Old instance(s) still running: $(pgrep -f "${EXEC_NAME}\$" | tr '\n' ' ')" >&2
        exit 1
    fi
    # LaunchServices can still be tearing down the killed instance (or finishing
    # the lsregister above) and answer -600 "procNotFound"; retry a few times.
    NEW_PID=""
    for attempt in 1 2 3 4 5; do
        sleep 1
        open "$APP" 2>/dev/null || true
        for _ in $(seq 1 20); do
            NEW_PID="$(pgrep -f "${EXEC_NAME}\$" | head -1 || true)"
            [[ -n "$NEW_PID" ]] && break 2
            sleep 0.25
        done
        echo "    open attempt $attempt didn't start the app; retrying" >&2
    done
    if [[ -z "$NEW_PID" ]]; then
        echo "Failed to launch $APP" >&2
        exit 1
    fi
    echo "==> Launched, PID $NEW_PID"
fi
