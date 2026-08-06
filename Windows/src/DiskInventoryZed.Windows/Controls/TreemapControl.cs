using System.Globalization;
using System.Windows;
using System.Windows.Media;
using DiskInventoryZed.Core.Layout;
using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Windows.Controls;

public sealed class TreemapControl : FileVisualizationControl
{
    private static readonly SolidColorBrush BackgroundBrush = FrozenBrush(Color.FromRgb(10, 14, 19));
    private static readonly SolidColorBrush AggregateBrush = FrozenBrush(Color.FromRgb(91, 105, 119));
    private static readonly Pen DirectoryBorder = FrozenPen(Color.FromArgb(130, 255, 255, 255), 1.2);
    private static readonly Pen FileBorder = FrozenPen(Color.FromArgb(55, 255, 255, 255), 0.5);
    private IReadOnlyList<TreemapItem> _items = [];
    private FileNode? _layoutNode;
    private long _layoutMinimumSize = -1;
    private Size _layoutSize;

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);
        drawingContext.DrawRectangle(BackgroundBrush, null, new Rect(RenderSize));
        EnsureLayout();
        var pixelsPerDip = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        foreach (var item in _items)
        {
            var node = (item.Content as LayoutContent.Node)?.Value;
            var rectangle = new Rect(
                item.Rectangle.X,
                item.Rectangle.Y,
                item.Rectangle.Width,
                item.Rectangle.Height);
            var opacity = node is null
                ? 1
                : IsDimmed(node) ? (node.IsDirectory ? 0.3 : 0.12) : (node.IsDirectory ? 0.72 : 1);
            var brush = node is null ? AggregateBrush : FileTypePalette.BrushFor(node, opacity);
            var border = node?.IsDirectory == true ? DirectoryBorder : FileBorder;
            drawingContext.DrawRectangle(brush, border, rectangle);

            if (rectangle.Width <= 72 || rectangle.Height <= 25 || opacity < 0.2)
            {
                continue;
            }

            var text = new FormattedText(
                node?.DisplayName ?? $"Other ({((LayoutContent.Aggregate)item.Content).ItemCount:N0} items)",
                CultureInfo.CurrentUICulture,
                System.Windows.FlowDirection.LeftToRight,
                new Typeface("Segoe UI Semibold"),
                10,
                Brushes.White,
                pixelsPerDip)
            {
                MaxTextWidth = Math.Max(1, rectangle.Width - 8),
                MaxTextHeight = Math.Max(1, rectangle.Height - 4),
                Trimming = TextTrimming.CharacterEllipsis
            };
            drawingContext.DrawText(text, new Point(rectangle.X + 4, rectangle.Y + 3));
        }
    }

    protected override FileNode? HitTestNode(Point point)
    {
        EnsureLayout();
        for (var index = _items.Count - 1; index >= 0; index--)
        {
            if (_items[index].Rectangle.Contains(point.X, point.Y))
            {
                return (_items[index].Content as LayoutContent.Node)?.Value;
            }
        }

        return null;
    }

    protected override void ResetLayout()
    {
        _layoutNode = null;
        _items = [];
    }

    private void EnsureLayout()
    {
        if (Node is null || ActualWidth <= 1 || ActualHeight <= 1)
        {
            _items = [];
            _layoutNode = null;
            _layoutMinimumSize = -1;
            _layoutSize = default;
            return;
        }

        var size = new Size(ActualWidth, ActualHeight);
        if (ReferenceEquals(Node, _layoutNode) && _layoutMinimumSize == MinimumSize && size == _layoutSize)
        {
            return;
        }

        _layoutNode = Node;
        _layoutMinimumSize = MinimumSize;
        _layoutSize = size;
        var budget = VisualizationRenderBudget.ForTreemap(ActualWidth, ActualHeight);
        _items = TreemapLayout.Calculate(Node, ActualWidth, ActualHeight, MinimumSize, budget);
    }

    private static SolidColorBrush FrozenBrush(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    private static Pen FrozenPen(Color color, double thickness)
    {
        var pen = new Pen(FrozenBrush(color), thickness);
        pen.Freeze();
        return pen;
    }
}
