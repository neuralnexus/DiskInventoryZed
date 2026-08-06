# Corresponding Source

The `DiskInventoryZed-<version>-corresponding-source.tar.gz` release asset is
the source counterpart to the macOS and portable Linux object-code artifacts
from the same release. It contains:

- A `git archive` of the exact Disk Inventory Zed release commit.
- Commit-pinned source archives for every component statically linked into the
  portable Linux executable.
- The Swift Static Linux SDK recipe, vendored fts source, and SDK patches.
- `SOURCE-MANIFEST.json`, containing SHA-256 digests and the build inputs.
- The license and notice inventory used to construct the release payload.

Verify every nested archive against `SOURCE-MANIFEST.json` before use. The
upstream archives are retained in their downloaded form so their recorded
hashes can be checked independently.

## Portable Linux Build

The official build uses Swift 6.3.3 and the following Static Linux SDK:

```text
URL: https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
SHA-256: 87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b
```

Keep the downloaded corresponding-source archive so its release SHA-256 remains
the source binding embedded in the binary archive. Extract this bundle, then
extract `DiskInventoryZed-<version>.tar.gz`. From the project source directory,
install the SDK and export the commit and epoch recorded in the adjacent
`SOURCE-MANIFEST.json`:

```bash
SOURCE_MANIFEST=../SOURCE-MANIFEST.json
export PROJECT_COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["projectCommit"])' "$SOURCE_MANIFEST")"
export SOURCE_DATE_EPOCH="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sourceDateEpoch"])' "$SOURCE_MANIFEST")"
export SOURCE_ARCHIVE_PATH=/absolute/path/to/DiskInventoryZed-<version>-corresponding-source.tar.gz
./scripts/package-linux.sh x86_64-swift-linux-musl dist
./scripts/package-linux.sh aarch64-swift-linux-musl dist
```

The release workflow records its pinned toolchain setup action, runner family,
and exact project commit in `SOURCE-MANIFEST.json`. The source and packaging scripts are
licensed under GPL-3.0-or-later; upstream components retain their own terms.
