using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace DiskInventoryZed.Windows.Services;

internal sealed class AppDiagnostics
{
    private const int DefaultMaximumLogBytes = 512 * 1024;
    private static readonly Lazy<Mutex?> DiagnosticsMutex = new(CreateDiagnosticsMutex);
    private readonly object _gate = new();
    private readonly string _directory;
    private readonly string _logPath;
    private readonly string _previousLogPath;
    private readonly int _maximumLogBytes;
    private string? _ownedSessionMarkerPath;
    private bool _started;

    public AppDiagnostics(string? directory = null, int maximumLogBytes = DefaultMaximumLogBytes)
    {
        if (maximumLogBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumLogBytes));
        }

        _directory = directory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DiskInventoryZed");
        _logPath = Path.Combine(_directory, "diagnostics.jsonl");
        _previousLogPath = Path.Combine(_directory, "diagnostics.previous.jsonl");
        _maximumLogBytes = maximumLogBytes;
    }

    internal string LogPath => _logPath;

    public bool StartSession()
    {
        lock (_gate)
        {
            if (_started)
            {
                return false;
            }

            string? markerPath = null;
            var previousSessionWasUnclean = false;
            try
            {
                Directory.CreateDirectory(_directory);
                foreach (var existingMarker in Directory.EnumerateFiles(_directory, "session-*.active"))
                {
                    if (IsLiveSession(existingMarker))
                    {
                        continue;
                    }

                    previousSessionWasUnclean = true;
                    TryDelete(existingMarker);
                }

                using var process = Process.GetCurrentProcess();
                var processStartTime = process.StartTime.ToUniversalTime().Ticks;
                markerPath = Path.Combine(
                    _directory,
                    $"session-{Environment.ProcessId}-{Guid.NewGuid():N}.active");
                var temporaryMarker = markerPath + ".tmp";
                File.WriteAllText(
                    temporaryMarker,
                    $"{Environment.ProcessId}:{processStartTime}",
                    Encoding.ASCII);
                File.Move(temporaryMarker, markerPath, false);
                _ownedSessionMarkerPath = markerPath;
                _started = true;
            }
            catch
            {
                if (markerPath is not null)
                {
                    TryDelete(markerPath);
                    TryDelete(markerPath + ".tmp");
                }
                _ownedSessionMarkerPath = null;
                _started = false;
                return false;
            }

            TryWriteEvent(previousSessionWasUnclean ? "previous-session-unclean" : "session-started", null);
            return previousSessionWasUnclean;
        }
    }

    public void Record(string eventCode, Exception? error = null)
    {
        lock (_gate)
        {
            try
            {
                Directory.CreateDirectory(_directory);
                TryWriteEvent(eventCode, error);
            }
            catch
            {
                // Diagnostics must never become another application failure.
            }
        }
    }

    public void MarkCleanShutdown()
    {
        lock (_gate)
        {
            if (!_started)
            {
                return;
            }

            TryWriteEvent("session-ended", null);
            if (_ownedSessionMarkerPath is not null)
            {
                TryDelete(_ownedSessionMarkerPath);
            }
            _ownedSessionMarkerPath = null;
            _started = false;
        }
    }

    private void TryWriteEvent(string eventCode, Exception? error)
    {
        var diagnosticsMutex = DiagnosticsMutex.Value;
        if (diagnosticsMutex is null)
        {
            return;
        }

        var lockTaken = false;
        try
        {
            try
            {
                lockTaken = diagnosticsMutex.WaitOne(TimeSpan.FromMilliseconds(100));
            }
            catch (AbandonedMutexException)
            {
                lockTaken = true;
            }
            if (!lockTaken)
            {
                return;
            }

            WriteEvent(eventCode, error);
        }
        catch
        {
            // Diagnostics must never become another application failure.
        }
        finally
        {
            if (lockTaken)
            {
                try
                {
                    diagnosticsMutex.ReleaseMutex();
                }
                catch
                {
                    // A diagnostics lock failure must not escape into the application.
                }
            }
        }
    }

    private static Mutex? CreateDiagnosticsMutex()
    {
        try
        {
            return new Mutex(false, @"Local\DiskInventoryZed.Diagnostics");
        }
        catch
        {
            return null;
        }
    }

    private void WriteEvent(string eventCode, Exception? error)
    {
        var version = typeof(AppDiagnostics).Assembly.GetName().Version;
        var entry = new
        {
            timestampUtc = DateTimeOffset.UtcNow,
            eventCode,
            productVersion = version is null ? "unknown" : $"{version.Major}.{version.Minor}.{version.Build}",
            architecture = RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant(),
            processId = Environment.ProcessId,
            exceptionType = error?.GetType().FullName,
            hresult = error is null ? null : $"0x{error.HResult:x8}"
        };
        var line = JsonSerializer.Serialize(entry) + Environment.NewLine;
        if (File.Exists(_logPath) &&
            new FileInfo(_logPath).Length + Encoding.UTF8.GetByteCount(line) > _maximumLogBytes)
        {
            File.Move(_logPath, _previousLogPath, true);
        }
        File.AppendAllText(
            _logPath,
            line,
            new UTF8Encoding(false));
    }

    private static bool IsLiveSession(string markerPath)
    {
        try
        {
            var fields = File.ReadAllText(markerPath, Encoding.ASCII).Split(':');
            if (fields.Length != 2 ||
                !int.TryParse(fields[0], out var processId) ||
                !long.TryParse(fields[1], out var processStartTime))
            {
                return false;
            }

            using var process = Process.GetProcessById(processId);
            return !process.HasExited &&
                   process.StartTime.ToUniversalTime().Ticks == processStartTime;
        }
        catch (Exception error) when (
            error is ArgumentException or InvalidOperationException or IOException or
                UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch
        {
            // Stale diagnostics markers are best-effort cleanup only.
        }
    }
}
