using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.ExceptionServices;
using System.Threading.Channels;
using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Core.Scanning;

internal delegate FileMetadata FileMetadataReader(
    string path,
    bool isDirectory,
    bool isReparsePoint,
    long logicalSize,
    bool followReparsePoints);

/// <summary>A fixed-worker, cancellable scanner that publishes only a completed immutable tree.</summary>
public sealed class DiskScanner
{
    private static readonly HashSet<string> DeveloperFolderNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "node_modules", ".git", ".svn", ".hg", ".vs", "DerivedData", ".build", "bin", "obj"
    };
    private readonly FileMetadataReader _readMetadata;
    private readonly Func<string, FileAttributes> _getAttributes;
    private readonly Func<string, EnumerationOptions, IEnumerable<string>> _enumerateEntries;

    public DiskScanner() : this(
        WindowsFileMetadata.Read,
        File.GetAttributes,
        (path, options) => Directory.EnumerateFileSystemEntries(path, "*", options))
    {
    }

    internal DiskScanner(
        FileMetadataReader readMetadata,
        Func<string, FileAttributes>? getAttributes = null,
        Func<string, EnumerationOptions, IEnumerable<string>>? enumerateEntries = null)
    {
        _readMetadata = readMetadata;
        _getAttributes = getAttributes ?? File.GetAttributes;
        _enumerateEntries = enumerateEntries ??
            ((path, options) => Directory.EnumerateFileSystemEntries(path, "*", options));
    }

    public async Task<DiskScanResult> ScanAsync(
        string path,
        ScanOptions? options = null,
        IProgress<ScanProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var operation = StartScan(path, options, progress, cancellationToken);
        _ = operation.Result.ContinueWith(
            static result => _ = result.Exception,
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
        return await operation.Completion.ConfigureAwait(false);
    }

    public DiskScanOperation StartScan(
        string path,
        ScanOptions? options = null,
        IProgress<ScanProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var fatalError = new TaskCompletionSource<Exception>(TaskCreationOptions.RunContinuationsAsynchronously);
        var completion = Task.Run(
            () => ScanCoreAsync(path, options, progress, cancellationToken, fatalError),
            CancellationToken.None);
        var result = AwaitResultAsync(completion, fatalError.Task, cancellationToken);
        return new DiskScanOperation(result, completion, fatalError.Task);
    }

    private static async Task<DiskScanResult> AwaitResultAsync(
        Task<DiskScanResult> completion,
        Task<Exception> fatalError,
        CancellationToken cancellationToken)
    {
        var completed = await Task.WhenAny(completion, fatalError).WaitAsync(cancellationToken);
        if (ReferenceEquals(completed, fatalError))
        {
            throw await fatalError;
        }
        return await completion.WaitAsync(cancellationToken);
    }

    private async Task<DiskScanResult> ScanCoreAsync(
        string path,
        ScanOptions? options,
        IProgress<ScanProgress>? progress,
        CancellationToken cancellationToken,
        TaskCompletionSource<Exception> fatalErrorSignal)
    {
        options ??= new ScanOptions();
        if (options.MaximumEntries <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(options), "The scan entry limit must be greater than zero.");
        }
        if (!Path.IsPathFullyQualified(path))
        {
            throw new DiskScanException("Enter a fully qualified drive or UNC path.");
        }

        var rootPath = NormalizePath(path);
        cancellationToken.ThrowIfCancellationRequested();
        FileAttributes rootAttributes;
        try
        {
            rootAttributes = _getAttributes(rootPath);
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
            throw new DiskScanException($"Access to {rootPath} was denied. Check the current user's permissions and try again.", error);
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
        var rootMetadata = _readMetadata(
            rootPath,
            true,
            rootAttributes.HasFlag(FileAttributes.ReparsePoint),
            0,
            options.FollowReparsePoints);
        if (rootMetadata.ReparsePointClassification == ReparsePointClassification.Unknown)
        {
            throw new DiskScanException("The selected root is an unrecognized reparse point and cannot be scanned safely.");
        }

        var rootIsLink = rootMetadata.ReparsePointClassification == ReparsePointClassification.NameSurrogate;
        if (rootIsLink && !options.FollowReparsePoints)
        {
            throw new DiskScanException("The selected root is a link or junction. Enable Follow links and junctions only if you intend to scan its target.");
        }

        if (rootIsLink && rootMetadata.Identity is null)
        {
            throw new DiskScanException("The selected link target has no stable filesystem identity and cannot be followed safely.");
        }

        var state = new ScanState(
            rootPath,
            options,
            progress,
            _readMetadata,
            _getAttributes,
            _enumerateEntries);
        var rootRecord = state.CreateRootRecord(rootIsLink, rootMetadata);
        if (rootMetadata.MetadataUnavailable)
        {
            rootRecord.Issue = "Filesystem metadata for the selected root could not be read; the scan may be incomplete.";
            state.Diagnostics.IncrementMetadataUnavailableItems();
        }

        state.Records[rootPath] = rootRecord;
        if (rootMetadata.Identity is { } rootIdentity)
        {
            state.VisitedDirectories.TryAdd(rootIdentity, rootPath);
        }

        using var scanCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var scanToken = scanCancellation.Token;
        var channel = Channel.CreateUnbounded<WorkItem>(new UnboundedChannelOptions
        {
            AllowSynchronousContinuations = false,
            SingleReader = false,
            SingleWriter = false
        });
        var outstanding = 1;
        await channel.Writer.WriteAsync(new WorkItem(rootPath, rootRecord), scanToken);

        var workerCount = IsNetworkRoot(rootPath) ? 2 : Math.Clamp(Environment.ProcessorCount, 2, 8);
        Exception? fatalError = null;
        var workers = Enumerable.Range(0, workerCount).Select(_ => Task.Run(async () =>
        {
            try
            {
                await foreach (var work in channel.Reader.ReadAllAsync(scanToken))
                {
                    try
                    {
                        await ProcessDirectoryAsync(
                            work,
                            state,
                            channel.Writer,
                            () => Interlocked.Increment(ref outstanding),
                            () => Interlocked.Decrement(ref outstanding),
                            scanToken);
                    }
                    finally
                    {
                        if (Interlocked.Decrement(ref outstanding) == 0)
                        {
                            channel.Writer.TryComplete();
                        }
                    }
                }
            }
            catch (Exception error)
            {
                if (error is not OperationCanceledException)
                {
                    if (Interlocked.CompareExchange(ref fatalError, error, null) is null)
                    {
                        fatalErrorSignal.TrySetResult(error);
                    }
                }
                scanCancellation.Cancel();
                channel.Writer.TryComplete(error);
                throw;
            }
        }, CancellationToken.None)).ToArray();

        using var reporterCancellation = CancellationTokenSource.CreateLinkedTokenSource(scanToken);
        var reporter = ReportProgressAsync(state, reporterCancellation.Token);
        try
        {
            try
            {
                await Task.WhenAll(workers);
            }
            catch
            {
                if (Volatile.Read(ref fatalError) is { } fatal)
                {
                    ExceptionDispatchInfo.Capture(fatal).Throw();
                }
                cancellationToken.ThrowIfCancellationRequested();
                throw;
            }
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
        DeduplicateHardLinks(state, cancellationToken);
        var root = BuildTree(rootPath, state.Records, state.PathComparer, cancellationToken)
            ?? throw new DiskScanException("The scan did not produce a root folder.");
        if (rootRecord.EnumerationFailed && root.Children.Count == 0)
        {
            throw new DiskScanException($"Disk Inventory Zed could not read {rootPath}. Check the current user's permissions.");
        }

        stopwatch.Stop();
        var diagnostics = state.Diagnostics.Snapshot();
        progress?.Report(new ScanProgress(rootPath, state.FileCount, state.DirectoryCount, diagnostics.UnreadableItems));
        return new DiskScanResult(root, state.FileCount, state.DirectoryCount, stopwatch.Elapsed, diagnostics, options);
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
            cancellationToken.ThrowIfCancellationRequested();
            using var directoryGuard = OperatingSystem.IsWindows()
                ? WindowsFileMetadata.OpenDirectoryGuard(
                    work.Path,
                    state.Options.FollowReparsePoints,
                    work.Record.Identity)
                : null;
            var enumerationOptions = new EnumerationOptions
            {
                AttributesToSkip = 0,
                IgnoreInaccessible = false,
                RecurseSubdirectories = false,
                ReturnSpecialDirectories = false
            };

            cancellationToken.ThrowIfCancellationRequested();
            using var enumerator = state.EnumerateEntries(work.Path, enumerationOptions).GetEnumerator();
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!enumerator.MoveNext())
                {
                    break;
                }
                cancellationToken.ThrowIfCancellationRequested();
                var childPath = enumerator.Current;
                Volatile.Write(ref state.CurrentPath, childPath);

                FileAttributes attributes;
                try
                {
                    attributes = state.GetAttributes(childPath);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
                {
                    state.ReserveRecord();
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
                    state.Diagnostics.IncrementHiddenItemsExcluded();
                    continue;
                }

                if (state.Options.SkipDeveloperFolders && isDirectory && DeveloperFolderNames.Contains(name))
                {
                    state.Diagnostics.IncrementSkippedDirectories();
                    continue;
                }

                state.ReserveRecord();
                var apparentLogicalSize = isDirectory || isReparsePoint || OperatingSystem.IsWindows()
                    ? 0
                    : TryGetLogicalSize(childPath);
                var metadata = state.ReadMetadata(
                    childPath,
                    isDirectory,
                    isReparsePoint,
                    apparentLogicalSize,
                    state.Options.FollowReparsePoints);
                var isLink = metadata.ReparsePointClassification == ReparsePointClassification.NameSurrogate;
                var isUnknownReparse =
                    metadata.ReparsePointClassification == ReparsePointClassification.Unknown;
                var shouldTraverse = isDirectory && !isUnknownReparse &&
                    (!isLink || state.Options.FollowReparsePoints);
                var logicalSize = isLink || isUnknownReparse ? 0 : metadata.LogicalSize;
                if (metadata.AllocatedSizeIsApproximate && !isDirectory && !isLink && !isUnknownReparse)
                {
                    state.Diagnostics.IncrementApproximateAllocatedSizes();
                }

                var record = new ScanRecord(
                    childPath,
                    name,
                    (isLink && !shouldTraverse) || isUnknownReparse
                        ? FileNodeKind.SymbolicLink
                        : isDirectory ? FileNodeKind.Directory : FileNodeKind.File,
                    logicalSize,
                    isDirectory || isLink || isUnknownReparse ? 0 : metadata.AllocatedSize,
                    metadata.CreationDate ?? (isLink || isUnknownReparse ? null : TryGetCreationTime(childPath)),
                    metadata.ModificationDate ?? (isLink || isUnknownReparse ? null : TryGetModificationTime(childPath)),
                    isLink || isUnknownReparse,
                    metadata.Identity,
                    metadata.HardLinkCount);

                if (metadata.MetadataUnavailable && !isLink && !isUnknownReparse)
                {
                    record.Issue = "Filesystem metadata changed or could not be read; size and identity may be estimates.";
                    state.Diagnostics.IncrementMetadataUnavailableItems();
                }

                if (!isDirectory && !isLink && metadata.HardLinkCount > 1 && metadata.Identity is null)
                {
                    record.HasUnverifiedHardLinks = true;
                    record.Issue = "This file has multiple hard links, but its stable identity was unavailable; allocated storage may be counted more than once.";
                    state.Diagnostics.IncrementUnverifiedHardLinks();
                }

                if (isLink || isUnknownReparse)
                {
                    state.Diagnostics.IncrementSymbolicLinks();
                }

                if (isUnknownReparse)
                {
                    record.Issue = "The reparse-point type could not be identified, so this item was not resolved or followed.";
                    record.IsUnreadable = true;
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
                        record.IsUnreadable = true;
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
        catch (Exception error) when (
            error is not DiskScanException &&
            error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            work.Record.Issue = error.Message;
            work.Record.EnumerationFailed = true;
            work.Record.IsUnreadable = true;
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

    private static void DeduplicateHardLinks(ScanState state, CancellationToken cancellationToken)
    {
        var duplicateCount = 0;
        var groups = state.Records.Values
            .Where(record => record.Kind == FileNodeKind.File && record.Identity is not null)
            .GroupBy(record => record.Identity!.Value);

        foreach (var group in groups)
        {
            cancellationToken.ThrowIfCancellationRequested();
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
        StringComparer pathComparer,
        CancellationToken cancellationToken)
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
            cancellationToken.ThrowIfCancellationRequested();
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
                record.HasUnverifiedHardLinks,
                record.Issue,
                isContainer ? children.Sum(child => child.TotalFileCount) : 1,
                isContainer ? 1 + children.Sum(child => child.TotalDirectoryCount) : 0,
                record.IsUnreadable);
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
        public ScanState(
            string rootPath,
            ScanOptions options,
            IProgress<ScanProgress>? progress,
            FileMetadataReader readMetadata,
            Func<string, FileAttributes> getAttributes,
            Func<string, EnumerationOptions, IEnumerable<string>> enumerateEntries)
        {
            RootPath = rootPath;
            Options = options;
            Progress = progress;
            CurrentPath = rootPath;
            PathComparer = StringComparer.Ordinal;
            Records = new ConcurrentDictionary<string, ScanRecord>(PathComparer);
            ReadMetadata = readMetadata;
            GetAttributes = getAttributes;
            EnumerateEntries = enumerateEntries;
        }

        public string RootPath { get; }
        public ScanOptions Options { get; }
        public IProgress<ScanProgress>? Progress { get; }
        public StringComparer PathComparer { get; }
        public ConcurrentDictionary<string, ScanRecord> Records { get; }
        public ConcurrentDictionary<FileIdentity, string> VisitedDirectories { get; } = new();
        public MutableDiagnostics Diagnostics { get; } = new();
        public FileMetadataReader ReadMetadata { get; }
        public Func<string, FileAttributes> GetAttributes { get; }
        public Func<string, EnumerationOptions, IEnumerable<string>> EnumerateEntries { get; }
        public string CurrentPath;
        public int FileCount;
        public int DirectoryCount;
        private int _retainedEntries = 1;

        public void ReserveRecord()
        {
            if (Interlocked.Increment(ref _retainedEntries) > Options.MaximumEntries)
            {
                throw new DiskScanLimitExceededException(Options.MaximumEntries);
            }
        }

        public ScanRecord CreateRootRecord(bool isSymbolicLink, FileMetadata metadata)
        {
            var name = new DirectoryInfo(RootPath).Name;
            return new ScanRecord(
                RootPath,
                string.IsNullOrEmpty(name) ? RootPath : name,
                FileNodeKind.Directory,
                0,
                0,
                metadata.CreationDate ?? TryGetCreationTime(RootPath),
                metadata.ModificationDate ?? TryGetModificationTime(RootPath),
                isSymbolicLink,
                metadata.Identity,
                metadata.HardLinkCount);
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
        public bool HasUnverifiedHardLinks { get; set; }
        public bool EnumerationFailed { get; set; }
        public bool IsUnreadable { get; set; }
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
            Issue = issue,
            IsUnreadable = true
        };
    }

    private sealed class MutableDiagnostics
    {
        private readonly ConcurrentQueue<string> _firstUnreadablePaths = new();
        private int _unreadableItems;
        private int _skippedDirectories;
        private int _hiddenItemsExcluded;
        private int _symbolicLinks;
        private int _duplicateHardLinks;
        private int _unverifiedHardLinks;
        private int _revisitedDirectories;
        private int _approximateAllocatedSizes;
        private int _metadataUnavailableItems;
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
        public void IncrementHiddenItemsExcluded() => Interlocked.Increment(ref _hiddenItemsExcluded);
        public void IncrementSymbolicLinks() => Interlocked.Increment(ref _symbolicLinks);
        public void IncrementUnverifiedHardLinks() => Interlocked.Increment(ref _unverifiedHardLinks);
        public void IncrementRevisitedDirectories() => Interlocked.Increment(ref _revisitedDirectories);
        public void IncrementApproximateAllocatedSizes() => Interlocked.Increment(ref _approximateAllocatedSizes);
        public void IncrementMetadataUnavailableItems() => Interlocked.Increment(ref _metadataUnavailableItems);
        public void SetDuplicateHardLinks(int count) => Volatile.Write(ref _duplicateHardLinks, count);

        public ScanDiagnostics Snapshot() => new(
            Volatile.Read(ref _unreadableItems),
            Volatile.Read(ref _skippedDirectories),
            Volatile.Read(ref _hiddenItemsExcluded),
            Volatile.Read(ref _symbolicLinks),
            0,
            Volatile.Read(ref _duplicateHardLinks),
            Volatile.Read(ref _unverifiedHardLinks),
            Volatile.Read(ref _revisitedDirectories),
            Volatile.Read(ref _approximateAllocatedSizes),
            Volatile.Read(ref _metadataUnavailableItems),
            _firstUnreadablePaths.ToArray());
    }
}
