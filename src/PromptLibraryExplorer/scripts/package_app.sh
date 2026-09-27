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
# HOOK: Quick Look / app extensions (currently a no-op).
# A future step will build PLX*.appex (e.g. into $BUILD_DIR or an Extensions/
# staging dir in the package root). Any found are embedded in Contents/PlugIns/
# and signed below before the app itself.
# ---------------------------------------------------------------------------
APPEXES=("$BUILD_DIR"/PLX*.appex "$ROOT"/Extensions/*.appex)
shopt -u nullglob
if (( ${#APPEXES[@]} > 0 )); then
    mkdir -p "$STAGED_APP/Contents/PlugIns"
    for ext in "${APPEXES[@]}"; do
        echo "    plugin: $(basename "$ext")"
        cp -R "$ext" "$STAGED_APP/Contents/PlugIns/"
    done
fi

echo "==> Ad-hoc signing"
# Nested code first (inside-out), then the app.
if [[ -d "$STAGED_APP/Contents/PlugIns" ]]; then
    for ext in "$STAGED_APP/Contents/PlugIns"/*.appex; do
        codesign --force --sign - "$ext"
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
    open "$APP"
    for _ in $(seq 1 40); do
        NEW_PID="$(pgrep -f "${EXEC_NAME}\$" | head -1 || true)"
        [[ -n "$NEW_PID" ]] && break
        sleep 0.25
    done
    echo "==> Launched, PID ${NEW_PID:-unknown}"
fi
