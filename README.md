<img width="125" height="125" alt="16a92001-236b-448c-a6a1-bf9102c57574" src="https://github.com/user-attachments/assets/40f4d702-5e0d-47da-986a-377849ac6fbd" />

# Disk Inventory Zed

A modern, fast successor to the classic disk visualizers **Disk Inventory X** and **OverDisk**, with a native macOS release and a Windows port under active development.
This is not a fork; it is a GPL-licensed re-imagination of a KDirStat-style disk mapping utility.

## Overview

Disk Inventory Zed visualizes disk usage with interactive sunbursts, treemaps, and detailed file listings. The macOS application uses SwiftUI; the Windows port uses WPF and targets x64 and ARM64 systems, mapped drives, and UNC shares.

<img width="1510" height="912" alt="Screenshot 2026-05-28 at 12 38 48 PM" src="https://github.com/user-attachments/assets/ab03ce74-0768-4226-ac5c-2bf87c44e8be" />


## Features

- **Interactive Treemap Visualization** — Squarified treemap algorithm for optimal space usage visualization
- **Fast Concurrent Scanning** — Uses Swift concurrency for parallel directory traversal
- **Crash-Safe Scan Snapshots** — Bounded workers build an immutable tree before SwiftUI sees it
- **Bounded Windows Scans** — Windows fails closed at one million retained entries instead of risking unbounded memory growth
- **Three Visualizations** — Treemap, hierarchical sunburst, and detailed list views
- **Smart Sorting** — Sort by name or size (ascending/descending)
- **Bounded File Actions** — Reveal items in Finder or File Explorer; macOS also supports confirmed moves to Trash, while Windows performs no deletion
- **Quick Access** — Scan common folders, drive letters, mounted volumes, mapped drives, UNC shares, or any custom folder
- **Mounted Volume Overview** — Scan internal, external, and network volumes with free-space context
- **Breadcrumb Navigation** — Easy traversal up and down the directory tree
- **Platform-Native UI** — SwiftUI on macOS and a sunburst-first WPF interface on Windows
- **File Type Colors** — Files colored by extension type for quick visual identification
- **Storage Intelligence** — Largest files, old large files, and same-size duplicate discovery
- **Verified Duplicates** — Cancellable sample-first and full-file SHA-256 verification, including copies with different names
- **Scan Comparison (macOS)** — Compare a current scan with a versioned snapshot to find additions, removals, growth, and reclaimed space
- **Storage Accounting** — Shows logical and allocated sizes, de-duplicates hard links when identity metadata is available, and reports uncertainty
- **Scan Health** — Reports unreadable paths, skipped folders, packages, symlinks, and revisited targets
- **Global Search** — Debounced indexed search by file name or path without blocking the interface
- **Portable Exports** — Versioned JSON and streaming CSV with reliability metadata
- **Deep-Tree Safety** — Iterative tree building, navigation, and export avoid recursion overflow
- **Private Local Diagnostics** — Windows keeps a small local crash journal with no telemetry, scanned paths, filenames, or exception messages

## Requirements

### macOS

- macOS 13.0 (Ventura) or later
- Intel or Apple Silicon
- Xcode 15.0+ (for building from source)

### Windows Port Preview

- Windows 11 24H2 or later as this project's mainstream client baseline
- x64 is exercised on GitHub-hosted Windows CI; ARM64 archives are structurally validated, with native ARM64 execution still pending
- .NET 10.0.302 SDK and Visual Studio 2026 .NET desktop workload (only when building from source)

The latest public `v1.1` release contains macOS assets only. Windows source and CI packages on this
branch are preparing the planned `v1.2.0` release; do not treat ARM64 as production-validated until a
native ARM64 validation run is reported as passing. See [GitHub Releases](https://github.com/neuralnexus/DiskInventoryZed/releases)
for the asset matrix that actually shipped.

## Building

### macOS: Using Swift Package Manager

```bash
swift build
```

### macOS: Creating a Universal App Bundle

```bash
./build.sh
```

This will create `DiskInventoryZed.app` in the current directory, built as a universal binary for both Intel and Apple Silicon.

### macOS: Using Xcode

1. Open the project in Xcode
2. Select your target (Intel or Universal)
3. Build and run

### Windows

```powershell
dotnet restore Windows\DiskInventoryZed.Windows.sln
dotnet test Windows\DiskInventoryZed.Windows.sln -c Release
dotnet run --project Windows\src\DiskInventoryZed.Windows\DiskInventoryZed.Windows.csproj
```

Create self-contained x64 or ARM64 release zips with:

```powershell
pwsh Windows\scripts\package.ps1 -Runtime win-x64
pwsh Windows\scripts\package.ps1 -Runtime win-arm64
```

See [Windows/README.md](Windows/README.md) for network-path behavior, shortcuts, packaging, and accuracy notes.

## macOS First Launch

Developer builds are ad-hoc signed, so macOS Gatekeeper may show a security warning when you first
try to open one. The release workflow refuses to publish a tag unless its app is Developer ID signed
and its DMG is notarized and stapled:

> **"Apple could not verify 'DiskInventoryZed' is free of malware that may harm your Mac or compromise your privacy."**

### Downloading the DMG

The DMG installer includes:
- **DiskInventoryZed.app** — the main application
- **README.txt** — detailed first-launch instructions
- **LICENSE.txt** — the complete GNU GPL version 3 license

### Quick Method: Right-click to Open

1. **Right-click** (or Control-click) the `DiskInventoryZed.app`
2. Select **"Open"** from the context menu
3. Click **"Open"** in the dialog that appears

### Manual Method

1. Go to **System Settings > Privacy & Security**
2. Scroll down to the **Security** section
3. Click **"Open Anyway"** next to DiskInventoryZed
4. Click **"Open"** in the confirmation dialog

*Note: You only need to do this once. After the first launch, the app will open normally.*

## Usage

1. Launch the app
2. Click "Choose Folder" or select a quick access location from the sidebar
3. Wait for the scan to complete (progress is shown in real-time)
4. Explore the treemap visualization — click any rectangle to zoom into that folder
5. Switch to list view for detailed file information
6. Right-click any file or folder for actions. Both platforms can reveal items; only macOS offers a confirmed move to Trash.

The analysis sidebar goes beyond the classic Disk Inventory X workflow:

- **Types** aggregates storage by extension.
- **Largest** finds the largest files anywhere in the scanned tree.
- **Review** highlights old large files and files with the same byte size. Duplicate
  candidates are intentionally labeled as possibilities until the app verifies their full SHA-256
  content digests. Matching names are not required.
- **Changes (macOS)** compares a current scan with an earlier snapshot of the same location and separates
  growth, reductions, additions, and removals.
- **Selection** distinguishes logical size from space allocated on disk, which matters for sparse
  files, clones, and hard links.

## Architecture

- **SwiftUI** — Modern declarative UI framework
- **WPF on .NET 10 LTS** — Native Windows desktop UI with custom-drawn sunburst and treemap controls
- **Swift Concurrency** — A bounded actor-backed work queue with cooperative cancellation
- **Windows File IDs** — ReFS/NTFS 128-bit identity for cycle protection and hard-link accounting
- **Immutable Snapshots** — Background workers never mutate data already published to either UI
- **Iterative Tree Operations** — Deep paths do not consume one call-stack frame per directory
- **Cycle Protection** — Symlink targets and previously visited directories are not traversed twice
- **Two-Stage Duplicate Verification** — First/last-byte samples minimize I/O before full SHA-256 hashing
- **Squarified Treemap** — Industry-standard algorithm for optimal rectangle aspect ratios
- **MVVM Pattern** — Clean separation between views and business logic

## Accuracy Notes

- “On disk” uses allocated size when macOS provides it; “logical” is the apparent file length.
- Windows uses allocation size reported by the filesystem and reports metadata estimates separately
  from entries that could not be read or enumerated.
- Multiple hard links to the same file are shown and counted once when the filesystem supplies stable identity metadata; uncertain cases are reported.
- APFS clones can share physical blocks without exposing enough public per-file metadata to measure
  exact exclusive ownership. Disk Inventory Zed does not claim clone-level reclaimable bytes.
- Unreadable or intentionally skipped directories are surfaced in scan diagnostics instead of
  silently presenting the result as complete.
- Hidden Windows entries are excluded by default. The completed scan records that policy and reports
  the number of hidden entries encountered; descendants of an excluded directory are not enumerated.
- NTFS alternate data streams are not included in the initial Windows port. ReFS clones, Windows
  deduplication, cloud placeholders, and shared extents can also limit exact reclaimable-byte estimates.

## Release Integrity

- A release tag must exactly match the version in both platform manifests and point to a commit on `main`.
- Automation re-resolves the remote tag immediately before draft mutation and publication, and aborts
  if it no longer points to the commit that produced the artifacts.
- Tagged macOS artifacts require Developer ID signing and successful Apple notarization and stapling.
- Tagged Windows artifacts require allowlisted Authenticode publisher identity, SHA-256 signing, and a
  trusted RFC 3161 timestamp. Every shipped PE file must carry a valid embedded signature.
- GitHub artifact attestations bind each signed DMG and Windows zip to the release workflow and source
  commit. Verify a download with `gh attestation verify <file> --repo neuralnexus/DiskInventoryZed`.
- The approval-gated publication job creates a draft, downloads every uploaded asset, verifies local and
  server SHA-256 digests, and publishes that same identity immediately. It refuses existing published
  releases and drafts not owned by the current workflow run.
- Production tags fail closed unless immutable releases are enabled and both `release-signing` and
  `release-publish` environments require reviewers, prevent self-review and administrator bypass, and
  permit only `v*` tags.
- `release-publish` also requires a fine-grained `RELEASE_SETTINGS_TOKEN` secret scoped only to this
  repository with **Administration: read-only** permission so the workflow can verify immutability before
  creating a draft. Artifact publication continues to use the short-lived `GITHUB_TOKEN`.
- Apple credentials belong only in `release-signing`: `APPLE_SIGNING_CERTIFICATE_BASE64`,
  `APPLE_SIGNING_CERTIFICATE_PASSWORD`, `APPLE_KEYCHAIN_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`,
  `APPLE_TEAM_ID`, and `APPLE_APP_PASSWORD`.
- Windows credentials belong only in `release-signing`: `WINDOWS_SIGNING_CERTIFICATE_BASE64` and
  `WINDOWS_SIGNING_CERTIFICATE_PASSWORD`; allowlist `WINDOWS_SIGNING_CERTIFICATE_THUMBPRINT`,
  `WINDOWS_SIGNING_PUBLISHER_SUBJECT`, and the HTTPS `WINDOWS_TIMESTAMP_URL` as environment variables.
- The standard-library validator in `scripts/release_integrity.py` is unit-tested on every workflow run
  and rejects malformed manifests, prereleases, ownership changes, and release/asset identity changes.
- GitHub's legacy version/date selection determines the **Latest** release, so publishing an older
  maintenance tag does not unconditionally displace a newer release.
- Protect `v*` tags with an active tag ruleset whose only include is `refs/tags/v*`, whose exclusion list
  is empty, and whose rules prohibit updates and deletion; configure no bypass actors. GitHub API
  verification and publication are separate operations, so this ruleset remains part of the security boundary.
- Windows dependencies are restored from committed lock files with the repository-pinned .NET SDK.
- Windows release zips use a versioned top-level directory and include exact payload checksums,
  source/package metadata, the GPL, the .NET license, and third-party notices.

## License

Copyright (C) 2026 Matt Ivan.

This project is licensed under the GNU General Public License v3.0 (GPL-3.0) — see the [LICENSE](LICENSE) file for details.

## Acknowledgments

Design and concept inspired by:
- **[Disk Inventory X](https://www.derlien.com/)** by Tjark Derlien — the original macOS disk usage visualizer that started it all
- **[KDirStat](https://kdirstat.sourceforge.net/)** by Alexander Lehmann — the pioneering treemap visualization tool for disk usage
- **OverDisk** — the classic Windows circular disk-usage visualization that inspired the Windows sunburst-first workflow

These classic tools demonstrated that disk usage visualization should be beautiful, intuitive, and fast. Disk Inventory Zed carries that vision forward on macOS and Windows.

## Contributing

Contributions are welcome! This is open source software released under the GPL. Please ensure your contributions comply with the license terms.

## Author

Made by **Matt Ivan** — 2026
