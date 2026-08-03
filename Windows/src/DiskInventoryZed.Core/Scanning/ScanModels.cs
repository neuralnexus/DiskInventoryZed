using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Core.Scanning;

public sealed record ScanOptions(
    bool SkipDeveloperFolders = false,
    bool ShowHiddenFiles = false,
    bool FollowReparsePoints = false);

public sealed record ScanProgress(
    string CurrentPath,
    int Files,
    int Directories,
    int UnreadableItems);

public sealed record ScanDiagnostics(
    int UnreadableItems,
    int SkippedDirectories,
    int HiddenItemsExcluded,
    int SymbolicLinks,
    int Packages,
    int DuplicateHardLinks,
    int UnverifiedHardLinks,
    int RevisitedDirectories,
    int ApproximateAllocatedSizes,
    int MetadataUnavailableItems,
    IReadOnlyList<string> FirstUnreadablePaths)
{
    public static readonly ScanDiagnostics Empty = new(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, []);
}

public sealed record DiskScanResult(
    FileNode Root,
    int TotalFiles,
    int TotalDirectories,
    TimeSpan Duration,
    ScanDiagnostics Diagnostics,
    ScanOptions Options);

public sealed class DiskScanException : IOException
{
    public DiskScanException(string message) : base(message)
    {
    }

    public DiskScanException(string message, Exception innerException) : base(message, innerException)
    {
    }
}
