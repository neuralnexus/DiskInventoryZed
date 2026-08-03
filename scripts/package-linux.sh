#!/bin/bash
set -euo pipefail
umask 022

readonly SWIFT_SDK="${1:?usage: package-linux.sh swift-sdk [output-directory]}"
readonly OUTPUT_DIRECTORY="${2:-dist}"
SOURCE_DIRECTORY="$(pwd -P)"
readonly SOURCE_DIRECTORY

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

SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"
case "$SOURCE_DATE_EPOCH" in
    ""|*[!0-9]*)
        echo "SOURCE_DATE_EPOCH must be a non-negative integer." >&2
        exit 1
        ;;
esac
readonly SOURCE_DATE_EPOCH

VERSION="$(swift -e 'import Foundation; let data = try Data(contentsOf: URL(fileURLWithPath: "Resources/Info.plist")); let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil); guard let dictionary = value as? [String: Any], let version = dictionary["CFBundleShortVersionString"] as? String else { fatalError("Missing version") }; print(version)')"
readonly VERSION
readonly PACKAGE_NAME="DiskInventoryZed-${VERSION}-linux-${ARCHITECTURE}"
readonly ARCHIVE_PATH="${OUTPUT_DIRECTORY}/${PACKAGE_NAME}.tar.gz"
readonly TEMPORARY_ARCHIVE_PATH="${OUTPUT_DIRECTORY}/.${PACKAGE_NAME}.tar.gz.tmp.$$"
BUILD_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/DiskInventoryZed-linux.XXXXXX")"
readonly BUILD_DIRECTORY
readonly PACKAGE_DIRECTORY="${BUILD_DIRECTORY}/${PACKAGE_NAME}"

cleanup() {
    rm -rf "$BUILD_DIRECTORY"
    rm -f "$TEMPORARY_ARCHIVE_PATH"
}
trap cleanup EXIT

# Avoid path-sensitive LLVM reuse hashes in otherwise identical release binaries.
swift build \
    -c release \
    --swift-sdk "$SWIFT_SDK" \
    --scratch-path "$BUILD_DIRECTORY/build" \
    -Xswiftc -strict-concurrency=complete \
    -Xswiftc -debug-prefix-map -Xswiftc "${SOURCE_DIRECTORY}=/src" \
    -Xswiftc -debug-prefix-map -Xswiftc "${BUILD_DIRECTORY}=/build" \
    -Xswiftc -file-prefix-map -Xswiftc "${SOURCE_DIRECTORY}=/src" \
    -Xswiftc -file-prefix-map -Xswiftc "${BUILD_DIRECTORY}=/build" \
    -Xswiftc -Xfrontend -Xswiftc -disable-incremental-llvm-codegen \
    -Xlinker -s

readonly BINARY_PATH="${BUILD_DIRECTORY}/build/${SWIFT_SDK}/release/DiskInventoryZed"
if [ ! -f "$BINARY_PATH" ]; then
    echo "Linux binary not found at $BINARY_PATH" >&2
    exit 1
fi

mkdir -p "$PACKAGE_DIRECTORY" "$OUTPUT_DIRECTORY"
install -m 755 "$BINARY_PATH" "$PACKAGE_DIRECTORY/DiskInventoryZed"
install -m 644 README.md LICENSE "$PACKAGE_DIRECTORY/"

tar \
    --sort=name \
    --mtime="@${SOURCE_DATE_EPOCH}" \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --format=gnu \
    -C "$BUILD_DIRECTORY" \
    -cf - "$PACKAGE_NAME" | gzip -n > "$TEMPORARY_ARCHIVE_PATH"
mv -f "$TEMPORARY_ARCHIVE_PATH" "$ARCHIVE_PATH"

echo "Packaged $ARCHIVE_PATH"
