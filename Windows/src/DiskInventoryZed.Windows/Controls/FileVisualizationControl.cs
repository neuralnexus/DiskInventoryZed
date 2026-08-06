using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Windows.Controls;

public sealed class FileNodeEventArgs(FileNode node) : EventArgs
{
    public FileNode Node { get; } = node;
}

public abstract class FileVisualizationControl : FrameworkElement
{
    public static readonly DependencyProperty NodeProperty = DependencyProperty.Register(
        nameof(Node),
        typeof(FileNode),
        typeof(FileVisualizationControl),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender, OnVisualizationPropertyChanged));

    public static readonly DependencyProperty MinimumSizeProperty = DependencyProperty.Register(
        nameof(MinimumSize),
        typeof(long),
        typeof(FileVisualizationControl),
        new FrameworkPropertyMetadata(0L, FrameworkPropertyMetadataOptions.AffectsRender, OnVisualizationPropertyChanged));

    public static readonly DependencyProperty SearchTextProperty = DependencyProperty.Register(
        nameof(SearchText),
        typeof(string),
        typeof(FileVisualizationControl),
        new FrameworkPropertyMetadata(string.Empty, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty SelectedExtensionProperty = DependencyProperty.Register(
        nameof(SelectedExtension),
        typeof(string),
        typeof(FileVisualizationControl),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    protected FileVisualizationControl()
    {
        Focusable = true;
        ToolTipService.SetInitialShowDelay(this, 120);
        ToolTipService.SetShowDuration(this, 60_000);
        ToolTipService.SetBetweenShowDelay(this, 0);
    }

    public FileNode? Node
    {
        get => (FileNode?)GetValue(NodeProperty);
        set => SetValue(NodeProperty, value);
    }

    public long MinimumSize
    {
        get => (long)GetValue(MinimumSizeProperty);
        set => SetValue(MinimumSizeProperty, value);
    }

    public string SearchText
    {
        get => (string)GetValue(SearchTextProperty);
        set => SetValue(SearchTextProperty, value);
    }

    public string? SelectedExtension
    {
        get => (string?)GetValue(SelectedExtensionProperty);
        set => SetValue(SelectedExtensionProperty, value);
    }

    public event EventHandler<FileNodeEventArgs>? NodeInvoked;
    public event EventHandler<FileNodeEventArgs>? NodeSelected;

    protected abstract FileNode? HitTestNode(Point point);

    protected virtual void ResetLayout()
    {
    }

    protected bool IsDimmed(FileNode node)
    {
        if (!string.IsNullOrWhiteSpace(SelectedExtension))
        {
            if (node.IsDirectory)
            {
                return true;
            }

            var extension = node.Extension ?? "unknown";
            return !extension.Equals(SelectedExtension, StringComparison.OrdinalIgnoreCase);
        }

        var query = SearchText?.Trim();
        return !string.IsNullOrEmpty(query) &&
               !node.DisplayName.Contains(query, StringComparison.CurrentCultureIgnoreCase) &&
               !node.FullPath.Contains(query, StringComparison.CurrentCultureIgnoreCase);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var node = HitTestNode(e.GetPosition(this));
        Cursor = node is null ? Cursors.Arrow : Cursors.Hand;
        ToolTip = node is null
            ? null
            : $"{node.DisplayName}\n{node.FormattedSize}" +
              (node.IsDirectory ? $"\n{node.Children.Count:N0} immediate items" : string.Empty);
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        if (HitTestNode(e.GetPosition(this)) is not { } node)
        {
            return;
        }

        NodeSelected?.Invoke(this, new FileNodeEventArgs(node));
        if (node.IsDirectory)
        {
            NodeInvoked?.Invoke(this, new FileNodeEventArgs(node));
        }
    }

    protected override void OnMouseRightButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseRightButtonDown(e);
        if (HitTestNode(e.GetPosition(this)) is { } node)
        {
            NodeSelected?.Invoke(this, new FileNodeEventArgs(node));
        }
    }

    protected override void OnContextMenuOpening(ContextMenuEventArgs e)
    {
        if (HitTestNode(Mouse.GetPosition(this)) is null)
        {
            e.Handled = true;
            return;
        }

        base.OnContextMenuOpening(e);
    }

    private static void OnVisualizationPropertyChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args)
    {
        if (sender is FileVisualizationControl control)
        {
            control.ResetLayout();
            control.InvalidateVisual();
        }
    }
}
