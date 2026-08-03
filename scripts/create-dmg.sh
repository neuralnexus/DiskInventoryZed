#!/bin/bash
set -euo pipefail

readonly APP_NAME="DiskInventoryZed"
readonly DMG_NAME="DiskInventoryZed"
readonly SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
readonly PREBUILT_HELPER_APP="${PREBUILT_HELPER_APP:-}"
readonly DETACH_ATTEMPTS=5
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
readonly VERSION
readonly OUTPUT_DMG="${DMG_NAME}-${VERSION}.dmg"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/DiskInventoryZed-dmg.XXXXXX")"
readonly WORK_DIR
readonly DMG_CONTENTS="${WORK_DIR}/contents"
readonly WRITABLE_DMG="${WORK_DIR}/writable.dmg"
MOUNT_DIR=""
MOUNT_DEVICE=""

is_mounted() {
    local mount_dir="$1"
    local mount_line

    if [ -d "$mount_dir" ]; then
        mount_dir="$(cd "$mount_dir" && pwd -P)"
    fi

    while IFS= read -r mount_line; do
        case "$mount_line" in
            "${mount_dir} on "* | *" on ${mount_dir} "*) return 0 ;;
        esac
    done < <(/sbin/mount)
    return 1
}

is_attached() {
    local target="$1"

    if [[ "$target" == /dev/* ]]; then
        /usr/sbin/diskutil info "$target" >/dev/null 2>&1
    else
        is_mounted "$target"
    fi
}

detach_dmg() {
    local target="$1"
    local attempt
    local delay

    if ! is_attached "$target"; then
        return 0
    fi

    for ((attempt = 1; attempt <= DETACH_ATTEMPTS; attempt++)); do
        if hdiutil detach "$target"; then
            return 0
        fi

        if ! is_attached "$target"; then
            return 0
        fi

        if ((attempt < DETACH_ATTEMPTS)); then
            delay=$((1 << (attempt - 1)))
            echo "Detach attempt ${attempt}/${DETACH_ATTEMPTS} failed; retrying in ${delay}s..." >&2
            sleep "$delay"
        fi
    done

    echo "Normal detach failed after ${DETACH_ATTEMPTS} attempts; trying a forced detach..." >&2
    if hdiutil detach -force "$target"; then
        return 0
    fi

    echo "Error: Could not detach DMG at ${target}" >&2
    return 1
}

cleanup() {
    local exit_status=$?
    trap - EXIT

    local detach_target="${MOUNT_DEVICE:-$MOUNT_DIR}"
    if [ -n "$detach_target" ]; then
        if detach_dmg "$detach_target"; then
            MOUNT_DIR=""
            MOUNT_DEVICE=""
        else
            echo "Leaving ${WORK_DIR} intact because the DMG is still mounted." >&2
            exit_status=1
        fi
    fi

    if [ -z "$MOUNT_DIR" ] && [ -z "$MOUNT_DEVICE" ]; then
        rm -rf "$WORK_DIR"
    fi

    exit "$exit_status"
}
trap cleanup EXIT

echo "Creating DMG for Disk Inventory Zed..."

rm -f "${OUTPUT_DMG}"
mkdir -p "$DMG_CONTENTS"

# Copy the app
cp -R "${APP_NAME}.app" "$DMG_CONTENTS/"
codesign --verify --deep --strict --verbose=2 "$DMG_CONTENTS/${APP_NAME}.app"

# Create Applications symlink
ln -s /Applications "$DMG_CONTENTS/Applications"

# Create First-Run-Helper app from AppleScript
if [ -f "scripts/First-Run-Helper.applescript" ]; then
    echo "Creating First-Run-Helper app..."
    if [ -n "$PREBUILT_HELPER_APP" ]; then
        if [ ! -d "$PREBUILT_HELPER_APP" ]; then
            echo "Prebuilt helper app not found: $PREBUILT_HELPER_APP" >&2
            exit 1
        fi
        cp -R "$PREBUILT_HELPER_APP" "$DMG_CONTENTS/First-Run-Helper.app"
    else
        /usr/bin/env SIGNING_IDENTITY="$SIGNING_IDENTITY" \
            ./scripts/package-helper.sh "$DMG_CONTENTS/First-Run-Helper.app"
    fi

    codesign --verify --deep --strict --verbose=2 "$DMG_CONTENTS/First-Run-Helper.app"
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

# Mount in /Volumes so Finder can customize the disk window. Parse without a
# failure-prone grep pipeline, retaining the device as a cleanup fallback.
set +e
MOUNT_OUTPUT="$(hdiutil attach "$WRITABLE_DMG" -nobrowse -noverify 2>&1)"
ATTACH_STATUS=$?
set -e
MOUNT_DEVICE="$(perl -e '$text = shift; $device = $1 while $text =~ m{^(/dev/\S+)}mg; print $device // q{}' "$MOUNT_OUTPUT")"
MOUNT_PATH="$(perl -e '$text = shift; print $2 if $text =~ m{^(\S+)\s+Apple_(?:HFS|APFS)\s+(.+)$}m' "$MOUNT_OUTPUT")"
if [ -n "$MOUNT_PATH" ] && [ -d "$MOUNT_PATH" ]; then
    MOUNT_DIR="$(cd "$MOUNT_PATH" && pwd -P)"
fi

if [ "$ATTACH_STATUS" -ne 0 ] || [ -z "$MOUNT_DIR" ] || [ ! -d "$MOUNT_DIR" ]; then
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
MOUNT_VOLUME_NAME="$(basename "$MOUNT_DIR")"
osascript - "$MOUNT_VOLUME_NAME" <<'APPLESCRIPT'
on run argv
set volumeName to item 1 of argv
tell application "Finder"
    tell disk volumeName
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 700, 500}
        
        set theViewOptions to icon view options of container window
        set icon size of theViewOptions to 96
        set text size of theViewOptions to 12
        set arrangement of theViewOptions to not arranged
        
        set position of item "DiskInventoryZed.app" to {150, 200}
        set position of item "Applications" to {450, 200}
        try
            set position of item "First-Run-Helper.app" to {150, 350}
        end try
        try
            set position of item "README.txt" to {450, 350}
        end try
        
        set background picture of theViewOptions to file ".background:README.txt"
        
        update without registering applications
        delay 2
        close
    end tell
end tell
end run
APPLESCRIPT

# Unmount the DMG
if ! detach_dmg "${MOUNT_DEVICE:-$MOUNT_DIR}"; then
    echo "Leaving ${WORK_DIR} intact because the DMG is still mounted." >&2
    trap - EXIT
    exit 1
fi
MOUNT_DIR=""
MOUNT_DEVICE=""

# Convert to compressed read-only DMG
echo "Compressing DMG..."
hdiutil convert "$WRITABLE_DMG" -format UDZO -o "${OUTPUT_DMG}"

# Sign and verify the final disk image as well as its nested applications.
if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign --force --sign - "$OUTPUT_DMG"
else
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$OUTPUT_DMG"
fi
codesign --verify --strict --verbose=2 "$OUTPUT_DMG"
hdiutil verify "$OUTPUT_DMG"

echo "DMG created: ${OUTPUT_DMG}"
ls -lh "${OUTPUT_DMG}"

echo "Done!"
