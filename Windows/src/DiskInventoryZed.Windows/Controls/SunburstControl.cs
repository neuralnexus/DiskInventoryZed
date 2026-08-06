using System.Globalization;
using System.Windows;
using System.Windows.Media;
using DiskInventoryZed.Core.Layout;
using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Windows.Controls;

public sealed class SunburstControl : FileVisualizationControl
{
    private static readonly SolidColorBrush BackgroundBrush = FrozenBrush(Color.FromRgb(10, 14, 19));
    private static readonly SolidColorBrush AggregateBrush = FrozenBrush(Color.FromRgb(91, 105, 119));
    private static readonly SolidColorBrush CenterBrush = FrozenBrush(Color.FromRgb(23, 31, 41));
    private static readonly SolidColorBrush SecondaryTextBrush = FrozenBrush(Color.FromRgb(149, 163, 179));
    private static readonly Pen SliceBorder = FrozenPen(Color.FromArgb(70, 5, 8, 12), 0.65);
    private static readonly Pen CenterBorder = FrozenPen(Color.FromRgb(49, 63, 77), 1);
    private IReadOnlyList<SunburstSlice> _slices = [];
    private FileNode? _layoutNode;
    private long _layoutMinimumSize = -1;
    private Size _layoutSize;
    private Point _center;

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);
        drawingContext.DrawRectangle(BackgroundBrush, null, new Rect(RenderSize));
        EnsureLayout();
        if (Node is null)
        {
            return;
        }

        foreach (var slice in _slices)
        {
            var node = (slice.Content as LayoutContent.Node)?.Value;
            var opacity = node is not null && IsDimmed(node) ? 0.12 : 1;
            var geometry = CreateSliceGeometry(_center, slice);
            var brush = node is null ? AggregateBrush : FileTypePalette.BrushFor(node, opacity);
            drawingContext.DrawGeometry(brush, SliceBorder, geometry);
        }

        var centerRadius = _slices.Count == 0 ? 48 : _slices.Min(slice => slice.InnerRadius) - 4;
        drawingContext.DrawEllipse(
            CenterBrush,
            CenterBorder,
            _center,
            centerRadius,
            centerRadius);
        DrawCenterLabel(drawingContext, centerRadius);
        DrawSliceLabels(drawingContext);
    }

    protected override FileNode? HitTestNode(Point point)
    {
        EnsureLayout();
        var dx = point.X - _center.X;
        var dy = point.Y - _center.Y;
        var distance = Math.Sqrt(dx * dx + dy * dy);
        var angle = Math.Atan2(dy, dx);
        if (angle < 0)
        {
            angle += Math.PI * 2;
        }

        for (var index = _slices.Count - 1; index >= 0; index--)
        {
            var slice = _slices[index];
            if (distance >= slice.InnerRadius && distance <= slice.OuterRadius &&
                angle >= slice.StartAngle && angle <= slice.EndAngle)
            {
                return (slice.Content as LayoutContent.Node)?.Value;
            }
        }

        return null;
    }

    protected override void ResetLayout()
    {
        _layoutNode = null;
        _slices = [];
    }

    private void EnsureLayout()
    {
        _center = new Point(ActualWidth / 2, ActualHeight / 2);
        if (Node is null || ActualWidth <= 1 || ActualHeight <= 1)
        {
            _slices = [];
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
        var radius = Math.Max(10, Math.Min(ActualWidth, ActualHeight) / 2 - 22);
        var depth = radius > 330 ? 7 : radius > 230 ? 6 : 5;
        var budget = VisualizationRenderBudget.ForSunburst(radius, depth);
        _slices = SunburstLayout.Calculate(Node, radius, MinimumSize, depth, budget);
    }

    private static Geometry CreateSliceGeometry(Point center, SunburstSlice slice)
    {
        var endAngle = Math.Min(slice.EndAngle, slice.StartAngle + Math.PI * 2 - 0.00001);
        var span = endAngle - slice.StartAngle;
        var outerStart = PolarPoint(center, slice.OuterRadius, slice.StartAngle);
        var outerEnd = PolarPoint(center, slice.OuterRadius, endAngle);
        var innerEnd = PolarPoint(center, slice.InnerRadius, endAngle);
        var innerStart = PolarPoint(center, slice.InnerRadius, slice.StartAngle);

        var geometry = new StreamGeometry();
        using (var context = geometry.Open())
        {
            context.BeginFigure(outerStart, true, true);
            context.ArcTo(outerEnd, new Size(slice.OuterRadius, slice.OuterRadius), 0, span > Math.PI,
                SweepDirection.Clockwise, true, false);
            context.LineTo(innerEnd, true, false);
            context.ArcTo(innerStart, new Size(slice.InnerRadius, slice.InnerRadius), 0, span > Math.PI,
                SweepDirection.Counterclockwise, true, false);
        }

        geometry.Freeze();
        return geometry;
    }

    private void DrawCenterLabel(DrawingContext drawingContext, double centerRadius)
    {
        if (Node is null)
        {
            return;
        }

        var pixelsPerDip = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var name = new FormattedText(
            Node.DisplayName,
            CultureInfo.CurrentUICulture,
            System.Windows.FlowDirection.LeftToRight,
            new Typeface("Segoe UI Semibold"),
            11,
            Brushes.White,
            pixelsPerDip)
        {
            MaxTextWidth = Math.Max(30, centerRadius * 1.55),
            MaxLineCount = 2,
            TextAlignment = TextAlignment.Center,
            Trimming = TextTrimming.CharacterEllipsis
        };
        drawingContext.DrawText(name, new Point(_center.X - name.MaxTextWidth / 2, _center.Y - name.Height / 2 - 7));

        var size = new FormattedText(
            Node.FormattedSize,
            CultureInfo.CurrentUICulture,
            System.Windows.FlowDirection.LeftToRight,
            new Typeface("Segoe UI"),
            9,
            SecondaryTextBrush,
            pixelsPerDip);
        drawingContext.DrawText(size, new Point(_center.X - size.Width / 2, _center.Y + 14));
    }

    private void DrawSliceLabels(DrawingContext drawingContext)
    {
        var pixelsPerDip = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        foreach (var slice in _slices)
        {
            var node = (slice.Content as LayoutContent.Node)?.Value;
            var span = slice.EndAngle - slice.StartAngle;
            var middleRadius = (slice.InnerRadius + slice.OuterRadius) / 2;
            var arcLength = span * middleRadius;
            if (arcLength < 55 || slice.OuterRadius - slice.InnerRadius < 18 || node is not null && IsDimmed(node))
            {
                continue;
            }

            var position = PolarPoint(_center, middleRadius, (slice.StartAngle + slice.EndAngle) / 2);
            var text = new FormattedText(
                node?.DisplayName ?? $"Other ({((LayoutContent.Aggregate)slice.Content).ItemCount:N0} items)",
                CultureInfo.CurrentUICulture,
                System.Windows.FlowDirection.LeftToRight,
                new Typeface("Segoe UI Semibold"),
                8.5,
                Brushes.White,
                pixelsPerDip)
            {
                MaxTextWidth = Math.Min(100, arcLength - 5),
                Trimming = TextTrimming.CharacterEllipsis,
                TextAlignment = TextAlignment.Center
            };
            drawingContext.DrawText(text, new Point(position.X - text.MaxTextWidth / 2, position.Y - text.Height / 2));
        }
    }

    private static Point PolarPoint(Point center, double radius, double angle) =>
        new(center.X + Math.Cos(angle) * radius, center.Y + Math.Sin(angle) * radius);

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
