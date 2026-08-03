#!/bin/bash
set -euo pipefail

readonly ARTIFACT_PATH="${1:?usage: notarize.sh path/to/artifact.app-or.dmg}"

if [ ! -e "$ARTIFACT_PATH" ]; then
    echo "Artifact not found: $ARTIFACT_PATH" >&2
    exit 1
fi

: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required}"

SUBMISSION_PATH="$ARTIFACT_PATH"
TEMP_DIR=""
cleanup() {
    if [ -n "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

if [ -d "$ARTIFACT_PATH" ]; then
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/DiskInventoryZed-notarize.XXXXXX")"
    SUBMISSION_PATH="$TEMP_DIR/$(basename "$ARTIFACT_PATH").zip"
    ditto -c -k --sequesterRsrc --keepParent "$ARTIFACT_PATH" "$SUBMISSION_PATH"
fi

xcrun notarytool submit "$SUBMISSION_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
xcrun stapler staple "$ARTIFACT_PATH"
xcrun stapler validate "$ARTIFACT_PATH"
