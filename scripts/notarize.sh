#!/bin/bash
set -euo pipefail
umask 077

if [ "$#" -ne 1 ]; then
    echo "usage: notarize.sh path/to/artifact.app-or.dmg" >&2
    exit 2
fi
readonly ARTIFACT_PATH="$1"
if [ ! -e "$ARTIFACT_PATH" ] || [ -L "$ARTIFACT_PATH" ]; then
    echo "Artifact is missing or unsafe: $ARTIFACT_PATH" >&2
    exit 1
fi
case "$ARTIFACT_PATH" in
    *.app)
        if [ ! -d "$ARTIFACT_PATH" ]; then
            echo "The .app notarization input is not a directory: $ARTIFACT_PATH" >&2
            exit 1
        fi
        ;;
    *.dmg)
        if [ ! -f "$ARTIFACT_PATH" ]; then
            echo "The .dmg notarization input is not a file: $ARTIFACT_PATH" >&2
            exit 1
        fi
        ;;
    *)
        echo "Notarization supports only .app and .dmg artifacts." >&2
        exit 2
        ;;
esac

: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required}"

TEMPORARY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/DiskInventoryZed-notarize.XXXXXX")"
readonly TEMPORARY_DIRECTORY
readonly RESULT_PATH="$TEMPORARY_DIRECTORY/result.json"
readonly LOG_PATH="$TEMPORARY_DIRECTORY/notary-log.json"
SUBMISSION_PATH="$ARTIFACT_PATH"

cleanup() {
    rm -rf "$TEMPORARY_DIRECTORY"
}
trap cleanup EXIT

if [ -d "$ARTIFACT_PATH" ]; then
    SUBMISSION_PATH="$TEMPORARY_DIRECTORY/$(basename "$ARTIFACT_PATH").zip"
    ditto -c -k --sequesterRsrc --keepParent "$ARTIFACT_PATH" "$SUBMISSION_PATH"
fi

set +e
xcrun notarytool submit "$SUBMISSION_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait \
    --timeout 30m \
    --output-format json >"$RESULT_PATH"
SUBMIT_STATUS=$?
set -e

read -r SUBMISSION_ID NOTARY_STATUS < <(python3 - "$RESULT_PATH" <<'PY'
import json
from pathlib import Path
import sys

try:
    result = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, ValueError):
    result = {}
print(result.get("id", ""), result.get("status", ""))
PY
)
readonly SUBMISSION_ID NOTARY_STATUS
if [ "$SUBMIT_STATUS" -ne 0 ] || [ "$NOTARY_STATUS" != "Accepted" ]; then
    if [ -n "$SUBMISSION_ID" ]; then
        xcrun notarytool log "$SUBMISSION_ID" "$LOG_PATH" \
            --apple-id "$APPLE_ID" \
            --team-id "$APPLE_TEAM_ID" \
            --password "$APPLE_APP_PASSWORD" || true
        if [ -f "$LOG_PATH" ]; then
            python3 -m json.tool "$LOG_PATH" >&2 || true
        fi
    fi
    echo "Apple notarization failed with status '${NOTARY_STATUS:-unknown}'." >&2
    exit 1
fi

for attempt in 1 2 3 4 5; do
    if xcrun stapler staple "$ARTIFACT_PATH"; then
        break
    fi
    if [ "$attempt" -eq 5 ]; then
        echo "The notarization ticket could not be stapled after five attempts." >&2
        exit 1
    fi
    sleep $((1 << (attempt - 1)))
done
xcrun stapler validate "$ARTIFACT_PATH"

echo "Notarized and stapled $ARTIFACT_PATH (submission $SUBMISSION_ID)"
