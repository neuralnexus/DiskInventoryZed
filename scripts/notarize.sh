#!/bin/bash
set -euo pipefail

readonly DMG_PATH="${1:?usage: notarize.sh path/to/DiskInventoryZed.dmg}"

if [ ! -f "$DMG_PATH" ]; then
    echo "DMG not found: $DMG_PATH" >&2
    exit 1
fi

: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required}"

xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
