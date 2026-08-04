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
- A one-million-entry safety limit that fails closed before retained scan data can exhaust memory
- Bounded, privacy-safe local crash diagnostics with no telemetry

The Windows application does not delete, recycle, rename, or otherwise mutate scanned items. A scan
is a point-in-time path snapshot; File Explorer actions resolve the current item at that path and are
disabled while a new snapshot is being built.

## Requirements

- Windows 10 version 22H2 or Windows 11
- x64 or ARM64 processor
- .NET is not required for release downloads; published builds are self-contained

Official release executables and DLLs are Authenticode-signed and RFC 3161 timestamped. SmartScreen may
still show a reputation warning for a new publisher or release. Verify the zip against the SHA-256
checksum and GitHub artifact attestation published with the release. Each zip includes the GPL license,
the .NET runtime license, third-party notices, package metadata, and an exact payload manifest.

## Run A Release

1. Extract the zip to a writable folder.
2. Run `DiskInventoryZed.exe`.
3. Choose a folder or drive, click a listed drive, or paste a UNC path and select **Scan**.

The portable zip does not install services, drivers, Explorer extensions, or telemetry.

The archive has one versioned top-level folder. Keep its files together after extraction;
`PACKAGE-MANIFEST.sha256` covers every payload file other than the manifest itself, and
`PACKAGE-METADATA.json` records the version, runtime identifier, source commit, SDK, and signature policy.

## Verify A Release

Compare the downloaded zip with `DiskInventoryZed-Windows-checksums.txt` on the GitHub release, then verify
its provenance with GitHub CLI:

```powershell
Get-FileHash .\DiskInventoryZed-Windows-v1.2.0-win-x64.zip -Algorithm SHA256
gh attestation verify .\DiskInventoryZed-Windows-v1.2.0-win-x64.zip --repo neuralnexus/DiskInventoryZed
```

After extracting, `Get-AuthenticodeSignature` should report `Valid` for `DiskInventoryZed.exe`,
`DiskInventoryZed.dll`, and `DiskInventoryZed.Core.dll`. The package manifest uses lowercase SHA-256
followed by two spaces and a relative path so it can also be checked with standard SHA-256 tooling.

## Build From Source

Install the .NET 10.0.302 SDK and Visual Studio 2026 with the **.NET desktop development** workload.
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

The script defaults to `-SignaturePolicy Unsigned` for local builds. CI exercises `Test` signing with an
ephemeral trusted certificate; only the protected release workflow may use `Release`, an allowlisted
production certificate, and an HTTPS RFC 3161 timestamp service.

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
- A scan stops with an explicit error before retaining more than 1,000,000 entries. The previous completed
  snapshot remains visible; choose a smaller root or enable developer-folder exclusions before retrying.

## Diagnostics And Privacy

Disk Inventory Zed sends no telemetry. It keeps a local support journal in
`%LOCALAPPDATA%\DiskInventoryZed\diagnostics.jsonl` and at most one rotated
`diagnostics.previous.jsonl`, each bounded to approximately 512 KiB. Session markers in the same folder
allow the next launch to report an unclean exit without confusing another running instance for a crash.

Entries contain only a UTC timestamp, event code, product version, process architecture, process ID,
exception type, and HRESULT. Scanned paths, filenames, file contents, search text, exception messages,
exports, and settings are never written to this journal or transmitted. Review the JSONL files before
sharing them in a support report. Deleting the files while the app is closed is safe.

## Production Release Setup

Before creating a `v*` tag:

1. Enable immutable releases and create an active tag ruleset with only `refs/tags/v*`, no exclusions or bypass actors, and update/deletion restrictions.
2. Create `release-signing` and `release-publish` environments with required reviewers, self-review and administrator bypass disabled, and exactly one custom `v*` tag deployment policy.
3. Store Apple and Windows signing credentials only in `release-signing`.
4. Store a repository-scoped fine-grained `RELEASE_SETTINGS_TOKEN` with **Administration: read-only** only in `release-publish`.
5. Confirm the Windows publisher subject, certificate thumbprint, and HTTPS timestamp URL environment variables match the production certificate.

Signed artifacts are built before publication approval. After approval, one job verifies immutable-release
configuration, creates and verifies the draft, and publishes it immediately to minimize the mutable-draft
window. Separate GitHub API calls are not transactional, so protected tags and restricted repository write
access remain required.

## Project Layout

- `src/DiskInventoryZed.Core`: platform-neutral models, scanner, analysis, layouts, and export
- `src/DiskInventoryZed.Windows`: WPF shell, custom drawing controls, and Windows integration
- `tests/DiskInventoryZed.Core.Tests`: scanner, model, layout, export, and duplicate tests
- `tests/DiskInventoryZed.Windows.Tests`: ViewModel races, settings, WPF resources, and shell boundaries
- `scripts/package.ps1`: self-contained Windows zip packaging
