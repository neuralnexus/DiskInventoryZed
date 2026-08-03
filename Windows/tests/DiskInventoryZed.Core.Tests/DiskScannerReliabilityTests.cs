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
            (path, isDirectory, isReparsePoint, logicalSize) =>
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
        var scanner = new DiskScanner((path, isDirectory, isReparsePoint, logicalSize) =>
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
        var scanner = new DiskScanner((path, isDirectory, isReparsePoint, logicalSize) =>
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
        var scanner = new DiskScanner((_, _, _, logicalSize) =>
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
            (path, isDirectory, isReparsePoint, logicalSize) =>
                Metadata(logicalSize, isDirectory ? 0 : logicalSize),
            enumerateEntries: (_, _) => CancelThenYield(cancellation, child));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            scanner.ScanAsync(fixture.Path, new ScanOptions(ShowHiddenFiles: true), cancellationToken: cancellation.Token));
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
