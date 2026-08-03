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

Windows network APIs can block while an unavailable server times out. Cancel immediately restores
the last completed snapshot and prevents the abandoned generation from publishing, although its
background worker may remain blocked until Windows returns from the in-progress SMB request. The UI
allows one retry and then refuses additional scans while two generations remain blocked, preventing
unbounded thread-pool exhaustion. Network scans use fewer concurrent workers to avoid overloading a
share.

## Features

- Sunburst-first disk visualization with proportional concentric rings
- Squarified rectangular heatmap with nested folders
- Bounded worker count, scan progress, cancellation, and immutable completed results
- Windows allocation-size accounting for sparse and compressed files when exposed by the filesystem
- ReFS/NTFS 128-bit file identity and hard-link de-duplication when stable identity is available
- Safe handling of symlinks, junctions, mount points, and other reparse tags
- Folder tree, breadcrumbs, history, global search, size filters, and type highlighting
- Largest-file, old-file, and same-size duplicate analysis
- Sample-first and full SHA-256 duplicate verification
- Schema-v3 JSON snapshots compatible with the macOS application
- Streaming CSV inventory export
- Non-destructive File Explorer integration for opening and revealing items

The Windows application does not delete, recycle, rename, or otherwise mutate scanned items. A scan
is a point-in-time path snapshot; File Explorer actions resolve the current item at that path and are
disabled while a new snapshot is being built.

## Requirements

- Windows 10 version 22H2 or Windows 11
- x64 or ARM64 processor
- .NET is not required for release downloads; published builds are self-contained

Release zips are currently not Authenticode-signed. Windows SmartScreen may therefore ask for
confirmation on first launch. Verify the zip against the SHA-256 checksum published with the release.
Each zip includes the GPL license plus the .NET runtime license and third-party notices.

## Run A Release

1. Extract the zip to a writable folder.
2. Run `DiskInventoryZed.exe`.
3. Choose a folder or drive, click a listed drive, or paste a UNC path and select **Scan**.

The portable zip does not install services, drivers, Explorer extensions, or telemetry.

## Build From Source

Install the .NET 8.0.423 SDK and Visual Studio 2022 with the **.NET desktop development** workload.
The repository-root `global.json` and committed NuGet lock files define the build toolchain.

```powershell
dotnet restore Windows\DiskInventoryZed.Windows.sln
dotnet test Windows\DiskInventoryZed.Windows.sln -c Release
dotnet run --project Windows\src\DiskInventoryZed.Windows\DiskInventoryZed.Windows.csproj
```

CI runs the cross-platform Core suite and the Windows/WPF reliability suite with zero skipped tests.
It retains TRX and Cobertura reports and enforces package-level floors of 65% line / 60% branch for
Core and 10% line / 5% branch for the Windows application. Native Windows tests cover allocation
metadata, hard links, hidden entries, junction cycles, atomic export replacement, WPF resources,
directory-guard identity/handle release, scan-generation races, dispatcher affinity, disposal, and
packaged x64 startup through asynchronous drive discovery. ARM64 packages
are structurally verified; native ARM64 execution remains a gate for the planned self-hosted runner.

Do not attach a persistent self-hosted runner to untrusted fork pull requests. Prefer an ephemeral,
isolated runner using local NTFS storage, and label it by architecture so CI can reject a mismatched
host before running filesystem tests.

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

## Accuracy Notes

- **On disk** uses Windows allocation size when available and reports a logical-size estimate when
  the filesystem or server does not expose allocation data. Metadata estimates are diagnosed
  separately from entries that could not be read or enumerated.
- Hard-linked files are shown at every path and counted once only when stable file identity is
  available. The scan reports files whose hard-link identity could not be verified.
- Hidden entries are excluded by default. Diagnostics report encountered exclusions, but cannot
  count descendants inside a directory that was not traversed.
- NTFS alternate data streams are not enumerated in this initial Windows release.
- ReFS block cloning, Windows Server Data Deduplication, cloud placeholders, and shared extents can
  prevent exact per-file reclaimable-byte accounting.
- Cloud placeholders are scanned from metadata without intentional hydration. Content-based duplicate
  verification opens one no-recall read handle and skips offline, partial, or indeterminate placeholders.
- JSON and CSV exports preserve whether an issue is a non-fatal estimate or an unreadable entry; the
  CSV field is appended so existing column positions remain stable.
- Reparse points that cannot be classified safely are shown but not traversed.
- A selected root that is a link or junction is rejected unless **Follow links and junctions** is
  enabled; a root whose reparse type or target identity is unknown is rejected.

## Project Layout

- `src/DiskInventoryZed.Core`: platform-neutral models, scanner, analysis, layouts, and export
- `src/DiskInventoryZed.Windows`: WPF shell, custom drawing controls, and Windows integration
- `tests/DiskInventoryZed.Core.Tests`: scanner, model, layout, export, and duplicate tests
- `tests/DiskInventoryZed.Windows.Tests`: ViewModel races, settings, WPF resources, and shell boundaries
- `scripts/package.ps1`: self-contained Windows zip packaging
