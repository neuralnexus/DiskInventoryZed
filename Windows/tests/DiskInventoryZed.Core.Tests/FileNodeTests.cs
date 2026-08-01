using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Core.Tests;

public sealed class FileNodeTests
{
    [Fact]
    public void PathLookupPreservesDeepTreesWithoutRecursion()
    {
        const int depth = 5_000;
        var node = new FileNode(
            Path.Combine(Path.GetTempPath(), "deep", "leaf.bin"),
            "leaf.bin",
            FileNodeKind.File,
            1,
            4096);
        var leafId = node.Id;
        for (var index = depth - 1; index >= 0; index--)
        {
            var path = Path.Combine(Path.GetTempPath(), "deep", index.ToString());
            node = new FileNode(path, index.ToString(), FileNodeKind.Directory, node.LogicalSize, node.AllocatedSize, [node]);
        }

        Assert.Same(node.FindById(leafId), node.PathTo(leafId)?[^1]);
        Assert.Equal(depth + 1, node.PathTo(leafId)?.Count);
    }

    [Fact]
    public void PackageNodesUseContainerCounts()
    {
        var child = new FileNode("C:\\fixture\\App.pkg\\data.bin", "data.bin", FileNodeKind.File, 10, 16);
        var package = new FileNode("C:\\fixture\\App.pkg", "App.pkg", FileNodeKind.Package, 10, 16, [child]);

        Assert.True(package.IsContainer);
        Assert.Equal(1, package.TotalFileCount);
        Assert.Equal(1, package.TotalDirectoryCount);
    }

    [Fact]
    public void ExactPathIdentityDoesNotCollapseCaseSensitiveNames()
    {
        var lower = new FileNode("C:\\fixture\\foo", "foo", FileNodeKind.File, 1, 1);
        var upper = new FileNode("C:\\fixture\\FOO", "FOO", FileNodeKind.File, 1, 1);

        Assert.NotEqual(lower, upper);
    }
}
