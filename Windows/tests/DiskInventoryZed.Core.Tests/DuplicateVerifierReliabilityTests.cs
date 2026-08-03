using DiskInventoryZed.Core.Analysis;
using DiskInventoryZed.Core.Models;
using DiskInventoryZed.Core.Scanning;

namespace DiskInventoryZed.Core.Tests;

public sealed class DuplicateVerifierReliabilityTests
{
    [Fact]
    public void ExtendedAttributesBitIsNotMistakenForRecallOnOpen()
    {
        const uint fileAttributeEa = 0x00040000;

        Assert.True(WindowsFileMetadata.IsLocallyAvailableRegularFile(fileAttributeEa, 0));
        Assert.False(WindowsFileMetadata.IsLocallyAvailableRegularFile(0x00400000, 0));
        Assert.False(WindowsFileMetadata.IsLocallyAvailableRegularFile(0, 0x00000010));
        Assert.False(WindowsFileMetadata.IsLocallyAvailableRegularFile(0, 0xffffffff));
    }

    [Fact]
    public async Task MatchingSamplesWithDifferentMiddleContentAreRejected()
    {
        using var fixture = new TemporaryDirectory();
        const int length = 3 * 64 * 1024;
        var firstContent = Enumerable.Repeat((byte)0x41, length).ToArray();
        var secondContent = firstContent.ToArray();
        Array.Fill(secondContent, (byte)0x42, 64 * 1024, 64 * 1024);
        var firstPath = Path.Combine(fixture.Path, "first.bin");
        var secondPath = Path.Combine(fixture.Path, "second.bin");
        await File.WriteAllBytesAsync(firstPath, firstContent);
        await File.WriteAllBytesAsync(secondPath, secondContent);

        var result = await DuplicateVerifier.VerifyAsync(
            [new DuplicateCandidate(length, [NodeFor(firstPath), NodeFor(secondPath)])]);

        Assert.Empty(result.Groups);
        Assert.Equal(0, result.TotalUnreadableFiles);
    }

    [Fact]
    public async Task UnreadableCountIsNotTruncatedWithExamplePaths()
    {
        using var fixture = new TemporaryDirectory();
        var files = Enumerable.Range(0, 101)
            .Select(index => new FileNode(
                Path.Combine(fixture.Path, $"missing-{index}.bin"),
                $"missing-{index}.bin",
                FileNodeKind.File,
                10_000_000,
                10_000_000))
            .ToArray();

        var result = await DuplicateVerifier.VerifyAsync([new DuplicateCandidate(10_000_000, files)]);

        Assert.Empty(result.Groups);
        Assert.Equal(101, result.TotalUnreadableFiles);
        Assert.Equal(100, result.UnreadablePaths.Count);
    }

    [Fact]
    public async Task UnreadablePathsThatDifferOnlyByCaseRemainDistinct()
    {
        using var fixture = new TemporaryDirectory();
        var upper = new FileNode(Path.Combine(fixture.Path, "MISSING.bin"), "MISSING.bin", FileNodeKind.File, 10, 10);
        var lower = new FileNode(Path.Combine(fixture.Path, "missing.bin"), "missing.bin", FileNodeKind.File, 10, 10);

        var result = await DuplicateVerifier.VerifyAsync([new DuplicateCandidate(10, [upper, lower])]);

        Assert.Equal(2, result.TotalUnreadableFiles);
    }

    [Fact]
    public async Task CancellationAtHashingBoundaryStopsVerification()
    {
        using var fixture = new TemporaryDirectory();
        var content = Enumerable.Range(0, 2 * 1024 * 1024)
            .Select(index => (byte)(index % 251))
            .ToArray();
        var firstPath = Path.Combine(fixture.Path, "first.bin");
        var secondPath = Path.Combine(fixture.Path, "second.bin");
        await File.WriteAllBytesAsync(firstPath, content);
        await File.WriteAllBytesAsync(secondPath, content);
        using var cancellation = new CancellationTokenSource();
        var progress = new SynchronousProgress<DuplicateVerificationProgress>(item =>
        {
            if (item.Phase == DuplicateVerificationPhase.Hashing)
            {
                cancellation.Cancel();
            }
        });

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => DuplicateVerifier.VerifyAsync(
            [new DuplicateCandidate(content.Length, [NodeFor(firstPath), NodeFor(secondPath)])],
            progress,
            cancellation.Token));
    }

    private static FileNode NodeFor(string path)
    {
        var info = new FileInfo(path);
        return new FileNode(
            path,
            info.Name,
            FileNodeKind.File,
            info.Length,
            info.Length,
            modificationDate: info.LastWriteTimeUtc);
    }

    private sealed class SynchronousProgress<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }
}
