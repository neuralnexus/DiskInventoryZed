#!/bin/bash
set -e

APP_NAME="DiskInventoryZed"
DMG_NAME="DiskInventoryZed"
VERSION="1.0"
OUTPUT_DMG="${DMG_NAME}-${VERSION}.dmg"

echo "Creating DMG for Disk Inventory Zed..."

# Clean up any existing files
rm -f "${OUTPUT_DMG}"
rm -rf "tmp-dmg"

# Create temporary directory for DMG contents
mkdir -p "tmp-dmg"

# Copy the app
cp -R "${APP_NAME}.app" "tmp-dmg/"

# Create Applications symlink
ln -s /Applications "tmp-dmg/Applications"

# Create First-Run-Helper app from AppleScript
if [ -f "scripts/First-Run-Helper.applescript" ]; then
    echo "Creating First-Run-Helper app..."
    osacompile -o "tmp-dmg/First-Run-Helper.app" "scripts/First-Run-Helper.applescript"
fi

# Create a README with instructions
cat > "tmp-dmg/README.txt" << 'EOF'
Disk Inventory Zed - First Launch Instructions
===============================================

Since this app is not distributed through the Mac App Store or notarized 
by Apple, macOS Gatekeeper may show a security warning when you first 
try to open it.

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
APP_SIZE=$(du -sh "tmp-dmg" | cut -f1)
echo "App size: ${APP_SIZE}"

# Create temporary DMG (larger than needed, will be compressed)
hdiutil create -srcfolder "tmp-dmg" -volname "Disk Inventory Zed" -fs HFS+ -format UDRW -size "100m" "tmp-dmg-temp.dmg"

# Mount the DMG and get mount point
MOUNT_OUTPUT=$(hdiutil attach "tmp-dmg-temp.dmg" -nobrowse -noverify)
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

# Convert to compressed read-only DMG
echo "Compressing DMG..."
hdiutil convert "tmp-dmg-temp.dmg" -format UDZO -o "${OUTPUT_DMG}"

# Clean up
rm -f "tmp-dmg-temp.dmg"
rm -rf "tmp-dmg"

# Verify the DMG
echo "DMG created: ${OUTPUT_DMG}"
ls -lh "${OUTPUT_DMG}"

echo "Done!"
