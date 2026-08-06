namespace DiskInventoryZed.Windows.Controls;

internal static class VisualizationRenderBudget
{
    internal const int Minimum = 64;
    internal const int Maximum = 2048;

    public static int ForTreemap(double width, double height) =>
        Clamp(Math.Ceiling(Math.Max(0, width) * Math.Max(0, height) / 256));

    public static int ForSunburst(double radius, int depth) =>
        Clamp(Math.Ceiling(Math.PI * 2 * Math.Max(0, radius) * Math.Max(1, depth) / 4));

    private static int Clamp(double value) =>
        (int)Math.Clamp(value, Minimum, Maximum);
}
