#!/bin/bash
set -euo pipefail
umask 022

readonly SWIFT_SDK="${1:?usage: package-linux.sh swift-sdk [output-directory]}"
readonly OUTPUT_DIRECTORY="${2:-dist}"
SOURCE_DIRECTORY="$(pwd -P)"
readonly SOURCE_DIRECTORY
readonly STATIC_SDK_URL="https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz"
readonly STATIC_SDK_SHA256="87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b"
readonly BUILD_ENVIRONMENT="${BUILD_ENVIRONMENT:-Swift 6.3.3 on Linux}"

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

SOURCE_TREE_STATE="clean"
HAS_GIT_WORKTREE=false
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    HAS_GIT_WORKTREE=true
    DETECTED_PROJECT_COMMIT="$(git rev-parse --verify 'HEAD^{commit}')"
    if [ -n "${PROJECT_COMMIT:-}" ] && [ "$PROJECT_COMMIT" != "$DETECTED_PROJECT_COMMIT" ]; then
        echo "PROJECT_COMMIT does not match the checked-out source." >&2
        exit 1
    fi
    PROJECT_COMMIT="$DETECTED_PROJECT_COMMIT"
    SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"
    if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
        SOURCE_TREE_STATE="dirty"
        if [ "${ALLOW_DIRTY_BUILD:-false}" != true ]; then
            echo "Refusing to package a portable binary from a dirty worktree." >&2
            exit 1
        fi
    fi
else
    : "${PROJECT_COMMIT:?PROJECT_COMMIT is required outside a Git worktree}"
    : "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH is required outside a Git worktree}"
fi
if [[ ! "$PROJECT_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "PROJECT_COMMIT must be a 40-character lowercase Git object ID." >&2
    exit 1
fi
readonly PROJECT_COMMIT SOURCE_TREE_STATE HAS_GIT_WORKTREE

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
readonly SBOM_PATH="${OUTPUT_DIRECTORY}/${PACKAGE_NAME}.spdx.json"
readonly TEMPORARY_SBOM_PATH="${OUTPUT_DIRECTORY}/.${PACKAGE_NAME}.spdx.json.tmp.$$"
BUILD_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/DiskInventoryZed-linux.XXXXXX")"
readonly BUILD_DIRECTORY
readonly PACKAGE_DIRECTORY="${BUILD_DIRECTORY}/${PACKAGE_NAME}"

cleanup() {
    rm -rf "$BUILD_DIRECTORY"
    rm -f "$TEMPORARY_ARCHIVE_PATH"
    rm -f "$TEMPORARY_SBOM_PATH"
}
trap cleanup EXIT

EXPECTED_PROJECT_ARCHIVE_PATH=""
if [ "$HAS_GIT_WORKTREE" = true ]; then
    EXPECTED_PROJECT_ARCHIVE_PATH="${BUILD_DIRECTORY}/expected-project-source.tar.gz"
    git archive \
        --format=tar \
        --prefix="DiskInventoryZed-${VERSION}/" \
        "$PROJECT_COMMIT" | gzip -n > "$EXPECTED_PROJECT_ARCHIVE_PATH"
fi
readonly EXPECTED_PROJECT_ARCHIVE_PATH

mkdir -p "$OUTPUT_DIRECTORY"
SOURCE_ARCHIVE_PATH="${SOURCE_ARCHIVE_PATH:-}"
if [ -z "$SOURCE_ARCHIVE_PATH" ]; then
    shopt -s nullglob
    source_archives=("${OUTPUT_DIRECTORY}/DiskInventoryZed-${VERSION}-corresponding-source.tar.gz")
    shopt -u nullglob
    if [ "${#source_archives[@]}" -ne 1 ]; then
        echo "Build the matching corresponding-source archive before portable binaries." >&2
        exit 1
    fi
    SOURCE_ARCHIVE_PATH="${source_archives[0]}"
fi
if [ ! -f "$SOURCE_ARCHIVE_PATH" ] || [ -L "$SOURCE_ARCHIVE_PATH" ]; then
    echo "Corresponding-source archive is missing or unsafe: $SOURCE_ARCHIVE_PATH" >&2
    exit 1
fi
readonly SOURCE_ARCHIVE_PATH
SOURCE_ARCHIVE_NAME="$(basename "$SOURCE_ARCHIVE_PATH")"
readonly SOURCE_ARCHIVE_NAME
if [ "$SOURCE_ARCHIVE_NAME" != "DiskInventoryZed-${VERSION}-corresponding-source.tar.gz" ]; then
    echo "Corresponding-source archive name does not match version $VERSION." >&2
    exit 1
fi
ACTUAL_SOURCE_ARCHIVE_SHA256="$(sha256sum "$SOURCE_ARCHIVE_PATH" | cut -d ' ' -f 1)"
readonly ACTUAL_SOURCE_ARCHIVE_SHA256
if [ -n "${SOURCE_ARCHIVE_SHA256:-}" ] && \
   [ "$SOURCE_ARCHIVE_SHA256" != "$ACTUAL_SOURCE_ARCHIVE_SHA256" ]; then
    echo "Corresponding-source archive SHA-256 does not match SOURCE_ARCHIVE_SHA256." >&2
    exit 1
fi
readonly SOURCE_ARCHIVE_SHA256="$ACTUAL_SOURCE_ARCHIVE_SHA256"

python3 - \
    "$SOURCE_ARCHIVE_PATH" \
    "$VERSION" \
    "$PROJECT_COMMIT" \
    "${ALLOW_DIRTY_BUILD:-false}" \
    "$SOURCE_DIRECTORY" \
    "$HAS_GIT_WORKTREE" \
    "$OUTPUT_DIRECTORY" \
    "Legal/source-components.json" \
    "$EXPECTED_PROJECT_ARCHIVE_PATH" <<'PY'
from io import BytesIO
import hashlib
import json
from pathlib import Path
from pathlib import PurePosixPath
import stat
import sys
import tarfile

archive = Path(sys.argv[1])
root_name = archive.name.removesuffix(".tar.gz")
manifest_name = "SOURCE-MANIFEST.json"
project_name = f"DiskInventoryZed-{sys.argv[2]}.tar.gz"
actual_files = {}
captured_files: dict[str, bytes] = {}
seen_members: set[str] = set()
with tarfile.open(archive, "r:gz") as source:
    for member in source.getmembers():
        if member.name in seen_members:
            raise SystemExit(f"Duplicate corresponding-source member: {member.name}")
        seen_members.add(member.name)
        path = PurePosixPath(member.name)
        try:
            relative = path.relative_to(PurePosixPath(root_name))
        except ValueError:
            raise SystemExit(f"Corresponding-source member escapes its root: {path}")
        if str(relative) == "." or member.isdir():
            continue
        if not member.isfile():
            raise SystemExit(f"Unsupported corresponding-source member type: {path}")
        name = relative.as_posix()
        if name in actual_files:
            raise SystemExit(f"Duplicate normalized corresponding-source path: {name}")
        extracted = source.extractfile(member)
        if extracted is None:
            raise SystemExit(f"Could not read corresponding-source member: {name}")
        digest = hashlib.sha256()
        captured = bytearray() if name in {manifest_name, project_name, "source-components.json"} else None
        size = 0
        while chunk := extracted.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
            if captured is not None:
                captured.extend(chunk)
        if size != member.size:
            raise SystemExit(f"Corresponding-source member size changed while reading: {name}")
        actual_files[name] = {"path": name, "sha256": digest.hexdigest(), "size": size}
        if captured is not None:
            captured_files[name] = bytes(captured)

try:
    manifest = json.loads(captured_files[manifest_name])
except (KeyError, ValueError):
    raise SystemExit("Corresponding-source manifest is missing or invalid")
if manifest.get("schemaVersion") != 1:
    raise SystemExit("Unsupported corresponding-source manifest")
if manifest.get("version") != sys.argv[2]:
    raise SystemExit("Corresponding-source version does not match the binary")
if manifest.get("projectCommit") != sys.argv[3]:
    raise SystemExit("Corresponding-source commit does not match the binary")
if manifest.get("sourceTreeState") != "clean" and sys.argv[4] != "true":
    raise SystemExit("Corresponding-source archive was produced from a dirty worktree")

manifest_entries = manifest.get("files")
if not isinstance(manifest_entries, list):
    raise SystemExit("Corresponding-source manifest has no file inventory")
expected_files = {}
for entry in manifest_entries:
    if not isinstance(entry, dict):
        raise SystemExit("Malformed corresponding-source file entry")
    name = entry.get("path")
    digest = entry.get("sha256")
    size = entry.get("size")
    if (
        not isinstance(name, str)
        or not name
        or PurePosixPath(name).is_absolute()
        or ".." in PurePosixPath(name).parts
        or name in expected_files
        or not isinstance(digest, str)
        or len(digest) != 64
        or any(character not in "0123456789abcdef" for character in digest)
        or not isinstance(size, int)
        or isinstance(size, bool)
        or size < 0
    ):
        raise SystemExit(f"Malformed corresponding-source file entry: {entry!r}")
    expected_files[name] = {"path": name, "sha256": digest, "size": size}

actual_files.pop(manifest_name, None)
if actual_files != expected_files:
    missing = sorted(set(expected_files) - set(actual_files))
    extra = sorted(set(actual_files) - set(expected_files))
    changed = sorted(
        name
        for name in set(actual_files) & set(expected_files)
        if actual_files[name] != expected_files[name]
    )
    raise SystemExit(
        "Corresponding-source file inventory mismatch: "
        f"missing={missing}, extra={extra}, changed={changed}"
    )

required_sources_path = Path(sys.argv[8])
required_sources_bytes = required_sources_path.read_bytes()
if captured_files.get("source-components.json") != required_sources_bytes:
    raise SystemExit("Corresponding-source component manifest does not match the project")
required_sources = json.loads(required_sources_bytes)
if required_sources.get("schemaVersion") != 1 or not isinstance(required_sources.get("files"), list):
    raise SystemExit("Unsupported project source-component manifest")
for entry in required_sources["files"]:
    name = f"upstream/{entry['name']}"
    actual = actual_files.get(name)
    if actual is None or actual["sha256"] != entry["sha256"]:
        raise SystemExit(f"Required upstream source is missing or invalid: {name}")

try:
    project_archive = captured_files[project_name]
except KeyError:
    raise SystemExit("Project source archive is missing")
if sys.argv[6] == "true":
    if project_archive != Path(sys.argv[9]).read_bytes():
        raise SystemExit("Project source archive does not match the release commit")
else:

    project_prefix = PurePosixPath(f"DiskInventoryZed-{sys.argv[2]}")
    expected = {}
    with tarfile.open(fileobj=BytesIO(project_archive), mode="r:gz") as source:
        for member in source.getmembers():
            path = PurePosixPath(member.name)
            try:
                relative = path.relative_to(project_prefix)
            except ValueError:
                raise SystemExit(f"Unexpected project archive path: {path}")
            if str(relative) == ".":
                continue
            name = relative.as_posix()
            if member.isfile():
                extracted = source.extractfile(member)
                if extracted is None:
                    raise SystemExit(f"Could not read project source file: {name}")
                expected[name] = ("file", extracted.read(), bool(member.mode & 0o111))
            elif member.issym():
                expected[name] = ("symlink", member.linkname, False)

    source_directory = Path(sys.argv[5]).resolve()
    output_directory = Path(sys.argv[7]).resolve()
    ignored_roots = {".build", ".git", "dist", "DiskInventoryZed.app", "__pycache__"}
    actual = {}
    for path in source_directory.rglob("*"):
        relative = path.relative_to(source_directory)
        if relative.parts[0] in ignored_roots or path == output_directory or output_directory in path.parents:
            continue
        name = relative.as_posix()
        if path.is_symlink():
            actual[name] = ("symlink", path.readlink().as_posix(), False)
        elif path.is_file():
            actual[name] = (
                "file",
                path.read_bytes(),
                bool(stat.S_IMODE(path.stat().st_mode) & 0o111),
            )
    if actual != expected:
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        changed = sorted(
            name for name in set(actual) & set(expected) if actual[name] != expected[name]
        )
        raise SystemExit(
            "Gitless source does not match the corresponding-source bundle: "
            f"missing={missing}, extra={extra}, changed={changed}"
        )
PY

LEGAL_DIRECTORY="${LEGAL_DIRECTORY:-}"
if [ -z "$LEGAL_DIRECTORY" ]; then
    LEGAL_DIRECTORY="${BUILD_DIRECTORY}/licenses"
    python3 scripts/fetch-verified-files.py \
        Legal/third-party-components.json \
        "$LEGAL_DIRECTORY"
fi
if [ ! -d "$LEGAL_DIRECTORY" ] || [ -L "$LEGAL_DIRECTORY" ]; then
    echo "Verified legal payload is missing or unsafe: $LEGAL_DIRECTORY" >&2
    exit 1
fi
readonly LEGAL_DIRECTORY

python3 - Legal/third-party-components.json "$LEGAL_DIRECTORY" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
directory = Path(sys.argv[2])
expected_names = {entry["name"] for entry in manifest["files"]}
actual_names = {path.name for path in directory.iterdir() if path.is_file()}
if actual_names != expected_names:
    raise SystemExit("Legal payload file set does not match its manifest")
for entry in manifest["files"]:
    digest = hashlib.sha256((directory / entry["name"]).read_bytes()).hexdigest()
    if digest != entry["sha256"]:
        raise SystemExit(f"Legal payload hash mismatch: {entry['name']}")
PY

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

mkdir -p "$PACKAGE_DIRECTORY/licenses"
install -m 755 "$BINARY_PATH" "$PACKAGE_DIRECTORY/DiskInventoryZed"
install -m 644 README.md "$PACKAGE_DIRECTORY/README.md"
install -m 644 LICENSE "$PACKAGE_DIRECTORY/LICENSE.txt"
install -m 644 \
    Legal/PROJECT-NOTICE.txt \
    Legal/THIRD-PARTY-NOTICES.txt \
    Legal/third-party-components.json \
    Legal/source-components.json \
    "$PACKAGE_DIRECTORY/"
install -m 644 "$LEGAL_DIRECTORY"/* "$PACKAGE_DIRECTORY/licenses/"

python3 - \
    "$PACKAGE_DIRECTORY" \
    "$BINARY_PATH" \
    "$VERSION" \
    "$ARCHITECTURE" \
    "$PROJECT_COMMIT" \
    "$SOURCE_TREE_STATE" \
    "$SOURCE_DATE_EPOCH" \
    "$BUILD_ENVIRONMENT" \
    "$STATIC_SDK_URL" \
    "$STATIC_SDK_SHA256" \
    "$SOURCE_ARCHIVE_NAME" \
    "$SOURCE_ARCHIVE_SHA256" \
    "$SWIFT_SDK" <<'PY'
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys

package_directory = Path(sys.argv[1])
binary = Path(sys.argv[2])
version = sys.argv[3]
architecture = sys.argv[4]
commit = sys.argv[5]
source_tree_state = sys.argv[6]
source_date_epoch = int(sys.argv[7])
build_environment = sys.argv[8]
sdk_url = sys.argv[9]
sdk_sha256 = sys.argv[10]
source_archive = sys.argv[11]
source_sha256 = sys.argv[12]
release_url = (
    f"https://github.com/neuralnexus/DiskInventoryZed/releases/download/"
    f"v{version}/{source_archive}"
)

binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
source_access = f"""Disk Inventory Zed Corresponding Source
=======================================

The complete corresponding source for this object-code release is available
from the same GitHub release at no additional charge.

URL: {release_url}
SHA-256: {source_sha256}
Project commit: {commit}

The source asset includes the exact application source, linked-component
sources, build scripts, Static Linux SDK recipe and patches, and a verified
source manifest.
"""
(package_directory / "SOURCE-ACCESS.txt").write_text(source_access, encoding="utf-8")

manifest = {
    "schemaVersion": 1,
    "name": package_directory.name,
    "version": version,
    "architecture": architecture,
    "projectCommit": commit,
    "sourceTreeState": source_tree_state,
    "sourceDateEpoch": source_date_epoch,
    "created": datetime.fromtimestamp(source_date_epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "buildEnvironment": build_environment,
    "swiftSDK": {
        "identifier": sys.argv[13],
        "url": sdk_url,
        "sha256": sdk_sha256,
    },
    "binary": {"name": "DiskInventoryZed", "sha256": binary_hash},
    "correspondingSource": {
        "name": source_archive,
        "sha256": source_sha256,
        "url": release_url,
    },
}
(package_directory / "BUILD-MANIFEST.json").write_text(
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

python3 scripts/generate-linux-sbom.py \
    --binary "$BINARY_PATH" \
    --archive "$TEMPORARY_ARCHIVE_PATH" \
    --archive-name "${PACKAGE_NAME}.tar.gz" \
    --output "$TEMPORARY_SBOM_PATH" \
    --architecture "$ARCHITECTURE" \
    --version "$VERSION" \
    --commit "$PROJECT_COMMIT" \
    --source-archive "$SOURCE_ARCHIVE_NAME" \
    --source-sha256 "$SOURCE_ARCHIVE_SHA256" \
    --source-date-epoch "$SOURCE_DATE_EPOCH" \
    --components Legal/third-party-components.json \
    --licenses "$LEGAL_DIRECTORY"

mv -f "$TEMPORARY_ARCHIVE_PATH" "$ARCHIVE_PATH"
mv -f "$TEMPORARY_SBOM_PATH" "$SBOM_PATH"

echo "Packaged $ARCHIVE_PATH"
echo "Generated $SBOM_PATH"
