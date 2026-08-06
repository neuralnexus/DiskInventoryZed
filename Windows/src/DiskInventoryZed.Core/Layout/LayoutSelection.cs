using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Core.Layout;

internal static class LayoutSelection
{
    public static IReadOnlyList<LayoutContent> Select(
        IReadOnlyList<FileNode> children,
        long minimumSize,
        int maximumItems,
        Func<FileNode, long, bool> isIndividuallyVisible)
    {
        if (maximumItems <= 0)
        {
            return [];
        }

        var eligibleCount = 0;
        var visibleCount = 0;
        var totalSize = 0L;
        for (var index = 0; index < children.Count; index++)
        {
            var child = children[index];
            if (child.AllocatedSize <= 0 || minimumSize > 0 && child.AllocatedSize < minimumSize)
            {
                continue;
            }
            eligibleCount++;
            totalSize = checked(totalSize + child.AllocatedSize);
        }
        if (eligibleCount == 0 || totalSize <= 0)
        {
            return [];
        }

        for (var index = 0; index < children.Count; index++)
        {
            var child = children[index];
            if (child.AllocatedSize > 0 &&
                (minimumSize == 0 || child.AllocatedSize >= minimumSize) &&
                isIndividuallyVisible(child, totalSize))
            {
                visibleCount++;
            }
        }

        var aggregateRequired = visibleCount < eligibleCount || visibleCount > maximumItems;
        var realCapacity = Math.Max(0, maximumItems - (aggregateRequired ? 1 : 0));
        var priorityComparer = CandidatePriorityComparer.Instance;
        var retained = new PriorityQueue<FileNode, CandidatePriority>(priorityComparer);
        for (var index = 0; index < children.Count; index++)
        {
            var child = children[index];
            if (child.AllocatedSize <= 0 ||
                minimumSize > 0 && child.AllocatedSize < minimumSize ||
                !isIndividuallyVisible(child, totalSize) ||
                realCapacity == 0)
            {
                continue;
            }

            var priority = new CandidatePriority(child.AllocatedSize, child.FullPath);
            if (retained.Count < realCapacity)
            {
                retained.Enqueue(child, priority);
            }
            else if (retained.TryPeek(out _, out var worst) && priorityComparer.Compare(priority, worst) > 0)
            {
                retained.Dequeue();
                retained.Enqueue(child, priority);
            }
        }

        var retainedNodes = new List<FileNode>(retained.Count);
        while (retained.TryDequeue(out var node, out _))
        {
            retainedNodes.Add(node);
        }
        retainedNodes.Sort(static (left, right) =>
        {
            var sizeOrder = right.AllocatedSize.CompareTo(left.AllocatedSize);
            return sizeOrder != 0
                ? sizeOrder
                : StringComparer.Ordinal.Compare(left.FullPath, right.FullPath);
        });

        var result = new List<LayoutContent>(retainedNodes.Count + (aggregateRequired ? 1 : 0));
        var retainedSize = 0L;
        foreach (var node in retainedNodes)
        {
            retainedSize = checked(retainedSize + node.AllocatedSize);
            result.Add(new LayoutContent.Node(node));
        }
        if (aggregateRequired)
        {
            result.Add(new LayoutContent.Aggregate(totalSize - retainedSize, eligibleCount - retainedNodes.Count));
        }
        return result;
    }

    private readonly record struct CandidatePriority(long Size, string Path);

    private sealed class CandidatePriorityComparer : IComparer<CandidatePriority>
    {
        public static readonly CandidatePriorityComparer Instance = new();

        public int Compare(CandidatePriority left, CandidatePriority right)
        {
            var sizeOrder = left.Size.CompareTo(right.Size);
            return sizeOrder != 0
                ? sizeOrder
                : StringComparer.Ordinal.Compare(right.Path, left.Path);
        }
    }
}
