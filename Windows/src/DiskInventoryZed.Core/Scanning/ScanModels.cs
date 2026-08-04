using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Core.Scanning;

public sealed record ScanOptions(
    bool SkipDeveloperFolders = false,
    bool ShowHiddenFiles = false,
    bool FollowReparsePoints = false,
    int MaximumEntries = 1_000_000);

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

/// <summary>
/// Result reacts immediately to cancellation or a fatal worker error. Completion remains pending until
/// every in-flight filesystem call returns and must be observed to bound abandoned workers.
/// </summary>
public sealed record DiskScanOperation(
    Task<DiskScanResult> Result,
    Task<DiskScanResult> Completion,
    Task<Exception> FatalError);

public class DiskScanException : IOException
{
    public DiskScanException(string message) : base(message)
    {
    }

    public DiskScanException(string message, Exception innerException) : base(message, innerException)
    {
    }
}

public sealed class DiskScanLimitExceededException : DiskScanException
{
    public DiskScanLimitExceededException(int maximumEntries)
        : base($"The scan reached the safety limit of {maximumEntries:N0} retained entries. Scan a smaller folder or exclude developer output to avoid exhausting system memory.")
    {
        MaximumEntries = maximumEntries;
    }

    public int MaximumEntries { get; }
}
