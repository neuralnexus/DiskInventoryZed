using DiskInventoryZed.Core.Models;
using DiskInventoryZed.Core.Scanning;

namespace DiskInventoryZed.Core.Tests;

public sealed class DiskScannerPostProcessingTests
{
    [Fact]
    public void HardLinkOwnerIsTheOrdinalLowestPath()
    {
        var identity = new FileIdentity(1, Guid.NewGuid());
        var zed = Record("C:\\root\\zed.bin", 4096, identity, hardLinkCount: 2);
        var alpha = Record("C:\\root\\alpha.bin", 4096, identity, hardLinkCount: 2);

        var duplicateCount = DiskScanner.DeduplicateHardLinks(
            [zed, alpha],
            StringComparer.Ordinal,
            CancellationToken.None);

        Assert.Equal(1, duplicateCount);
        Assert.Equal(4096, alpha.AllocatedSize);
        Assert.False(alpha.IsHardLinkDuplicate);
        Assert.Equal(0, zed.AllocatedSize);
        Assert.True(zed.IsHardLinkDuplicate);
    }

    [Fact]
    public void StableIdentityWinsWhenReportedLinkCountFallsToOne()
    {
        var sharedIdentity = new FileIdentity(1, Guid.NewGuid());
        var first = Record("C:\\root\\first.bin", 1, sharedIdentity);
        var second = Record("C:\\root\\second.bin", 1, sharedIdentity);

        var duplicateCount = DiskScanner.DeduplicateHardLinks(
            [second, first],
            StringComparer.Ordinal,
            CancellationToken.None);

        Assert.Equal(1, duplicateCount);
        Assert.Equal(1, first.AllocatedSize);
        Assert.Equal(0, second.AllocatedSize);
        Assert.True(second.IsHardLinkDuplicate);
    }

    [Fact]
    public void StableSortPreservesEqualKeyOrderAndUnwrapsCancellation()
    {
        var values = Enumerable.Range(0, 1000).ToArray();
        var stable = DiskScanner.StableSortWithCancellation(
            values,
            Comparer<int>.Create(static (_, _) => 0),
            CancellationToken.None);
        Assert.Equal(values, stable);

        using var cancellation = new CancellationTokenSource();
        var comparisons = 0;
        var comparer = Comparer<int>.Create((left, right) =>
        {
            if (Interlocked.Increment(ref comparisons) == 10)
            {
                cancellation.Cancel();
            }
            return left.CompareTo(right);
        });

        var error = Assert.Throws<OperationCanceledException>(() => DiskScanner.StableSortWithCancellation(
            values.Reverse(), comparer, cancellation.Token));
        Assert.Equal(cancellation.Token, error.CancellationToken);
    }

    [Fact]
    public void MaterializationAndAggregationPreserveOrderingAndCounts()
    {
        var small = File("C:\\root\\small.bin", "same", 10);
        var large = File("C:\\root\\large.bin", "same", 20);
        var built = new Dictionary<string, FileNode>(StringComparer.Ordinal)
        {
            [small.FullPath] = small,
            [large.FullPath] = large
        };

        var children = DiskScanner.MaterializeChildren(
            [small.FullPath, "C:\\root\\missing.bin", large.FullPath],
            built,
            CancellationToken.None);
        var aggregate = DiskScanner.AggregateChildren(children, CancellationToken.None);

        Assert.Equal([large, small], children);
        Assert.Equal(30, aggregate.LogicalSize);
        Assert.Equal(30, aggregate.AllocatedSize);
        Assert.Equal(2, aggregate.TotalFileCount);
        Assert.Equal(1, aggregate.TotalDirectoryCount);
    }

    [Fact]
    public void MaterializationStopsAfterCancellationDuringIndexAccess()
    {
        using var cancellation = new CancellationTokenSource();
        var paths = new CancellingReadOnlyList<string>(
            ["C:\\root\\one", "C:\\root\\two", "C:\\root\\three"],
            cancellation,
            cancelAtIndex: 1);
        var built = new TrackingReadOnlyDictionary<string, FileNode>(new Dictionary<string, FileNode>());

        Assert.Throws<OperationCanceledException>(() => DiskScanner.MaterializeChildren(
            paths,
            built,
            cancellation.Token));
        Assert.Equal(2, paths.ReadCount);
        Assert.Equal(1, built.LookupCount);
    }

    [Fact]
    public void AggregationUsesCheckedArithmetic()
    {
        var maximumLogical = new FileNode(
            "C:\\root\\maximum-logical.bin", "maximum-logical.bin", FileNodeKind.File, long.MaxValue, 0);
        var oneLogical = new FileNode("C:\\root\\one-logical.bin", "one-logical.bin", FileNodeKind.File, 1, 0);
        var maximumAllocated = new FileNode(
            "C:\\root\\maximum-allocated.bin", "maximum-allocated.bin", FileNodeKind.File, 0, long.MaxValue);
        var oneAllocated = new FileNode(
            "C:\\root\\one-allocated.bin", "one-allocated.bin", FileNodeKind.File, 0, 1);
        var maximumFiles = new FileNode(
            "C:\\root\\maximum-files.bin", "maximum-files.bin", FileNodeKind.File, 0, 0,
            totalFileCount: int.MaxValue);
        var oneFile = new FileNode(
            "C:\\root\\one-file.bin", "one-file.bin", FileNodeKind.File, 0, 0, totalFileCount: 1);
        var maximumDirectories = new FileNode(
            "C:\\root\\maximum-directories", "maximum-directories", FileNodeKind.Directory, 0, 0,
            totalDirectoryCount: int.MaxValue);

        Assert.Throws<OverflowException>(() => DiskScanner.AggregateChildren(
            [maximumLogical, oneLogical],
            CancellationToken.None));
        Assert.Throws<OverflowException>(() => DiskScanner.AggregateChildren(
            [maximumAllocated, oneAllocated],
            CancellationToken.None));
        Assert.Throws<OverflowException>(() => DiskScanner.AggregateChildren(
            [maximumFiles, oneFile],
            CancellationToken.None));
        Assert.Throws<OverflowException>(() => DiskScanner.AggregateChildren(
            [maximumDirectories],
            CancellationToken.None));
    }

    [Fact]
    public void BuildTreePreservesStableOrderingAndContainerTotals()
    {
        var root = Record("C:\\root", 0, null, FileNodeKind.Directory);
        var alpha = Record("C:\\root\\alpha.bin", 10, null);
        var beta = Record("C:\\root\\beta.bin", 20, null);
        root.ChildPaths = [alpha.Path, beta.Path];
        var records = new Dictionary<string, DiskScanner.ScanRecord>(StringComparer.Ordinal)
        {
            [root.Path] = root,
            [alpha.Path] = alpha,
            [beta.Path] = beta
        };

        var tree = DiskScanner.BuildTree(root.Path, records, StringComparer.Ordinal, CancellationToken.None);

        Assert.NotNull(tree);
        Assert.Equal(["beta.bin", "alpha.bin"], tree.Children.Select(child => child.DisplayName));
        Assert.Equal(30, tree.LogicalSize);
        Assert.Equal(30, tree.AllocatedSize);
        Assert.Equal(2, tree.TotalFileCount);
        Assert.Equal(1, tree.TotalDirectoryCount);
    }

    private static DiskScanner.ScanRecord Record(
        string path,
        long allocatedSize,
        FileIdentity? identity,
        FileNodeKind kind = FileNodeKind.File,
        uint hardLinkCount = 1) => new(
            path,
            path[(path.LastIndexOf('\\') + 1)..],
            kind,
            allocatedSize,
            allocatedSize,
            null,
            null,
            false,
            identity,
            hardLinkCount);

    private static FileNode File(string path, string name, long size) =>
        new(path, name, FileNodeKind.File, size, size);

    private sealed class CancellingReadOnlyList<T>(
        IReadOnlyList<T> inner,
        CancellationTokenSource cancellation,
        int cancelAtIndex) : IReadOnlyList<T>
    {
        public int ReadCount { get; private set; }
        public int Count => inner.Count;
        public T this[int index]
        {
            get
            {
                ReadCount++;
                if (index == cancelAtIndex)
                {
                    cancellation.Cancel();
                }
                return inner[index];
            }
        }

        public IEnumerator<T> GetEnumerator() => inner.GetEnumerator();
        System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();
    }

    private sealed class TrackingReadOnlyDictionary<TKey, TValue>(IReadOnlyDictionary<TKey, TValue> inner)
        : IReadOnlyDictionary<TKey, TValue> where TKey : notnull
    {
        public int LookupCount { get; private set; }
        public IEnumerable<TKey> Keys => inner.Keys;
        public IEnumerable<TValue> Values => inner.Values;
        public int Count => inner.Count;
        public TValue this[TKey key] => inner[key];
        public bool ContainsKey(TKey key) => inner.ContainsKey(key);
        public bool TryGetValue(TKey key, out TValue value)
        {
            LookupCount++;
            return inner.TryGetValue(key, out value!);
        }
        public IEnumerator<KeyValuePair<TKey, TValue>> GetEnumerator() => inner.GetEnumerator();
        System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();
    }
}
