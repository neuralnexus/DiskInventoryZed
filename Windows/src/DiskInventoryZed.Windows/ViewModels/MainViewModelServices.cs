using DiskInventoryZed.Core.Analysis;
using DiskInventoryZed.Core.Models;
using DiskInventoryZed.Core.Scanning;
using DiskInventoryZed.Windows.Services;

namespace DiskInventoryZed.Windows.ViewModels;

internal sealed record VisibleItemsResult(IReadOnlyList<FileNode> Items, int Total);

internal sealed record MainViewModelServices(
    Func<string, ScanOptions, IProgress<ScanProgress>?, CancellationToken, DiskScanOperation> StartScan,
    Func<FileNode, CancellationToken, Task<ScanAnalysis>> AnalyzeAsync,
    Func<IReadOnlyList<DuplicateCandidate>, IProgress<DuplicateVerificationProgress>?, CancellationToken, Task<DuplicateVerificationResult>> VerifyDuplicatesAsync,
    Func<FileNode, ScanAnalysis?, string, string?, long, FileSortOrder, CancellationToken, VisibleItemsResult> FilterVisibleItems,
    Func<TimeSpan, CancellationToken, Task> DelayAsync,
    Func<AppSettings> LoadSettings,
    Action<AppSettings> SaveSettings)
{
    public static MainViewModelServices CreateDefault()
    {
        var settingsStore = new AppSettingsStore();
        return new MainViewModelServices(
            (path, options, progress, cancellationToken) =>
                new DiskScanner().StartScan(path, options, progress, cancellationToken),
            (root, cancellationToken) =>
                Task.FromResult(ScanAnalyzer.Analyze(root, cancellationToken)),
            DuplicateVerifier.VerifyAsync,
            VisibleItemsFilter.Apply,
            Task.Delay,
            settingsStore.Load,
            settingsStore.Save);
    }
}
