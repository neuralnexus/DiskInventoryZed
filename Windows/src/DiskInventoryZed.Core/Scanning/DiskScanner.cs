using System.Collections.Concurrent;
using System.Diagnostics;
using System.Threading.Channels;
using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Core.Scanning;

/// <summary>A fixed-worker, cancellable scanner that publishes only a completed immutable tree.</summary>
public sealed class DiskScanner
{
    private static readonly HashSet<string> DeveloperFolderNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "node_modules", ".git", ".svn", ".hg", ".vs", "DerivedData", ".build", "bin", "obj"
    };

    public async Task<DiskScanResult> ScanAsync(
        string path,
        ScanOptions? options = null,
        IProgress<ScanProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        options ??= new ScanOptions();
        var rootPath = NormalizePath(path);
        FileAttributes rootAttributes;
        try
        {
            rootAttributes = File.GetAttributes(rootPath);
            if (!rootAttributes.HasFlag(FileAttributes.Directory))
            {
                throw new DiskScanException("The selected location is not a folder.");
            }
        }
        catch (DiskScanException)
        {
            throw;
        }
        catch (UnauthorizedAccessException error)
        {
            throw new DiskScanException($"Access to {rootPath} was denied. Try a different folder or run as an administrator.", error);
        }
        catch (Exception error) when (error is IOException or System.Security.SecurityException)
        {
            var networkHint = IsNetworkRoot(rootPath)
                ? " Check that the server is online and that Windows can open the share."
                : string.Empty;
            throw new DiskScanException($"The selected location could not be opened.{networkHint}", error);
        }

        cancellationToken.ThrowIfCancellationRequested();
        var stopwatch = Stopwatch.StartNew();
        var rootMetadata = WindowsFileMetadata.Read(
            rootPath,
            true,
            rootAttributes.HasFlag(FileAttributes.ReparsePoint),
            0);
        var rootIsLink = rootMetadata.ReparsePointClassification is
            ReparsePointClassification.NameSurrogate or ReparsePointClassification.Unknown;
        var state = new ScanState(rootPath, options, progress);
        var rootRecord = state.CreateRootRecord(rootIsLink);
        if (rootMetadata.ReparsePointClassification == ReparsePointClassification.Unknown)
        {
            rootRecord.Issue = "The root reparse-point type could not be identified.";
            state.Diagnostics.RecordUnreadable(rootPath);
        }

        state.Records[rootPath] = rootRecord;
        if (rootMetadata.Identity is { } rootIdentity)
        {
            state.VisitedDirectories.TryAdd(rootIdentity, rootPath);
        }

        var channel = Channel.CreateUnbounded<WorkItem>(new UnboundedChannelOptions
        {
            AllowSynchronousContinuations = false,
            SingleReader = false,
            SingleWriter = false
        });
        var outstanding = 1;
        await channel.Writer.WriteAsync(new WorkItem(rootPath, rootRecord), cancellationToken);

        var workerCount = IsNetworkRoot(rootPath) ? 2 : Math.Clamp(Environment.ProcessorCount, 2, 8);
        var workers = Enumerable.Range(0, workerCount).Select(_ => Task.Run(async () =>
        {
            await foreach (var work in channel.Reader.ReadAllAsync(cancellationToken))
            {
                try
                {
                    await ProcessDirectoryAsync(
                        work,
                        state,
                        channel.Writer,
                        () => Interlocked.Increment(ref outstanding),
                        () => Interlocked.Decrement(ref outstanding),
                        cancellationToken);
                }
                finally
                {
                    if (Interlocked.Decrement(ref outstanding) == 0)
                    {
                        channel.Writer.TryComplete();
                    }
                }
            }
        }, cancellationToken)).ToArray();

        using var reporterCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var reporter = ReportProgressAsync(state, reporterCancellation.Token);
        try
        {
            await Task.WhenAll(workers);
        }
        finally
        {
            reporterCancellation.Cancel();
            try
            {
                await reporter;
            }
            catch (OperationCanceledException)
            {
                // The progress loop always ends through cancellation.
            }
        }

        cancellationToken.ThrowIfCancellationRequested();
        DeduplicateHardLinks(state);
        var root = BuildTree(rootPath, state.Records, state.PathComparer)
            ?? throw new DiskScanException("The scan did not produce a root folder.");
        if (root.IsUnreadable && root.Children.Count == 0)
        {
            throw new DiskScanException($"Disk Inventory Zed could not read {rootPath}. Try running it as an administrator.");
        }

        stopwatch.Stop();
        var diagnostics = state.Diagnostics.Snapshot();
        progress?.Report(new ScanProgress(rootPath, state.FileCount, state.DirectoryCount, diagnostics.UnreadableItems));
        return new DiskScanResult(root, state.FileCount, state.DirectoryCount, stopwatch.Elapsed, diagnostics);
    }

    private static async Task ProcessDirectoryAsync(
        WorkItem work,
        ScanState state,
        ChannelWriter<WorkItem> writer,
        Action reserveWork,
        Action releaseWork,
        CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref state.DirectoryCount);
        Volatile.Write(ref state.CurrentPath, work.Path);
        var childPaths = new List<string>();

        try
        {
            var enumerationOptions = new EnumerationOptions
            {
                AttributesToSkip = 0,
                IgnoreInaccessible = false,
                RecurseSubdirectories = false,
                ReturnSpecialDirectories = false
            };

            foreach (var childPath in Directory.EnumerateFileSystemEntries(work.Path, "*", enumerationOptions))
            {
                cancellationToken.ThrowIfCancellationRequested();
                Volatile.Write(ref state.CurrentPath, childPath);

                FileAttributes attributes;
                try
                {
                    attributes = File.GetAttributes(childPath);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
                {
                    var inaccessible = ScanRecord.Inaccessible(childPath, error.Message);
                    state.Records[childPath] = inaccessible;
                    childPaths.Add(childPath);
                    Interlocked.Increment(ref state.FileCount);
                    state.Diagnostics.RecordUnreadable(childPath);
                    continue;
                }

                var isDirectory = attributes.HasFlag(FileAttributes.Directory);
                var isReparsePoint = attributes.HasFlag(FileAttributes.ReparsePoint);
                var isHidden = attributes.HasFlag(FileAttributes.Hidden);
                var name = Path.GetFileName(childPath);
                if (!state.Options.ShowHiddenFiles && isHidden)
                {
                    continue;
                }

                if (state.Options.SkipDeveloperFolders && isDirectory && DeveloperFolderNames.Contains(name))
                {
                    state.Diagnostics.IncrementSkippedDirectories();
                    continue;
                }

                var apparentLogicalSize = isDirectory ? 0 : TryGetLogicalSize(childPath);
                var metadata = WindowsFileMetadata.Read(childPath, isDirectory, isReparsePoint, apparentLogicalSize);
                var isLink = metadata.ReparsePointClassification == ReparsePointClassification.NameSurrogate;
                var isUnknownDirectoryReparse = isDirectory &&
                    metadata.ReparsePointClassification == ReparsePointClassification.Unknown;
                var shouldTraverse = isDirectory && !isUnknownDirectoryReparse &&
                    (!isLink || state.Options.FollowReparsePoints);
                var logicalSize = isLink ? 0 : apparentLogicalSize;
                if (metadata.AllocatedSizeIsApproximate && !isDirectory && !isLink)
                {
                    state.Diagnostics.IncrementApproximateAllocatedSizes();
                }

                var record = new ScanRecord(
                    childPath,
                    name,
                    (isLink && !shouldTraverse) || isUnknownDirectoryReparse
                        ? FileNodeKind.SymbolicLink
                        : isDirectory ? FileNodeKind.Directory : FileNodeKind.File,
                    logicalSize,
                    isDirectory || isLink ? 0 : metadata.AllocatedSize,
                    TryGetCreationTime(childPath),
                    TryGetModificationTime(childPath),
                    isLink || isUnknownDirectoryReparse,
                    metadata.Identity,
                    metadata.HardLinkCount);

                if (isLink)
                {
                    state.Diagnostics.IncrementSymbolicLinks();
                }

                if (isUnknownDirectoryReparse)
                {
                    record.Issue = "The reparse-point type could not be identified, so this directory was not followed.";
                    state.Diagnostics.RecordUnreadable(childPath);
                }

                state.Records[childPath] = record;
                childPaths.Add(childPath);

                if (!shouldTraverse)
                {
                    Interlocked.Increment(ref state.FileCount);
                    continue;
                }

                if (metadata.Identity is not { } identity)
                {
                    if (isLink)
                    {
                        record.Kind = FileNodeKind.SymbolicLink;
                        record.Issue = "The reparse-point target identity could not be read, so it was not followed.";
                        Interlocked.Increment(ref state.FileCount);
                        state.Diagnostics.RecordUnreadable(childPath);
                        continue;
                    }
                }
                else if (!state.VisitedDirectories.TryAdd(identity, childPath))
                {
                    record.Kind = FileNodeKind.SymbolicLink;
                    record.Issue = "This directory target was already scanned and was not followed again.";
                    Interlocked.Increment(ref state.FileCount);
                    state.Diagnostics.IncrementRevisitedDirectories();
                    continue;
                }

                reserveWork();
                try
                {
                    await writer.WriteAsync(new WorkItem(childPath, record), cancellationToken);
                }
                catch
                {
                    releaseWork();
                    throw;
                }
            }
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            work.Record.Issue = error.Message;
            state.Diagnostics.RecordUnreadable(work.Path);
        }
        finally
        {
            work.Record.ChildPaths = childPaths;
        }
    }

    private static async Task ReportProgressAsync(ScanState state, CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(125));
        while (await timer.WaitForNextTickAsync(cancellationToken))
        {
            state.Progress?.Report(new ScanProgress(
                Volatile.Read(ref state.CurrentPath),
                Volatile.Read(ref state.FileCount),
                Volatile.Read(ref state.DirectoryCount),
                state.Diagnostics.UnreadableItems));
        }
    }

    private static void DeduplicateHardLinks(ScanState state)
    {
        var duplicateCount = 0;
        var groups = state.Records.Values
            .Where(record => record.Kind == FileNodeKind.File && record.Identity is not null)
            .GroupBy(record => record.Identity!.Value);

        foreach (var group in groups)
        {
            var records = group.OrderBy(record => record.Path, state.PathComparer).ToArray();
            for (var index = 1; index < records.Length; index++)
            {
                records[index].AllocatedSize = 0;
                records[index].IsHardLinkDuplicate = true;
                duplicateCount++;
            }
        }

        state.Diagnostics.SetDuplicateHardLinks(duplicateCount);
    }

    private static FileNode? BuildTree(
        string rootPath,
        ConcurrentDictionary<string, ScanRecord> records,
        StringComparer pathComparer)
    {
        if (!records.ContainsKey(rootPath))
        {
            return null;
        }

        var stack = new Stack<(string Path, bool ChildrenVisited)>();
        var built = new Dictionary<string, FileNode>(pathComparer);
        stack.Push((rootPath, false));

        while (stack.TryPop(out var item))
        {
            if (!records.TryGetValue(item.Path, out var record))
            {
                continue;
            }

            if (!item.ChildrenVisited)
            {
                stack.Push((item.Path, true));
                for (var index = record.ChildPaths.Count - 1; index >= 0; index--)
                {
                    var childPath = record.ChildPaths[index];
                    if (!built.ContainsKey(childPath))
                    {
                        stack.Push((childPath, false));
                    }
                }

                continue;
            }

            var children = record.ChildPaths
                .Select(path => built.GetValueOrDefault(path))
                .OfType<FileNode>()
                .OrderByDescending(child => child.AllocatedSize)
                .ThenBy(child => child.DisplayName, StringComparer.CurrentCultureIgnoreCase)
                .ToArray();
            var isContainer = record.Kind is FileNodeKind.Directory or FileNodeKind.Package;
            var logicalSize = isContainer ? children.Sum(child => child.LogicalSize) : record.LogicalSize;
            var allocatedSize = isContainer ? children.Sum(child => child.AllocatedSize) : record.AllocatedSize;

            built[record.Path] = new FileNode(
                record.Path,
                record.Name,
                record.Kind,
                logicalSize,
                allocatedSize,
                children,
                record.CreationDate,
                record.ModificationDate,
                record.IsSymbolicLink,
                record.IsHardLinkDuplicate,
                record.Issue,
                isContainer ? children.Sum(child => child.TotalFileCount) : 1,
                isContainer ? 1 + children.Sum(child => child.TotalDirectoryCount) : 0);
        }

        return built.GetValueOrDefault(rootPath);
    }

    private static long TryGetLogicalSize(string path)
    {
        try
        {
            return new FileInfo(path).Length;
        }
        catch
        {
            return 0;
        }
    }

    private static DateTimeOffset? TryGetCreationTime(string path)
    {
        try
        {
            return new DateTimeOffset(File.GetCreationTimeUtc(path), TimeSpan.Zero);
        }
        catch
        {
            return null;
        }
    }

    private static DateTimeOffset? TryGetModificationTime(string path)
    {
        try
        {
            return new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero);
        }
        catch
        {
            return null;
        }
    }

    private static string NormalizePath(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var root = Path.GetPathRoot(fullPath);
        return string.Equals(fullPath, root, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)
            ? fullPath
            : fullPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }

    private static bool IsNetworkRoot(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }

        if (path.StartsWith("\\\\", StringComparison.Ordinal))
        {
            return true;
        }

        try
        {
            var root = Path.GetPathRoot(path);
            return !string.IsNullOrWhiteSpace(root) && new DriveInfo(root).DriveType == DriveType.Network;
        }
        catch
        {
            return false;
        }
    }

    private sealed record WorkItem(string Path, ScanRecord Record);

    private sealed class ScanState
    {
        public ScanState(string rootPath, ScanOptions options, IProgress<ScanProgress>? progress)
        {
            RootPath = rootPath;
            Options = options;
            Progress = progress;
            CurrentPath = rootPath;
            PathComparer = StringComparer.Ordinal;
            Records = new ConcurrentDictionary<string, ScanRecord>(PathComparer);
        }

        public string RootPath { get; }
        public ScanOptions Options { get; }
        public IProgress<ScanProgress>? Progress { get; }
        public StringComparer PathComparer { get; }
        public ConcurrentDictionary<string, ScanRecord> Records { get; }
        public ConcurrentDictionary<FileIdentity, string> VisitedDirectories { get; } = new();
        public MutableDiagnostics Diagnostics { get; } = new();
        public string CurrentPath;
        public int FileCount;
        public int DirectoryCount;

        public ScanRecord CreateRootRecord(bool isSymbolicLink)
        {
            var name = new DirectoryInfo(RootPath).Name;
            return new ScanRecord(
                RootPath,
                string.IsNullOrEmpty(name) ? RootPath : name,
                FileNodeKind.Directory,
                0,
                0,
                TryGetCreationTime(RootPath),
                TryGetModificationTime(RootPath),
                isSymbolicLink,
                null,
                1);
        }
    }

    private sealed class ScanRecord(
        string path,
        string name,
        FileNodeKind kind,
        long logicalSize,
        long allocatedSize,
        DateTimeOffset? creationDate,
        DateTimeOffset? modificationDate,
        bool isSymbolicLink,
        FileIdentity? identity,
        uint hardLinkCount)
    {
        public string Path { get; } = path;
        public string Name { get; } = name;
        public FileNodeKind Kind { get; set; } = kind;
        public long LogicalSize { get; } = logicalSize;
        public long AllocatedSize { get; set; } = allocatedSize;
        public DateTimeOffset? CreationDate { get; } = creationDate;
        public DateTimeOffset? ModificationDate { get; } = modificationDate;
        public bool IsSymbolicLink { get; } = isSymbolicLink;
        public FileIdentity? Identity { get; } = identity;
        public uint HardLinkCount { get; } = hardLinkCount;
        public bool IsHardLinkDuplicate { get; set; }
        public string? Issue { get; set; }
        public IReadOnlyList<string> ChildPaths { get; set; } = [];

        public static ScanRecord Inaccessible(string path, string issue) => new(
            path,
            System.IO.Path.GetFileName(path),
            FileNodeKind.File,
            0,
            0,
            null,
            null,
            false,
            null,
            1)
        {
            Issue = issue
        };
    }

    private sealed class MutableDiagnostics
    {
        private readonly ConcurrentQueue<string> _firstUnreadablePaths = new();
        private int _unreadableItems;
        private int _skippedDirectories;
        private int _symbolicLinks;
        private int _duplicateHardLinks;
        private int _revisitedDirectories;
        private int _approximateAllocatedSizes;
        private int _storedUnreadablePaths;

        public int UnreadableItems => Volatile.Read(ref _unreadableItems);

        public void RecordUnreadable(string path)
        {
            Interlocked.Increment(ref _unreadableItems);
            if (Interlocked.Increment(ref _storedUnreadablePaths) <= 20)
            {
                _firstUnreadablePaths.Enqueue(path);
            }
        }

        public void IncrementSkippedDirectories() => Interlocked.Increment(ref _skippedDirectories);
        public void IncrementSymbolicLinks() => Interlocked.Increment(ref _symbolicLinks);
        public void IncrementRevisitedDirectories() => Interlocked.Increment(ref _revisitedDirectories);
        public void IncrementApproximateAllocatedSizes() => Interlocked.Increment(ref _approximateAllocatedSizes);
        public void SetDuplicateHardLinks(int count) => Volatile.Write(ref _duplicateHardLinks, count);

        public ScanDiagnostics Snapshot() => new(
            Volatile.Read(ref _unreadableItems),
            Volatile.Read(ref _skippedDirectories),
            Volatile.Read(ref _symbolicLinks),
            0,
            Volatile.Read(ref _duplicateHardLinks),
            Volatile.Read(ref _revisitedDirectories),
            Volatile.Read(ref _approximateAllocatedSizes),
            _firstUnreadablePaths.ToArray());
    }
}
