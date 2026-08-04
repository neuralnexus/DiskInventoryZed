using System.Windows.Media;
using DiskInventoryZed.Windows.Controls;

namespace DiskInventoryZed.Windows.Tests;

public sealed class FileTypePaletteTests
{
    [Fact]
    public void ArbitraryExtensionsReuseTheBoundedColorPalette()
    {
        var brushes = new HashSet<SolidColorBrush>(ReferenceEqualityComparer.Instance);

        for (var index = 0; index < 10_000; index++)
        {
            brushes.Add(FileTypePalette.BrushForExtension($"custom-extension-{index}"));
        }

        Assert.InRange(brushes.Count, 1, 360);
        Assert.All(brushes, brush => Assert.True(brush.IsFrozen));
    }
}
