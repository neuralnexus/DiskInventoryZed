using System.IO;
using System.Text.Json;
using DiskInventoryZed.Windows.Services;

namespace DiskInventoryZed.Windows.Tests;

public sealed class AppDiagnosticsTests
{
    [Fact]
    public void ConcurrentSessionsDoNotReportEachOtherAsUnclean()
    {
        using var fixture = new TemporaryDirectory();
        var first = new AppDiagnostics(fixture.Path);
        Assert.False(first.StartSession());

        var second = new AppDiagnostics(fixture.Path);
        Assert.False(second.StartSession());
        second.MarkCleanShutdown();
        first.MarkCleanShutdown();

        var third = new AppDiagnostics(fixture.Path);
        Assert.False(third.StartSession());
        third.MarkCleanShutdown();
    }

    [Fact]
    public void DeadSessionIsDetectedAndItsMarkerIsRemoved()
    {
        using var fixture = new TemporaryDirectory();
        var staleMarker = Path.Combine(fixture.Path, "session-2147483647-stale.active");
        File.WriteAllText(staleMarker, "2147483647:0");

        var diagnostics = new AppDiagnostics(fixture.Path);
        Assert.True(diagnostics.StartSession());
        diagnostics.MarkCleanShutdown();

        Assert.False(File.Exists(staleMarker));
        var log = File.ReadAllText(diagnostics.LogPath);
        Assert.Contains("previous-session-unclean", log, StringComparison.Ordinal);
        Assert.Contains("session-ended", log, StringComparison.Ordinal);
    }

    [Fact]
    public void ExceptionMessagesAndPathsAreNotPersisted()
    {
        using var fixture = new TemporaryDirectory();
        var diagnostics = new AppDiagnostics(fixture.Path);
        diagnostics.StartSession();
        diagnostics.Record("scan-failed", new IOException("Sensitive C:\\Users\\person\\private.txt"));
        diagnostics.MarkCleanShutdown();

        var log = File.ReadAllText(diagnostics.LogPath);
        Assert.Contains("scan-failed", log, StringComparison.Ordinal);
        Assert.Contains(typeof(IOException).FullName!, log, StringComparison.Ordinal);
        Assert.DoesNotContain("Sensitive", log, StringComparison.Ordinal);
        Assert.DoesNotContain("private.txt", log, StringComparison.Ordinal);
    }

    [Fact]
    public void LogRotationKeepsOnlyOneBoundedPreviousFile()
    {
        using var fixture = new TemporaryDirectory();
        var diagnostics = new AppDiagnostics(fixture.Path, maximumLogBytes: 512);
        diagnostics.StartSession();
        for (var index = 0; index < 10; index++)
        {
            diagnostics.Record("bounded-event");
        }

        diagnostics.MarkCleanShutdown();

        var previousPath = Path.Combine(fixture.Path, "diagnostics.previous.jsonl");
        Assert.True(File.Exists(previousPath));
        Assert.InRange(new FileInfo(previousPath).Length, 1, 512);
        Assert.InRange(new FileInfo(diagnostics.LogPath).Length, 1, 512);
    }

    [Fact]
    public async Task ConcurrentInstancesWriteCompleteJsonLines()
    {
        using var fixture = new TemporaryDirectory();
        var first = new AppDiagnostics(fixture.Path);
        var second = new AppDiagnostics(fixture.Path);
        first.StartSession();
        second.StartSession();

        await Task.WhenAll(
            Task.Run(() => RecordEvents(first, "first")),
            Task.Run(() => RecordEvents(second, "second")));
        first.MarkCleanShutdown();
        second.MarkCleanShutdown();

        var lines = File.ReadAllLines(first.LogPath);
        Assert.NotEmpty(lines);
        foreach (var line in lines)
        {
            using var document = JsonDocument.Parse(line);
            Assert.Equal(JsonValueKind.Object, document.RootElement.ValueKind);
        }

        static void RecordEvents(AppDiagnostics diagnostics, string prefix)
        {
            for (var index = 0; index < 50; index++)
            {
                diagnostics.Record($"{prefix}-event");
            }
        }
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public TemporaryDirectory()
        {
            Path = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                $"DiskInventoryZedDiagnosticsTests-{Guid.NewGuid():N}");
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public void Dispose()
        {
            try
            {
                Directory.Delete(Path, true);
            }
            catch
            {
                // Best-effort test cleanup.
            }
        }
    }
}
