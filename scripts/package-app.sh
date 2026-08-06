#!/bin/bash
set -euo pipefail
umask 022

readonly APP_NAME="DiskInventoryZed"
SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIRECTORY
SOURCE_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd -P)"
readonly SOURCE_DIRECTORY
readonly SIGNING_IDENTITY="${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID identity or '-' for a local build}"
readonly OUTPUT_ARGUMENT="${1:-${SOURCE_DIRECTORY}/${APP_NAME}.app}"

mkdir -p "$(dirname "$OUTPUT_ARGUMENT")"
OUTPUT_PARENT="$(cd "$(dirname "$OUTPUT_ARGUMENT")" && pwd -P)"
readonly OUTPUT_PARENT
OUTPUT_BASENAME="$(basename "$OUTPUT_ARGUMENT")"
readonly OUTPUT_BASENAME
readonly OUTPUT_APP="${OUTPUT_PARENT}/${OUTPUT_BASENAME}"
if [[ "$OUTPUT_APP" != *.app ]]; then
    echo "App output path must end in .app: $OUTPUT_APP" >&2
    exit 1
fi
if { [ -e "$OUTPUT_APP" ] && [ ! -d "$OUTPUT_APP" ]; } || [ -L "$OUTPUT_APP" ]; then
    echo "Refusing to replace a non-directory or symbolic-link app output: $OUTPUT_APP" >&2
    exit 1
fi

readonly INFO_PLIST="${SOURCE_DIRECTORY}/Resources/Info.plist"
readonly ICON_PATH="${SOURCE_DIRECTORY}/images/AppIcon.icns"
readonly ENTITLEMENTS_PATH="${SOURCE_DIRECTORY}/DiskInventoryZed.app.entitlements"
for required_path in "$INFO_PLIST" "$ICON_PATH" "$ENTITLEMENTS_PATH"; do
    if [ ! -f "$required_path" ]; then
        echo "Required app resource is missing: $required_path" >&2
        exit 1
    fi
done

BINARY_DIRECTORY="$(
    cd "$SOURCE_DIRECTORY"
    swift build -c release --arch arm64 --arch x86_64 --show-bin-path
)"
readonly BINARY_DIRECTORY
readonly BINARY_PATH="${BINARY_DIRECTORY}/${APP_NAME}"
if [ ! -f "$BINARY_PATH" ]; then
    echo "Binary not found at $BINARY_PATH" >&2
    exit 1
fi

STAGING_ROOT="$(mktemp -d "${OUTPUT_PARENT}/.${APP_NAME}-app.XXXXXX")"
readonly STAGING_ROOT
readonly STAGED_APP="${STAGING_ROOT}/${APP_NAME}.app"

cleanup() {
    local exit_status=$?
    trap - EXIT
    rm -rf "$STAGING_ROOT"
    exit "$exit_status"
}
trap cleanup EXIT

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources/Legal"
install -m 755 "$BINARY_PATH" "$STAGED_APP/Contents/MacOS/$APP_NAME"
install -m 644 "$INFO_PLIST" "$STAGED_APP/Contents/Info.plist"
install -m 644 "$ICON_PATH" "$STAGED_APP/Contents/Resources/AppIcon.icns"
install -m 644 "$SOURCE_DIRECTORY/LICENSE" "$STAGED_APP/Contents/Resources/Legal/LICENSE.txt"
install -m 644 \
    "$SOURCE_DIRECTORY/Legal/PROJECT-NOTICE.txt" \
    "$SOURCE_DIRECTORY/Legal/Credits.rtf" \
    "$STAGED_APP/Contents/Resources/Legal/"
install -m 644 \
    "$SOURCE_DIRECTORY/Legal/Credits.rtf" \
    "$STAGED_APP/Contents/Resources/Credits.rtf"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
readonly VERSION
PROJECT_COMMIT="$(git -C "$SOURCE_DIRECTORY" rev-parse --verify 'HEAD^{commit}')"
readonly PROJECT_COMMIT
if [ "${DISTRIBUTION_BUILD:-false}" = true ]; then
    : "${EXPECTED_VERSION:?EXPECTED_VERSION is required for a distribution build}"
    : "${SOURCE_ARCHIVE_NAME:?SOURCE_ARCHIVE_NAME is required for a distribution build}"
    : "${SOURCE_ARCHIVE_SHA256:?SOURCE_ARCHIVE_SHA256 is required for a distribution build}"
fi
readonly VERIFICATION_EXPECTED_VERSION="${EXPECTED_VERSION:-$VERSION}"

python3 - \
    "$STAGED_APP/Contents/Resources/Legal/SOURCE-ACCESS.txt" \
    "$VERSION" \
    "$PROJECT_COMMIT" \
    "${SOURCE_ARCHIVE_NAME:-}" \
    "${SOURCE_ARCHIVE_SHA256:-}" <<'PY'
from pathlib import Path
import sys

output = Path(sys.argv[1])
version, commit, source_name, source_hash = sys.argv[2:]
if source_name and source_hash:
    location = (
        "Corresponding source for this object-code release is available from "
        "the same GitHub release at no additional charge.\n\n"
        f"URL: https://github.com/neuralnexus/DiskInventoryZed/releases/download/v{version}/{source_name}\n"
        f"SHA-256: {source_hash}\n"
    )
else:
    location = (
        "This is a local development build. Its recorded project source is at:\n\n"
        f"https://github.com/neuralnexus/DiskInventoryZed/tree/{commit}\n"
    )
output.write_text(
    "Disk Inventory Zed Corresponding Source\n"
    "=======================================\n\n"
    + location
    + f"Project commit: {commit}\n",
    encoding="utf-8",
)
PY

plutil -lint "$STAGED_APP/Contents/Info.plist"
if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign \
        --sign - \
        --force \
        --options runtime \
        --entitlements "$ENTITLEMENTS_PATH" \
        "$STAGED_APP"
    readonly VERIFICATION_MODE="adhoc"
else
    codesign \
        --sign "$SIGNING_IDENTITY" \
        --force \
        --options runtime \
        --timestamp \
        --entitlements "$ENTITLEMENTS_PATH" \
        "$STAGED_APP"
    readonly VERIFICATION_MODE="release"
fi

EXPECTED_VERSION="$VERIFICATION_EXPECTED_VERSION" \
    "$SCRIPT_DIRECTORY/verify-macos-app.sh" "$STAGED_APP" "$VERIFICATION_MODE"

"$SCRIPT_DIRECTORY/atomic-publish.py" \
    --replace-directory \
    "$STAGED_APP" \
    "$OUTPUT_APP"

echo "Packaged $OUTPUT_APP ($(lipo -archs "$OUTPUT_APP/Contents/MacOS/$APP_NAME"))"
