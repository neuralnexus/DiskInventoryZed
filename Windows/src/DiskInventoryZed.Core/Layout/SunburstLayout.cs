using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Core.Layout;

public static class SunburstLayout
{
    private const double MinimumVisibleAngle = Math.PI / 360; // 0.5 degrees

    public static IReadOnlyList<SunburstSlice> Calculate(
        FileNode root,
        double outerRadius,
        long minimumSize = 0,
        int maximumDepth = 6)
    {
        if (outerRadius <= 10 || maximumDepth <= 0)
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

        var slices = new List<SunburstSlice>();
        AppendChildren(root, 0, 0, Math.PI * 2, innerRadius, ringWidth, minimumSize, maximumDepth, slices);
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
        List<SunburstSlice> slices)
    {
        if (depth >= maximumDepth)
        {
            return;
        }

        var children = parent.Children
            .Where(child => child.AllocatedSize > 0 && (minimumSize == 0 || child.AllocatedSize >= minimumSize))
            .ToArray();
        var totalSize = children.Aggregate(0d, (sum, child) => sum + child.AllocatedSize);
        if (totalSize <= 0)
        {
            return;
        }

        var currentAngle = startAngle;
        var totalSpan = endAngle - startAngle;
        var innerRadius = baseRadius + depth * ringWidth;
        var outerRadius = innerRadius + Math.Max(2, ringWidth - 3);
        foreach (var child in children)
        {
            var span = child.AllocatedSize / totalSize * totalSpan;
            var nextAngle = currentAngle + span;
            if (span >= MinimumVisibleAngle)
            {
                slices.Add(new SunburstSlice(
                    child,
                    currentAngle,
                    nextAngle,
                    innerRadius,
                    outerRadius,
                    depth));
                if (child.IsContainer)
                {
                    AppendChildren(
                        child,
                        depth + 1,
                        currentAngle,
                        nextAngle,
                        baseRadius,
                        ringWidth,
                        minimumSize,
                        maximumDepth,
                        slices);
                }
            }

            currentAngle = nextAngle;
        }
    }
}
