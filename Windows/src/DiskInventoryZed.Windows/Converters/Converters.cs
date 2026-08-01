using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;
using DiskInventoryZed.Core.Analysis;
using DiskInventoryZed.Core.Models;
using DiskInventoryZed.Windows.Controls;

namespace DiskInventoryZed.Windows.Converters;

public sealed class InverseBooleanToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is not Visibility.Visible;
}

public sealed class FileTypeBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value switch
    {
        FileNode node => FileTypePalette.BrushFor(node),
        ExtensionStat stat => FileTypePalette.BrushForExtension(stat.Extension),
        _ => Brushes.Gray
    };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        Binding.DoNothing;
}

public sealed class NodeGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value switch
    {
        FileNode { IsSymbolicLink: true } => "↗",
        FileNode { IsDirectory: true } => "▰",
        FileNode => "▪",
        _ => "▪"
    };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        Binding.DoNothing;
}
