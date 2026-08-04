using DiskInventoryZed.Core.Models;
using DiskInventoryZed.Core.Utilities;

namespace DiskInventoryZed.Core.Analysis;

public sealed record ExtensionStat(string Extension, long TotalSize, int FileCount)
{
    public string DisplayName => Extension == "unknown" ? "NO EXTENSION" : Extension.ToUpperInvariant();
    public string FormattedSize => ByteSizeFormatter.Format(TotalSize);
}

public sealed record DuplicateCandidate(long FileSize, IReadOnlyList<FileNode> Files)
{
    public string DisplayName
    {
        get
        {
            var names = Files.Select(file => file.DisplayName).Distinct(StringComparer.OrdinalIgnoreCase).Take(2).ToArray();
            return names.Length == 1 ? names[0] : $"{Files.Count:N0} same-sized files";
        }
    }

    public long PotentialSavings => Files.Count < 2
        ? 0
        : Files.Sum(file => file.AllocatedSize) - Files.Min(file => file.AllocatedSize);
    public string Summary => $"{Files.Count:N0} files, up to {ByteSizeFormatter.Format(PotentialSavings)}";
}

public sealed record ScanAnalysis(
    IReadOnlyList<ExtensionStat> ExtensionStats,
    IReadOnlyList<FileNode> LargestFiles,
    IReadOnlyList<FileNode> OldLargeFiles,
    IReadOnlyList<DuplicateCandidate> DuplicateCandidates,
    IReadOnlyList<FileNode> AllNodes,
    IReadOnlyDictionary<string, FileNode> NodesById,
    IReadOnlyDictionary<string, string> ParentById);

public static class ScanAnalyzer
{
    internal const int MaximumExtensionStats = 500;

    public static ScanAnalysis Analyze(FileNode root, CancellationToken cancellationToken = default)
    {
        try
        {
            return AnalyzeCore(root, cancellationToken);
        }
        catch (InvalidOperationException) when (cancellationToken.IsCancellationRequested)
        {
            cancellationToken.ThrowIfCancellationRequested();
            throw;
        }
    }

    private static ScanAnalysis AnalyzeCore(FileNode root, CancellationToken cancellationToken)
    {
        var extensions = new Dictionary<string, (long Size, int Count)>(StringComparer.OrdinalIgnoreCase);
        var files = new List<FileNode>();
        var allNodes = new List<FileNode>();
        var nodesById = new Dictionary<string, FileNode>(StringComparer.Ordinal);
        var parentById = new Dictionary<string, string>(StringComparer.Ordinal);
        var duplicateGroups = new Dictionary<long, List<FileNode>>();
        var oldFileCutoff = DateTimeOffset.Now.AddYears(-1);
        var stack = new Stack<(FileNode Node, string? ParentId)>();
        stack.Push((root, null));

        while (stack.TryPop(out var item))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var node = item.Node;
            allNodes.Add(node);
            nodesById[node.Id] = node;
            if (item.ParentId is not null)
            {
                parentById[node.Id] = item.ParentId;
            }

            if (node.IsContainer)
            {
                for (var index = node.Children.Count - 1; index >= 0; index--)
                {
                    stack.Push((node.Children[index], node.Id));
                }

                continue;
            }

            files.Add(node);
            var extension = string.IsNullOrWhiteSpace(node.Extension) ? "unknown" : node.Extension.ToLowerInvariant();
            var aggregate = extensions.GetValueOrDefault(extension);
            extensions[extension] = (aggregate.Size + node.AllocatedSize, aggregate.Count + 1);

            if (node.Kind == FileNodeKind.File &&
                node.LogicalSize >= 10_000_000 &&
                !node.IsHardLinkDuplicate &&
                !node.HasUnverifiedHardLinks)
            {
                if (!duplicateGroups.TryGetValue(node.LogicalSize, out var matches))
                {
                    matches = [];
                    duplicateGroups[node.LogicalSize] = matches;
                }

                matches.Add(node);
            }
        }

        var extensionStats = ObserveCancellation(extensions, cancellationToken)
            .Select(item => new ExtensionStat(item.Key, item.Value.Size, item.Value.Count))
            .OrderByDescending(
                item => item.TotalSize,
                new CancellationComparer<long>(Comparer<long>.Default, cancellationToken))
            .ThenBy(
                item => item.Extension,
                new CancellationComparer<string>(StringComparer.OrdinalIgnoreCase, cancellationToken))
            .Take(MaximumExtensionStats)
            .ToArray();
        var largestFiles = ObserveCancellation(files, cancellationToken)
            .OrderByDescending(
                file => file.AllocatedSize,
                new CancellationComparer<long>(Comparer<long>.Default, cancellationToken))
            .Take(100)
            .ToArray();
        var oldLargeFiles = ObserveCancellation(files, cancellationToken)
            .Where(file => file.AllocatedSize >= 100_000_000 && file.ModificationDate < oldFileCutoff)
            .OrderByDescending(
                file => file.AllocatedSize,
                new CancellationComparer<long>(Comparer<long>.Default, cancellationToken))
            .Take(100)
            .ToArray();
        var duplicateCandidates = ObserveCancellation(duplicateGroups.Values, cancellationToken)
            .Where(matches => matches.Count > 1)
            .Select(matches => new DuplicateCandidate(
                matches[0].LogicalSize,
                ObserveCancellation(matches, cancellationToken)
                    .OrderBy(
                        file => file.FullPath,
                        new CancellationComparer<string>(StringComparer.OrdinalIgnoreCase, cancellationToken))
                    .ToArray()))
            .OrderByDescending(
                candidate => candidate.PotentialSavings,
                new CancellationComparer<long>(Comparer<long>.Default, cancellationToken))
            .Take(500)
            .ToArray();

        cancellationToken.ThrowIfCancellationRequested();
        return new ScanAnalysis(
            extensionStats,
            largestFiles,
            oldLargeFiles,
            duplicateCandidates,
            allNodes,
            nodesById,
            parentById);
    }

    private static IEnumerable<T> ObserveCancellation<T>(
        IEnumerable<T> source,
        CancellationToken cancellationToken)
    {
        var count = 0;
        foreach (var item in source)
        {
            if ((count++ & 255) == 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
            }
            yield return item;
        }
    }

    private sealed class CancellationComparer<T>(IComparer<T> inner, CancellationToken cancellationToken) : IComparer<T>
    {
        private int _comparisons;

        public int Compare(T? left, T? right)
        {
            if ((_comparisons++ & 255) == 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
            }
            return inner.Compare(left!, right!);
        }
    }
}
