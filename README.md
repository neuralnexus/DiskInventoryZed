<img width="125" height="125" alt="16a92001-236b-448c-a6a1-bf9102c57574" src="https://github.com/user-attachments/assets/40f4d702-5e0d-47da-986a-377849ac6fbd" />

# Disk Inventory Zed

A modern disk usage analyzer with a native macOS interface and a read-only Linux CLI.
This GPL-licensed project is not a fork of **Disk Inventory X**; it is a re-imagination of a KDirStat-style treemapping disk utility.

## Overview

Disk Inventory Zed visualizes disk usage on macOS with interactive treemaps and detailed file listings. The same storage accounting and versioned exports are available through a read-only command-line interface on Linux.

<img width="1510" height="912" alt="Screenshot 2026-05-28 at 12 38 48 PM" src="https://github.com/user-attachments/assets/ab03ce74-0768-4226-ac5c-2bf87c44e8be" />


## Features

- **Interactive Treemap Visualization** — Squarified treemap algorithm for optimal space usage visualization
- **Fast Concurrent Scanning** — Uses Swift concurrency for parallel directory traversal
- **Immutable Scan Snapshots** — Bounded workers finish a tree before a frontend can observe it
- **Three Visualizations** — Treemap, hierarchical sunburst, and detailed list views
- **Smart Sorting** — Sort by name or size (ascending/descending)
- **Safe Cleanup** — Reveal in Finder or move confirmed files and folders to macOS Trash; protected scan roots are blocked
- **Quick Access** — Scan Home, Applications, Documents, Downloads, or any custom folder
- **Mounted Volume Overview** — Scan internal, external, and network volumes with free-space context
- **Breadcrumb Navigation** — Easy traversal up and down the directory tree
- **Dark Mode** — Native support for macOS dark mode
- **File Type Colors** — Files colored by extension type for quick visual identification
- **Storage Intelligence** — Largest files, old large files, and same-size duplicate discovery
- **Verified Duplicates** — Cancellable sample-first and full-file SHA-256 verification, including copies with different names
- **Scan Comparison** — Compare a current scan with a versioned snapshot to find additions, removals, growth, and reclaimed space
- **Accurate Storage Accounting** — Shows logical and allocated sizes and avoids hard-link double counting
- **Scan Health** — Reports unreadable paths, skipped folders, packages, symlinks, and revisited targets
- **Global Search** — Debounced indexed search by file name or path without blocking the interface
- **Portable Exports** — Versioned JSON and streaming CSV with reliability metadata
- **Deep-Tree Safety** — Iterative tree building, navigation, and cleanup updates avoid recursion overflow
- **Linux CLI** — Read-only directory scans and JSON/CSV exports

### Platform Capabilities

| Capability | macOS | Linux |
| --- | --- | --- |
| Bounded scanning, size accounting, hard-link handling, diagnostics | Yes | Yes |
| JSON and CSV exports | Yes | Yes |
| Treemap, sunburst, list browser, search, and analysis sidebar | Yes | No |
| Snapshot comparison and duplicate verification UI | Yes | No |
| Open, reveal, Quick Look, and move to Trash | Yes | No; the CLI is read-only |
| Release packaging (v1.2+) | Universal notarized DMG | Static x86_64 and ARM64 archives |

Linux currently provides the same hardened scanning and export core, not a desktop GUI equivalent.

## Requirements

### macOS App

- macOS 13.0 (Ventura) or later
- Intel or Apple Silicon
- Xcode 15.0+ (for building from source)

### Linux CLI

- v1.2+ release archive: x86_64 or ARM64 Linux; no Swift runtime is required
- Source build: a distribution and toolchain supported by Swift 5.9 or later

Starting with v1.2, release archives use Swift's fully static musl SDK and do not depend on a
distribution's glibc, libstdc++, or Swift installation. CI runs the same x86_64 binary on Ubuntu
22.04/24.04, Debian 12, Fedora 42, Rocky Linux 9, and Alpine 3.23, and runs the ARM64 binary on
Ubuntu and Alpine.

## Building

### Using Swift Package Manager

```bash
swift build
```

SwiftPM builds the native app executable on macOS and the command-line executable on Linux.

### Creating a Universal App Bundle

```bash
./build.sh
```

This will create `DiskInventoryZed.app` in the current directory, built as a universal binary for both Intel and Apple Silicon.

### Using Xcode

1. Open `Package.swift` in Xcode
2. Select the `DiskInventoryZed` scheme and **My Mac** destination
3. Build and run; use `./build.sh` for an explicit Intel/Apple Silicon universal bundle

### Building the Linux CLI

```bash
swift build -c release
.build/release/DiskInventoryZed --help
```

Native source-build smoke tests run on Ubuntu 22.04/24.04, Debian 12, Amazon Linux 2, and Red Hat
UBI 9. Portable release packaging specifically requires the Swift 6.3.3 Linux toolchain. Install
its matching Static Linux SDK, then build either architecture:

```bash
swift sdk install \
  https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
  --checksum 87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b
export SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"
./scripts/package-source.sh dist
./scripts/package-linux.sh x86_64-swift-linux-musl dist
./scripts/package-linux.sh aarch64-swift-linux-musl dist
```

The source packager downloads commit-pinned upstream source archives and rejects any SHA-256
mismatch. Each portable archive includes the full GPL, third-party notices, exact build metadata,
and corresponding-source directions. Per-architecture SPDX 2.3 JSON documents are emitted beside
the binary archives.

### Installing a Linux Release

Download the archive matching your architecture, then install the executable:

```bash
grep 'linux-x86_64\.tar\.gz$' DiskInventoryZed-checksums.txt | sha256sum -c -
tar -xzf DiskInventoryZed-*-linux-x86_64.tar.gz
sudo install -m 755 DiskInventoryZed-*-linux-x86_64/DiskInventoryZed /usr/local/bin/
DiskInventoryZed --help
```

On ARM64, use the corresponding `linux-aarch64` archive and directory names.

Official releases also publish GitHub artifact attestations. Verify a downloaded artifact with:

```bash
gh attestation verify DiskInventoryZed-1.2-linux-x86_64.tar.gz \
  --repo neuralnexus/DiskInventoryZed
```

## Installing the macOS Release

Starting with v1.2, official tagged releases are Developer ID signed, hardened-runtime enabled,
notarized, and stapled. The release gate verifies the final mounted DMG and the exact app delivered
inside it before publication.

The DMG contains exactly `DiskInventoryZed.app` and an `Applications` symlink. Open the DMG, drag the
app to Applications, and launch it from `/Applications`.

If Gatekeeper rejects an official v1.2-or-later artifact, do not use **Open Anyway**, remove
quarantine manually, or disable Gatekeeper. Delete the download, verify its release checksum and
GitHub attestation, and report the failed release artifact.

Protected locations may require Full Disk Access. Grant it only if needed under **System Settings >
Privacy & Security > Full Disk Access**, then restart Disk Inventory Zed.

Developer and ordinary CI builds are ad-hoc signed and explicitly labeled
`UNSIGNED-CI-NOT-FOR-DISTRIBUTION`; they are not release artifacts.

### Release Controls

Tagged publication requires all build jobs to pass and the tag to match the version on the current
`main` commit. The protected GitHub `release` environment must define the public `APPLE_TEAM_ID`
environment variable and the Apple signing/notarization secrets used by the workflow. The variable
is independently compared with the notarization Team ID and every delivered code signature.
The environment must also provide a narrowly scoped `RELEASE_POLICY_TOKEN` with repository
**Administration: read** permission so publication can fail closed unless immutable Releases are
enabled.

Repository administration must protect `main`, require the build workflow, require review for the
`release` environment, restrict workflow changes with `CODEOWNERS`, protect `v*` tags, and enable
immutable GitHub Releases. These controls are external to this repository and are required before a
production tag is created.

## macOS Usage

1. Launch the app
2. Click "Choose Folder" or select a quick access location from the sidebar
3. Wait for the scan to complete (progress is shown in real-time)
4. Explore the treemap visualization — click any rectangle to zoom into that folder
5. Switch to list view for detailed file information
6. Right-click any file or folder for actions (reveal in Finder, move to trash)

## Linux Usage

Scan a directory and print a storage summary:

```bash
DiskInventoryZed /home/user
```

Create a JSON export. Hidden entries are included by default so disk totals are complete:

```bash
DiskInventoryZed --json scan.json /home/user
```

Create a CSV export in a separate scan:

```bash
DiskInventoryZed --csv scan.csv /home/user
```

Use `--exclude-hidden` to omit hidden entries or `--skip-developer-folders` to omit folders such as
`.git`, `node_modules`, and `.build`. Use `--version` to print the installed release version.
The Linux CLI lists symlinks but never follows them, and it never deletes or moves files. Use one
export option per scan and place the output outside the scanned directory. If any entry cannot be
read or represented safely, the command exits nonzero and does not write the requested export.
`SIGINT` and `SIGTERM` cancel work cooperatively so temporary export state can be removed. If
shutdown stalls, a forced-exit watchdog preserves the conventional 130 or 143 status.
The selected scan root must not contain `..` or pass through a symbolic-link path component.
Linux exports are create-only, refuse to replace any existing path, and use owner-only permissions
(`0600`). Export directory ancestry must be owned by the current user or root; group- or
world-writable directories require the sticky bit. Do not route an export through a bind mount that
aliases any part of the scan path. Export destinations must support Unix ownership, file modes, and
hard links; FAT/exFAT and some SMB or FUSE mounts are not suitable export destinations.

### macOS Analysis Sidebar

The macOS analysis sidebar goes beyond the classic Disk Inventory X workflow:

- **Types** aggregates storage by extension.
- **Largest** finds the largest files anywhere in the scanned tree.
- **Review** highlights old large files and files with the same byte size. Duplicate
  candidates are intentionally labeled as possibilities until the app verifies their full SHA-256
  content digests. Matching names are not required.
- **Changes** compares a current scan with an earlier snapshot of the same location and separates
  growth, reductions, additions, and removals.
- **Selection** distinguishes logical size from space allocated on disk, which matters for sparse
  files, clones, and hard links.

## Architecture

- **SwiftUI** — Modern declarative UI framework
- **Swift Concurrency** — A bounded actor-backed work queue with cooperative cancellation
- **Platform Front Ends** — SwiftUI on macOS and a read-only command-line interface on Linux
- **Immutable Snapshots** — Background workers never mutate data already published to SwiftUI
- **Iterative Tree Operations** — Deep paths do not consume one call-stack frame per directory
- **Cycle Protection** — Symlink targets and previously visited directories are not traversed twice
- **Two-Stage Duplicate Verification** — First/last-byte samples minimize I/O before full SHA-256 hashing
- **Squarified Treemap** — Industry-standard algorithm for optimal rectangle aspect ratios
- **MVVM Pattern** — Clean separation between views and business logic

## Accuracy Notes

- “On disk” uses allocated size when macOS provides it and Linux `stat` block accounting; “logical” is the apparent file length.
- Totals sum file allocation and do not include filesystem directory-entry metadata.
- Multiple hard links to the same file are shown, but their allocated storage is counted once.
- Linux filenames that are not valid UTF-8 are reported as unreadable, and prevent export, because exported paths are UTF-8 strings.
- Scans and exports are capped at 250,000 examined entries, individual directories at 25,000
  examined entries including hidden entries, 8 MiB of retained paths per directory, and 64 MiB of
  retained file-system paths per scan.
- Linux scan paths are capped at 256 components and 16 KiB per path. Imported JSON snapshots are
  capped at 256 MiB.
- APFS clones and Linux reflinks or deduplicated extents can share physical blocks without exposing
  enough portable per-file metadata to measure exact exclusive ownership. Disk Inventory Zed reports
  per-inode allocated blocks and does not claim clone-level or reflink-level reclaimable bytes.
- Unreadable or intentionally skipped directories are surfaced in scan diagnostics instead of
  silently presenting the result as complete.

## License

Copyright (C) 2026 Matt Ivan.

This project is licensed under the GNU General Public License v3.0 or later
(`GPL-3.0-or-later`). See the complete [LICENSE](LICENSE) text for details.

## Acknowledgments

Design and concept inspired by:
- **[Disk Inventory X](https://www.derlien.com/)** by Tjark Derlien — the original macOS disk usage visualizer that started it all
- **[KDirStat](https://kdirstat.sourceforge.net/)** by Alexander Lehmann — the pioneering treemap visualization tool for disk usage

These classic tools demonstrated that disk usage analysis should be beautiful, intuitive, and fast. Disk Inventory Zed carries that vision forward with a native macOS interface and a portable Swift scanning core.

## Contributing

Contributions are welcome! This is open source software released under the GPL. Please ensure your contributions comply with the license terms.

## Author

Made by **Matt Ivan** — 2026
