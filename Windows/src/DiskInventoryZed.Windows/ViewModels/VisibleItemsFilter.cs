using DiskInventoryZed.Core.Analysis;
using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Windows.ViewModels;

internal static class VisibleItemsFilter
{
    public static VisibleItemsResult Apply(
        FileNode current,
        ScanAnalysis? analysis,
        string query,
        string? extension,
        long minimumSize,
        FileSortOrder sortOrder,
        CancellationToken cancellationToken)
    {
        IEnumerable<FileNode> source = string.IsNullOrEmpty(query)
            ? current.Children
            : analysis?.AllNodes ?? [];
        var visited = 0;
        source = source.Where(node =>
        {
            if ((visited++ & 255) == 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
            }

            return node.AllocatedSize >= minimumSize &&
                   (string.IsNullOrEmpty(query) ||
                    node.DisplayName.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
                    node.FullPath.Contains(query, StringComparison.CurrentCultureIgnoreCase)) &&
                   (string.IsNullOrEmpty(extension) ||
                    !node.IsDirectory && (node.Extension ?? "unknown").Equals(extension, StringComparison.OrdinalIgnoreCase));
        });
        var sizeComparer = new CancellationComparer<long>(Comparer<long>.Default, cancellationToken);
        var nameComparer = new CancellationComparer<string>(StringComparer.CurrentCultureIgnoreCase, cancellationToken);
        source = sortOrder switch
        {
            FileSortOrder.SizeAscending => source.OrderBy(node => node.AllocatedSize, sizeComparer).ThenBy(node => node.DisplayName, nameComparer),
            FileSortOrder.NameAscending => source.OrderBy(node => node.DisplayName, nameComparer),
            FileSortOrder.NameDescending => source.OrderByDescending(node => node.DisplayName, nameComparer),
            _ => source.OrderByDescending(node => node.AllocatedSize, sizeComparer).ThenBy(node => node.DisplayName, nameComparer)
        };

        FileNode[] matches;
        try
        {
            matches = source.ToArray();
        }
        catch (InvalidOperationException) when (cancellationToken.IsCancellationRequested)
        {
            cancellationToken.ThrowIfCancellationRequested();
            throw;
        }
        cancellationToken.ThrowIfCancellationRequested();
        return new VisibleItemsResult(matches.Take(2_000).ToArray(), matches.Length);
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
