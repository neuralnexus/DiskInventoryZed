using System.Text.Json;
using System.IO;

namespace DiskInventoryZed.Windows.Services;

public sealed class AppSettings
{
    public string? LastScanPath { get; set; }
    public bool SkipDeveloperFolders { get; set; }
    public bool ShowHiddenFiles { get; set; }
    public bool FollowReparsePoints { get; set; }
    public long MinimumSize { get; set; }
}

public sealed class AppSettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private readonly string _settingsPath;

    public AppSettingsStore()
    {
        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DiskInventoryZed");
        _settingsPath = Path.Combine(directory, "settings.json");
    }

    public AppSettings Load()
    {
        try
        {
            return File.Exists(_settingsPath)
                ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(_settingsPath), JsonOptions) ?? new AppSettings()
                : new AppSettings();
        }
        catch
        {
            return new AppSettings();
        }
    }

    public void Save(AppSettings settings)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_settingsPath)!);
            var temporaryPath = _settingsPath + ".tmp";
            File.WriteAllText(temporaryPath, JsonSerializer.Serialize(settings, JsonOptions));
            File.Move(temporaryPath, _settingsPath, true);
        }
        catch
        {
            // Settings must never prevent scanning or closing the application.
        }
    }
}
