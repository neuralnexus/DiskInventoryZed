#!/bin/bash
set -euo pipefail

readonly APP_PATH="${1:?usage: verify-macos-app.sh path/to/DiskInventoryZed.app [adhoc|release|notarized]}"
readonly MODE="${2:-adhoc}"
readonly EXPECTED_BUNDLE_ID="com.diskinventoryzed.DiskInventoryZed"
readonly EXPECTED_EXECUTABLE="DiskInventoryZed"

case "$MODE" in
    adhoc|release|notarized) ;;
    *)
        echo "Unknown app verification mode: $MODE" >&2
        exit 2
        ;;
esac
if [ ! -d "$APP_PATH" ] || [ -L "$APP_PATH" ]; then
    echo "App bundle is missing or is a symbolic link: $APP_PATH" >&2
    exit 1
fi
if [ "$MODE" != adhoc ]; then
    : "${EXPECTED_TEAM_ID:?EXPECTED_TEAM_ID is required for release verification}"
    : "${EXPECTED_VERSION:?EXPECTED_VERSION is required for release verification}"
fi

readonly INFO_PLIST="$APP_PATH/Contents/Info.plist"
readonly EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXPECTED_EXECUTABLE"
readonly ICON_PATH="$APP_PATH/Contents/Resources/AppIcon.icns"
readonly LEGAL_DIRECTORY="$APP_PATH/Contents/Resources/Legal"
for required_path in \
    "$INFO_PLIST" \
    "$EXECUTABLE_PATH" \
    "$ICON_PATH" \
    "$LEGAL_DIRECTORY/LICENSE.txt" \
    "$LEGAL_DIRECTORY/PROJECT-NOTICE.txt" \
    "$LEGAL_DIRECTORY/SOURCE-ACCESS.txt" \
    "$APP_PATH/Contents/Resources/Credits.rtf"; do
    if [ ! -f "$required_path" ] || [ -L "$required_path" ]; then
        echo "Required app payload is missing or unsafe: $required_path" >&2
        exit 1
    fi
done

python3 - "$INFO_PLIST" "${EXPECTED_VERSION:-}" <<'PY'
import plistlib
import re
import sys

with open(sys.argv[1], "rb") as source:
    info = plistlib.load(source)
expected = {
    "CFBundleIdentifier": "com.diskinventoryzed.DiskInventoryZed",
    "CFBundleExecutable": "DiskInventoryZed",
    "CFBundlePackageType": "APPL",
    "LSMinimumSystemVersion": "13.0",
    "CFBundleIconFile": "AppIcon",
}
for key, value in expected.items():
    if info.get(key) != value:
        raise SystemExit(f"Unexpected {key}: {info.get(key)!r}")
if sys.argv[2] and info.get("CFBundleShortVersionString") != sys.argv[2]:
    raise SystemExit("The app version does not match the expected release version")
if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", str(info.get("CFBundleVersion", ""))):
    raise SystemExit("CFBundleVersion must be numeric")
for key in (
    "NSDesktopFolderUsageDescription",
    "NSDocumentsFolderUsageDescription",
    "NSDownloadsFolderUsageDescription",
    "NSNetworkVolumesUsageDescription",
    "NSRemovableVolumesUsageDescription",
):
    if not isinstance(info.get(key), str) or not info[key].strip():
        raise SystemExit(f"Missing privacy purpose string: {key}")
PY

python3 - "$LEGAL_DIRECTORY/LICENSE.txt" <<'PY'
import hashlib
from pathlib import Path
import sys

expected = "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"
actual = hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest()
if actual != expected:
    raise SystemExit("The app does not contain the canonical GPLv3 license text")
PY

ARCHITECTURES="$(lipo -archs "$EXECUTABLE_PATH")"
readonly ARCHITECTURES
python3 - "$ARCHITECTURES" <<'PY'
import sys

architectures = sys.argv[1].split()
if len(architectures) != 2 or set(architectures) != {"arm64", "x86_64"}:
    raise SystemExit(f"Expected exactly arm64 and x86_64, found: {architectures}")
PY

verification_arguments=(--verify --all-architectures --deep --strict --verbose=2)
if [ "$MODE" = notarized ]; then
    verification_arguments+=(--check-notarization)
fi
if [ "$MODE" = adhoc ]; then
    codesign "${verification_arguments[@]}" "$APP_PATH"
else
    readonly APPLICATION_REQUIREMENT="=anchor apple generic and certificate leaf[subject.OU] = \"${EXPECTED_TEAM_ID}\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and identifier \"${EXPECTED_BUNDLE_ID}\""
    codesign "${verification_arguments[@]}" -R "$APPLICATION_REQUIREMENT" "$APP_PATH"
fi

TEMPORARY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/DiskInventoryZed-app-verify.XXXXXX")"
readonly TEMPORARY_DIRECTORY
cleanup() {
    rm -rf "$TEMPORARY_DIRECTORY"
}
trap cleanup EXIT

for architecture in arm64 x86_64; do
    display_path="$TEMPORARY_DIRECTORY/codesign-$architecture.txt"
    codesign --display --architecture "$architecture" --verbose=4 "$APP_PATH" \
        >/dev/null 2>"$display_path"
    grep -Fq "Identifier=$EXPECTED_BUNDLE_ID" "$display_path"
    grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)' "$display_path"
    if [ "$MODE" != adhoc ]; then
        grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" "$display_path"
        grep -Eq '^Authority=Developer ID Application:' "$display_path"
        grep -Eq '^Timestamp=.+$' "$display_path"
        if grep -Fq 'Timestamp=none' "$display_path"; then
            echo "The $architecture signature does not have a secure timestamp." >&2
            exit 1
        fi
    fi
    entitlements_path="$TEMPORARY_DIRECTORY/entitlements-$architecture.plist"
    if ! codesign \
        --display \
        --architecture "$architecture" \
        --entitlements :- \
        "$APP_PATH" >"$entitlements_path" 2>/dev/null; then
        echo "Could not read $architecture entitlements." >&2
        exit 1
    fi
    if [ -s "$entitlements_path" ]; then
        python3 - "$entitlements_path" "$architecture" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    entitlements = plistlib.load(source)
if entitlements != {}:
    raise SystemExit(f"Unexpected {sys.argv[2]} app entitlements: {sorted(entitlements)}")
PY
    fi
done

if [ "$MODE" = notarized ]; then
    xcrun stapler validate "$APP_PATH"
fi

echo "Verified $APP_PATH ($MODE; $ARCHITECTURES)"
