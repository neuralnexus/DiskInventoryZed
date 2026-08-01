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

    [Fact]
    public void SunburstRejectsAViewportThatCannotFitARing()
    {
        var root = DirectoryNode("root", [File("file.bin", 1)]);
        var slices = SunburstLayout.Calculate(root, 20);
        Assert.All(slices, slice => Assert.InRange(slice.OuterRadius, 0, 20));
    }

    [Fact]
    public void TreemapDoesNotExceedRenderingCap()
    {
        var children = Enumerable.Range(0, 60_010)
            .Select(index => File($"{index}.bin", 1))
            .ToArray();
        var largeDirectory = DirectoryNode("large", children);
        var root = DirectoryNode("root", [largeDirectory, File("sibling.bin", 1)]);

        var rectangles = TreemapLayout.Calculate(root, 1600, 900);

        Assert.InRange(rectangles.Count, 1, 60_000);
        Assert.All(rectangles, item => Assert.True(item.Rectangle.Width >= 0 && item.Rectangle.Height >= 0));
    }

    private static FileNode File(string name, long size) =>
        new(Path.Combine("C:\\fixture", name), name, FileNodeKind.File, size, size);

    private static FileNode DirectoryNode(string name, IReadOnlyList<FileNode> children) =>
        new(Path.Combine("C:\\fixture", name), name, FileNodeKind.Directory,
            children.Sum(child => child.LogicalSize), children.Sum(child => child.AllocatedSize), children);
}
