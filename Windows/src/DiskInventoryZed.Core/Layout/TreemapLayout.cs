using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Core.Layout;

public static class TreemapLayout
{
    private const int MaximumDepth = 64;
    private const double MinimumExpandableArea = 120;

    public static IReadOnlyList<TreemapItem> Calculate(
        FileNode root,
        double width,
        double height,
        long minimumSize = 0,
        int maximumItems = 2048)
    {
        if (width <= 1 || height <= 1 ||
            !double.IsFinite(width) || !double.IsFinite(height) ||
            !double.IsFinite(width * height) ||
            maximumItems <= 0)
        {
            return [];
        }

        var result = new List<TreemapItem>(Math.Min(maximumItems, 512));
        AppendChildren(root, new RectD(0, 0, width, height), 0, minimumSize, maximumItems, result);
        return result;
    }

    private static void AppendChildren(
        FileNode parent,
        RectD parentRectangle,
        int depth,
        long minimumSize,
        int maximumItems,
        List<TreemapItem> result)
    {
        if (depth >= MaximumDepth || result.Count >= maximumItems)
        {
            return;
        }

        var content = LayoutSelection.Select(
            parent.Children,
            minimumSize,
            maximumItems - result.Count,
            (child, totalSize) => child.AllocatedSize / (double)totalSize * parentRectangle.Area >= 1);
        if (content.Count == 0)
        {
            return;
        }

        var layouts = Squarify(content, parentRectangle);
        var added = new List<NodeLayout>(layouts.Count);
        foreach (var layout in layouts)
        {
            if (result.Count >= maximumItems)
            {
                break;
            }
            result.Add(new TreemapItem(layout.Content, layout.Rectangle, depth));
            added.Add(layout);
        }

        foreach (var layout in added)
        {
            if (result.Count >= maximumItems ||
                layout.Content is not LayoutContent.Node { Value: { IsContainer: true } node } ||
                node.Children.Count == 0 ||
                layout.Rectangle.Area < MinimumExpandableArea)
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
                AppendChildren(node, childRectangle, depth + 1, minimumSize, maximumItems, result);
            }
        }
    }

    private static IReadOnlyList<NodeLayout> Squarify(IReadOnlyList<LayoutContent> content, RectD rectangle)
    {
        var sorted = content.Where(item => item.AllocatedSize > 0)
            .OrderByDescending(item => item.AllocatedSize)
            .ThenBy(ContentOrderKey, StringComparer.Ordinal)
            .ToArray();
        var totalSize = sorted.Sum(item => (decimal)item.AllocatedSize);
        if (totalSize <= 0 || rectangle.Width <= 0 || rectangle.Height <= 0 ||
            !double.IsFinite(rectangle.Area))
        {
            return [];
        }

        var items = new WeightedNode[sorted.Length];
        var remainingSize = totalSize;
        var remainingArea = rectangle.Area;
        for (var index = 0; index < sorted.Length; index++)
        {
            var area = index == sorted.Length - 1
                ? remainingArea
                : remainingArea * (double)((decimal)sorted[index].AllocatedSize / remainingSize);
            if (index < sorted.Length - 1 && area >= remainingArea)
            {
                area = Math.Max(0, Math.BitDecrement(remainingArea));
            }
            area = Math.Clamp(area, 0, remainingArea);
            items[index] = new WeightedNode(sorted[index], area);
            remainingArea = Math.Max(0, remainingArea - area);
            remainingSize -= sorted[index].AllocatedSize;
        }
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
            var (rowLayouts, remainder) = LayoutRow(
                row,
                remaining,
                reserveRemainder: itemIndex < items.Length);
            if (rowLayouts.Count == 0)
            {
                layouts.AddRange(row.Select(item => new NodeLayout(
                    item.Content,
                    new RectD(remaining.X, remaining.Y, 0, 0))));
            }
            else
            {
                layouts.AddRange(rowLayouts);
            }
            remaining = remainder;
        }
        while (itemIndex < items.Length)
        {
            layouts.Add(new NodeLayout(
                items[itemIndex++].Content,
                new RectD(remaining.X, remaining.Y, 0, 0)));
        }
        return layouts;
    }

    private static string ContentOrderKey(LayoutContent content) =>
        content is LayoutContent.Node node ? node.Value.FullPath : "\uffff";

    private static (IReadOnlyList<NodeLayout> Layouts, RectD Remainder) LayoutRow(
        IReadOnlyList<WeightedNode> row,
        RectD rectangle,
        bool reserveRemainder)
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
            if (reserveRemainder && columnWidth >= rectangle.Width)
            {
                var reservedWidth = Math.BitDecrement(rectangle.Width);
                if (reservedWidth > 0)
                {
                    columnWidth = reservedWidth;
                }
            }
            if (columnWidth <= 0)
            {
                return ([], rectangle);
            }
            var y = rectangle.Y;
            for (var index = 0; index < row.Count; index++)
            {
                var height = index == row.Count - 1 ? Math.Max(0, rectangle.Bottom - y) : row[index].Area / columnWidth;
                layouts.Add(new NodeLayout(row[index].Content, new RectD(rectangle.X, y, columnWidth, height)));
                y += height;
            }
            return (layouts, new RectD(
                rectangle.X + columnWidth,
                rectangle.Y,
                Math.Max(0, rectangle.Width - columnWidth),
                rectangle.Height));
        }

        var rowHeight = Math.Min(rectangle.Height, rowArea / rectangle.Width);
        if (reserveRemainder && rowHeight >= rectangle.Height)
        {
            var reservedHeight = Math.BitDecrement(rectangle.Height);
            if (reservedHeight > 0)
            {
                rowHeight = reservedHeight;
            }
        }
        if (rowHeight <= 0)
        {
            return ([], rectangle);
        }
        var x = rectangle.X;
        for (var index = 0; index < row.Count; index++)
        {
            var width = index == row.Count - 1 ? Math.Max(0, rectangle.Right - x) : row[index].Area / rowHeight;
            layouts.Add(new NodeLayout(row[index].Content, new RectD(x, rectangle.Y, width, rowHeight)));
            x += width;
        }
        return (layouts, new RectD(
            rectangle.X,
            rectangle.Y + rowHeight,
            rectangle.Width,
            Math.Max(0, rectangle.Height - rowHeight)));
    }

    private sealed record WeightedNode(LayoutContent Content, double Area);
    private sealed record NodeLayout(LayoutContent Content, RectD Rectangle);

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
            var sideToSum = shortSide / Sum;
            var sumToSide = Sum / shortSide;
            var result = Math.Max(
                sideToSum * sideToSum * Maximum,
                sumToSide * sumToSide / Minimum);
            return double.IsNaN(result) ? double.PositiveInfinity : result;
        }
    }
}
