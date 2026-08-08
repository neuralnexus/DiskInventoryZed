<img width="125" height="125" alt="16a92001-236b-448c-a6a1-bf9102c57574" src="https://github.com/user-attachments/assets/40f4d702-5e0d-47da-986a-377849ac6fbd" />

# Disk Inventory Zed

A modern, fast, native successor to the classic macOS utility **Disk Inventory X**.
This is not a fork; it is a re-imagination of a kdirstat style treemapping disk utility built for MacOS file discovery. 
License is GPL. 

## Overview

Disk Inventory Zed is a native macOS application that visualizes disk usage with beautiful, interactive treemaps and detailed file listings. Built with SwiftUI and modern macOS APIs, it supports both Intel and Apple Silicon Macs.

<img width="1840" height="1191" alt="DiskInventoryZed Screenshot 2026-08-07 at 9 55 01 PM" src="https://github.com/user-attachments/assets/7df2c971-0144-4223-9e08-66f59bb4d437" />
<img width="1510" height="912" alt="Screenshot 2026-05-28 at 12 38 48 PM" src="https://github.com/user-attachments/assets/ab03ce74-0768-4226-ac5c-2bf87c44e8be" />


## Features

- **Interactive Treemap Visualization** — Squarified treemap algorithm for optimal space usage visualization
- **Fast Concurrent Scanning** — Uses Swift concurrency for parallel directory traversal
- **Crash-Safe Scan Snapshots** — Bounded workers build an immutable tree before SwiftUI sees it
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

## Requirements

- macOS 13.0 (Ventura) or later
- Intel or Apple Silicon
- Xcode 15.0+ (for building from source)

## Building

### Using Swift Package Manager

```bash
swift build
```

### Creating a Universal App Bundle

```bash
./build.sh
```

This will create `DiskInventoryZed.app` in the current directory, built as a universal binary for both Intel and Apple Silicon.

### Using Xcode

1. Open the project in Xcode
2. Select your target (Intel or Universal)
3. Build and run

## First Launch

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
6. Right-click any file or folder for actions (reveal in Finder, move to trash)

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
- **Swift Concurrency** — A bounded actor-backed work queue with cooperative cancellation
- **Immutable Snapshots** — Background workers never mutate data already published to SwiftUI
- **Iterative Tree Operations** — Deep paths do not consume one call-stack frame per directory
- **Cycle Protection** — Symlink targets and previously visited directories are not traversed twice
- **Two-Stage Duplicate Verification** — First/last-byte samples minimize I/O before full SHA-256 hashing
- **Squarified Treemap** — Industry-standard algorithm for optimal rectangle aspect ratios
- **MVVM Pattern** — Clean separation between views and business logic

## Accuracy Notes

- “On disk” uses allocated size when macOS provides it; “logical” is the apparent file length.
- Multiple hard links to the same file are shown, but their allocated storage is counted once.
- APFS clones can share physical blocks without exposing enough public per-file metadata to measure
  exact exclusive ownership. Disk Inventory Zed does not claim clone-level reclaimable bytes.
- Unreadable or intentionally skipped directories are surfaced in scan diagnostics instead of
  silently presenting the result as complete.

## License

Copyright (C) 2026 Matt Ivan.

This project is licensed under the GNU General Public License v3.0 (GPL-3.0) — see the [LICENSE](LICENSE) file for details.

## Acknowledgments

Design and concept inspired by:
- **[Disk Inventory X](https://www.derlien.com/)** by Tjark Derlien — the original macOS disk usage visualizer that started it all
- **[KDirStat](https://kdirstat.sourceforge.net/)** by Alexander Lehmann — the pioneering treemap visualization tool for disk usage

These classic tools demonstrated that disk usage visualization should be beautiful, intuitive, and fast. Disk Inventory Zed carries that vision forward with modern macOS technologies.

## Contributing

Contributions are welcome! This is open source software released under the GPL. Please ensure your contributions comply with the license terms.

## Author

Made by **Matt Ivan** — 2026
