#!/bin/bash
set -euo pipefail

readonly DMG_PATH="${1:?usage: verify-macos-dmg.sh path/to/DiskInventoryZed.dmg [adhoc|release|notarized]}"
readonly MODE="${2:-adhoc}"
SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIRECTORY
case "$MODE" in
    adhoc|release|notarized) ;;
    *)
        echo "Unknown DMG verification mode: $MODE" >&2
        exit 2
        ;;
esac
if [ ! -f "$DMG_PATH" ] || [ -L "$DMG_PATH" ]; then
    echo "DMG is missing or unsafe: $DMG_PATH" >&2
    exit 1
fi
if [ "$MODE" != adhoc ]; then
    : "${EXPECTED_TEAM_ID:?EXPECTED_TEAM_ID is required for release verification}"
    : "${EXPECTED_VERSION:?EXPECTED_VERSION is required for release verification}"
fi

verification_arguments=(--verify --strict --verbose=2)
if [ "$MODE" = notarized ]; then
    verification_arguments+=(--check-notarization)
fi
if [ "$MODE" = adhoc ]; then
    codesign "${verification_arguments[@]}" "$DMG_PATH"
else
    readonly DEVELOPER_ID_REQUIREMENT="=anchor apple generic and certificate leaf[subject.OU] = \"${EXPECTED_TEAM_ID}\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    codesign "${verification_arguments[@]}" -R "$DEVELOPER_ID_REQUIREMENT" "$DMG_PATH"
    SIGNATURE_DETAILS="$(codesign --display --verbose=4 "$DMG_PATH" 2>&1 >/dev/null)"
    grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" <<<"$SIGNATURE_DETAILS"
    grep -Eq '^Authority=Developer ID Application:' <<<"$SIGNATURE_DETAILS"
    grep -Eq '^Timestamp=.+$' <<<"$SIGNATURE_DETAILS"
    if grep -Fq 'Timestamp=none' <<<"$SIGNATURE_DETAILS"; then
        echo "The DMG signature does not have a secure timestamp." >&2
        exit 1
    fi
fi
hdiutil verify "$DMG_PATH"

if [ "$MODE" = notarized ]; then
    xcrun stapler validate "$DMG_PATH"
    if [ "$(spctl --status)" != "assessments enabled" ]; then
        echo "Gatekeeper assessments are not enabled on the release runner." >&2
        exit 1
    fi
    spctl --assess \
        --ignore-cache \
        --no-cache \
        --type open \
        --context context:primary-signature \
        --verbose=4 \
        "$DMG_PATH"
fi

MOUNT_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/DiskInventoryZed-mount.XXXXXX")"
readonly MOUNT_DIRECTORY
ATTACHED=false

detach() {
    local attempt
    if ! /usr/sbin/diskutil info "$MOUNT_DIRECTORY" >/dev/null 2>&1; then
        ATTACHED=false
        return 0
    fi
    for attempt in 1 2 3 4 5; do
        if hdiutil detach "$MOUNT_DIRECTORY"; then
            ATTACHED=false
            return 0
        fi
        sleep "$attempt"
    done
    return 1
}

cleanup() {
    local exit_status=$?
    trap - EXIT
    if [ "$ATTACHED" = true ] && ! detach; then
        echo "Could not detach the verification mount at $MOUNT_DIRECTORY" >&2
        exit_status=1
    fi
    rmdir "$MOUNT_DIRECTORY" 2>/dev/null || true
    exit "$exit_status"
}
trap cleanup EXIT

ATTACHED=true
hdiutil attach "$DMG_PATH" \
    -readonly \
    -nobrowse \
    -noautoopen \
    -mountpoint "$MOUNT_DIRECTORY" >/dev/null

python3 - "$MOUNT_DIRECTORY" <<'PY'
import os
from pathlib import Path
import sys

root = Path(sys.argv[1])
actual = set(os.listdir(root))
expected = {"DiskInventoryZed.app", "Applications"}
if actual != expected:
    raise SystemExit(f"Unexpected DMG contents: {sorted(actual)}")
app = root / "DiskInventoryZed.app"
applications = root / "Applications"
if app.is_symlink() or not app.is_dir():
    raise SystemExit("DiskInventoryZed.app is not a real app directory")
if not applications.is_symlink() or os.readlink(applications) != "/Applications":
    raise SystemExit("Applications does not link to /Applications")
PY

readonly MOUNTED_APP="$MOUNT_DIRECTORY/DiskInventoryZed.app"
EXPECTED_VERSION="${EXPECTED_VERSION:-}" \
    "$SCRIPT_DIRECTORY/verify-macos-app.sh" "$MOUNTED_APP" "$MODE"
if [ "$MODE" = notarized ]; then
    spctl --assess \
        --ignore-cache \
        --no-cache \
        --type execute \
        --verbose=4 \
        "$MOUNTED_APP"
fi

detach
echo "Verified $DMG_PATH ($MODE)"
