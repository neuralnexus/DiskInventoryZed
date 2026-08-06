using DiskInventoryZed.Core.Layout;
using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Core.Tests;

public sealed class LayoutTests
{
    [Fact]
    public void SunburstAllocatesProportionalAnglesAndStaysInsideRadius()
    {
        var large = File("large.bin", 75);
        var small = File("small.bin", 25);
        var root = DirectoryNode("root", [large, small]);

        var slices = SunburstLayout.Calculate(root, 200, maximumDepth: 3);

        Assert.Equal(2, slices.Count);
        Assert.Equal(3 * Math.PI / 2, slices[0].EndAngle - slices[0].StartAngle, 6);
        Assert.All(slices, slice => Assert.InRange(slice.OuterRadius, 0, 200));
    }

    [Theory]
    [InlineData(721)]
    [InlineData(10_000)]
    public void SunburstAggregatesSubMinimumEqualChildren(int childCount)
    {
        var children = Enumerable.Range(0, childCount).Select(index => File($"{index:D5}.bin", 1)).ToArray();
        var root = DirectoryNode("root", children);

        var slice = Assert.Single(SunburstLayout.Calculate(root, 200, maximumDepth: 1));
        var aggregate = Assert.IsType<LayoutContent.Aggregate>(slice.Content);

        Assert.Equal(childCount, aggregate.ItemCount);
        Assert.Equal(childCount, aggregate.AllocatedSize);
        Assert.Equal(2 * Math.PI, slice.EndAngle - slice.StartAngle, 6);
    }

    [Fact]
    public void SunburstBudgetIsGlobalDeterministicAndWeightPreserving()
    {
        var root = DirectoryNode(
            "root",
            Enumerable.Range(0, 10).Reverse().Select(index => File($"{index:D2}.bin", 10)).ToArray());

        var slices = SunburstLayout.Calculate(root, 200, maximumDepth: 3, maximumItems: 4);

        Assert.Equal(4, slices.Count);
        Assert.Equal(["00.bin", "01.bin", "02.bin"], slices
            .Select(slice => slice.Content)
            .OfType<LayoutContent.Node>()
            .Select(item => item.Value.DisplayName));
        var aggregate = Assert.IsType<LayoutContent.Aggregate>(slices[^1].Content);
        Assert.Equal(7, aggregate.ItemCount);
        Assert.Equal(100, slices.Sum(slice => slice.Content.AllocatedSize));
        Assert.Equal(2 * Math.PI, slices.Sum(slice => slice.EndAngle - slice.StartAngle), 6);
    }

    [Fact]
    public void TreemapAggregatesLargeFanoutWithinBudget()
    {
        const int childCount = 60_010;
        const int budget = 512;
        var children = Enumerable.Range(0, childCount).Select(index => File($"{index:D5}.bin", 1)).ToArray();
        var root = DirectoryNode("root", children);

        var rectangles = TreemapLayout.Calculate(root, 1600, 900, maximumItems: budget);

        Assert.Equal(budget, rectangles.Count);
        Assert.Equal(budget - 1, rectangles.Count(item => item.Content is LayoutContent.Node));
        var aggregate = Assert.Single(rectangles.Select(item => item.Content).OfType<LayoutContent.Aggregate>());
        Assert.Equal(childCount - budget + 1, aggregate.ItemCount);
        Assert.Equal(childCount, rectangles.Sum(item => item.Content.AllocatedSize));
        Assert.All(rectangles, item =>
        {
            Assert.InRange(item.Rectangle.X, 0, 1600);
            Assert.InRange(item.Rectangle.Y, 0, 900);
            Assert.InRange(item.Rectangle.Right, 0, 1600.000001);
            Assert.InRange(item.Rectangle.Bottom, 0, 900.000001);
        });
    }

    [Theory]
    [InlineData(100, 100)]
    [InlineData(106.62953577099249, 304.9454162139903)]
    public void TreemapRetainsPositiveAggregateAcrossDoublePrecisionBoundary(double width, double height)
    {
        var root = DirectoryNode("root", [File("dominant.bin", 1L << 53), File("tiny.bin", 1)]);

        var rectangles = TreemapLayout.Calculate(root, width, height);

        Assert.Equal(2, rectangles.Count);
        var aggregate = Assert.Single(rectangles, item => item.Content is LayoutContent.Aggregate);
        Assert.Equal(1, aggregate.Content.AllocatedSize);
        Assert.True(aggregate.Rectangle.Area > 0);
        Assert.Equal((1L << 53) + 1, rectangles.Sum(item => item.Content.AllocatedSize));
    }

    [Fact]
    public void LayoutBudgetsApplyAcrossDescendantsAfterImmediateSiblings()
    {
        var directories = Enumerable.Range(0, 5)
            .Select(directory => DirectoryNode(
                $"directory-{directory}",
                Enumerable.Range(0, 100).Select(file => File($"{directory}-{file:D3}.bin", 1)).ToArray()))
            .ToArray();
        var root = DirectoryNode("root", directories);

        var sunburst = SunburstLayout.Calculate(root, 300, maximumDepth: 4, maximumItems: 20);
        var treemap = TreemapLayout.Calculate(root, 1200, 800, maximumItems: 20);

        Assert.Equal(20, sunburst.Count);
        Assert.Equal(5, sunburst.Count(slice => slice.Depth == 0));
        Assert.Equal(20, treemap.Count);
        Assert.Equal(5, treemap.Count(item => item.Depth == 0));
    }

    [Fact]
    public void InvalidViewportOrBudgetProducesNoLayout()
    {
        var root = DirectoryNode("root", [File("file.bin", 1)]);

        Assert.Empty(SunburstLayout.Calculate(root, 10));
        Assert.Empty(SunburstLayout.Calculate(root, 200, maximumItems: 0));
        Assert.Empty(TreemapLayout.Calculate(root, 0, 100));
        Assert.Empty(TreemapLayout.Calculate(root, 100, 100, maximumItems: 0));
    }

    private static FileNode File(string name, long size) =>
        new(Path.Combine("C:\\fixture", name), name, FileNodeKind.File, size, size);

    private static FileNode DirectoryNode(string name, IReadOnlyList<FileNode> children) =>
        new(Path.Combine("C:\\fixture", name), name, FileNodeKind.Directory,
            children.Sum(child => child.LogicalSize), children.Sum(child => child.AllocatedSize), children);
}
