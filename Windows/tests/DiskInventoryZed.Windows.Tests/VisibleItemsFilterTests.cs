using System.IO;
using DiskInventoryZed.Core.Analysis;
using DiskInventoryZed.Core.Models;
using DiskInventoryZed.Windows.ViewModels;

namespace DiskInventoryZed.Windows.Tests;

public sealed class VisibleItemsFilterTests
{
    [Fact]
    public void EmptyQueryUsesCurrentChildrenAndAppliesSortAndSize()
    {
        var small = File("small.txt", 1);
        var large = File("large.bin", 10);
        var root = Root([small, large]);

        var result = VisibleItemsFilter.Apply(
            root,
            ScanAnalyzer.Analyze(root),
            string.Empty,
            null,
            2,
            FileSortOrder.SizeDescending,
            CancellationToken.None);

        Assert.Equal([large], result.Items);
        Assert.Equal(1, result.Total);
    }

    [Fact]
    public void SearchUsesEntireAnalysisAndExtensionFilter()
    {
        var nestedFile = new FileNode("C:\\root\\nested\\match.txt", "match.txt", FileNodeKind.File, 2, 2);
        var nested = new FileNode("C:\\root\\nested", "nested", FileNodeKind.Directory, 2, 2, [nestedFile]);
        var root = Root([nested, File("match.bin", 3)]);

        var result = VisibleItemsFilter.Apply(
            root,
            ScanAnalyzer.Analyze(root),
            "match",
            "txt",
            0,
            FileSortOrder.NameAscending,
            CancellationToken.None);

        Assert.Equal([nestedFile], result.Items);
    }

    [Fact]
    public void ResultsAreCappedAndTotalRemainsVisible()
    {
        var children = Enumerable.Range(0, 2_050)
            .Select(index => File($"{index:D4}.bin", index + 1))
            .ToArray();
        var root = Root(children);

        var result = VisibleItemsFilter.Apply(
            root,
            null,
            string.Empty,
            null,
            0,
            FileSortOrder.NameAscending,
            CancellationToken.None);

        Assert.Equal(2_000, result.Items.Count);
        Assert.Equal(2_050, result.Total);
        Assert.Equal("0000.bin", result.Items[0].DisplayName);
    }

    private static FileNode File(string name, long size) =>
        new(Path.Combine("C:\\root", name), name, FileNodeKind.File, size, size);

    private static FileNode Root(IReadOnlyList<FileNode> children) =>
        new(
            "C:\\root",
            "root",
            FileNodeKind.Directory,
            children.Sum(child => child.LogicalSize),
            children.Sum(child => child.AllocatedSize),
            children);
}
