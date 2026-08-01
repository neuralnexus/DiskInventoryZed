# Disk Inventory Zed for Windows

The Windows port is a native WPF application for Windows 10 and Windows 11. It opens in the
interactive circular sunburst view and includes the rectangular heatmap and sortable file list.

## Supported Locations

- Local fixed, removable, and mounted volumes
- Mapped network drive letters such as `Z:\`
- UNC roots and folders such as `\\server\share` or `\\server\share\folder`

Mapped drives appear in the Drives panel. A UNC path can be pasted directly into the location
field even when the share is not mapped to a drive letter. Scans use the permissions of the
current Windows user and do not require administrator access.

Windows network APIs can block while an unavailable server times out. The Cancel button stops
cooperatively, but Windows may need to return from an in-progress SMB request before the scan can
fully exit. Network scans use fewer concurrent workers to avoid overloading a share.

## Features

- Sunburst-first disk visualization with proportional concentric rings
- Squarified rectangular heatmap with nested folders
- Bounded worker count, scan progress, cancellation, and immutable completed results
- Windows allocated-size accounting for sparse and compressed files
- ReFS/NTFS 128-bit file identity and deterministic hard-link de-duplication
- Safe handling of symlinks, junctions, mount points, and other reparse tags
- Folder tree, breadcrumbs, history, global search, size filters, and type highlighting
- Largest-file, old-file, and same-size duplicate analysis
- Sample-first and full SHA-256 duplicate verification
- Schema-v3 JSON snapshots compatible with the macOS application
- Streaming CSV inventory export
- File Explorer integration and confirmed Recycle Bin cleanup

Network items cannot be sent to the Recycle Bin from Disk Inventory Zed. The application uses
Windows `IFileOperation` with `FOFX_RECYCLEONDELETE` for eligible local items and never falls back
to permanent deletion.

## Requirements

- Windows 10 version 22H2 or Windows 11
- x64 or ARM64 processor
- .NET is not required for release downloads; published builds are self-contained

Release zips are unsigned unless an Authenticode certificate is configured. Windows SmartScreen
may therefore ask for confirmation on first launch.

## Run A Release

1. Extract the zip to a writable folder.
2. Run `DiskInventoryZed.exe`.
3. Choose a folder or drive, click a listed drive, or paste a UNC path and select **Scan**.

The portable zip does not install services, drivers, Explorer extensions, or telemetry.

## Build From Source

Install the .NET 8 SDK and Visual Studio 2022 with the **.NET desktop development** workload.

```powershell
dotnet restore Windows\DiskInventoryZed.Windows.sln
dotnet test Windows\tests\DiskInventoryZed.Core.Tests\DiskInventoryZed.Core.Tests.csproj -c Release
dotnet run --project Windows\src\DiskInventoryZed.Windows\DiskInventoryZed.Windows.csproj
```

Create a self-contained release zip:

```powershell
pwsh Windows\scripts\package.ps1 -Runtime win-x64
pwsh Windows\scripts\package.ps1 -Runtime win-arm64
```

Artifacts are written to `artifacts\windows`.

## Keyboard Shortcuts

- `Ctrl+1`: Sunburst
- `Ctrl+2`: Heatmap
- `Ctrl+3`: List
- `Alt+Left` / `Alt+Right`: Back / forward
- `Backspace`: Parent folder
- `F5`: Rescan
- `Esc`: Cancel the current scan
- `Delete`: Recycle the explicitly selected visualization or list item

## Accuracy Notes

- **On disk** uses Windows allocation size when available and reports a logical-size estimate when
  the filesystem or server does not expose allocation data.
- Hard-linked files are shown at every path, but their allocated storage is counted once.
- NTFS alternate data streams are not enumerated in this initial Windows release.
- ReFS block cloning, Windows Server Data Deduplication, cloud placeholders, and shared extents can
  prevent exact per-file reclaimable-byte accounting.
- Cloud placeholders are scanned from metadata without intentional hydration. Offline files are
  skipped during content-based duplicate verification.
- Reparse points that cannot be classified safely are shown but not traversed.

## Project Layout

- `src/DiskInventoryZed.Core`: platform-neutral models, scanner, analysis, layouts, and export
- `src/DiskInventoryZed.Windows`: WPF shell, custom drawing controls, and Windows integration
- `tests/DiskInventoryZed.Core.Tests`: scanner, model, layout, export, and duplicate tests
- `scripts/package.ps1`: self-contained Windows zip packaging
