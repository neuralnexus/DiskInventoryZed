#!/bin/bash
set -euo pipefail

readonly HELPER_APP="${1:-First-Run-Helper.app}"
readonly SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
readonly HELPER_SOURCE="scripts/First-Run-Helper.applescript"

if [ ! -f "$HELPER_SOURCE" ]; then
    echo "Helper source not found: $HELPER_SOURCE" >&2
    exit 1
fi

rm -rf "$HELPER_APP"
osacompile -o "$HELPER_APP" "$HELPER_SOURCE"

if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign --force --deep --sign - "$HELPER_APP"
else
    codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$HELPER_APP"
fi

codesign --verify --deep --strict --verbose=2 "$HELPER_APP"
echo "Packaged $HELPER_APP"
