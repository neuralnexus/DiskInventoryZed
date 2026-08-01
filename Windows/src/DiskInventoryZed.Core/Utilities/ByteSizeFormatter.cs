namespace DiskInventoryZed.Core.Utilities;

public static class ByteSizeFormatter
{
    private static readonly string[] Units = ["bytes", "KB", "MB", "GB", "TB", "PB"];

    public static string Format(long bytes)
    {
        bytes = Math.Max(0, bytes);
        var value = (double)bytes;
        var unit = 0;
        while (value >= 1000 && unit < Units.Length - 1)
        {
            value /= 1000;
            unit++;
        }

        if (unit == 0)
        {
            return $"{bytes:N0} {Units[unit]}";
        }

        return value >= 100 ? $"{value:N0} {Units[unit]}" : $"{value:N1} {Units[unit]}";
    }
}
