using System.Reflection;
using System.Windows;
using System.Windows.Threading;
using DiskInventoryZed.Core.Analysis;
using DiskInventoryZed.Core.Models;
using DiskInventoryZed.Core.Scanning;
using DiskInventoryZed.Windows.Services;
using DiskInventoryZed.Windows.ViewModels;

namespace DiskInventoryZed.Windows.Tests;

public sealed class WindowsStartupAndShellBoundaryTests
{
    [Fact]
    public Task AppResourcesAndMainWindowLoadOnSta() => RunOnStaAsync(() =>
    {
        var app = new App();
        app.InitializeComponent();
        using var viewModel = new MainViewModel(TestServices());
        var window = new MainWindow(viewModel);
        try
        {
            Assert.NotNull(app.Resources["AccentBrush"]);
            Assert.Equal(0, window.VisualizationTabs.SelectedIndex);
            Assert.Same(viewModel, window.DataContext);
        }
        finally
        {
            window.Close();
            app.Shutdown();
        }
        return Task.CompletedTask;
    });

    [Fact]
    public Task ScanCapacityRecoveryIsRaisedOnTheCapturedDispatcher() => RunOnStaAsync(async () =>
    {
        var dispatcher = Dispatcher.CurrentDispatcher;
        var workers = new[]
        {
            new TaskCompletionSource<DiskScanResult>(TaskCreationOptions.RunContinuationsAsynchronously),
            new TaskCompletionSource<DiskScanResult>(TaskCreationOptions.RunContinuationsAsynchronously)
        };
        var started = new[]
        {
            new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously),
            new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)
        };
        var returned = new[]
        {
            new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously),
            new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)
        };
        var calls = 0;
        using var viewModel = new MainViewModel(new MainViewModelServices(
            async (_, _, _, _) =>
            {
                var index = Interlocked.Increment(ref calls) - 1;
                started[index].TrySetResult();
                var result = await workers[index].Task;
                returned[index].TrySetResult();
                return result;
            },
            (_, _) => throw new InvalidOperationException("No analysis expected."),
            (_, _, _) => throw new InvalidOperationException("No verification expected."),
            VisibleItemsFilter.Apply,
            (_, _) => Task.CompletedTask,
            () => new AppSettings(),
            _ => { }));
        var recovery = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var awaitingRecovery = false;
        var recoveryWasOnDispatcher = false;
        viewModel.PropertyChanged += (_, change) =>
        {
            if (awaitingRecovery && change.PropertyName == nameof(MainViewModel.CanStartScan) && viewModel.CanStartScan)
            {
                recoveryWasOnDispatcher = dispatcher.CheckAccess();
                recovery.TrySetResult();
            }
        };

        try
        {
            var first = viewModel.ScanAsync("C:\\first");
            await started[0].Task.WaitAsync(TimeSpan.FromSeconds(2));
            viewModel.CancelScan();
            await first.WaitAsync(TimeSpan.FromSeconds(2));

            var second = viewModel.ScanAsync("C:\\second");
            await started[1].Task.WaitAsync(TimeSpan.FromSeconds(2));
            viewModel.CancelScan();
            await second.WaitAsync(TimeSpan.FromSeconds(2));
            Assert.False(viewModel.CanStartScan);

            awaitingRecovery = true;
            workers[0].TrySetResult(Result("late-one"));
            await recovery.Task.WaitAsync(TimeSpan.FromSeconds(2));
            Assert.True(recoveryWasOnDispatcher);
        }
        finally
        {
            foreach (var worker in workers)
            {
                worker.TrySetResult(Result("late"));
            }
            var startedCount = Math.Min(Volatile.Read(ref calls), returned.Length);
            await Task.WhenAll(returned.Take(startedCount).Select(item => item.Task)).WaitAsync(TimeSpan.FromSeconds(2));
        }
    });

    [Fact]
    public Task ObservableScanAndVerificationUpdatesStayOnTheDispatcher() => RunOnStaAsync(async () =>
    {
        var dispatcher = Dispatcher.CurrentDispatcher;
        var first = new FileNode("C:\\root\\first.bin", "first.bin", FileNodeKind.File, 10_000_000, 10_000_000);
        var second = new FileNode("C:\\root\\second.bin", "second.bin", FileNodeKind.File, 10_000_000, 10_000_000);
        var root = new FileNode("C:\\root", "root", FileNodeKind.Directory, 20_000_000, 20_000_000, [first, second]);
        var group = new VerifiedDuplicateGroup(new string('a', 64), 10_000_000, [first, second]);
        var scanStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseScan = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var analysisStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseAnalysis = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var filterStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseFilter = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var verificationStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseVerification = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var viewModel = new MainViewModel(new MainViewModelServices(
            async (_, _, _, _) =>
            {
                scanStarted.TrySetResult();
                await releaseScan.Task;
                return new DiskScanResult(
                    root, 2, 1, TimeSpan.Zero, ScanDiagnostics.Empty, new ScanOptions(ShowHiddenFiles: true));
            },
            async (node, token) =>
            {
                analysisStarted.TrySetResult();
                await releaseAnalysis.Task;
                return ScanAnalyzer.Analyze(node, token);
            },
            async (_, _, _) =>
            {
                verificationStarted.TrySetResult();
                await releaseVerification.Task;
                return new DuplicateVerificationResult([group], [], 0);
            },
            (current, analysis, query, extension, minimumSize, sortOrder, token) =>
            {
                filterStarted.TrySetResult();
                releaseFilter.Task.GetAwaiter().GetResult();
                return VisibleItemsFilter.Apply(
                    current, analysis, query, extension, minimumSize, sortOrder, token);
            },
            (_, _) => Task.CompletedTask,
            () => new AppSettings(),
            _ => { }));
        var stayedOnDispatcher = true;
        void RecordAffinity() => stayedOnDispatcher &= dispatcher.CheckAccess();
        viewModel.PropertyChanged += (_, _) => RecordAffinity();
        viewModel.RootFolders.CollectionChanged += (_, _) => RecordAffinity();
        viewModel.VisibleItems.CollectionChanged += (_, _) => RecordAffinity();
        viewModel.DuplicateCandidates.CollectionChanged += (_, _) => RecordAffinity();
        viewModel.VerifiedDuplicates.CollectionChanged += (_, _) => RecordAffinity();

        try
        {
            var scan = viewModel.ScanAsync("C:\\root");
            await scanStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));
            releaseScan.TrySetResult();
            await analysisStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));
            releaseAnalysis.TrySetResult();
            await scan.WaitAsync(TimeSpan.FromSeconds(2));
            await filterStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));
            releaseFilter.TrySetResult();
            await viewModel.WaitForFilterAsync().WaitAsync(TimeSpan.FromSeconds(2));
            var verification = viewModel.VerifyDuplicatesAsync();
            await verificationStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));
            releaseVerification.TrySetResult();
            await verification.WaitAsync(TimeSpan.FromSeconds(2));
            await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);

            Assert.True(stayedOnDispatcher);
            Assert.Single(viewModel.VerifiedDuplicates);
        }
        finally
        {
            releaseScan.TrySetResult();
            releaseAnalysis.TrySetResult();
            releaseFilter.TrySetResult();
            releaseVerification.TrySetResult();
        }
    });

    [Fact]
    public void ShellServicePublicBoundaryContainsNoMutationOperations()
    {
        var methodNames = typeof(WindowsShellService)
            .GetMethods(BindingFlags.Public | BindingFlags.Static | BindingFlags.DeclaredOnly)
            .Select(method => method.Name)
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToArray();

        Assert.Equal(["Open", "OpenContainingFolder", "RevealAsync"], methodNames);
        Assert.DoesNotContain(methodNames, name =>
            name.Contains("delete", StringComparison.OrdinalIgnoreCase) ||
            name.Contains("move", StringComparison.OrdinalIgnoreCase) ||
            name.Contains("recycle", StringComparison.OrdinalIgnoreCase));
    }

    private static MainViewModelServices TestServices() =>
        new(
            (_, _, _, _) => throw new InvalidOperationException("No scan expected."),
            (_, _) => throw new InvalidOperationException("No analysis expected."),
            (_, _, _) => throw new InvalidOperationException("No verification expected."),
            VisibleItemsFilter.Apply,
            Task.Delay,
            () => new AppSettings(),
            _ => { });

    private static DiskScanResult Result(string name)
    {
        var root = new FileNode($"C:\\{name}", name, FileNodeKind.Directory, 0, 0);
        return new DiskScanResult(root, 0, 1, TimeSpan.Zero, ScanDiagnostics.Empty, new ScanOptions());
    }

    private static Task RunOnStaAsync(Func<Task> action)
    {
        var completion = new TaskCompletionSource<object?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                var dispatcher = Dispatcher.CurrentDispatcher;
                SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher));
                var operation = ExecuteAsync();
                if (!operation.IsCompleted)
                {
                    Dispatcher.Run();
                }
                operation.GetAwaiter().GetResult();
                completion.SetResult(null);

                async Task ExecuteAsync()
                {
                    try
                    {
                        await action();
                    }
                    finally
                    {
                        if (!dispatcher.HasShutdownStarted)
                        {
                            dispatcher.BeginInvokeShutdown(DispatcherPriority.Background);
                        }
                    }
                }
            }
            catch (Exception error)
            {
                completion.SetException(error);
            }
        });
        thread.IsBackground = true;
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return WaitForThreadAsync();

        async Task WaitForThreadAsync()
        {
            try
            {
                await completion.Task.WaitAsync(TimeSpan.FromSeconds(10));
            }
            finally
            {
                if (!thread.Join(TimeSpan.FromSeconds(1)))
                {
                    throw new TimeoutException("The WPF STA test thread did not terminate.");
                }
            }
        }
    }
}
