#!/bin/bash
set -euo pipefail

echo "Building Disk Inventory Zed for Intel and Apple Silicon…"
swift build -c release --arch arm64 --arch x86_64
./scripts/package-app.sh

echo "App bundle created at DiskInventoryZed.app"
echo "Grant Full Disk Access in System Settings when scanning protected locations."
