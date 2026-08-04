using System.Collections.Concurrent;
using System.Windows.Media;
using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Windows.Controls;

public static class FileTypePalette
{
    private static readonly ConcurrentDictionary<(Color Color, byte Opacity), SolidColorBrush> Brushes = new();
    private static readonly string[] FolderColors = ["#367FC2", "#31A778", "#D17A35", "#B44784", "#7654C8"];

    public static SolidColorBrush BrushFor(FileNode node, double opacity = 1) => node.IsDirectory
        ? CachedBrush(
            Parse(FolderColors[(int)(StableHash(node.FullPath) % (ulong)FolderColors.Length)]),
            opacity)
        : BrushForExtension(node.Extension ?? "unknown", opacity);

    public static SolidColorBrush BrushForExtension(string extension, double opacity = 1)
    {
        var normalized = extension.ToLowerInvariant();
        var color = normalized switch
        {
            "jpg" or "jpeg" or "png" or "gif" or "bmp" or "tiff" or "heic" or "webp" or "svg" or "ico" => Color.FromRgb(66, 154, 224),
            "mp4" or "mov" or "avi" or "mkv" or "wmv" or "webm" or "m4v" or "mpg" or "mpeg" => Color.FromRgb(224, 72, 108),
            "mp3" or "aac" or "wav" or "flac" or "m4a" or "ogg" or "wma" or "aiff" => Color.FromRgb(133, 91, 224),
            "pdf" => Color.FromRgb(231, 130, 61),
            "doc" or "docx" or "txt" or "rtf" or "md" or "tex" => Color.FromRgb(62, 194, 119),
            "xls" or "xlsx" or "csv" => Color.FromRgb(57, 207, 139),
            "ppt" or "pptx" => Color.FromRgb(222, 174, 63),
            "zip" or "rar" or "7z" or "tar" or "gz" or "bz2" or "xz" => Color.FromRgb(135, 145, 157),
            "exe" or "dll" or "msi" or "sys" => Color.FromRgb(179, 113, 220),
            "cs" or "swift" or "c" or "cpp" or "h" or "py" or "js" or "ts" or "rb" or "go" or "rs" or "java" or "html" or "css" or "xml" or "json" or "yaml" or "toml" => Color.FromRgb(66, 170, 218),
            "unknown" => Color.FromRgb(112, 126, 141),
            _ => HsvToColor(StableHash(normalized) % 360, 0.58, 0.84)
        };
        return CachedBrush(color, opacity);
    }

    private static SolidColorBrush CachedBrush(Color color, double opacity)
    {
        if (double.IsNaN(opacity))
        {
            opacity = 1;
        }
        var normalizedOpacity = (byte)Math.Round(Math.Clamp(opacity, 0, 1) * byte.MaxValue);
        return Brushes.GetOrAdd((color, normalizedOpacity), static key =>
        {
            var brush = new SolidColorBrush(key.Color) { Opacity = key.Opacity / (double)byte.MaxValue };
            brush.Freeze();
            return brush;
        });
    }

    private static Color Parse(string value) => (Color)ColorConverter.ConvertFromString(value);

    private static ulong StableHash(string value)
    {
        const ulong offset = 14_695_981_039_346_656_037;
        const ulong prime = 1_099_511_628_211;
        var hash = offset;
        foreach (var character in System.Text.Encoding.UTF8.GetBytes(value))
        {
            hash ^= character;
            hash *= prime;
        }

        return hash;
    }

    private static Color HsvToColor(ulong hue, double saturation, double value)
    {
        var h = hue / 60d;
        var chroma = value * saturation;
        var x = chroma * (1 - Math.Abs(h % 2 - 1));
        var offset = value - chroma;
        var (r, g, b) = h switch
        {
            < 1 => (chroma, x, 0d),
            < 2 => (x, chroma, 0d),
            < 3 => (0d, chroma, x),
            < 4 => (0d, x, chroma),
            < 5 => (x, 0d, chroma),
            _ => (chroma, 0d, x)
        };
        return Color.FromRgb(
            (byte)Math.Round((r + offset) * 255),
            (byte)Math.Round((g + offset) * 255),
            (byte)Math.Round((b + offset) * 255));
    }
}
