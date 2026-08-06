using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Core.Layout;

public readonly record struct RectD(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
    public double Area => Math.Max(0, Width) * Math.Max(0, Height);
    public bool Contains(double x, double y) => x >= X && x <= Right && y >= Y && y <= Bottom;
    public RectD Inset(double amount) => new(
        X + amount,
        Y + amount,
        Math.Max(0, Width - amount * 2),
        Math.Max(0, Height - amount * 2));
}

public abstract record LayoutContent(long AllocatedSize)
{
    public sealed record Node(FileNode Value) : LayoutContent(Value.AllocatedSize);
    public sealed record Aggregate(long Size, int ItemCount) : LayoutContent(Size);
}

public sealed record TreemapItem(LayoutContent Content, RectD Rectangle, int Depth);

public sealed record SunburstSlice(
    LayoutContent Content,
    double StartAngle,
    double EndAngle,
    double InnerRadius,
    double OuterRadius,
    int Depth);
