<img width="125" height="125" alt="16a92001-236b-448c-a6a1-bf9102c57574" src="https://github.com/user-attachments/assets/40f4d702-5e0d-47da-986a-377849ac6fbd" />

# Disk Inventory Zed

A modern, fast, native successor to the classic macOS utility **Disk Inventory X**.

## Overview

Disk Inventory Zed is a native macOS application that visualizes disk usage with beautiful, interactive treemaps and detailed file listings. Built with SwiftUI and modern macOS APIs, it supports both Intel and Apple Silicon Macs.

<img width="1510" height="912" alt="Screenshot 2026-05-28 at 12 38 48 PM" src="https://github.com/user-attachments/assets/ab03ce74-0768-4226-ac5c-2bf87c44e8be" />


## Features

- **Interactive Treemap Visualization** — Squarified treemap algorithm for optimal space usage visualization
- **Fast Concurrent Scanning** — Uses Swift concurrency for parallel directory traversal
- **Dual View Modes** — Switch between treemap and detailed list view
- **Smart Sorting** — Sort by name or size (ascending/descending)
- **File Actions** — Reveal in Finder, move to trash
- **Quick Access** — Scan Home, Applications, Documents, Downloads, or any custom folder
- **Breadcrumb Navigation** — Easy traversal up and down the directory tree
- **Dark Mode** — Native support for macOS dark mode
- **File Type Colors** — Files colored by extension type for quick visual identification

## Requirements

- macOS 13.0 (Ventura) or later
- Intel or Apple Silicon (M1/M2/M3/M4 or later)
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

Since Disk Inventory Zed is not distributed through the Mac App Store or notarized by Apple, macOS Gatekeeper may show a security warning when you first try to open it:

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

## Architecture

- **SwiftUI** — Modern declarative UI framework
- **Swift Concurrency** — Async/await with concurrent task groups for fast scanning
- **Squarified Treemap** — Industry-standard algorithm for optimal rectangle aspect ratios
- **MVVM Pattern** — Clean separation between views and business logic

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
