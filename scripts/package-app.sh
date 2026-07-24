#!/bin/bash
set -euo pipefail

readonly APP_NAME="DiskInventoryZed"
readonly APP_BUNDLE="${APP_NAME}.app"
readonly BINARY_PATH=".build/apple/Products/release/${APP_NAME}"
readonly SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

if [ ! -f "$BINARY_PATH" ]; then
    echo "Binary not found at $BINARY_PATH" >&2
    exit 1
fi

if [ ! -f "Resources/Info.plist" ]; then
    echo "Resources/Info.plist is missing" >&2
    exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
install -m 755 "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
install -m 644 "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

if [ -f "images/AppIcon.icns" ]; then
    install -m 644 "images/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

plutil -lint "$APP_BUNDLE/Contents/Info.plist"

if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign --force --deep --sign - "$APP_BUNDLE"
else
    codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --entitlements DiskInventoryZed.app.entitlements \
        --sign "$SIGNING_IDENTITY" \
        "$APP_BUNDLE"
fi

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

readonly ARCHITECTURES="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME")"
if [[ "$ARCHITECTURES" != *"arm64"* || "$ARCHITECTURES" != *"x86_64"* ]]; then
    echo "Expected a universal binary, found: $ARCHITECTURES" >&2
    exit 1
fi

echo "Packaged $APP_BUNDLE ($ARCHITECTURES)"
