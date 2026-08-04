using DiskInventoryZed.Core.Models;
using DiskInventoryZed.Core.Scanning;

namespace DiskInventoryZed.Core.Tests;

public sealed class DiskScannerReliabilityTests
{
    [Fact]
    public async Task RelativeAndFileRootsAreRejected()
    {
        await Assert.ThrowsAsync<DiskScanException>(() => new DiskScanner().ScanAsync("relative"));

        using var fixture = new TemporaryDirectory();
        var file = Path.Combine(fixture.Path, "file.bin");
        await File.WriteAllBytesAsync(file, [1]);

        var error = await Assert.ThrowsAsync<DiskScanException>(() => new DiskScanner().ScanAsync(file));
        Assert.Contains("not a folder", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task DeveloperDirectoriesAreExcludedAndDiagnosed()
    {
        using var fixture = new TemporaryDirectory();
        var developerDirectory = Directory.CreateDirectory(Path.Combine(fixture.Path, "node_modules"));
        await File.WriteAllBytesAsync(Path.Combine(developerDirectory.FullName, "dependency.bin"), [1, 2, 3]);
        await File.WriteAllBytesAsync(Path.Combine(fixture.Path, "included.bin"), [4]);

        var result = await new DiskScanner().ScanAsync(
            fixture.Path,
            new ScanOptions(SkipDeveloperFolders: true, ShowHiddenFiles: true));

        Assert.DoesNotContain(result.Root.Children, node => node.DisplayName == "node_modules");
        Assert.Contains(result.Root.Children, node => node.DisplayName == "included.bin");
        Assert.Equal(1, result.Diagnostics.SkippedDirectories);
        Assert.True(result.Options.SkipDeveloperFolders);
    }

    [Fact]
    public async Task UnknownFileReparsePointIsNeverResolvedOrCounted()
    {
        using var fixture = new TemporaryDirectory();
        var child = Path.Combine(fixture.Path, "unknown-link.bin");
        await File.WriteAllBytesAsync(child, new byte[4096]);
        var scanner = new DiskScanner(
            (path, isDirectory, isReparsePoint, logicalSize, _) =>
                path == child
                    ? Metadata(0, 0, ReparsePointClassification.Unknown)
                    : Metadata(logicalSize, isDirectory ? 0 : logicalSize),
            path => path == child
                ? FileAttributes.ReparsePoint
                : File.GetAttributes(path));

        var result = await scanner.ScanAsync(fixture.Path, new ScanOptions(ShowHiddenFiles: true));
        var node = Assert.Single(result.Root.Children);

        Assert.Equal(FileNodeKind.SymbolicLink, node.Kind);
        Assert.Equal(0, node.LogicalSize);
        Assert.Equal(0, node.AllocatedSize);
        Assert.NotNull(node.Issue);
        Assert.Equal(1, result.Diagnostics.SymbolicLinks);
        Assert.Equal(1, result.Diagnostics.UnreadableItems);
    }

    [Fact]
    public async Task IdentityUnavailableHardLinksAreNotPresentedAsReliable()
    {
        using var fixture = new TemporaryDirectory();
        var child = Path.Combine(fixture.Path, "linked.bin");
        await File.WriteAllBytesAsync(child, new byte[4096]);
        var scanner = new DiskScanner((path, isDirectory, isReparsePoint, logicalSize, _) =>
            path == child
                ? Metadata(logicalSize, 4096, hardLinkCount: 2)
                : Metadata(logicalSize, isDirectory ? 0 : logicalSize));

        var result = await scanner.ScanAsync(fixture.Path, new ScanOptions(ShowHiddenFiles: true));
        var node = Assert.Single(result.Root.Children);

        Assert.True(node.HasUnverifiedHardLinks);
        Assert.False(node.IsHardLinkDuplicate);
        Assert.Equal(4096, node.AllocatedSize);
        Assert.Equal(1, result.Diagnostics.UnverifiedHardLinks);
    }

    [Fact]
    public async Task MetadataOpenFailureProducesAnExplicitPartialNode()
    {
        using var fixture = new TemporaryDirectory();
        var child = Path.Combine(fixture.Path, "changed.bin");
        await File.WriteAllBytesAsync(child, [1, 2, 3]);
        var scanner = new DiskScanner((path, isDirectory, isReparsePoint, logicalSize, _) =>
            path == child
                ? Metadata(logicalSize, logicalSize, approximate: true, metadataUnavailable: true)
                : Metadata(logicalSize, isDirectory ? 0 : logicalSize));

        var result = await scanner.ScanAsync(fixture.Path, new ScanOptions(ShowHiddenFiles: true));
        var node = Assert.Single(result.Root.Children);

        Assert.False(node.IsUnreadable);
        Assert.Contains("metadata", node.Issue!, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(0, result.Diagnostics.UnreadableItems);
        Assert.Equal(1, result.Diagnostics.ApproximateAllocatedSizes);
        Assert.Equal(1, result.Diagnostics.MetadataUnavailableItems);
    }

    [Fact]
    public async Task EmptyRootWithUnavailableMetadataStillProducesAResult()
    {
        using var fixture = new TemporaryDirectory();
        var scanner = new DiskScanner((_, _, _, logicalSize, _) =>
            Metadata(logicalSize, 0, approximate: true, metadataUnavailable: true));

        var result = await scanner.ScanAsync(fixture.Path, new ScanOptions(ShowHiddenFiles: true));

        Assert.Empty(result.Root.Children);
        Assert.Equal(0, result.Diagnostics.UnreadableItems);
        Assert.Equal(1, result.Diagnostics.MetadataUnavailableItems);
    }

    [Fact]
    public async Task CancellationDuringEnumerationPublishesNoResult()
    {
        using var fixture = new TemporaryDirectory();
        var child = Path.Combine(fixture.Path, "file.bin");
        await File.WriteAllBytesAsync(child, [1]);
        using var cancellation = new CancellationTokenSource();
        var scanner = new DiskScanner(
            (path, isDirectory, isReparsePoint, logicalSize, _) =>
                Metadata(logicalSize, isDirectory ? 0 : logicalSize),
            enumerateEntries: (_, _) => CancelThenYield(cancellation, child));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            scanner.ScanAsync(fixture.Path, new ScanOptions(ShowHiddenFiles: true), cancellationToken: cancellation.Token));
    }

    [Fact]
    public async Task EntryLimitFailsClosedBeforeRetainingAnUnboundedScan()
    {
        using var fixture = new TemporaryDirectory();
        var children = Enumerable.Range(0, 4)
            .Select(index => Path.Combine(fixture.Path, $"file-{index}.bin"))
            .ToArray();
        var scanner = new DiskScanner(
            (_, isDirectory, _, logicalSize, _) => Metadata(logicalSize, isDirectory ? 0 : logicalSize),
            path => children.Contains(path, StringComparer.Ordinal) ? FileAttributes.Normal : FileAttributes.Directory,
            (_, _) => children);

        var error = await Assert.ThrowsAsync<DiskScanLimitExceededException>(() => scanner.ScanAsync(
            fixture.Path,
            new ScanOptions(ShowHiddenFiles: true, MaximumEntries: 3)));

        Assert.Equal(3, error.MaximumEntries);
        Assert.Contains("safety limit", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task EntryLimitIncludesTheRootAndAllowsTheExactBoundary()
    {
        using var fixture = new TemporaryDirectory();
        var children = Enumerable.Range(0, 2)
            .Select(index => Path.Combine(fixture.Path, $"file-{index}.bin"))
            .ToArray();
        var scanner = new DiskScanner(
            (_, isDirectory, _, logicalSize, _) => Metadata(logicalSize, isDirectory ? 0 : logicalSize),
            path => children.Contains(path, StringComparer.Ordinal) ? FileAttributes.Normal : FileAttributes.Directory,
            (_, _) => children);

        var result = await scanner.ScanAsync(
            fixture.Path,
            new ScanOptions(ShowHiddenFiles: true, MaximumEntries: 3));

        Assert.Equal(2, result.TotalFiles);
        Assert.Equal(3, result.Options.MaximumEntries);
    }

    [Fact]
    public async Task EntryLimitSignalsBeforeAnotherWorkerReturnsFromBlockedIo()
    {
        using var fixture = new TemporaryDirectory();
        var blockedDirectory = Directory.CreateDirectory(Path.Combine(fixture.Path, "blocked")).FullName;
        var limitDirectory = Directory.CreateDirectory(Path.Combine(fixture.Path, "limit")).FullName;
        var children = new[]
        {
            Path.Combine(limitDirectory, "first.bin"),
            Path.Combine(limitDirectory, "second.bin")
        };
        using var releaseBlockedWorker = new ManualResetEventSlim();
        using var blockedWorkerStarted = new ManualResetEventSlim();
        var scanner = new DiskScanner(
            (_, isDirectory, _, logicalSize, _) => Metadata(logicalSize, isDirectory ? 0 : logicalSize),
            path => path == fixture.Path || path == blockedDirectory || path == limitDirectory
                ? FileAttributes.Directory
                : FileAttributes.Normal,
            (path, _) => path switch
            {
                var root when root == fixture.Path => [blockedDirectory, limitDirectory],
                var blocked when blocked == blockedDirectory => BlockUntilReleased(),
                var limited when limited == limitDirectory => EnumerateAfterBlockedWorkerStarts(),
                _ => []
            });

        var operation = scanner.StartScan(
            fixture.Path,
            new ScanOptions(ShowHiddenFiles: true, MaximumEntries: 4));
        try
        {
            var error = await operation.FatalError.WaitAsync(TimeSpan.FromSeconds(10));
            await Assert.ThrowsAsync<DiskScanLimitExceededException>(() => operation.Result);

            Assert.IsType<DiskScanLimitExceededException>(error);
            Assert.False(operation.Completion.IsCompleted);
        }
        finally
        {
            releaseBlockedWorker.Set();
        }
        await Assert.ThrowsAsync<DiskScanLimitExceededException>(() => operation.Completion);

        IEnumerable<string> BlockUntilReleased()
        {
            blockedWorkerStarted.Set();
            releaseBlockedWorker.Wait();
            return [];
        }

        IEnumerable<string> EnumerateAfterBlockedWorkerStarts()
        {
            Assert.True(blockedWorkerStarted.Wait(TimeSpan.FromSeconds(10)));
            return children;
        }
    }

    [Fact]
    public async Task StartScanReturnsBeforeBlockingRootIoCompletes()
    {
        using var fixture = new TemporaryDirectory();
        using var releaseRootIo = new ManualResetEventSlim();
        using var rootIoStarted = new ManualResetEventSlim();
        var scanner = new DiskScanner(
            (_, isDirectory, _, logicalSize, _) => Metadata(logicalSize, isDirectory ? 0 : logicalSize),
            _ =>
            {
                rootIoStarted.Set();
                releaseRootIo.Wait();
                return FileAttributes.Directory;
            },
            (_, _) => []);

        var startCall = Task.Run(() => scanner.StartScan(fixture.Path));
        try
        {
            Assert.True(rootIoStarted.Wait(TimeSpan.FromSeconds(2)));
            var operation = await startCall.WaitAsync(TimeSpan.FromSeconds(2));
            Assert.False(operation.Completion.IsCompleted);
        }
        finally
        {
            releaseRootIo.Set();
        }

        var startedOperation = await startCall;
        await startedOperation.Completion.WaitAsync(TimeSpan.FromSeconds(2));
    }

    private static IEnumerable<string> CancelThenYield(CancellationTokenSource cancellation, string path)
    {
        cancellation.Cancel();
        yield return path;
    }

    private static FileMetadata Metadata(
        long logicalSize,
        long allocatedSize,
        ReparsePointClassification classification = ReparsePointClassification.NotReparsePoint,
        uint hardLinkCount = 1,
        bool approximate = false,
        bool metadataUnavailable = false) =>
        new(
            logicalSize,
            allocatedSize,
            null,
            hardLinkCount,
            approximate,
            null,
            null,
            classification,
            metadataUnavailable);
}
