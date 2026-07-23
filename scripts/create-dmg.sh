#!/bin/bash
set -euo pipefail

readonly APP_NAME="DiskInventoryZed"
readonly DMG_NAME="DiskInventoryZed"
readonly VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
readonly OUTPUT_DMG="${DMG_NAME}-${VERSION}.dmg"
readonly WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/DiskInventoryZed-dmg.XXXXXX")"
readonly DMG_CONTENTS="${WORK_DIR}/contents"
readonly WRITABLE_DMG="${WORK_DIR}/writable.dmg"
MOUNT_DIR=""

cleanup() {
    if [ -n "$MOUNT_DIR" ] && mount | grep -Fq "on $MOUNT_DIR "; then
        hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "Creating DMG for Disk Inventory Zed..."

rm -f "${OUTPUT_DMG}"
mkdir -p "$DMG_CONTENTS"

# Copy the app
cp -R "${APP_NAME}.app" "$DMG_CONTENTS/"

# Create Applications symlink
ln -s /Applications "$DMG_CONTENTS/Applications"

# Create First-Run-Helper app from AppleScript
if [ -f "scripts/First-Run-Helper.applescript" ]; then
    echo "Creating First-Run-Helper app..."
    osacompile -o "$DMG_CONTENTS/First-Run-Helper.app" "scripts/First-Run-Helper.applescript"
fi

# Create a README with instructions
cat > "$DMG_CONTENTS/README.txt" << 'EOF'
Disk Inventory Zed - First Launch Instructions
===============================================

If this build was not notarized by Apple, macOS Gatekeeper may show a
security warning when you first try to open it.

METHOD 1: Right-click to Open (Quickest)
-----------------------------------------
1. Right-click (or Control-click) on DiskInventoryZed.app
2. Select "Open" from the context menu
3. Click "Open" in the dialog that appears

METHOD 2: Use System Settings
------------------------------
1. Double-click DiskInventoryZed.app (it will show a warning)
2. Go to System Settings > Privacy & Security
3. Scroll down to the Security section
4. Click "Open Anyway" next to DiskInventoryZed
5. Click "Open" in the confirmation dialog

METHOD 3: Use the First-Run-Helper
-----------------------------------
1. Double-click "First-Run-Helper.app" in this window
2. Click "Open Security Settings" in the dialog
3. System Settings will open to the Security pane
4. Click "Open Anyway" next to DiskInventoryZed

Note: You only need to do this once. After the first launch, 
the app will open normally.

Need Full Disk Access?
----------------------
To scan all directories, you may need to grant Full Disk Access:
1. System Settings > Privacy & Security > Full Disk Access
2. Click the + button
3. Navigate to Applications > Disk Inventory Zed
4. Click "Open"
5. Restart Disk Inventory Zed

Enjoy using Disk Inventory Zed!
EOF

# Calculate DMG size
APP_SIZE=$(du -sh "$DMG_CONTENTS" | cut -f1)
echo "App size: ${APP_SIZE}"

# Create temporary DMG (larger than needed, will be compressed)
hdiutil create -srcfolder "$DMG_CONTENTS" -volname "Disk Inventory Zed" -fs HFS+ -format UDRW -size "100m" "$WRITABLE_DMG"

# Mount the DMG and get mount point
MOUNT_OUTPUT=$(hdiutil attach "$WRITABLE_DMG" -nobrowse -noverify)
MOUNT_DIR=$(echo "$MOUNT_OUTPUT" | grep -E "Apple_HFS|Apple_APFS" | perl -pe 's/.*(?:Apple_HFS|Apple_APFS)\s+(.*)$/\1/' | head -1)

if [ -z "$MOUNT_DIR" ] || [ ! -d "$MOUNT_DIR" ]; then
    echo "Error: Could not mount DMG"
    echo "Mount output: $MOUNT_OUTPUT"
    exit 1
fi

echo "DMG mounted at: ${MOUNT_DIR}"

# Create background directory
mkdir -p "${MOUNT_DIR}/.background"

# Create a simple background text file
cat > "${MOUNT_DIR}/.background/README.txt" << 'EOF'
Disk Inventory Zed

Drag DiskInventoryZed.app to Applications

First time? Double-click First-Run-Helper for help

See README.txt for detailed instructions
EOF

# Set up the window appearance using AppleScript
osascript << APPLESCRIPT
set mountDir to "${MOUNT_DIR}"

tell application "Finder"
    tell disk "Disk Inventory Zed"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 700, 500}
        
        set theViewOptions to icon view options of container window
        set icon size of theViewOptions to 96
        set text size of theViewOptions to 12
        set arrangement of theViewOptions to not arranged
        
        -- Position the app icon
        set position of item "DiskInventoryZed.app" to {150, 200}
        
        -- Position the Applications symlink
        set position of item "Applications" to {450, 200}
        
        -- Position First-Run-Helper if it exists
        try
            set position of item "First-Run-Helper.app" to {150, 350}
        end try
        
        -- Position README
        try
            set position of item "README.txt" to {450, 350}
        end try
        
        -- Set background color
        set background picture of theViewOptions to file ".background:README.txt"
        
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

# Unmount the DMG
hdiutil detach "${MOUNT_DIR}"
MOUNT_DIR=""

# Convert to compressed read-only DMG
echo "Compressing DMG..."
hdiutil convert "$WRITABLE_DMG" -format UDZO -o "${OUTPUT_DMG}"

# Verify the DMG
echo "DMG created: ${OUTPUT_DMG}"
ls -lh "${OUTPUT_DMG}"

echo "Done!"
