using DiskInventoryZed.Core.Analysis;
using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Core.Tests;

public sealed class ScanAnalyzerTests
{
    [Fact]
    public void DuplicateCandidatesExcludeKnownAndUnverifiableHardLinks()
    {
        var eligibleA = File("eligible-a.bin", 10_000_000);
        var eligibleB = File("eligible-b.bin", 10_000_000);
        var hardLinkAlias = File("alias.bin", 10_000_000, isHardLinkDuplicate: true);
        var uncertain = File("uncertain.bin", 10_000_000, hasUnverifiedHardLinks: true);
        var root = DirectoryNode([eligibleA, eligibleB, hardLinkAlias, uncertain]);

        var analysis = ScanAnalyzer.Analyze(root);
        var candidate = Assert.Single(analysis.DuplicateCandidates);

        Assert.Equal([eligibleA, eligibleB], candidate.Files);
    }

    [Fact]
    public void DuplicateCandidatesRespectThresholdAndDeterministicOrder()
    {
        var belowThresholdA = File("small-a.bin", 9_999_999);
        var belowThresholdB = File("small-b.bin", 9_999_999);
        var zed = File("zed.bin", 10_000_000);
        var alpha = File("alpha.bin", 10_000_000);
        var root = DirectoryNode([zed, belowThresholdA, alpha, belowThresholdB]);

        var analysis = ScanAnalyzer.Analyze(root);
        var candidate = Assert.Single(analysis.DuplicateCandidates);

        Assert.Equal([alpha, zed], candidate.Files);
    }

    [Fact]
    public void CancelledAnalysisThrowsBeforePublication()
    {
        var root = DirectoryNode([File("file.bin", 1)]);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        Assert.Throws<OperationCanceledException>(() => ScanAnalyzer.Analyze(root, cancellation.Token));
    }

    private static FileNode File(
        string name,
        long size,
        bool isHardLinkDuplicate = false,
        bool hasUnverifiedHardLinks = false) =>
        new(
            Path.Combine("C:\\fixture", name),
            name,
            FileNodeKind.File,
            size,
            size,
            isHardLinkDuplicate: isHardLinkDuplicate,
            hasUnverifiedHardLinks: hasUnverifiedHardLinks);

    private static FileNode DirectoryNode(IReadOnlyList<FileNode> children) =>
        new(
            "C:\\fixture",
            "fixture",
            FileNodeKind.Directory,
            children.Sum(child => child.LogicalSize),
            children.Sum(child => child.AllocatedSize),
            children);
}
