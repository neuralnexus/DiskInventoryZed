using System.IO;
using DiskInventoryZed.Core.Analysis;
using DiskInventoryZed.Core.Models;
using DiskInventoryZed.Core.Scanning;
using DiskInventoryZed.Windows.Services;
using DiskInventoryZed.Windows.ViewModels;

namespace DiskInventoryZed.Windows.Tests;

public sealed class MainViewModelReliabilityTests
{
    [Fact]
    public void ProductIdentityExposesVersionArchitectureAndPrivacyContract()
    {
        using var viewModel = new MainViewModel(Services());

        Assert.Contains("v1.2.0", viewModel.ProductIdentity, StringComparison.Ordinal);
        Assert.Contains("no telemetry", viewModel.ProductIdentity, StringComparison.Ordinal);
        Assert.Contains(System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(),
            viewModel.ProductIdentity,
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task ScanPathNormalizesQuotesAndWhitespaceIntroducedByExpansion()
    {
        var variable = $"DISK_INVENTORY_ZED_TEST_PATH_{Guid.NewGuid():N}";
        Environment.SetEnvironmentVariable(variable, "  \"C:\\expanded\"  ");
        string? scannedPath = null;
        try
        {
            using var viewModel = new MainViewModel(Services(scanAsync: (path, _, _, _) =>
            {
                scannedPath = path;
                return Task.FromResult(Result(Root("expanded")));
            }));

            await viewModel.ScanAsync($"%{variable}%");

            Assert.Equal("C:\\expanded", scannedPath);
        }
        finally
        {
            Environment.SetEnvironmentVariable(variable, null);
        }
    }

    [Fact]
    public async Task CancelReleasesUiBeforeBlockedScannerReturnsAndLateResultCannotPublish()
    {
        var scanner = new TaskCompletionSource<DiskScanResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var scannerReturned = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var viewModel = new MainViewModel(Services(scanAsync: async (_, _, _, _) =>
        {
            var result = await scanner.Task;
            scannerReturned.TrySetResult();
            return result;
        }));
        string? error = null;
        viewModel.ErrorRaised += (_, message) => error = message;

        try
        {
            var firstScan = viewModel.ScanAsync("C:\\blocked");
            Assert.True(viewModel.IsScanning);

            await viewModel.ScanAsync("C:\\second");
            Assert.NotNull(error);
            Assert.Contains("already active", error!, StringComparison.OrdinalIgnoreCase);

            viewModel.CancelScan();
            await firstScan.WaitAsync(TimeSpan.FromSeconds(2));

            Assert.False(viewModel.IsScanning);
            Assert.True(viewModel.CanStartScan);
            Assert.Null(viewModel.RootNode);

            scanner.TrySetResult(Result(Root("late")));
            await scannerReturned.Task.WaitAsync(TimeSpan.FromSeconds(2));
            Assert.Null(viewModel.RootNode);
        }
        finally
        {
            scanner.TrySetResult(Result(Root("late")));
        }
    }

    [Fact]
    public async Task FailedReplacementPreservesPublishedSnapshotAndVerifiedGroups()
    {
        var initialRoot = DuplicateRoot("initial");
        var verified = new VerifiedDuplicateGroup(
            new string('a', 64),
            10_000_000,
            initialRoot.Children);
        using var viewModel = new MainViewModel(Services(
            scanAsync: (path, _, _, _) => path.EndsWith("initial", StringComparison.Ordinal)
                ? Task.FromResult(Result(initialRoot))
                : Task.FromException<DiskScanResult>(new IOException("replacement failed")),
            verifyAsync: (_, _, _) => Task.FromResult(
                new DuplicateVerificationResult([verified], [], 0))));

        await viewModel.ScanAsync("C:\\initial");
        await viewModel.VerifyDuplicatesAsync();
        var originalStatus = viewModel.VerificationStatus;
        Assert.Single(viewModel.VerifiedDuplicates);

        await viewModel.ScanAsync("C:\\replacement");

        Assert.Same(initialRoot, viewModel.RootNode);
        Assert.Single(viewModel.VerifiedDuplicates);
        Assert.Equal(originalStatus, viewModel.VerificationStatus);
        Assert.Equal("C:\\initial", viewModel.PathText);
    }

    [Fact]
    public async Task RepeatedCancellationCannotCreateUnboundedBlockedWorkers()
    {
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
        using var viewModel = new MainViewModel(Services(scanAsync: async (_, _, _, _) =>
        {
            var index = Interlocked.Increment(ref calls) - 1;
            started[index].TrySetResult();
            var result = await workers[index].Task;
            returned[index].TrySetResult();
            return result;
        }));
        string? error = null;
        viewModel.ErrorRaised += (_, message) => error = message;

        try
        {
            var first = viewModel.ScanAsync("C:\\first");
            await started[0].Task.WaitAsync(TimeSpan.FromSeconds(2));
            viewModel.CancelScan();
            await first.WaitAsync(TimeSpan.FromSeconds(2));
            Assert.True(viewModel.CanStartScan);

            var second = viewModel.ScanAsync("C:\\second");
            await started[1].Task.WaitAsync(TimeSpan.FromSeconds(2));
            viewModel.CancelScan();
            await second.WaitAsync(TimeSpan.FromSeconds(2));
            Assert.False(viewModel.CanStartScan);

            await viewModel.ScanAsync("C:\\third");
            Assert.Equal(2, Volatile.Read(ref calls));
            Assert.Contains("still blocked", error!, StringComparison.OrdinalIgnoreCase);

            workers[0].TrySetResult(Result(Root("late")));
            await returned[0].Task.WaitAsync(TimeSpan.FromSeconds(2));
            await WaitUntilAsync(() => viewModel.CanStartScan);
            Assert.True(viewModel.CanStartScan);
        }
        finally
        {
            foreach (var worker in workers)
            {
                worker.TrySetResult(Result(Root("late")));
            }
            var startedCount = Math.Min(Volatile.Read(ref calls), returned.Length);
            await Task.WhenAll(returned.Take(startedCount).Select(item => item.Task)).WaitAsync(TimeSpan.FromSeconds(2));
        }
    }

    [Fact]
    public async Task CancelledVerificationCannotStartAnotherWorkerUntilTheFirstReturns()
    {
        var verifier = new TaskCompletionSource<DuplicateVerificationResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var returned = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        using var viewModel = new MainViewModel(Services(
            scanAsync: (_, _, _, _) => Task.FromResult(Result(DuplicateRoot("root"))),
            verifyAsync: async (_, _, _) =>
            {
                Interlocked.Increment(ref calls);
                started.TrySetResult();
                var result = await verifier.Task;
                returned.TrySetResult();
                return result;
            }));
        await viewModel.ScanAsync("C:\\root");

        try
        {
            var verification = viewModel.VerifyDuplicatesAsync();
            await started.Task.WaitAsync(TimeSpan.FromSeconds(2));
            viewModel.CancelDuplicateVerification();
            await verification.WaitAsync(TimeSpan.FromSeconds(2));

            Assert.False(viewModel.IsVerifying);
            Assert.False(viewModel.CanVerifyDuplicates);
            await viewModel.VerifyDuplicatesAsync();
            Assert.Equal(1, Volatile.Read(ref calls));

            verifier.TrySetResult(new DuplicateVerificationResult([], [], 0));
            await returned.Task.WaitAsync(TimeSpan.FromSeconds(2));
            await WaitUntilAsync(() => viewModel.CanVerifyDuplicates);
            Assert.True(viewModel.CanVerifyDuplicates);
        }
        finally
        {
            verifier.TrySetResult(new DuplicateVerificationResult([], [], 0));
        }
    }

    [Fact]
    public async Task SupersedingScanInvalidatesLateVerificationStatus()
    {
        var root = DuplicateRoot("initial");
        var scanner = new TaskCompletionSource<DiskScanResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var verifier = new TaskCompletionSource<DuplicateVerificationResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var scannerReturned = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var verifierReturned = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var viewModel = new MainViewModel(Services(
            scanAsync: async (path, _, _, _) =>
            {
                if (path.EndsWith("initial", StringComparison.Ordinal))
                {
                    return Result(root);
                }

                var result = await scanner.Task;
                scannerReturned.TrySetResult();
                return result;
            },
            verifyAsync: async (_, _, _) =>
            {
                var result = await verifier.Task;
                verifierReturned.TrySetResult();
                return result;
            }));
        try
        {
            await viewModel.ScanAsync("C:\\initial");

            var verification = viewModel.VerifyDuplicatesAsync();
            await WaitUntilAsync(() => viewModel.IsVerifying);
            var replacement = viewModel.ScanAsync("C:\\replacement");
            await verification.WaitAsync(TimeSpan.FromSeconds(2));
            Assert.Equal("Verification cancelled by the new scan request.", viewModel.VerificationStatus);

            viewModel.CancelScan();
            await replacement.WaitAsync(TimeSpan.FromSeconds(2));
            verifier.TrySetResult(new DuplicateVerificationResult([], [], 0));
            scanner.TrySetResult(Result(Root("late")));
            await Task.WhenAll(verifierReturned.Task, scannerReturned.Task).WaitAsync(TimeSpan.FromSeconds(2));

            Assert.Same(root, viewModel.RootNode);
            Assert.Equal("Verification cancelled by the new scan request.", viewModel.VerificationStatus);
        }
        finally
        {
            verifier.TrySetResult(new DuplicateVerificationResult([], [], 0));
            scanner.TrySetResult(Result(Root("late")));
        }
    }

    [Fact]
    public async Task FilterRequestsAreSerialAndCoalesceToTheNewestQuery()
    {
        var oldStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseOld = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var active = 0;
        var maximumActive = 0;
        var calls = 0;
        var oldNode = File("C:\\root\\old.bin", "old.bin", 1);
        var newNode = File("C:\\root\\new.bin", "new.bin", 2);
        var root = new FileNode("C:\\root", "root", FileNodeKind.Directory, 3, 3, [oldNode, newNode]);
        using var viewModel = new MainViewModel(Services(
            scanAsync: (_, _, _, _) => Task.FromResult(Result(root)),
            filter: (_, _, query, _, _, _, _) =>
            {
                Interlocked.Increment(ref calls);
                var currentActive = Interlocked.Increment(ref active);
                SetMaximum(ref maximumActive, currentActive);
                try
                {
                    if (query == "old")
                    {
                        oldStarted.TrySetResult();
                        releaseOld.Task.GetAwaiter().GetResult();
                        return new VisibleItemsResult([oldNode], 1);
                    }

                    return query == "new"
                        ? new VisibleItemsResult([newNode], 1)
                        : new VisibleItemsResult([oldNode, newNode], 2);
                }
                finally
                {
                    Interlocked.Decrement(ref active);
                }
            }));
        await viewModel.ScanAsync("C:\\root");
        await viewModel.WaitForFilterAsync().WaitAsync(TimeSpan.FromSeconds(2));
        Interlocked.Exchange(ref calls, 0);
        Interlocked.Exchange(ref maximumActive, 0);

        viewModel.SearchText = "old";
        var idle = viewModel.WaitForFilterAsync();
        try
        {
            await oldStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));
            for (var index = 0; index < 20; index++)
            {
                viewModel.SearchText = $"superseded-{index}";
            }
            viewModel.SearchText = "new";
            Assert.Equal(1, Volatile.Read(ref calls));
            releaseOld.TrySetResult();
            await idle.WaitAsync(TimeSpan.FromSeconds(2));

            Assert.Equal(2, Volatile.Read(ref calls));
            Assert.Equal(1, Volatile.Read(ref maximumActive));
            Assert.Equal([newNode], viewModel.VisibleItems);
        }
        finally
        {
            releaseOld.TrySetResult();
        }
    }

    [Fact]
    public async Task DisposeSuppressesLateScanPublicationAndNotifications()
    {
        var scanner = new TaskCompletionSource<DiskScanResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var returned = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var viewModel = new MainViewModel(Services(scanAsync: async (_, _, _, _) =>
        {
            started.TrySetResult();
            var result = await scanner.Task;
            returned.TrySetResult();
            return result;
        }));
        var notificationsAfterDispose = 0;
        var disposed = false;
        viewModel.PropertyChanged += (_, _) =>
        {
            if (disposed)
            {
                Interlocked.Increment(ref notificationsAfterDispose);
            }
        };
        string? error = null;
        viewModel.ErrorRaised += (_, message) => error = message;

        var scan = viewModel.ScanAsync("C:\\blocked");
        try
        {
            await started.Task.WaitAsync(TimeSpan.FromSeconds(2));
            disposed = true;
            viewModel.Dispose();
            scanner.TrySetResult(Result(Root("late")));
            await Task.WhenAll(scan, returned.Task).WaitAsync(TimeSpan.FromSeconds(2));

            Assert.Null(viewModel.RootNode);
            Assert.Null(error);
            Assert.Equal(0, Volatile.Read(ref notificationsAfterDispose));
        }
        finally
        {
            disposed = true;
            viewModel.Dispose();
            scanner.TrySetResult(Result(Root("late")));
        }
    }

    [Fact]
    public async Task DisposeSuppressesLateVerificationPublicationAndNotifications()
    {
        var root = DuplicateRoot("root");
        var lateGroup = new VerifiedDuplicateGroup(new string('a', 64), 10_000_000, root.Children);
        var lateResult = new DuplicateVerificationResult([lateGroup], [], 0);
        var verifier = new TaskCompletionSource<DuplicateVerificationResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var returned = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var viewModel = new MainViewModel(Services(
            scanAsync: (_, _, _, _) => Task.FromResult(Result(root)),
            verifyAsync: async (_, _, _) =>
            {
                started.TrySetResult();
                var result = await verifier.Task;
                returned.TrySetResult();
                return result;
            }));
        await viewModel.ScanAsync("C:\\root");
        await viewModel.WaitForFilterAsync().WaitAsync(TimeSpan.FromSeconds(2));
        var originalStatus = viewModel.VerificationStatus;
        var notificationsAfterDispose = 0;
        var disposed = false;
        viewModel.PropertyChanged += (_, _) =>
        {
            if (disposed)
            {
                Interlocked.Increment(ref notificationsAfterDispose);
            }
        };
        viewModel.VerifiedDuplicates.CollectionChanged += (_, _) =>
        {
            if (disposed)
            {
                Interlocked.Increment(ref notificationsAfterDispose);
            }
        };

        var verification = viewModel.VerifyDuplicatesAsync();
        try
        {
            await started.Task.WaitAsync(TimeSpan.FromSeconds(2));
            disposed = true;
            viewModel.Dispose();
            verifier.TrySetResult(lateResult);
            await Task.WhenAll(verification, returned.Task).WaitAsync(TimeSpan.FromSeconds(2));

            Assert.Empty(viewModel.VerifiedDuplicates);
            Assert.Equal(originalStatus, viewModel.VerificationStatus);
            Assert.Equal(0, Volatile.Read(ref notificationsAfterDispose));
        }
        finally
        {
            disposed = true;
            viewModel.Dispose();
            verifier.TrySetResult(lateResult);
        }
    }

    [Fact]
    public async Task DisposeSuppressesLateFilterPublicationAndNotifications()
    {
        var filterStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseFilter = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var oldNode = File("C:\\root\\old.bin", "old.bin", 1);
        var newNode = File("C:\\root\\new.bin", "new.bin", 2);
        var root = new FileNode("C:\\root", "root", FileNodeKind.Directory, 3, 3, [oldNode, newNode]);
        var viewModel = new MainViewModel(Services(
            scanAsync: (_, _, _, _) => Task.FromResult(Result(root)),
            filter: (_, _, query, _, _, _, _) =>
            {
                if (query == "old")
                {
                    filterStarted.TrySetResult();
                    releaseFilter.Task.GetAwaiter().GetResult();
                    return new VisibleItemsResult([oldNode], 1);
                }
                return new VisibleItemsResult([oldNode, newNode], 2);
            }));
        await viewModel.ScanAsync("C:\\root");
        await viewModel.WaitForFilterAsync().WaitAsync(TimeSpan.FromSeconds(2));
        var originalItems = viewModel.VisibleItems.ToArray();
        var notificationsAfterDispose = 0;
        var disposed = false;
        viewModel.PropertyChanged += (_, _) =>
        {
            if (disposed)
            {
                Interlocked.Increment(ref notificationsAfterDispose);
            }
        };

        viewModel.SearchText = "old";
        var idle = viewModel.WaitForFilterAsync();
        try
        {
            await filterStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));
            disposed = true;
            viewModel.Dispose();
            releaseFilter.TrySetResult();
            await idle.WaitAsync(TimeSpan.FromSeconds(2));

            Assert.Equal(originalItems, viewModel.VisibleItems);
            Assert.Equal(0, Volatile.Read(ref notificationsAfterDispose));
        }
        finally
        {
            disposed = true;
            viewModel.Dispose();
            releaseFilter.TrySetResult();
        }
    }

    [Fact]
    public async Task OldNodeIsCanonicalizedToCurrentSnapshotByPath()
    {
        var oldFile = File("C:\\root\\same.bin", "old display", 1);
        var newFile = File("C:\\root\\same.bin", "new display", 2);
        var oldRoot = new FileNode("C:\\root", "root", FileNodeKind.Directory, 1, 1, [oldFile]);
        var newRoot = new FileNode("C:\\root", "root", FileNodeKind.Directory, 2, 2, [newFile]);
        var calls = 0;
        using var viewModel = new MainViewModel(Services(scanAsync: (_, _, _, _) =>
            Task.FromResult(Result(Interlocked.Increment(ref calls) == 1 ? oldRoot : newRoot))));

        await viewModel.ScanAsync("C:\\root");
        await viewModel.ScanAsync("C:\\root");

        Assert.True(viewModel.TryGetActiveNode(oldFile, out var canonical));
        Assert.Same(newFile, canonical);
    }

    [Fact]
    public async Task VerificationStatusReportsTotalUnreadableCountAndBoundedExamples()
    {
        var root = DuplicateRoot("root");
        using var viewModel = new MainViewModel(Services(
            scanAsync: (_, _, _, _) => Task.FromResult(Result(root)),
            verifyAsync: (_, _, _) => Task.FromResult(
                new DuplicateVerificationResult([], Enumerable.Repeat("path", 100).ToArray(), 101))));
        await viewModel.ScanAsync("C:\\root");

        await viewModel.VerifyDuplicatesAsync();

        Assert.Contains("101 files", viewModel.VerificationStatus, StringComparison.Ordinal);
        Assert.Contains("showing first 100", viewModel.VerificationStatus, StringComparison.Ordinal);
    }

    private static MainViewModelServices Services(
        Func<string, ScanOptions, IProgress<ScanProgress>?, CancellationToken, Task<DiskScanResult>>? scanAsync = null,
        Func<FileNode, CancellationToken, Task<ScanAnalysis>>? analyzeAsync = null,
        Func<IReadOnlyList<DuplicateCandidate>, IProgress<DuplicateVerificationProgress>?, CancellationToken, Task<DuplicateVerificationResult>>? verifyAsync = null,
        Func<FileNode, ScanAnalysis?, string, string?, long, FileSortOrder, CancellationToken, VisibleItemsResult>? filter = null) =>
        new(
            (path, options, progress, token) => FromTask(
                (scanAsync ?? ((_, _, _, _) => Task.FromResult(Result(Root("root")))))
                    (path, options, progress, token),
                token),
            analyzeAsync ?? ((root, token) => Task.FromResult(ScanAnalyzer.Analyze(root, token))),
            verifyAsync ?? ((_, _, _) => Task.FromResult(new DuplicateVerificationResult([], [], 0))),
            filter ?? VisibleItemsFilter.Apply,
            (_, _) => Task.CompletedTask,
            () => new AppSettings(),
            _ => { });

    private static DiskScanOperation FromTask(Task<DiskScanResult> task, CancellationToken token) =>
        new(task.WaitAsync(token), task, new TaskCompletionSource<Exception>().Task);

    private static DiskScanResult Result(FileNode root) =>
        new(
            root,
            root.TotalFileCount,
            root.TotalDirectoryCount,
            TimeSpan.FromMilliseconds(10),
            ScanDiagnostics.Empty,
            new ScanOptions(ShowHiddenFiles: true));

    private static FileNode Root(string name) =>
        new($"C:\\{name}", name, FileNodeKind.Directory, 0, 0);

    private static FileNode DuplicateRoot(string name)
    {
        var first = File($"C:\\{name}\\first.bin", "first.bin", 10_000_000);
        var second = File($"C:\\{name}\\second.bin", "second.bin", 10_000_000);
        return new FileNode($"C:\\{name}", name, FileNodeKind.Directory, 20_000_000, 20_000_000, [first, second]);
    }

    private static FileNode File(string path, string name, long size) =>
        new(path, name, FileNodeKind.File, size, size);

    private static async Task WaitUntilAsync(Func<bool> predicate)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        while (!predicate())
        {
            await Task.Delay(10, timeout.Token);
        }
    }

    private static void SetMaximum(ref int target, int value)
    {
        var current = Volatile.Read(ref target);
        while (value > current)
        {
            var observed = Interlocked.CompareExchange(ref target, value, current);
            if (observed == current)
            {
                return;
            }
            current = observed;
        }
    }
}
