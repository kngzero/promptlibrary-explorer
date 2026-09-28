#!/usr/bin/env bash
# Build PromptLibraryExplorer (release), assemble "PromptLibrary Explorer.app" from
# scratch, INSTALL it to /Applications and keep a zipped build copy in dist/.
#
# Usage:
#   scripts/package_app.sh               # build + assemble + sign + zip + install + register
#   scripts/package_app.sh --launch      # ...then kill running instances and open the installed app
#   scripts/package_app.sh --no-install  # build + assemble + sign + zip only (alias: --zip-only)
#
# Where things go:
#   Installed app : /Applications/PromptLibrary Explorer.app
#                   (~/Applications/... if /Applications isn't writable; the script says so)
#   Build copies  : <package root>/dist/PromptLibrary Explorer-<version>-<git sha>.zip
#                   <package root>/dist/PromptLibrary Explorer-latest.zip
#                   (the last 5 versioned zips are kept; dist/ is git-ignored)
#
# Why a zip and not an unzipped .app in the package root (Dropbox): LaunchServices and
# pluginkit register every .app they see on disk. An unzipped copy in Dropbox became a
# second registered "PromptLibrary Explorer" whose Quick Look extensions clashed with the
# installed one (pluginkit elects one copy per extension id, often the stale one). A zip
# is inert. The old in-repo .app is unregistered and deleted after a successful install.
#
# Notes:
#   - The Command Line Tools toolchain can't evaluate SwiftPM manifests on this
#     machine; the Xcode toolchain works, so DEVELOPER_DIR defaults to Xcode.
#   - The bundle's Info.plist is sourced from Resources/Info.plist (tracked in git).
#   - The bundle is assembled in $TMPDIR (outside Dropbox), then copied into a hidden
#     temp sibling in the install dir and swapped in with rename(2).
#   - Only these are ever deleted: files in dist/, the old in-repo .app, the target app
#     in the install dir (replaced), and this script's own temp dirs.
set -euo pipefail

LAUNCH=0
INSTALL=1
for arg in "$@"; do
    case "$arg" in
        --launch) LAUNCH=1 ;;
        --no-install|--zip-only) INSTALL=0 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done
if (( LAUNCH && !INSTALL )); then
    echo "--launch needs an installed app; drop --no-install/--zip-only" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PromptLibrary Explorer.app"
ZIP_BASE="PromptLibrary Explorer"
LEGACY_APP="$ROOT/$APP_NAME"          # old unzipped copy in the package root (Dropbox)
DIST="$ROOT/dist"
KEEP_ZIPS=5
EXEC_NAME="PromptLibraryExplorer"
RES="$ROOT/Resources"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cd "$ROOT"

# Temp dirs, all removed on exit.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/package_app.XXXXXX")"
INSTALL_TMP=""
cleanup() {
    rm -rf "$STAGE"
    if [[ -n "$INSTALL_TMP" && -d "$INSTALL_TMP" ]]; then
        rm -rf "$INSTALL_TMP"
    fi
}
trap cleanup EXIT

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
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$RES/Info.plist")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$RES/Info.plist")"
GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
EXT_IDS=()
for ext in "${QL_EXTENSIONS[@]}"; do
    EXT_IDS+=("$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$ROOT/Extensions/$ext/Info.plist")")
done

STAGED_APP="$STAGE/$APP_NAME"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

echo "==> Assembling bundle ($APP_ID $VERSION, $GIT_SHA)"
cp "$RES/Info.plist" "$STAGED_APP/Contents/Info.plist"
# Build number: the git commit count, so it always increases (the marketing version
# MAJOR.FEATURE.FIXES lives in Resources/Info.plist; see scripts/bump_version.sh).
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$STAGED_APP/Contents/Info.plist"
# Build identity for the About panel (not in the tracked plist: it changes every commit).
/usr/libexec/PlistBuddy -c "Add :PLXGitCommit string $GIT_SHA" "$STAGED_APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :PLXGitCommit $GIT_SHA" "$STAGED_APP/Contents/Info.plist"
cp "$BUILD_DIR/$EXEC_NAME" "$STAGED_APP/Contents/MacOS/$EXEC_NAME"
# Existing convention: a second copy named after the display name. Keep both.
cp "$BUILD_DIR/$EXEC_NAME" "$STAGED_APP/Contents/MacOS/PromptLibrary Explorer"
cp "$RES/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"

# App Intents metadata (Shortcuts actions). SwiftPM doesn't run Xcode's "Extract App
# Intents Metadata" phase, so do it here: the release build emits the compiler's const
# values for the App Intents protocols (Package.swift, appIntentsFlags) and Xcode's
# appintentsmetadataprocessor turns them into Contents/Resources/Metadata.appintents,
# which LaunchServices reads when the app is registered. Without it the app still
# works (and promptlibrary:// links still do); Shortcuts just won't list the actions.
AIMP="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor"
CONST_VALUES="$ROOT/.build/appintents/$EXEC_NAME.swiftconstvalues"
if [[ -x "$AIMP" && -f "$CONST_VALUES" ]]; then
    echo "==> Extracting App Intents metadata"
    find "$ROOT/$EXEC_NAME" -name '*.swift' > "$STAGE/appintents-sources.txt"
    echo "$CONST_VALUES" > "$STAGE/appintents-constvalues.txt"
    XCODE_BUILD_VERSION="$(xcodebuild -version 2>/dev/null | awk '/Build version/ { print $3 }')"
    DEPLOYMENT_TARGET="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$RES/Info.plist" 2>/dev/null || echo 14.0)"
    if "$AIMP" \
        --output "$STAGED_APP/Contents/Resources" \
        --toolchain-dir "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain" \
        --module-name "$EXEC_NAME" \
        --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
        --xcode-version "${XCODE_BUILD_VERSION:-unknown}" \
        --platform-family macOS \
        --deployment-target "$DEPLOYMENT_TARGET" \
        --target-triple "$(uname -m)-apple-macos$DEPLOYMENT_TARGET" \
        --binary-file "$STAGED_APP/Contents/MacOS/$EXEC_NAME" \
        --bundle-identifier "$APP_ID" \
        --source-file-list "$STAGE/appintents-sources.txt" \
        --swift-const-vals-list "$STAGE/appintents-constvalues.txt" \
        > "$STAGE/appintents.log" 2>&1 \
        && [[ -f "$STAGED_APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]]
    then
        echo "    Metadata.appintents: $(/usr/bin/python3 -c 'import json,sys; print(", ".join(sorted(json.load(open(sys.argv[1]))["actions"])))' \
            "$STAGED_APP/Contents/Resources/Metadata.appintents/extract.actionsdata" 2>/dev/null || echo written)"
    else
        echo "    WARNING: App Intents metadata extraction failed; Shortcuts won't list the actions:" >&2
        sed 's/^/    /' "$STAGE/appintents.log" | tail -20 >&2
        rm -rf "$STAGED_APP/Contents/Resources/Metadata.appintents"
    fi
else
    echo "    WARNING: no App Intents const values ($CONST_VALUES); Shortcuts won't list the actions" >&2
fi

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
codesign --verify --deep --strict "$STAGED_APP"
echo "==> Signature OK (staged)"

# ---------------------------------------------------------------------------
# Zipped build copy in dist/ (inside the package root, i.e. Dropbox).
# ---------------------------------------------------------------------------
mkdir -p "$DIST"
ZIP="$DIST/$ZIP_BASE-$VERSION-$GIT_SHA.zip"
LATEST_ZIP="$DIST/$ZIP_BASE-latest.zip"
echo "==> Zipping build copy -> $ZIP"
# --norsrc/--noextattr: no ._AppleDouble files inside the bundle (they break codesign
# when the zip is expanded with plain unzip); signatures are embedded, not xattrs.
ditto -c -k --keepParent --norsrc --noextattr --noacl "$STAGED_APP" "$STAGE/build.zip"
cp "$STAGE/build.zip" "$DIST/.$ZIP_BASE-$GIT_SHA.zip.tmp"
mv -f "$DIST/.$ZIP_BASE-$GIT_SHA.zip.tmp" "$ZIP"
cp "$STAGE/build.zip" "$DIST/.$ZIP_BASE-latest.zip.tmp"
mv -f "$DIST/.$ZIP_BASE-latest.zip.tmp" "$LATEST_ZIP"
echo "    latest: $LATEST_ZIP"
# Keep the newest $KEEP_ZIPS versioned zips (by mtime); never touches -latest.zip.
n=0
while IFS= read -r z; do
    [[ -n "$z" ]] || continue
    [[ "$z" == "$ZIP_BASE-latest.zip" ]] && continue
    n=$((n + 1))
    if (( n > KEEP_ZIPS )); then
        echo "    pruning old zip: $z"
        rm -f "$DIST/$z"
    fi
done < <(cd "$DIST" && ls -t -- "$ZIP_BASE"-*.zip 2>/dev/null || true)

if (( !INSTALL )); then
    echo "==> --no-install: skipped install; build copy is $ZIP"
    exit 0
fi

# ---------------------------------------------------------------------------
# Install: copy into a hidden temp sibling in the install dir, verify, then swap.
# ---------------------------------------------------------------------------
INSTALL_DIR="/Applications"
if [[ ! -w "$INSTALL_DIR" ]]; then
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
    echo "==> /Applications is not writable; installing to $INSTALL_DIR instead"
fi
INSTALLED_APP="$INSTALL_DIR/$APP_NAME"

echo "==> Installing -> $INSTALLED_APP"
INSTALL_TMP="$(mktemp -d "$INSTALL_DIR/.package_app.install.XXXXXX")"
ditto "$STAGED_APP" "$INSTALL_TMP/$APP_NAME"
codesign --verify --deep --strict "$INSTALL_TMP/$APP_NAME"
if [[ -e "$INSTALLED_APP" ]]; then
    mv "$INSTALLED_APP" "$INSTALL_TMP/previous.app"
fi
mv "$INSTALL_TMP/$APP_NAME" "$INSTALLED_APP"
# The previous install (if any) is only unregistered here; cleanup() deletes it.
if [[ -d "$INSTALL_TMP/previous.app" ]]; then
    "$LSREGISTER" -u "$INSTALL_TMP/previous.app" >/dev/null 2>&1 || true
fi
codesign --verify --deep --strict "$INSTALLED_APP"
echo "==> Signature OK (installed)"

# ---------------------------------------------------------------------------
# Retire the old unzipped copy in the package root (only after a good install).
# ---------------------------------------------------------------------------
if [[ -d "$LEGACY_APP" ]]; then
    echo "==> Removing old in-repo bundle: $LEGACY_APP"
    shopt -s nullglob
    for appex in "$LEGACY_APP/Contents/PlugIns"/*.appex; do
        pluginkit -r "$appex" >/dev/null 2>&1 || true
    done
    shopt -u nullglob
    "$LSREGISTER" -u "$LEGACY_APP" >/dev/null 2>&1 || true
    rm -rf "$LEGACY_APP"
fi

# ---------------------------------------------------------------------------
# Register the installed copy and its Quick Look extensions.
# ---------------------------------------------------------------------------
"$LSREGISTER" -f "$INSTALLED_APP"
echo "==> Registered with LaunchServices: $INSTALLED_APP"
for ext in "$INSTALLED_APP/Contents/PlugIns"/*.appex; do
    pluginkit -a "$ext" 2>/dev/null || echo "    pluginkit -a failed for $(basename "$ext")" >&2
done

# Drop registrations of any other copy (old Dropbox path, stale installs, ...).
# Unregister only; nothing outside the paths listed in the header is deleted.
stale_paths() {
    local id
    for id in "${EXT_IDS[@]}"; do
        pluginkit -mAvvv -i "$id" 2>/dev/null | sed -n 's/^[[:space:]]*Path = //p' || true
    done
    for sdk in com.apple.quicklook.preview com.apple.quicklook.thumbnail; do
        pluginkit -mAvvv -p "$sdk" 2>/dev/null | sed -n 's/^[[:space:]]*Path = //p' \
            | grep -F -e "${QL_EXTENSIONS[0]}.appex" -e "${QL_EXTENSIONS[1]}.appex" || true
    done
    # LaunchServices records are separated by "-----" lines; "identifier:" comes before
    # "path:" in plugin records and after it in bundle records, so collect both per
    # record and emit at the separator. (Pairing across records once unregistered two
    # unrelated /System extensions; the basename filter below is a second guard.)
    "$LSREGISTER" -dump 2>/dev/null | awk -v ids="$APP_ID ${EXT_IDS[*]}" '
        function flush() { if ((id in want) && p != "") print p; id = ""; p = "" }
        BEGIN { n = split(ids, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
        /^-----/ { flush(); next }
        /^path:/ && p == "" { p = $0; sub(/^path:[[:space:]]*/, "", p); sub(/ \(0x[0-9a-f]+\)$/, "", p) }
        /^identifier:/ && id == "" { id = $2 }
        END { flush() }
    ' || true
}
while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    case "$p" in
        "$INSTALLED_APP"|"$INSTALLED_APP"/*) continue ;;
        /System/*) continue ;;
    esac
    # Only ever touch our own bundle names.
    case "$(basename "$p")" in
        "$APP_NAME"|"${QL_EXTENSIONS[0]}.appex"|"${QL_EXTENSIONS[1]}.appex") ;;
        *) continue ;;
    esac
    echo "    unregistering stale copy: $p"
    if [[ "$p" == *.appex ]]; then
        pluginkit -r "$p" >/dev/null 2>&1 || true
    fi
    "$LSREGISTER" -u "$p" >/dev/null 2>&1 || true
done < <(stale_paths | sort -u)

qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true
echo "==> Registered Quick Look extensions:"
for id in "${EXT_IDS[@]}"; do
    pluginkit -mAvvv -i "$id" 2>/dev/null | sed -n 's/^[[:space:]]*Path = /    /p' || true
done

if (( LAUNCH )); then
    echo "==> Relaunching"
    # Matches by executable name, so it also kills an instance running from any old path.
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
        open "$INSTALLED_APP" 2>/dev/null || true
        for _ in $(seq 1 20); do
            NEW_PID="$(pgrep -f "${EXEC_NAME}\$" | head -1 || true)"
            [[ -n "$NEW_PID" ]] && break 2
            sleep 0.25
        done
        echo "    open attempt $attempt didn't start the app; retrying" >&2
    done
    if [[ -z "$NEW_PID" ]]; then
        echo "Failed to launch $INSTALLED_APP" >&2
        exit 1
    fi
    echo "==> Launched, PID $NEW_PID ($(ps -o comm= -p "$NEW_PID"))"
fi

echo "==> Done: installed $INSTALLED_APP, build copy $ZIP"
