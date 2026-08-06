#!/bin/bash
set -euo pipefail
umask 022

readonly OUTPUT_DIRECTORY="${1:-dist}"
SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIRECTORY
SOURCE_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd -P)"
readonly SOURCE_DIRECTORY
readonly STATIC_SDK_URL="https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz"
readonly STATIC_SDK_SHA256="87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b"
readonly BUILD_ENVIRONMENT="${BUILD_ENVIRONMENT:-Swift 6.3.3 on Linux}"

if [ "$(uname -s)" != "Linux" ]; then
    echo "Corresponding-source archives must be built on Linux with GNU tar." >&2
    exit 1
fi
if ! tar --version | grep -q 'GNU tar'; then
    echo "GNU tar is required for deterministic source archives." >&2
    exit 1
fi

SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$SOURCE_DIRECTORY" log -1 --format=%ct)}"
case "$SOURCE_DATE_EPOCH" in
    ""|*[!0-9]*)
        echo "SOURCE_DATE_EPOCH must be a non-negative integer." >&2
        exit 1
        ;;
esac
readonly SOURCE_DATE_EPOCH

VERSION="$(python3 - "$SOURCE_DIRECTORY/Resources/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    print(plistlib.load(source)["CFBundleShortVersionString"])
PY
)"
readonly VERSION
PROJECT_COMMIT="$(git -C "$SOURCE_DIRECTORY" rev-parse --verify 'HEAD^{commit}')"
readonly PROJECT_COMMIT
SOURCE_TREE_STATE="clean"
if [ -n "$(git -C "$SOURCE_DIRECTORY" status --porcelain --untracked-files=normal)" ]; then
    SOURCE_TREE_STATE="dirty"
    if [ "${ALLOW_DIRTY_BUILD:-false}" != true ]; then
        echo "Refusing to package corresponding source from a dirty worktree." >&2
        exit 1
    fi
fi
readonly SOURCE_TREE_STATE
readonly PACKAGE_NAME="DiskInventoryZed-${VERSION}-corresponding-source"

mkdir -p "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY_ABSOLUTE="$(cd "$OUTPUT_DIRECTORY" && pwd -P)"
readonly OUTPUT_DIRECTORY_ABSOLUTE
readonly ARCHIVE_PATH="${OUTPUT_DIRECTORY_ABSOLUTE}/${PACKAGE_NAME}.tar.gz"
readonly TEMPORARY_ARCHIVE_PATH="${OUTPUT_DIRECTORY_ABSOLUTE}/.${PACKAGE_NAME}.tar.gz.tmp.$$"
BUILD_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/DiskInventoryZed-source.XXXXXX")"
readonly BUILD_DIRECTORY
readonly PACKAGE_DIRECTORY="${BUILD_DIRECTORY}/${PACKAGE_NAME}"
readonly UPSTREAM_DIRECTORY="${PACKAGE_DIRECTORY}/upstream"

cleanup() {
    rm -rf "$BUILD_DIRECTORY"
    rm -f "$TEMPORARY_ARCHIVE_PATH"
}
trap cleanup EXIT

mkdir -p "$PACKAGE_DIRECTORY"
python3 "$SCRIPT_DIRECTORY/fetch-verified-files.py" \
    "$SOURCE_DIRECTORY/Legal/source-components.json" \
    "$UPSTREAM_DIRECTORY"

git -C "$SOURCE_DIRECTORY" archive \
    --format=tar \
    --prefix="DiskInventoryZed-${VERSION}/" \
    "$PROJECT_COMMIT" | gzip -n > "${PACKAGE_DIRECTORY}/DiskInventoryZed-${VERSION}.tar.gz"

install -m 644 \
    "$SOURCE_DIRECTORY/LICENSE" \
    "$SOURCE_DIRECTORY/Legal/PROJECT-NOTICE.txt" \
    "$SOURCE_DIRECTORY/Legal/THIRD-PARTY-NOTICES.txt" \
    "$SOURCE_DIRECTORY/Legal/third-party-components.json" \
    "$SOURCE_DIRECTORY/Legal/source-components.json" \
    "$SOURCE_DIRECTORY/Legal/CORRESPONDING-SOURCE.md" \
    "$PACKAGE_DIRECTORY/"

python3 - \
    "$PACKAGE_DIRECTORY" \
    "$VERSION" \
    "$PROJECT_COMMIT" \
    "$SOURCE_TREE_STATE" \
    "$SOURCE_DATE_EPOCH" \
    "$BUILD_ENVIRONMENT" \
    "$STATIC_SDK_URL" \
    "$STATIC_SDK_SHA256" <<'PY'
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys

package_directory = Path(sys.argv[1])
manifest = {
    "schemaVersion": 1,
    "name": package_directory.name,
    "version": sys.argv[2],
    "projectCommit": sys.argv[3],
    "sourceTreeState": sys.argv[4],
    "sourceDateEpoch": int(sys.argv[5]),
    "created": datetime.fromtimestamp(int(sys.argv[5]), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "buildEnvironment": sys.argv[6],
    "swiftStaticSDK": {
        "identifier": "swift-6.3.3-RELEASE_static-linux-0.1.0",
        "url": sys.argv[7],
        "sha256": sys.argv[8],
    },
    "files": [],
}
for path in sorted(package_directory.rglob("*")):
    if not path.is_file() or path.name == "SOURCE-MANIFEST.json":
        continue
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    manifest["files"].append({
        "path": path.relative_to(package_directory).as_posix(),
        "sha256": digest.hexdigest(),
        "size": path.stat().st_size,
    })
(package_directory / "SOURCE-MANIFEST.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

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
sha256sum "$ARCHIVE_PATH"
