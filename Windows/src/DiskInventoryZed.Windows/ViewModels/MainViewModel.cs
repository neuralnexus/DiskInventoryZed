using System.Collections.ObjectModel;
using System.IO;
using DiskInventoryZed.Core.Analysis;
using DiskInventoryZed.Core.Models;
using DiskInventoryZed.Core.Scanning;
using DiskInventoryZed.Core.Utilities;
using DiskInventoryZed.Windows.Services;

namespace DiskInventoryZed.Windows.ViewModels;

public enum FileSortOrder
{
    SizeDescending,
    SizeAscending,
    NameAscending,
    NameDescending
}

public sealed record Choice<T>(string Label, T Value);

public sealed record LocationItem(string Label, string Path, string Detail, bool IsNetwork = false)
{
    public string DriveBadge => IsNetwork ? "NET" : "HDD";
}

public sealed class MainViewModel : ObservableObject, IDisposable
{
    private readonly AppSettingsStore _settingsStore = new();
    private readonly AppSettings _settings;
    private readonly List<FileNode> _navigation = [];
    private CancellationTokenSource? _scanCancellation;
    private CancellationTokenSource? _filterCancellation;
    private CancellationTokenSource? _verificationCancellation;
    private ScanAnalysis? _analysis;
    private FileNode? _rootNode;
    private FileNode? _currentNode;
    private FileNode? _selectedNode;
    private DiskScanResult? _scanResult;
    private int _navigationIndex = -1;
    private bool _isScanning;
    private bool _isAnalyzing;
    private bool _isVerifying;
    private string _pathText = string.Empty;
    private string _searchText = string.Empty;
    private string _scanProgressText = string.Empty;
    private string _scanStatusPath = string.Empty;
    private string _verificationStatus = string.Empty;
    private string? _selectedExtension;
    private long _minimumSize;
    private FileSortOrder _sortOrder = FileSortOrder.SizeDescending;
    private bool _skipDeveloperFolders;
    private bool _showHiddenFiles;
    private bool _followReparsePoints;

    public MainViewModel()
    {
        _settings = _settingsStore.Load();
        _minimumSize = _settings.MinimumSize;
        _skipDeveloperFolders = _settings.SkipDeveloperFolders;
        _showHiddenFiles = _settings.ShowHiddenFiles;
        _followReparsePoints = _settings.FollowReparsePoints;
        _pathText = _settings.LastScanPath ?? string.Empty;

        MinimumSizeOptions =
        [
            new Choice<long>("All sizes", 0),
            new Choice<long>("> 1 MB", 1_000_000),
            new Choice<long>("> 10 MB", 10_000_000),
            new Choice<long>("> 100 MB", 100_000_000),
            new Choice<long>("> 1 GB", 1_000_000_000)
        ];
        SortOptions =
        [
            new Choice<FileSortOrder>("Largest first", FileSortOrder.SizeDescending),
            new Choice<FileSortOrder>("Smallest first", FileSortOrder.SizeAscending),
            new Choice<FileSortOrder>("Name A-Z", FileSortOrder.NameAscending),
            new Choice<FileSortOrder>("Name Z-A", FileSortOrder.NameDescending)
        ];
        BuildQuickLocations();
    }

    public event EventHandler<string>? ErrorRaised;

    public ObservableCollection<FileNode> RootFolders { get; } = [];
    public ObservableCollection<FileNode> Breadcrumb { get; } = [];
    public ObservableCollection<FileNode> VisibleItems { get; } = [];
    public ObservableCollection<ExtensionStat> ExtensionStats { get; } = [];
    public ObservableCollection<FileNode> LargestFiles { get; } = [];
    public ObservableCollection<FileNode> OldLargeFiles { get; } = [];
    public ObservableCollection<DuplicateCandidate> DuplicateCandidates { get; } = [];
    public ObservableCollection<VerifiedDuplicateGroup> VerifiedDuplicates { get; } = [];
    public ObservableCollection<LocationItem> QuickLocations { get; } = [];
    public ObservableCollection<LocationItem> Drives { get; } = [];
    public IReadOnlyList<Choice<long>> MinimumSizeOptions { get; }
    public IReadOnlyList<Choice<FileSortOrder>> SortOptions { get; }

    public FileNode? RootNode
    {
        get => _rootNode;
        private set
        {
            if (SetProperty(ref _rootNode, value))
            {
                OnPropertyChanged(nameof(HasScan));
                OnPropertyChanged(nameof(SummarySize));
                OnPropertyChanged(nameof(SummaryFileCount));
                OnPropertyChanged(nameof(SummaryDirectoryCount));
                OnPropertyChanged(nameof(CanRescan));
            }
        }
    }

    public FileNode? CurrentNode
    {
        get => _currentNode;
        private set
        {
            if (SetProperty(ref _currentNode, value))
            {
                OnPropertyChanged(nameof(StatusText));
                OnPropertyChanged(nameof(InspectedNode));
            }
        }
    }

    public FileNode? SelectedNode
    {
        get => _selectedNode;
        set
        {
            if (SetProperty(ref _selectedNode, value))
            {
                OnPropertyChanged(nameof(InspectedNode));
            }
        }
    }

    public FileNode? InspectedNode => SelectedNode ?? CurrentNode;
    public DiskScanResult? ScanResult => _scanResult;

    public bool HasScan => RootNode is not null;
    public bool CanRescan => RootNode is not null && !IsScanning;
    public bool CanNavigateBack => _navigationIndex > 0;
    public bool CanNavigateForward => _navigationIndex >= 0 && _navigationIndex < _navigation.Count - 1;

    public bool IsScanning
    {
        get => _isScanning;
        private set
        {
            if (SetProperty(ref _isScanning, value))
            {
                OnPropertyChanged(nameof(CanRescan));
            }
        }
    }

    public bool IsAnalyzing
    {
        get => _isAnalyzing;
        private set => SetProperty(ref _isAnalyzing, value);
    }

    public bool IsVerifying
    {
        get => _isVerifying;
        private set => SetProperty(ref _isVerifying, value);
    }

    public string PathText
    {
        get => _pathText;
        set => SetProperty(ref _pathText, value);
    }

    public string SearchText
    {
        get => _searchText;
        set
        {
            if (SetProperty(ref _searchText, value))
            {
                ScheduleVisibleItemsRefresh();
            }
        }
    }

    public string ScanProgressText
    {
        get => _scanProgressText;
        private set => SetProperty(ref _scanProgressText, value);
    }

    public string ScanStatusPath
    {
        get => _scanStatusPath;
        private set => SetProperty(ref _scanStatusPath, value);
    }

    public string VerificationStatus
    {
        get => _verificationStatus;
        private set => SetProperty(ref _verificationStatus, value);
    }

    public string? SelectedExtension
    {
        get => _selectedExtension;
        set
        {
            if (SetProperty(ref _selectedExtension, value))
            {
                ScheduleVisibleItemsRefresh();
            }
        }
    }

    public long MinimumSize
    {
        get => _minimumSize;
        set
        {
            if (SetProperty(ref _minimumSize, value))
            {
                _settings.MinimumSize = value;
                SaveSettings();
                ScheduleVisibleItemsRefresh();
            }
        }
    }

    public FileSortOrder SortOrder
    {
        get => _sortOrder;
        set
        {
            if (SetProperty(ref _sortOrder, value))
            {
                ScheduleVisibleItemsRefresh();
            }
        }
    }

    public bool SkipDeveloperFolders
    {
        get => _skipDeveloperFolders;
        set
        {
            if (SetProperty(ref _skipDeveloperFolders, value))
            {
                _settings.SkipDeveloperFolders = value;
                SaveSettings();
            }
        }
    }

    public bool ShowHiddenFiles
    {
        get => _showHiddenFiles;
        set
        {
            if (SetProperty(ref _showHiddenFiles, value))
            {
                _settings.ShowHiddenFiles = value;
                SaveSettings();
            }
        }
    }

    public bool FollowReparsePoints
    {
        get => _followReparsePoints;
        set
        {
            if (SetProperty(ref _followReparsePoints, value))
            {
                _settings.FollowReparsePoints = value;
                SaveSettings();
            }
        }
    }

    public string SummarySize => RootNode?.FormattedSize ?? "-";
    public string SummaryFileCount => _scanResult is null ? "-" : $"{_scanResult.TotalFiles:N0}";
    public string SummaryDirectoryCount => _scanResult is null ? "-" : $"{_scanResult.TotalDirectories:N0}";
    public string DiagnosticsSummary
    {
        get
        {
            if (_scanResult is null)
            {
                return string.Empty;
            }

            var diagnostics = _scanResult.Diagnostics;
            var details = new List<string>();
            if (diagnostics.UnreadableItems > 0) details.Add($"{diagnostics.UnreadableItems:N0} unreadable");
            if (diagnostics.SkippedDirectories > 0) details.Add($"{diagnostics.SkippedDirectories:N0} skipped");
            if (diagnostics.SymbolicLinks > 0) details.Add($"{diagnostics.SymbolicLinks:N0} links");
            if (diagnostics.DuplicateHardLinks > 0) details.Add($"{diagnostics.DuplicateHardLinks:N0} hard-link aliases");
            if (diagnostics.ApproximateAllocatedSizes > 0) details.Add($"{diagnostics.ApproximateAllocatedSizes:N0} estimated sizes");
            return details.Count == 0 ? "Complete scan" : string.Join("  |  ", details);
        }
    }

    public string StatusText => CurrentNode is null || _scanResult is null
        ? "Ready"
        : $"{CurrentNode.FormattedSize}  |  {CurrentNode.Children.Count:N0} immediate items  |  " +
          $"scan {_scanResult.Duration.TotalSeconds:N1}s";

    public async Task ScanAsync(string path)
    {
        path = Environment.ExpandEnvironmentVariables(path.Trim().Trim('"'));
        if (string.IsNullOrWhiteSpace(path))
        {
            ErrorRaised?.Invoke(this, "Enter a folder, mapped drive, or UNC path to scan.");
            return;
        }

        _scanCancellation?.Cancel();
        _verificationCancellation?.Cancel();
        var cancellation = new CancellationTokenSource();
        _scanCancellation = cancellation;
        IsScanning = true;
        IsAnalyzing = false;
        ScanProgressText = "Preparing scan...";
        ScanStatusPath = path;
        PathText = path;

        var progress = new Progress<ScanProgress>(snapshot =>
        {
            if (!ReferenceEquals(_scanCancellation, cancellation))
            {
                return;
            }

            ScanProgressText = $"{snapshot.Files:N0} files  |  {snapshot.Directories:N0} folders" +
                               (snapshot.UnreadableItems > 0 ? $"  |  {snapshot.UnreadableItems:N0} unreadable" : string.Empty);
            ScanStatusPath = snapshot.CurrentPath;
        });

        try
        {
            var options = new ScanOptions(SkipDeveloperFolders, ShowHiddenFiles, FollowReparsePoints);
            var scanner = new DiskScanner();
            var result = await Task.Run(() => scanner.ScanAsync(path, options, progress, cancellation.Token), cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            IsAnalyzing = true;
            ScanProgressText = "Building file type and duplicate indexes...";
            var analysis = await Task.Run(() => ScanAnalyzer.Analyze(result.Root, cancellation.Token), cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            if (!ReferenceEquals(_scanCancellation, cancellation))
            {
                return;
            }

            _scanResult = result;
            OnPropertyChanged(nameof(ScanResult));
            _analysis = analysis;
            SelectedExtension = null;
            RootNode = result.Root;
            Replace(RootFolders, [result.Root]);
            Replace(ExtensionStats, analysis.ExtensionStats);
            Replace(LargestFiles, analysis.LargestFiles);
            Replace(OldLargeFiles, analysis.OldLargeFiles);
            Replace(DuplicateCandidates, analysis.DuplicateCandidates);
            VerifiedDuplicates.Clear();
            VerificationStatus = string.Empty;

            _navigation.Clear();
            _navigation.Add(result.Root);
            _navigationIndex = 0;
            SetCurrentNode(result.Root);
            _settings.LastScanPath = result.Root.FullPath;
            PathText = result.Root.FullPath;
            SaveSettings();
            RaiseScanSummaryProperties();
        }
        catch (OperationCanceledException)
        {
            // Cancellation leaves the previous completed snapshot visible.
        }
        catch (Exception error)
        {
            if (ReferenceEquals(_scanCancellation, cancellation))
            {
                ErrorRaised?.Invoke(this, error.Message);
            }
        }
        finally
        {
            if (ReferenceEquals(_scanCancellation, cancellation))
            {
                IsScanning = false;
                IsAnalyzing = false;
                _scanCancellation = null;
            }

            cancellation.Dispose();
        }
    }

    public void CancelScan() => _scanCancellation?.Cancel();

    public Task RescanAsync() => RootNode is null ? Task.CompletedTask : ScanAsync(RootNode.FullPath);

    public void NavigateTo(FileNode node)
    {
        if (!node.IsDirectory)
        {
            SelectedNode = node;
            return;
        }

        if (node.Equals(CurrentNode))
        {
            SelectedNode = null;
            return;
        }

        if (_navigationIndex < _navigation.Count - 1)
        {
            _navigation.RemoveRange(_navigationIndex + 1, _navigation.Count - _navigationIndex - 1);
        }

        if (_navigation.Count == 0 || !_navigation[^1].Equals(node))
        {
            _navigation.Add(node);
        }

        _navigationIndex = _navigation.Count - 1;
        SetCurrentNode(node);
    }

    public void NavigateBack()
    {
        if (!CanNavigateBack) return;
        _navigationIndex--;
        SetCurrentNode(_navigation[_navigationIndex]);
    }

    public void NavigateForward()
    {
        if (!CanNavigateForward) return;
        _navigationIndex++;
        SetCurrentNode(_navigation[_navigationIndex]);
    }

    public void NavigateUp()
    {
        if (Breadcrumb.Count > 1)
        {
            NavigateTo(Breadcrumb[^2]);
        }
    }

    public void NavigateToRoot()
    {
        if (RootNode is not null)
        {
            NavigateTo(RootNode);
        }
    }

    public void Focus(FileNode node)
    {
        if (_analysis is null || !_analysis.NodesById.ContainsKey(node.Id))
        {
            SelectedNode = node;
            return;
        }

        var parent = node;
        if (!node.IsDirectory && _analysis.ParentById.TryGetValue(node.Id, out var parentId) &&
            _analysis.NodesById.TryGetValue(parentId, out var parentNode))
        {
            parent = parentNode;
        }

        NavigateTo(parent);
        SelectedNode = node.IsDirectory ? null : node;
    }

    public async Task VerifyDuplicatesAsync()
    {
        if (DuplicateCandidates.Count == 0 || IsVerifying)
        {
            return;
        }

        _verificationCancellation?.Cancel();
        var cancellation = new CancellationTokenSource();
        _verificationCancellation = cancellation;
        IsVerifying = true;
        VerifiedDuplicates.Clear();
        var progress = new Progress<DuplicateVerificationProgress>(item =>
        {
            if (!ReferenceEquals(_verificationCancellation, cancellation))
            {
                return;
            }

            var phase = item.Phase == DuplicateVerificationPhase.Sampling ? "Sampling" : "Hashing";
            VerificationStatus = $"{phase} {item.CompletedFiles:N0} of {item.TotalFiles:N0}: {item.CurrentPath}";
        });

        try
        {
            var result = await Task.Run(
                () => DuplicateVerifier.VerifyAsync(DuplicateCandidates.ToArray(), progress, cancellation.Token),
                cancellation.Token);
            if (!ReferenceEquals(_verificationCancellation, cancellation))
            {
                return;
            }

            Replace(VerifiedDuplicates, result.Groups);
            VerificationStatus = result.Groups.Count == 0
                ? "No content-identical groups were found."
                : $"{result.Groups.Count:N0} verified groups";
            if (result.UnreadablePaths.Count > 0)
            {
                VerificationStatus += $"; {result.UnreadablePaths.Count:N0} files could not be verified";
            }
        }
        catch (OperationCanceledException)
        {
            if (ReferenceEquals(_verificationCancellation, cancellation))
            {
                VerificationStatus = "Verification cancelled.";
            }
        }
        catch (Exception error)
        {
            if (ReferenceEquals(_verificationCancellation, cancellation))
            {
                ErrorRaised?.Invoke(this, $"Duplicate verification failed: {error.Message}");
            }
        }
        finally
        {
            if (ReferenceEquals(_verificationCancellation, cancellation))
            {
                IsVerifying = false;
                _verificationCancellation = null;
            }

            cancellation.Dispose();
        }
    }

    public void CancelDuplicateVerification() => _verificationCancellation?.Cancel();

    public async Task RefreshDrivesAsync()
    {
        try
        {
            var drives = await Task.Run(ReadDrives);
            Replace(Drives, drives);
        }
        catch (Exception error)
        {
            ErrorRaised?.Invoke(this, $"Drive discovery failed: {error.Message}");
        }
    }

    public void Dispose()
    {
        _scanCancellation?.Cancel();
        _filterCancellation?.Cancel();
        _verificationCancellation?.Cancel();
    }

    private void SetCurrentNode(FileNode node)
    {
        CurrentNode = node;
        SelectedNode = null;
        Replace(Breadcrumb, IndexedPathTo(node));
        OnPropertyChanged(nameof(CanNavigateBack));
        OnPropertyChanged(nameof(CanNavigateForward));
        ScheduleVisibleItemsRefresh(immediate: true);
    }

    private async void ScheduleVisibleItemsRefresh(bool immediate = false)
    {
        _filterCancellation?.Cancel();
        var cancellation = new CancellationTokenSource();
        _filterCancellation = cancellation;
        try
        {
            if (!immediate)
            {
                await Task.Delay(160, cancellation.Token);
            }

            var current = CurrentNode;
            var analysis = _analysis;
            if (current is null)
            {
                VisibleItems.Clear();
                return;
            }

            var query = SearchText.Trim();
            var extension = SelectedExtension;
            var minimumSize = MinimumSize;
            var sortOrder = SortOrder;
            var candidates = await Task.Run(() =>
            {
                cancellation.Token.ThrowIfCancellationRequested();
                IEnumerable<FileNode> source = string.IsNullOrEmpty(query)
                    ? current.Children
                    : analysis?.AllNodes ?? [];
                var visited = 0;
                source = source.Where(node =>
                {
                    if ((visited++ & 255) == 0)
                    {
                        cancellation.Token.ThrowIfCancellationRequested();
                    }

                    return node.AllocatedSize >= minimumSize &&
                           (string.IsNullOrEmpty(query) ||
                            node.DisplayName.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
                            node.FullPath.Contains(query, StringComparison.CurrentCultureIgnoreCase)) &&
                           (string.IsNullOrEmpty(extension) ||
                            !node.IsDirectory && (node.Extension ?? "unknown").Equals(extension, StringComparison.OrdinalIgnoreCase));
                });
                source = sortOrder switch
                {
                    FileSortOrder.SizeAscending => source.OrderBy(node => node.AllocatedSize).ThenBy(node => node.DisplayName, StringComparer.CurrentCultureIgnoreCase),
                    FileSortOrder.NameAscending => source.OrderBy(node => node.DisplayName, StringComparer.CurrentCultureIgnoreCase),
                    FileSortOrder.NameDescending => source.OrderByDescending(node => node.DisplayName, StringComparer.CurrentCultureIgnoreCase),
                    _ => source.OrderByDescending(node => node.AllocatedSize).ThenBy(node => node.DisplayName, StringComparer.CurrentCultureIgnoreCase)
                };
                return source.Take(2_000).ToArray();
            }, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            if (ReferenceEquals(_filterCancellation, cancellation))
            {
                Replace(VisibleItems, candidates);
            }
        }
        catch (OperationCanceledException)
        {
            // A newer filter superseded this one.
        }
        catch (Exception error)
        {
            if (ReferenceEquals(_filterCancellation, cancellation))
            {
                ErrorRaised?.Invoke(this, $"The file filter failed: {error.Message}");
            }
        }
        finally
        {
            if (ReferenceEquals(_filterCancellation, cancellation))
            {
                _filterCancellation = null;
            }

            cancellation.Dispose();
        }
    }

    private void BuildQuickLocations()
    {
        AddLocation("Home", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        AddLocation("Desktop", Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory));
        AddLocation("Documents", Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments));
        AddLocation("Downloads", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads"));
        if (!string.IsNullOrWhiteSpace(_settings.LastScanPath))
        {
            QuickLocations.Add(new LocationItem("Last scan", _settings.LastScanPath, _settings.LastScanPath));
        }
    }

    private IReadOnlyList<FileNode> IndexedPathTo(FileNode node)
    {
        if (_analysis is null)
        {
            return [node];
        }

        var path = new List<FileNode> { node };
        var cursor = node.Id;
        while (_analysis.ParentById.TryGetValue(cursor, out var parentId) &&
               _analysis.NodesById.TryGetValue(parentId, out var parent))
        {
            path.Add(parent);
            cursor = parentId;
        }

        path.Reverse();
        return path;
    }

    private void AddLocation(string label, string path)
    {
        if (!string.IsNullOrWhiteSpace(path))
        {
            QuickLocations.Add(new LocationItem(label, path, path));
        }
    }

    private static IReadOnlyList<LocationItem> ReadDrives()
    {
        var result = new List<LocationItem>();
        DriveInfo[] availableDrives;
        try
        {
            availableDrives = DriveInfo.GetDrives();
        }
        catch
        {
            return result;
        }

        foreach (var drive in availableDrives)
        {
            try
            {
                var network = drive.DriveType == DriveType.Network;
                if (network)
                {
                    result.Add(new LocationItem(drive.Name, drive.RootDirectory.FullName, "Mapped network drive", true));
                    continue;
                }

                var label = drive.IsReady && !string.IsNullOrWhiteSpace(drive.VolumeLabel)
                    ? $"{drive.Name}  {drive.VolumeLabel}"
                    : drive.Name;
                var detail = drive.IsReady
                    ? $"{ByteSizeFormatter.Format(drive.AvailableFreeSpace)} free of {ByteSizeFormatter.Format(drive.TotalSize)}"
                    : network ? "Mapped network drive" : drive.DriveType.ToString();
                result.Add(new LocationItem(label, drive.RootDirectory.FullName, detail, network));
            }
            catch
            {
                result.Add(new LocationItem(drive.Name, drive.Name, drive.DriveType.ToString(), drive.DriveType == DriveType.Network));
            }
        }

        return result.OrderBy(item => item.Path, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    private void SaveSettings() => _settingsStore.Save(_settings);

    private void RaiseScanSummaryProperties()
    {
        OnPropertyChanged(nameof(SummarySize));
        OnPropertyChanged(nameof(SummaryFileCount));
        OnPropertyChanged(nameof(SummaryDirectoryCount));
        OnPropertyChanged(nameof(DiagnosticsSummary));
        OnPropertyChanged(nameof(StatusText));
    }

    private static void Replace<T>(ObservableCollection<T> collection, IEnumerable<T> values)
    {
        collection.Clear();
        foreach (var value in values)
        {
            collection.Add(value);
        }
    }
}
