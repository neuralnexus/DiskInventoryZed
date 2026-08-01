using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Core.Layout;

public static class TreemapLayout
{
    private const int MaximumRectangles = 60_000;
    private const int MaximumDepth = 64;
    private const double MinimumExpandableArea = 120;

    public static IReadOnlyList<TreemapItem> Calculate(
        FileNode root,
        double width,
        double height,
        long minimumSize = 0)
    {
        if (width <= 1 || height <= 1)
        {
            return [];
        }

        var result = new List<TreemapItem>(Math.Min(4096, MaximumRectangles));
        AppendChildren(root, new RectD(0, 0, width, height), 0, minimumSize, result);
        return result;
    }

    private static void AppendChildren(
        FileNode parent,
        RectD parentRectangle,
        int depth,
        long minimumSize,
        List<TreemapItem> result)
    {
        if (depth >= MaximumDepth || result.Count >= MaximumRectangles)
        {
            return;
        }

        var available = MaximumRectangles - result.Count;
        var children = parent.Children
            .Where(child => child.AllocatedSize > 0 && (minimumSize == 0 || child.AllocatedSize >= minimumSize))
            .Take(available)
            .ToArray();
        if (children.Length == 0)
        {
            return;
        }

        foreach (var layout in Squarify(children, parentRectangle))
        {
            if (result.Count >= MaximumRectangles)
            {
                break;
            }

            if (layout.Rectangle.Width < 0.5 || layout.Rectangle.Height < 0.5)
            {
                continue;
            }

            result.Add(new TreemapItem(layout.Node, layout.Rectangle, depth));
            if (!layout.Node.IsContainer || layout.Node.Children.Count == 0 ||
                layout.Rectangle.Area < MinimumExpandableArea || result.Count >= MaximumRectangles)
            {
                continue;
            }

            var inset = Math.Min(4, Math.Max(1.5, Math.Min(layout.Rectangle.Width, layout.Rectangle.Height) * 0.025));
            var childRectangle = layout.Rectangle.Inset(inset);
            if (layout.Rectangle.Height > 26)
            {
                childRectangle = childRectangle with
                {
                    Y = childRectangle.Y + 12,
                    Height = Math.Max(0, childRectangle.Height - 12)
                };
            }

            if (childRectangle.Width > 2 && childRectangle.Height > 2)
            {
                AppendChildren(layout.Node, childRectangle, depth + 1, minimumSize, result);
            }
        }
    }

    private static IReadOnlyList<NodeLayout> Squarify(IReadOnlyList<FileNode> children, RectD rectangle)
    {
        var sorted = children.Where(child => child.AllocatedSize > 0)
            .OrderByDescending(child => child.AllocatedSize)
            .ToArray();
        var totalSize = sorted.Aggregate(0d, (sum, child) => sum + child.AllocatedSize);
        if (totalSize <= 0 || rectangle.Width <= 0 || rectangle.Height <= 0)
        {
            return [];
        }

        var scale = rectangle.Area / totalSize;
        var items = sorted.Select(child => new WeightedNode(child, child.AllocatedSize * scale)).ToArray();
        var itemIndex = 0;
        var remaining = rectangle;
        var layouts = new List<NodeLayout>(items.Length);

        while (itemIndex < items.Length && remaining.Width > 0 && remaining.Height > 0)
        {
            var row = new List<WeightedNode>();
            var shortSide = Math.Min(remaining.Width, remaining.Height);
            var metrics = RowMetrics.Empty;
            while (itemIndex < items.Length)
            {
                var next = items[itemIndex];
                var candidate = metrics.Add(next.Area);
                if (row.Count == 0 || candidate.WorstRatio(shortSide) <= metrics.WorstRatio(shortSide))
                {
                    row.Add(next);
                    metrics = candidate;
                    itemIndex++;
                }
                else
                {
                    break;
                }
            }

            var (rowLayouts, remainder) = LayoutRow(row, remaining);
            layouts.AddRange(rowLayouts);
            remaining = remainder;
        }

        return layouts;
    }

    private static (IReadOnlyList<NodeLayout> Layouts, RectD Remainder) LayoutRow(
        IReadOnlyList<WeightedNode> row,
        RectD rectangle)
    {
        if (row.Count == 0)
        {
            return ([], rectangle);
        }

        var rowArea = row.Sum(item => item.Area);
        var layouts = new List<NodeLayout>(row.Count);
        if (rectangle.Width >= rectangle.Height)
        {
            var columnWidth = Math.Min(rectangle.Width, rowArea / rectangle.Height);
            if (columnWidth <= 0)
            {
                return ([], rectangle);
            }

            var y = rectangle.Y;
            for (var index = 0; index < row.Count; index++)
            {
                var height = index == row.Count - 1 ? Math.Max(0, rectangle.Bottom - y) : row[index].Area / columnWidth;
                layouts.Add(new NodeLayout(row[index].Node, new RectD(rectangle.X, y, columnWidth, height)));
                y += height;
            }

            return (layouts, new RectD(
                rectangle.X + columnWidth,
                rectangle.Y,
                Math.Max(0, rectangle.Width - columnWidth),
                rectangle.Height));
        }

        var rowHeight = Math.Min(rectangle.Height, rowArea / rectangle.Width);
        if (rowHeight <= 0)
        {
            return ([], rectangle);
        }

        var x = rectangle.X;
        for (var index = 0; index < row.Count; index++)
        {
            var width = index == row.Count - 1 ? Math.Max(0, rectangle.Right - x) : row[index].Area / rowHeight;
            layouts.Add(new NodeLayout(row[index].Node, new RectD(x, rectangle.Y, width, rowHeight)));
            x += width;
        }

        return (layouts, new RectD(
            rectangle.X,
            rectangle.Y + rowHeight,
            rectangle.Width,
            Math.Max(0, rectangle.Height - rowHeight)));
    }

    private sealed record WeightedNode(FileNode Node, double Area);
    private sealed record NodeLayout(FileNode Node, RectD Rectangle);

    private readonly record struct RowMetrics(double Sum, double Minimum, double Maximum)
    {
        public static readonly RowMetrics Empty = new(0, double.PositiveInfinity, 0);

        public RowMetrics Add(double area) => new(Sum + area, Math.Min(Minimum, area), Math.Max(Maximum, area));

        public double WorstRatio(double shortSide)
        {
            if (Sum <= 0 || Minimum <= 0 || shortSide <= 0)
            {
                return double.PositiveInfinity;
            }

            var sideSquared = shortSide * shortSide;
            var sumSquared = Sum * Sum;
            return Math.Max(sideSquared * Maximum / sumSquared, sumSquared / (sideSquared * Minimum));
        }
    }
}
