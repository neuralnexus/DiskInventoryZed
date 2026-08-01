<img width="125" height="125" alt="16a92001-236b-448c-a6a1-bf9102c57574" src="https://github.com/user-attachments/assets/40f4d702-5e0d-47da-986a-377849ac6fbd" />

# Disk Inventory Zed

A modern, fast successor to the classic disk visualizers **Disk Inventory X** and **OverDisk**, with native applications for macOS and Windows.
This is not a fork; it is a GPL-licensed re-imagination of a KDirStat-style disk mapping utility.

## Overview

Disk Inventory Zed visualizes disk usage with interactive sunbursts, treemaps, and detailed file listings. The macOS application uses SwiftUI; the Windows port uses WPF and supports x64 and ARM64 Windows systems, mapped drives, and UNC shares.

<img width="1510" height="912" alt="Screenshot 2026-05-28 at 12 38 48 PM" src="https://github.com/user-attachments/assets/ab03ce74-0768-4226-ac5c-2bf87c44e8be" />


## Features

- **Interactive Treemap Visualization** — Squarified treemap algorithm for optimal space usage visualization
- **Fast Concurrent Scanning** — Uses Swift concurrency for parallel directory traversal
- **Crash-Safe Scan Snapshots** — Bounded workers build an immutable tree before SwiftUI sees it
- **Three Visualizations** — Treemap, hierarchical sunburst, and detailed list views
- **Smart Sorting** — Sort by name or size (ascending/descending)
- **Safe Cleanup** — Reveal in Finder or File Explorer and move confirmed local items to Trash or the Recycle Bin; protected roots are blocked
- **Quick Access** — Scan common folders, drive letters, mounted volumes, mapped drives, UNC shares, or any custom folder
- **Mounted Volume Overview** — Scan internal, external, and network volumes with free-space context
- **Breadcrumb Navigation** — Easy traversal up and down the directory tree
- **Platform-Native UI** — SwiftUI on macOS and a sunburst-first WPF interface on Windows
- **File Type Colors** — Files colored by extension type for quick visual identification
- **Storage Intelligence** — Largest files, old large files, and same-size duplicate discovery
- **Verified Duplicates** — Cancellable sample-first and full-file SHA-256 verification, including copies with different names
- **Scan Comparison** — Compare a current scan with a versioned snapshot to find additions, removals, growth, and reclaimed space
- **Accurate Storage Accounting** — Shows logical and allocated sizes and avoids hard-link double counting
- **Scan Health** — Reports unreadable paths, skipped folders, packages, symlinks, and revisited targets
- **Global Search** — Debounced indexed search by file name or path without blocking the interface
- **Portable Exports** — Versioned JSON and streaming CSV with reliability metadata
- **Deep-Tree Safety** — Iterative tree building, navigation, and cleanup updates avoid recursion overflow

## Requirements

### macOS

- macOS 13.0 (Ventura) or later
- Intel or Apple Silicon
- Xcode 15.0+ (for building from source)

### Windows

- Windows 10 22H2 or Windows 11
- x64 or ARM64
- .NET 8 SDK and Visual Studio 2022 .NET desktop workload (only when building from source)

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
dotnet test Windows\tests\DiskInventoryZed.Core.Tests\DiskInventoryZed.Core.Tests.csproj -c Release
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
try to open one. Tagged releases can be Developer ID signed and notarized when the repository's
Apple signing credentials are configured:

> **"Apple could not verify 'DiskInventoryZed' is free of malware that may harm your Mac or compromise your privacy."**

### Downloading the DMG

The DMG installer includes:
- **DiskInventoryZed.app** — the main application
- **First-Run-Helper.app** — click this to open Security & Privacy settings automatically
- **README.txt** — detailed first-launch instructions

### Quick Method: Right-click to Open

1. **Right-click** (or Control-click) the `DiskInventoryZed.app`
2. Select **"Open"** from the context menu
3. Click **"Open"** in the dialog that appears

### Using the First-Run-Helper

1. Double-click **"First-Run-Helper.app"** in the DMG
2. Click **"Open Security Settings"** in the dialog
3. System Settings will open to the Security pane
4. Click **"Open Anyway"** next to DiskInventoryZed
5. Click **"Open"** in the confirmation dialog

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
6. Right-click any file or folder for actions (reveal in Finder/File Explorer or move eligible local items to Trash/Recycle Bin)

The analysis sidebar goes beyond the classic Disk Inventory X workflow:

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
- **WPF on .NET 8** — Native Windows desktop UI with custom-drawn sunburst and treemap controls
- **Swift Concurrency** — A bounded actor-backed work queue with cooperative cancellation
- **Windows File IDs** — ReFS/NTFS 128-bit identity for cycle protection and hard-link accounting
- **Immutable Snapshots** — Background workers never mutate data already published to SwiftUI
- **Iterative Tree Operations** — Deep paths do not consume one call-stack frame per directory
- **Cycle Protection** — Symlink targets and previously visited directories are not traversed twice
- **Two-Stage Duplicate Verification** — First/last-byte samples minimize I/O before full SHA-256 hashing
- **Squarified Treemap** — Industry-standard algorithm for optimal rectangle aspect ratios
- **MVVM Pattern** — Clean separation between views and business logic

## Accuracy Notes

- “On disk” uses allocated size when macOS provides it; “logical” is the apparent file length.
- Windows uses allocation size reported by the filesystem and marks logical-size fallbacks in scan diagnostics.
- Multiple hard links to the same file are shown, but their allocated storage is counted once.
- APFS clones can share physical blocks without exposing enough public per-file metadata to measure
  exact exclusive ownership. Disk Inventory Zed does not claim clone-level reclaimable bytes.
- Unreadable or intentionally skipped directories are surfaced in scan diagnostics instead of
  silently presenting the result as complete.
- NTFS alternate data streams are not included in the initial Windows port. ReFS clones, Windows
  deduplication, cloud placeholders, and shared extents can also limit exact reclaimable-byte estimates.

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
