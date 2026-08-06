using System.IO;
using DiskInventoryZed.Windows.Services;

namespace DiskInventoryZed.Windows.Tests;

public sealed class AppSettingsStoreTests
{
    [Fact]
    public void MalformedSettingsFailToSafeDefaults()
    {
        using var fixture = new TemporaryDirectory();
        var path = Path.Combine(fixture.Path, "settings.json");
        File.WriteAllText(path, "{not-json");

        var settings = new AppSettingsStore(path).Load();

        Assert.Null(settings.LastScanPath);
        Assert.False(settings.FollowReparsePoints);
        Assert.False(settings.ShowHiddenFiles);
    }

    [Fact]
    public void SaveAtomicallyReplacesSettingsWithoutLeavingTemporaryFile()
    {
        using var fixture = new TemporaryDirectory();
        var path = Path.Combine(fixture.Path, "settings.json");
        var store = new AppSettingsStore(path);
        store.Save(new AppSettings { LastScanPath = "C:\\first" });

        store.Save(new AppSettings { LastScanPath = "C:\\second", ShowHiddenFiles = true });

        var loaded = store.Load();
        Assert.Equal("C:\\second", loaded.LastScanPath);
        Assert.True(loaded.ShowHiddenFiles);
        Assert.False(File.Exists(path + ".tmp"));
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public TemporaryDirectory()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"DiskInventoryZedSettingsTests-{Guid.NewGuid():N}");
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
