#!/bin/bash
set -euo pipefail
umask 022

readonly SWIFT_SDK="${1:?usage: package-linux.sh swift-sdk [output-directory]}"
readonly OUTPUT_DIRECTORY="${2:-dist}"

if [ "$(uname -s)" != "Linux" ]; then
    echo "Portable Linux archives must currently be built from a Linux Swift toolchain." >&2
    exit 1
fi

case "$SWIFT_SDK" in
    x86_64-swift-linux-musl) readonly ARCHITECTURE="x86_64" ;;
    aarch64-swift-linux-musl) readonly ARCHITECTURE="aarch64" ;;
    *)
        echo "Unsupported Swift SDK: $SWIFT_SDK" >&2
        exit 1
        ;;
esac

VERSION="$(swift -e 'import Foundation; let data = try Data(contentsOf: URL(fileURLWithPath: "Resources/Info.plist")); let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil); guard let dictionary = value as? [String: Any], let version = dictionary["CFBundleShortVersionString"] as? String else { fatalError("Missing version") }; print(version)')"
readonly VERSION
readonly PACKAGE_NAME="DiskInventoryZed-${VERSION}-linux-${ARCHITECTURE}"
BUILD_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/DiskInventoryZed-linux.XXXXXX")"
readonly BUILD_DIRECTORY
readonly PACKAGE_DIRECTORY="${BUILD_DIRECTORY}/${PACKAGE_NAME}"

cleanup() {
    rm -rf "$BUILD_DIRECTORY"
}
trap cleanup EXIT

swift build \
    -c release \
    --swift-sdk "$SWIFT_SDK" \
    --scratch-path "$BUILD_DIRECTORY/build" \
    -Xswiftc -strict-concurrency=complete \
    -Xlinker -s

readonly BINARY_PATH="${BUILD_DIRECTORY}/build/${SWIFT_SDK}/release/DiskInventoryZed"
if [ ! -f "$BINARY_PATH" ]; then
    echo "Linux binary not found at $BINARY_PATH" >&2
    exit 1
fi

mkdir -p "$PACKAGE_DIRECTORY" "$OUTPUT_DIRECTORY"
install -m 755 "$BINARY_PATH" "$PACKAGE_DIRECTORY/DiskInventoryZed"
install -m 644 README.md LICENSE "$PACKAGE_DIRECTORY/"

rm -f "${OUTPUT_DIRECTORY}/${PACKAGE_NAME}.tar.gz"
tar -C "$BUILD_DIRECTORY" -czf "${OUTPUT_DIRECTORY}/${PACKAGE_NAME}.tar.gz" "$PACKAGE_NAME"

echo "Packaged ${OUTPUT_DIRECTORY}/${PACKAGE_NAME}.tar.gz"
