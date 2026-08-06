#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIRECTORY
cd "$SCRIPT_DIRECTORY"

echo "Building Disk Inventory Zed for Intel and Apple Silicon..."
swift build -c release --arch arm64 --arch x86_64
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}" ./scripts/package-app.sh

echo "App bundle created at DiskInventoryZed.app"
echo "Grant Full Disk Access in System Settings when scanning protected locations."
