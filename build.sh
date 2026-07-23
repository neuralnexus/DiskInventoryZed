#!/bin/bash
set -e

APP_NAME="DiskInventoryZed"
BUNDLE_ID="com.diskinventoryzed.DiskInventoryZed"
BUILD_CONFIG="release"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Building Disk Inventory Zed...${NC}"

# Build universal binary
swift build -c $BUILD_CONFIG --arch arm64 --arch x86_64

# Find the built binary
BINARY_PATH=".build/apple/Products/$BUILD_CONFIG/$APP_NAME"

if [ ! -f "$BINARY_PATH" ]; then
    echo -e "${RED}Error: Binary not found at $BINARY_PATH${NC}"
    exit 1
fi

echo -e "${GREEN}Binary built successfully at $BINARY_PATH${NC}"

# Create app bundle structure
APP_BUNDLE="$APP_NAME.app"
rm -rf "$APP_BUNDLE"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/"

# Copy app icon if it exists
if [ -f "images/AppIcon.icns" ]; then
    cp "images/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
    echo -e "${GREEN}App icon copied to bundle${NC}"
fi

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Disk Inventory Zed</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Matt Ivan. Licensed under GPL-3.0.</string>
    <key>LSUIElement</key>
    <false/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

# Create entitlements file
# Sandbox disabled for full disk scanning
cat > "$APP_BUNDLE.entitlements" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
EOF

# Verify architecture
echo -e "${YELLOW}Verifying universal binary...${NC}"
lipo -info "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Check architectures
ARCHS=$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME")
echo -e "${GREEN}Supported architectures: $ARCHS${NC}"

if [[ "$ARCHS" == *"arm64"* && "$ARCHS" == *"x86_64"* ]]; then
    echo -e "${GREEN}✓ Universal binary verified (Intel + Apple Silicon)${NC}"
else
    echo -e "${YELLOW}⚠ Warning: Not a universal binary. Only found: $ARCHS${NC}"
fi

echo -e "${GREEN}App bundle created: $APP_BUNDLE${NC}"
echo -e "${YELLOW}Note: To run the app, you may need to:${NC}"
echo -e "  1. Sign the app: codesign --force --deep --sign - $APP_BUNDLE"
echo -e "  2. Or run directly: open $APP_BUNDLE"
echo -e "  3. For full disk access, grant permission in System Settings > Privacy & Security"
