#!/usr/bin/env bash
# Version scheme: MAJOR.FEATURE.FIXES  (#.#.##)
#   major    -> (MAJOR+1).0.00   breaking / big-rewrite releases
#   feature  -> MAJOR.(FEATURE+1).00   new features (resets fixes)
#   fix      -> MAJOR.FEATURE.(FIXES+1)   bug fixes / small improvements (2 digits)
# Docs-only changes don't bump the version.
#
# Source of truth: Resources/Info.plist CFBundleShortVersionString.
# CFBundleVersion (the build number) is stamped by package_app.sh from the git
# commit count, so it always increases.
#
# Usage: scripts/bump_version.sh major|feature|fix [--dry-run]
#        scripts/bump_version.sh show
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Resources/Info.plist"
PB=/usr/libexec/PlistBuddy

current="$($PB -c 'Print CFBundleShortVersionString' "$PLIST")"
if ! [[ "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]{2,})$ ]]; then
    echo "Current version '$current' isn't MAJOR.FEATURE.FIXES (#.#.##)" >&2
    exit 1
fi
major=$((10#${BASH_REMATCH[1]})); feature=$((10#${BASH_REMATCH[2]})); fixes=$((10#${BASH_REMATCH[3]}))

kind="${1:-}"
case "$kind" in
    show) echo "$current"; exit 0 ;;
    major)   major=$((major + 1)); feature=0; fixes=0 ;;
    feature) feature=$((feature + 1)); fixes=0 ;;
    fix)     fixes=$((fixes + 1)) ;;
    *) echo "Usage: $0 major|feature|fix [--dry-run] | show" >&2; exit 2 ;;
esac

next="$(printf '%d.%d.%02d' "$major" "$feature" "$fixes")"
if [[ "${2:-}" == "--dry-run" ]]; then
    echo "$current -> $next (dry run)"
    exit 0
fi
$PB -c "Set :CFBundleShortVersionString $next" "$PLIST"
plutil -lint "$PLIST" >/dev/null
echo "$current -> $next"
echo "Add a CHANGELOG.md entry for $next (repo root)."
