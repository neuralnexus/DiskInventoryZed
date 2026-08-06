#!/bin/bash
set -euo pipefail
umask 022

readonly APP_NAME="DiskInventoryZed"
SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIRECTORY
SOURCE_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd -P)"
readonly SOURCE_DIRECTORY
readonly SIGNING_IDENTITY="${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID identity or '-' for a local build}"
readonly APP_PATH="${1:-${SOURCE_DIRECTORY}/${APP_NAME}.app}"

if [ ! -d "$APP_PATH" ] || [ -L "$APP_PATH" ]; then
    echo "App bundle is missing or unsafe: $APP_PATH" >&2
    exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
readonly VERSION
readonly OUTPUT_ARGUMENT="${2:-${SOURCE_DIRECTORY}/${APP_NAME}-${VERSION}.dmg}"
mkdir -p "$(dirname "$OUTPUT_ARGUMENT")"
OUTPUT_PARENT="$(cd "$(dirname "$OUTPUT_ARGUMENT")" && pwd -P)"
readonly OUTPUT_PARENT
OUTPUT_BASENAME="$(basename "$OUTPUT_ARGUMENT")"
readonly OUTPUT_BASENAME
readonly OUTPUT_DMG="${OUTPUT_PARENT}/${OUTPUT_BASENAME}"
if [[ "$OUTPUT_DMG" != *.dmg ]]; then
    echo "DMG output path must end in .dmg: $OUTPUT_DMG" >&2
    exit 1
fi
if [ -e "$OUTPUT_DMG" ] || [ -L "$OUTPUT_DMG" ]; then
    echo "Refusing to replace an existing DMG output: $OUTPUT_DMG" >&2
    exit 1
fi

if [ "${APP_VERIFICATION_MODE:-}" = "" ]; then
    if [ "$SIGNING_IDENTITY" = "-" ]; then
        readonly APP_VERIFICATION_MODE="adhoc"
    else
        readonly APP_VERIFICATION_MODE="release"
    fi
else
    readonly APP_VERIFICATION_MODE
fi
if [ "${DISTRIBUTION_BUILD:-false}" = true ]; then
    : "${EXPECTED_VERSION:?EXPECTED_VERSION is required for a distribution build}"
fi
readonly VERIFICATION_EXPECTED_VERSION="${EXPECTED_VERSION:-$VERSION}"
EXPECTED_VERSION="$VERIFICATION_EXPECTED_VERSION" \
    "$SCRIPT_DIRECTORY/verify-macos-app.sh" "$APP_PATH" "$APP_VERIFICATION_MODE"

STAGING_ROOT="$(mktemp -d "${OUTPUT_PARENT}/.${APP_NAME}-dmg.XXXXXX")"
readonly STAGING_ROOT
readonly CONTENTS_DIRECTORY="${STAGING_ROOT}/contents"
readonly STAGED_DMG="${STAGING_ROOT}/${OUTPUT_BASENAME}"

cleanup() {
    rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

mkdir -p "$CONTENTS_DIRECTORY"
/usr/bin/ditto "$APP_PATH" "$CONTENTS_DIRECTORY/${APP_NAME}.app"
ln -s /Applications "$CONTENTS_DIRECTORY/Applications"

python3 - "$CONTENTS_DIRECTORY" <<'PY'
import os
from pathlib import Path
import sys

root = Path(sys.argv[1])
actual = set(os.listdir(root))
expected = {"DiskInventoryZed.app", "Applications"}
if actual != expected:
    raise SystemExit(f"Unexpected DMG source contents: {sorted(actual)}")
if not (root / "DiskInventoryZed.app").is_dir() or (root / "DiskInventoryZed.app").is_symlink():
    raise SystemExit("DiskInventoryZed.app must be a real directory")
if not (root / "Applications").is_symlink() or os.readlink(root / "Applications") != "/Applications":
    raise SystemExit("Applications must be a symbolic link to /Applications")
PY

EXPECTED_VERSION="$VERIFICATION_EXPECTED_VERSION" \
    "$SCRIPT_DIRECTORY/verify-macos-app.sh" \
    "$CONTENTS_DIRECTORY/${APP_NAME}.app" \
    "$APP_VERIFICATION_MODE"

hdiutil create \
    -srcfolder "$CONTENTS_DIRECTORY" \
    -volname "Disk Inventory Zed" \
    -fs HFS+ \
    -format UDZO \
    -nospotlight \
    -atomic \
    "$STAGED_DMG"

if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign --sign - --force "$STAGED_DMG"
else
    codesign --sign "$SIGNING_IDENTITY" --force --timestamp "$STAGED_DMG"
fi
codesign --verify --strict --verbose=2 "$STAGED_DMG"
hdiutil verify "$STAGED_DMG"

"$SCRIPT_DIRECTORY/atomic-publish.py" "$STAGED_DMG" "$OUTPUT_DMG"
echo "Created $OUTPUT_DMG"
