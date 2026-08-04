using System.Collections.ObjectModel;
using System.IO;
using System.Runtime.InteropServices;
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
    private const int MaximumOutstandingScanWorkers = 2;
    private readonly MainViewModelServices _services;
    private readonly AppSettings _settings;
    private readonly SynchronizationContext? _synchronizationContext;
    private readonly int? _ownerThreadId;
    private readonly List<FileNode> _navigation = [];
    private readonly object _filterGate = new();
    private readonly object _lifecycleGate = new();
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
    private long _nextGeneration;
    private long _publishedGeneration;
    private long _verificationEpoch;
    private string _visibleItemsStatus = string.Empty;
    private TaskCompletionSource? _filterIdleCompletion;
    private bool _filterRefreshPending;
    private bool _pendingFilterImmediate;
    private bool _filterPumpRunning;
    private int _outstandingScanWorkers;
    private int _outstandingVerificationWorkers;
    private int _disposed;

    private bool IsDisposed => Volatile.Read(ref _disposed) != 0;

    public MainViewModel() : this(MainViewModelServices.CreateDefault())
    {
    }

    internal MainViewModel(MainViewModelServices services)
    {
        _services = services;
        _synchronizationContext = SynchronizationContext.Current;
        _ownerThreadId = _synchronizationContext is System.Windows.Threading.DispatcherSynchronizationContext
            ? Environment.CurrentManagedThreadId
            : null;
        _settings = services.LoadSettings();
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
    public string ProductIdentity
    {
        get
        {
            var version = typeof(MainViewModel).Assembly.GetName().Version;
            var productVersion = version is null
                ? "unknown"
                : $"{version.Major}.{version.Minor}.{version.Build}";
            return $"v{productVersion} | {RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant()} | no telemetry";
        }
    }

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
                OnPropertyChanged(nameof(CanUseSnapshot));
                OnPropertyChanged(nameof(CanVerifyDuplicates));
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
            if (value is not null)
            {
                if (!CanUseSnapshot ||
                    _analysis is null ||
                    !_analysis.NodesById.TryGetValue(value.Id, out var activeNode))
                {
                    value = null;
                }
                else
                {
                    value = activeNode;
                }
            }

            if (SetProperty(ref _selectedNode, value))
            {
                OnPropertyChanged(nameof(InspectedNode));
            }
        }
    }

    public FileNode? InspectedNode => SelectedNode ?? CurrentNode;
    public DiskScanResult? ScanResult => _scanResult;

    public bool HasScan => RootNode is not null;
    public bool CanRescan => RootNode is not null && CanStartScan;
    public bool CanStartScan => !IsDisposed && !IsScanning && Volatile.Read(ref _outstandingScanWorkers) < MaximumOutstandingScanWorkers;
    public bool CanUseSnapshot => !IsDisposed && RootNode is not null && !IsScanning;
    public bool CanVerifyDuplicates => CanUseSnapshot && DuplicateCandidates.Count > 0 && !IsVerifying &&
        Volatile.Read(ref _outstandingVerificationWorkers) == 0;
    public bool CanNavigateBack => CanUseSnapshot && _navigationIndex > 0;
    public bool CanNavigateForward => CanUseSnapshot && _navigationIndex >= 0 && _navigationIndex < _navigation.Count - 1;

    public bool IsScanning
    {
        get => _isScanning;
        private set
        {
            if (SetProperty(ref _isScanning, value))
            {
                RaiseScanningProperties();
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
        private set
        {
            if (SetProperty(ref _isVerifying, value))
            {
                OnPropertyChanged(nameof(CanVerifyDuplicates));
            }
        }
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

    public string VisibleItemsStatus
    {
        get => _visibleItemsStatus;
        private set => SetProperty(ref _visibleItemsStatus, value);
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
            if (!_scanResult.Options.ShowHiddenFiles)
            {
                details.Add(diagnostics.HiddenItemsExcluded > 0
                    ? $"{diagnostics.HiddenItemsExcluded:N0} hidden excluded"
                    : "hidden items excluded by settings");
            }
            if (diagnostics.SymbolicLinks > 0) details.Add($"{diagnostics.SymbolicLinks:N0} links");
            if (diagnostics.DuplicateHardLinks > 0) details.Add($"{diagnostics.DuplicateHardLinks:N0} hard-link aliases");
            if (diagnostics.UnverifiedHardLinks > 0) details.Add($"{diagnostics.UnverifiedHardLinks:N0} hard links unverified");
            if (diagnostics.ApproximateAllocatedSizes > 0) details.Add($"{diagnostics.ApproximateAllocatedSizes:N0} estimated sizes");
            if (diagnostics.MetadataUnavailableItems > 0) details.Add($"{diagnostics.MetadataUnavailableItems:N0} metadata estimates");
            return details.Count == 0 ? "Complete for selected options" : string.Join("  |  ", details);
        }
    }

    public string DiagnosticsDetail => _scanResult is null
        ? string.Empty
        : _scanResult.Diagnostics.FirstUnreadablePaths.Count == 0
            ? string.Empty
            : "First unreadable paths:\n" + string.Join("\n", _scanResult.Diagnostics.FirstUnreadablePaths);

    public string StatusText => CurrentNode is null || _scanResult is null
        ? "Ready"
        : $"{CurrentNode.FormattedSize}  |  {CurrentNode.Children.Count:N0} immediate items  |  " +
          $"scan {_scanResult.Duration.TotalSeconds:N1}s";

    public async Task ScanAsync(string path)
    {
        VerifyAccess();
        path = Environment.ExpandEnvironmentVariables(path.Trim().Trim('"'));
        if (string.IsNullOrWhiteSpace(path))
        {
            RaiseError("Enter a folder, mapped drive, or UNC path to scan.");
            return;
        }

        CancellationTokenSource cancellation;
        CancellationTokenSource? verificationToCancel = null;
        string? rejection = null;
        lock (_lifecycleGate)
        {
            if (IsDisposed)
            {
                return;
            }
            if (_isScanning)
            {
                rejection = "A scan is already active. Cancel it and wait for cancellation to finish before starting another location.";
                cancellation = null!;
            }
            else if (Volatile.Read(ref _outstandingScanWorkers) >= MaximumOutstandingScanWorkers)
            {
                rejection = "Previous cancelled scans are still blocked by the filesystem. Wait for one to finish before starting another location.";
                cancellation = null!;
            }
            else
            {
                cancellation = new CancellationTokenSource();
                _scanCancellation = cancellation;
                verificationToCancel = _verificationCancellation;
                _isScanning = true;
            }
        }
        if (rejection is not null)
        {
            RaiseError(rejection);
            return;
        }
        OnPropertyChanged(nameof(IsScanning));
        RaiseScanningProperties();

        var generation = Interlocked.Increment(ref _nextGeneration);
        var previousPath = RootNode?.FullPath ?? string.Empty;
        Interlocked.Increment(ref _verificationEpoch);
        if (verificationToCancel is not null)
        {
            CancelSafely(verificationToCancel);
            VerificationStatus = "Verification cancelled by the new scan request.";
        }
        IsAnalyzing = false;
        ScanProgressText = "Preparing scan...";
        ScanStatusPath = path;
        PathText = path;
        SelectedNode = null;
        Task? backgroundOperation = null;

        var progress = new Progress<ScanProgress>(snapshot =>
        {
            if (IsDisposed || !ReferenceEquals(_scanCancellation, cancellation))
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
            var scanOperation = _services.StartScan(path, options, progress, cancellation.Token);
            TrackScanWorker(scanOperation.Completion);
            backgroundOperation = scanOperation.Completion;
            ObserveFault(scanOperation.Completion);
            var result = await scanOperation.Result;
            cancellation.Token.ThrowIfCancellationRequested();
            IsAnalyzing = true;
            ScanProgressText = "Building file type and duplicate indexes...";
            var analysisTask = Task.Run(
                () => _services.AnalyzeAsync(result.Root, cancellation.Token),
                CancellationToken.None);
            TrackScanWorker(analysisTask);
            backgroundOperation = analysisTask;
            ObserveFault(analysisTask);
            var analysis = await analysisTask.WaitAsync(cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            if (IsDisposed || !ReferenceEquals(_scanCancellation, cancellation))
            {
                return;
            }

            _scanResult = result;
            _publishedGeneration = generation;
            OnPropertyChanged(nameof(ScanResult));
            _analysis = analysis;
            SelectedExtension = null;
            RootNode = result.Root;
            Replace(RootFolders, [result.Root]);
            Replace(ExtensionStats, analysis.ExtensionStats);
            Replace(LargestFiles, analysis.LargestFiles);
            Replace(OldLargeFiles, analysis.OldLargeFiles);
            Replace(DuplicateCandidates, analysis.DuplicateCandidates);
            Replace(VerifiedDuplicates, []);
            VerificationStatus = string.Empty;

            if (IsDisposed)
            {
                return;
            }

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
            if (!IsDisposed)
            {
                // Cancellation leaves the previous completed snapshot visible.
                PathText = previousPath;
                ScanStatusPath = previousPath;
            }
        }
        catch (Exception error)
        {
            if (!IsDisposed && ReferenceEquals(_scanCancellation, cancellation))
            {
                App.RecordDiagnostic("scan-failed", error);
                PathText = previousPath;
                ScanStatusPath = previousPath;
                RaiseError(error.Message);
            }
        }
        finally
        {
            var ownsScan = false;
            lock (_lifecycleGate)
            {
                ownsScan = ReferenceEquals(_scanCancellation, cancellation);
                if (ownsScan)
                {
                    _scanCancellation = null;
                }
            }
            if (ownsScan)
            {
                IsScanning = false;
                IsAnalyzing = false;
            }

            DisposeWhenComplete(cancellation, backgroundOperation);
        }
    }

    public void CancelScan()
    {
        VerifyAccess();
        CancellationTokenSource? cancellation;
        lock (_lifecycleGate)
        {
            cancellation = _scanCancellation;
        }
        CancelSafely(cancellation);
    }

    public Task RescanAsync() => !CanRescan || RootNode is null ? Task.CompletedTask : ScanAsync(RootNode.FullPath);

    public void NavigateTo(FileNode node)
    {
        if (!TryGetActiveNode(node, out var activeNode))
        {
            return;
        }
        node = activeNode;

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
        if (!CanUseSnapshot || !CanNavigateBack) return;
        _navigationIndex--;
        SetCurrentNode(_navigation[_navigationIndex]);
    }

    public void NavigateForward()
    {
        if (!CanUseSnapshot || !CanNavigateForward) return;
        _navigationIndex++;
        SetCurrentNode(_navigation[_navigationIndex]);
    }

    public void NavigateUp()
    {
        if (CanUseSnapshot && Breadcrumb.Count > 1)
        {
            NavigateTo(Breadcrumb[^2]);
        }
    }

    public void NavigateToRoot()
    {
        if (CanUseSnapshot && RootNode is not null)
        {
            NavigateTo(RootNode);
        }
    }

    public void Focus(FileNode node)
    {
        if (!TryGetActiveNode(node, out var activeNode))
        {
            return;
        }
        node = activeNode;
        var analysis = _analysis!;

        var parent = node;
        if (!node.IsDirectory && analysis.ParentById.TryGetValue(node.Id, out var parentId) &&
            analysis.NodesById.TryGetValue(parentId, out var parentNode))
        {
            parent = parentNode;
        }

        NavigateTo(parent);
        SelectedNode = node.IsDirectory ? null : node;
    }

    public async Task VerifyDuplicatesAsync()
    {
        VerifyAccess();
        FileNode verificationRoot;
        CancellationTokenSource cancellation;
        CancellationTokenSource? previousCancellation;
        long verificationGeneration;
        long verificationEpoch;
        lock (_lifecycleGate)
        {
            if (IsDisposed || !CanVerifyDuplicates || RootNode is not { } root)
            {
                return;
            }
            verificationRoot = root;
            verificationGeneration = _publishedGeneration;
            verificationEpoch = Interlocked.Increment(ref _verificationEpoch);
            previousCancellation = _verificationCancellation;
            cancellation = new CancellationTokenSource();
            _verificationCancellation = cancellation;
            _isVerifying = true;
        }
        OnPropertyChanged(nameof(IsVerifying));
        OnPropertyChanged(nameof(CanVerifyDuplicates));
        Replace(VerifiedDuplicates, []);
        CancelSafely(previousCancellation);
        Task? backgroundOperation = null;
        var progress = new Progress<DuplicateVerificationProgress>(item =>
        {
            if (!IsVerificationCurrent(cancellation, verificationGeneration, verificationEpoch, verificationRoot))
            {
                return;
            }

            var phase = item.Phase == DuplicateVerificationPhase.Sampling ? "Sampling" : "Hashing";
            VerificationStatus = $"{phase} {item.CompletedFiles:N0} of {item.TotalFiles:N0}: {item.CurrentPath}";
        });

        try
        {
            var candidates = DuplicateCandidates.ToArray();
            var verificationTask = Task.Run(
                () => _services.VerifyDuplicatesAsync(candidates, progress, cancellation.Token),
                CancellationToken.None);
            TrackVerificationWorker(verificationTask);
            backgroundOperation = verificationTask;
            ObserveFault(verificationTask);
            var result = await verificationTask.WaitAsync(cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            if (!IsVerificationCurrent(cancellation, verificationGeneration, verificationEpoch, verificationRoot))
            {
                return;
            }

            Replace(VerifiedDuplicates, result.Groups);
            VerificationStatus = result.Groups.Count == 0
                ? "No content-identical groups were found."
                : $"{result.Groups.Count:N0} verified groups";
            if (result.TotalUnreadableFiles > 0)
            {
                VerificationStatus += $"; {result.TotalUnreadableFiles:N0} files could not be verified";
                if (result.TotalUnreadableFiles > result.UnreadablePaths.Count)
                {
                    VerificationStatus += $" (showing first {result.UnreadablePaths.Count:N0})";
                }
            }
        }
        catch (OperationCanceledException)
        {
            if (OwnsVerification(cancellation, verificationGeneration, verificationEpoch, verificationRoot))
            {
                VerificationStatus = "Verification cancelled.";
            }
        }
        catch (Exception error)
        {
            if (IsVerificationCurrent(cancellation, verificationGeneration, verificationEpoch, verificationRoot))
            {
                RaiseError($"Duplicate verification failed: {error.Message}");
            }
        }
        finally
        {
            var ownsVerification = false;
            lock (_lifecycleGate)
            {
                ownsVerification = ReferenceEquals(_verificationCancellation, cancellation);
                if (ownsVerification)
                {
                    _verificationCancellation = null;
                }
            }
            if (ownsVerification)
            {
                IsVerifying = false;
            }

            DisposeWhenComplete(cancellation, backgroundOperation);
        }
    }

    public void CancelDuplicateVerification()
    {
        VerifyAccess();
        CancellationTokenSource? cancellation;
        lock (_lifecycleGate)
        {
            cancellation = _verificationCancellation;
        }
        CancelSafely(cancellation);
    }

    public bool TryGetActiveNode(FileNode? candidate, out FileNode node)
    {
        if (CanUseSnapshot &&
            candidate is not null &&
            _analysis is not null &&
            _analysis.NodesById.TryGetValue(candidate.Id, out var activeNode))
        {
            node = activeNode;
            return true;
        }

        node = null!;
        return false;
    }

    public async Task RefreshDrivesAsync()
    {
        VerifyAccess();
        if (IsDisposed)
        {
            return;
        }
        var drives = await Task.Run(ReadDrives);
        if (!IsDisposed)
        {
            Replace(Drives, drives);
        }
    }

    public void Dispose()
    {
        VerifyAccess();
        CancellationTokenSource? scanCancellation;
        CancellationTokenSource? verificationCancellation;
        lock (_lifecycleGate)
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
            {
                return;
            }
            scanCancellation = _scanCancellation;
            verificationCancellation = _verificationCancellation;
        }

        DisableNotifications();
        CancelSafely(scanCancellation);
        CancelSafely(verificationCancellation);
        CancellationTokenSource? filterCancellation;
        lock (_filterGate)
        {
            _filterRefreshPending = false;
            filterCancellation = _filterCancellation;
            _filterCancellation = null;
        }
        CancelSafely(filterCancellation);
    }

    private void SetCurrentNode(FileNode node)
    {
        CurrentNode = node;
        SelectedNode = null;
        Replace(VisibleItems, []);
        VisibleItemsStatus = string.Empty;
        Replace(Breadcrumb, IndexedPathTo(node));
        OnPropertyChanged(nameof(CanNavigateBack));
        OnPropertyChanged(nameof(CanNavigateForward));
        ScheduleVisibleItemsRefresh(immediate: true);
    }

    internal Task WaitForFilterAsync()
    {
        lock (_filterGate)
        {
            return _filterIdleCompletion?.Task ?? Task.CompletedTask;
        }
    }

    private void ScheduleVisibleItemsRefresh(bool immediate = false)
    {
        VerifyAccess();
        var startPump = false;
        CancellationTokenSource? previousCancellation;
        lock (_filterGate)
        {
            if (IsDisposed)
            {
                return;
            }

            previousCancellation = _filterCancellation;
            _filterCancellation = null;
            _filterRefreshPending = true;
            _pendingFilterImmediate = immediate;
            _filterIdleCompletion ??= new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            if (!_filterPumpRunning)
            {
                _filterPumpRunning = true;
                startPump = true;
            }
        }
        CancelSafely(previousCancellation);

        if (startPump)
        {
            ObserveFault(RunFilterPumpAsync());
        }
    }

    private async Task RunFilterPumpAsync()
    {
        TaskCompletionSource? completed = null;
        try
        {
            while (true)
            {
                CancellationTokenSource cancellation;
                bool immediate;
                lock (_filterGate)
                {
                    if (IsDisposed || !_filterRefreshPending)
                    {
                        _filterPumpRunning = false;
                        completed = _filterIdleCompletion;
                        _filterIdleCompletion = null;
                        break;
                    }

                    _filterRefreshPending = false;
                    immediate = _pendingFilterImmediate;
                    cancellation = new CancellationTokenSource();
                    _filterCancellation = cancellation;
                }

                try
                {
                    await RefreshVisibleItemsAsync(immediate, cancellation);
                }
                finally
                {
                    lock (_filterGate)
                    {
                        if (ReferenceEquals(_filterCancellation, cancellation))
                        {
                            _filterCancellation = null;
                        }
                    }
                    cancellation.Dispose();
                }
            }
        }
        finally
        {
            if (completed is null)
            {
                lock (_filterGate)
                {
                    _filterPumpRunning = false;
                    completed = _filterIdleCompletion;
                    _filterIdleCompletion = null;
                }
            }
            completed?.TrySetResult();
        }
    }

    private async Task RefreshVisibleItemsAsync(bool immediate, CancellationTokenSource cancellation)
    {
        try
        {
            if (!immediate)
            {
                await _services.DelayAsync(TimeSpan.FromMilliseconds(160), cancellation.Token);
            }

            var current = CurrentNode;
            var analysis = _analysis;
            if (IsDisposed)
            {
                return;
            }
            if (current is null)
            {
                if (!IsDisposed)
                {
                    Replace(VisibleItems, []);
                    VisibleItemsStatus = string.Empty;
                }
                return;
            }

            var query = SearchText.Trim();
            var extension = SelectedExtension;
            var minimumSize = MinimumSize;
            var sortOrder = SortOrder;
            var filterTask = Task.Run(
                () => _services.FilterVisibleItems(
                    current,
                    analysis,
                    query,
                    extension,
                    minimumSize,
                    sortOrder,
                    cancellation.Token),
                CancellationToken.None);
            ObserveFault(filterTask);
            var filtered = await filterTask;
            cancellation.Token.ThrowIfCancellationRequested();
            if (!IsDisposed && ReferenceEquals(_filterCancellation, cancellation))
            {
                Replace(VisibleItems, filtered.Items);
                VisibleItemsStatus = filtered.Total > filtered.Items.Count
                    ? $"Showing {filtered.Items.Count:N0} of {filtered.Total:N0} matches"
                    : $"{filtered.Total:N0} items";
            }
        }
        catch (OperationCanceledException)
        {
            // A newer filter superseded this one.
        }
        catch (Exception error)
        {
            if (!IsDisposed && ReferenceEquals(_filterCancellation, cancellation))
            {
                RaiseError($"The file filter failed: {error.Message}");
            }
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

    private void SaveSettings() => _services.SaveSettings(_settings);

    private void RaiseError(string message)
    {
        lock (_lifecycleGate)
        {
            if (!IsDisposed)
            {
                ErrorRaised?.Invoke(this, message);
            }
        }
    }

    private void VerifyAccess()
    {
        if (_ownerThreadId is { } ownerThreadId && Environment.CurrentManagedThreadId != ownerThreadId)
        {
            throw new InvalidOperationException("MainViewModel operations must run on the WPF dispatcher thread.");
        }
    }

    private static void CancelSafely(CancellationTokenSource? cancellation)
    {
        try
        {
            cancellation?.Cancel();
        }
        catch (ObjectDisposedException)
        {
            // The owning controller completed between capture and cancellation.
        }
    }

    private bool IsVerificationCurrent(
        CancellationTokenSource cancellation,
        long generation,
        long epoch,
        FileNode root) =>
        !IsDisposed && OwnsVerification(cancellation, generation, epoch, root) &&
        !cancellation.IsCancellationRequested;

    private bool OwnsVerification(
        CancellationTokenSource cancellation,
        long generation,
        long epoch,
        FileNode root) =>
        !IsDisposed &&
        ReferenceEquals(_verificationCancellation, cancellation) &&
        !IsScanning &&
        generation == _publishedGeneration &&
        epoch == Volatile.Read(ref _verificationEpoch) &&
        ReferenceEquals(root, RootNode);

    private static void ObserveFault(Task task) =>
        _ = task.ContinueWith(
            completed => App.RecordDiagnostic(
                "background-operation-fault",
                completed.Exception?.GetBaseException()),
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);

    private static void DisposeWhenComplete(CancellationTokenSource cancellation, Task? operation)
    {
        if (operation is null || operation.IsCompleted)
        {
            cancellation.Dispose();
            return;
        }

        _ = operation.ContinueWith(
            _ => cancellation.Dispose(),
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private void TrackScanWorker(Task operation)
    {
        Interlocked.Increment(ref _outstandingScanWorkers);
        RaiseScanAvailability();
        _ = operation.ContinueWith(
            _ =>
            {
                Interlocked.Decrement(ref _outstandingScanWorkers);
                if (IsDisposed)
                {
                    return;
                }
                if (_synchronizationContext is null)
                {
                    RaiseScanAvailability();
                }
                else
                {
                    _synchronizationContext.Post(static state =>
                        ((MainViewModel)state!).RaiseScanAvailability(), this);
                }
            },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private void TrackVerificationWorker(Task operation)
    {
        Interlocked.Increment(ref _outstandingVerificationWorkers);
        OnPropertyChanged(nameof(CanVerifyDuplicates));
        _ = operation.ContinueWith(
            _ =>
            {
                Interlocked.Decrement(ref _outstandingVerificationWorkers);
                if (IsDisposed)
                {
                    return;
                }
                if (_synchronizationContext is null)
                {
                    OnPropertyChanged(nameof(CanVerifyDuplicates));
                }
                else
                {
                    _synchronizationContext.Post(static state =>
                        ((MainViewModel)state!).OnPropertyChanged(nameof(CanVerifyDuplicates)), this);
                }
            },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private void RaiseScanAvailability()
    {
        OnPropertyChanged(nameof(CanStartScan));
        OnPropertyChanged(nameof(CanRescan));
    }

    private void RaiseScanningProperties()
    {
        OnPropertyChanged(nameof(CanRescan));
        OnPropertyChanged(nameof(CanStartScan));
        OnPropertyChanged(nameof(CanUseSnapshot));
        OnPropertyChanged(nameof(CanVerifyDuplicates));
        OnPropertyChanged(nameof(CanNavigateBack));
        OnPropertyChanged(nameof(CanNavigateForward));
    }

    private void RaiseScanSummaryProperties()
    {
        OnPropertyChanged(nameof(SummarySize));
        OnPropertyChanged(nameof(SummaryFileCount));
        OnPropertyChanged(nameof(SummaryDirectoryCount));
        OnPropertyChanged(nameof(DiagnosticsSummary));
        OnPropertyChanged(nameof(DiagnosticsDetail));
        OnPropertyChanged(nameof(StatusText));
    }

    private void Replace<T>(ObservableCollection<T> collection, IEnumerable<T> values)
    {
        if (IsDisposed)
        {
            return;
        }
        collection.Clear();
        foreach (var value in values)
        {
            if (IsDisposed)
            {
                return;
            }
            collection.Add(value);
        }
    }
}
