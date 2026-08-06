using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Core.Layout;

public static class SunburstLayout
{
    private const double MinimumVisibleAngle = Math.PI / 360;

    public static IReadOnlyList<SunburstSlice> Calculate(
        FileNode root,
        double outerRadius,
        long minimumSize = 0,
        int maximumDepth = 6,
        int maximumItems = 2048)
    {
        if (outerRadius <= 10 || maximumDepth <= 0 || maximumItems <= 0)
        {
            return [];
        }

        var innerRadius = Math.Min(Math.Clamp(outerRadius * 0.18, 12, 64), outerRadius - 4);
        if (innerRadius <= 0 || outerRadius - innerRadius < 4)
        {
            return [];
        }
        var ringWidth = (outerRadius - innerRadius) / maximumDepth;
        if (ringWidth < 4)
        {
            maximumDepth = Math.Max(1, (int)((outerRadius - innerRadius) / 4));
            ringWidth = (outerRadius - innerRadius) / maximumDepth;
        }

        var slices = new List<SunburstSlice>(Math.Min(maximumItems, 512));
        AppendChildren(
            root,
            0,
            0,
            Math.PI * 2,
            innerRadius,
            ringWidth,
            minimumSize,
            maximumDepth,
            maximumItems,
            slices);
        return slices;
    }

    private static void AppendChildren(
        FileNode parent,
        int depth,
        double startAngle,
        double endAngle,
        double baseRadius,
        double ringWidth,
        long minimumSize,
        int maximumDepth,
        int maximumItems,
        List<SunburstSlice> slices)
    {
        if (depth >= maximumDepth || slices.Count >= maximumItems)
        {
            return;
        }

        var totalSpan = endAngle - startAngle;
        var available = maximumItems - slices.Count;
        var content = LayoutSelection.Select(
            parent.Children,
            minimumSize,
            available,
            (child, totalSize) => child.AllocatedSize / (double)totalSize * totalSpan >= MinimumVisibleAngle);
        if (content.Count == 0)
        {
            return;
        }

        var totalSize = content.Sum(item => (double)item.AllocatedSize);
        var currentAngle = startAngle;
        var innerRadius = baseRadius + depth * ringWidth;
        var outerRadius = innerRadius + Math.Max(2, ringWidth - 3);
        var descendants = new List<(FileNode Node, double StartAngle, double EndAngle)>();
        for (var index = 0; index < content.Count; index++)
        {
            var item = content[index];
            var nextAngle = index == content.Count - 1
                ? endAngle
                : currentAngle + item.AllocatedSize / totalSize * totalSpan;
            slices.Add(new SunburstSlice(item, currentAngle, nextAngle, innerRadius, outerRadius, depth));
            if (item is LayoutContent.Node { Value.IsContainer: true } node)
            {
                descendants.Add((node.Value, currentAngle, nextAngle));
            }
            currentAngle = nextAngle;
        }

        foreach (var descendant in descendants)
        {
            AppendChildren(
                descendant.Node,
                depth + 1,
                descendant.StartAngle,
                descendant.EndAngle,
                baseRadius,
                ringWidth,
                minimumSize,
                maximumDepth,
                maximumItems,
                slices);
        }
    }
}
