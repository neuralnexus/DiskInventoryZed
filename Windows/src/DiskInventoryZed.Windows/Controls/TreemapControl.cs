using System.Globalization;
using System.Windows;
using System.Windows.Media;
using DiskInventoryZed.Core.Layout;
using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Windows.Controls;

public sealed class TreemapControl : FileVisualizationControl
{
    private IReadOnlyList<TreemapItem> _items = [];
    private FileNode? _layoutNode;
    private long _layoutMinimumSize = -1;
    private Size _layoutSize;

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);
        drawingContext.DrawRectangle(new SolidColorBrush(Color.FromRgb(10, 14, 19)), null, new Rect(RenderSize));
        EnsureLayout();
        var pixelsPerDip = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        foreach (var item in _items)
        {
            var rectangle = new Rect(
                item.Rectangle.X,
                item.Rectangle.Y,
                item.Rectangle.Width,
                item.Rectangle.Height);
            var opacity = IsDimmed(item.Node) ? (item.Node.IsDirectory ? 0.3 : 0.12) : (item.Node.IsDirectory ? 0.72 : 1);
            var brush = FileTypePalette.BrushFor(item.Node, opacity);
            var border = new Pen(new SolidColorBrush(Color.FromArgb(item.Node.IsDirectory ? (byte)130 : (byte)55, 255, 255, 255)),
                item.Node.IsDirectory ? 1.2 : 0.5);
            border.Freeze();
            drawingContext.DrawRectangle(brush, border, rectangle);

            if (rectangle.Width <= 72 || rectangle.Height <= 25 || opacity < 0.2)
            {
                continue;
            }

            var text = new FormattedText(
                item.Node.DisplayName,
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
                return _items[index].Node;
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
        _items = TreemapLayout.Calculate(Node, ActualWidth, ActualHeight, MinimumSize);
    }
}
