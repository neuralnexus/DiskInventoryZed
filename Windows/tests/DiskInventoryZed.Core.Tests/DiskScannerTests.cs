using System.Runtime.InteropServices;
using System.Diagnostics;
using DiskInventoryZed.Core.Models;
using DiskInventoryZed.Core.Scanning;

namespace DiskInventoryZed.Core.Tests;

public sealed partial class DiskScannerTests
{
    [Fact]
    public async Task ScanBuildsCompleteImmutableTree()
    {
        using var fixture = new TemporaryDirectory();
        var nested = Directory.CreateDirectory(Path.Combine(fixture.Path, "nested"));
        await File.WriteAllBytesAsync(Path.Combine(fixture.Path, "root.bin"), new byte[4096]);
        await File.WriteAllBytesAsync(Path.Combine(nested.FullName, "nested.bin"), new byte[8192]);

        var result = await new DiskScanner().ScanAsync(
            fixture.Path,
            new ScanOptions(ShowHiddenFiles: true));

        Assert.Equal(2, result.TotalFiles);
        Assert.Equal(2, result.TotalDirectories);
        Assert.Equal(2, result.Root.Children.Count);
        Assert.True(result.Root.LogicalSize >= 12_288);
        Assert.True(result.Root.AllocatedSize > 0);
        Assert.NotNull(result.Root.FindById(Path.Combine(nested.FullName, "nested.bin")));
    }

    [Fact]
    public async Task CancelledScanThrowsCancellation()
    {
        using var fixture = new TemporaryDirectory();
        for (var index = 0; index < 100; index++)
        {
            var folder = Directory.CreateDirectory(Path.Combine(fixture.Path, $"folder-{index}"));
            await File.WriteAllBytesAsync(Path.Combine(folder.FullName, "file.bin"), new byte[512]);
        }

        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new DiskScanner().ScanAsync(fixture.Path, cancellationToken: cancellation.Token));
    }

    [Fact]
    public async Task WindowsHardLinksAreCountedOnceOnDisk()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var fixture = new TemporaryDirectory();
        var original = Path.Combine(fixture.Path, "original.bin");
        var linked = Path.Combine(fixture.Path, "linked.bin");
        await File.WriteAllBytesAsync(original, new byte[16_384]);
        Assert.True(CreateHardLinkW(linked, original, IntPtr.Zero));

        var result = await new DiskScanner().ScanAsync(fixture.Path, new ScanOptions(ShowHiddenFiles: true));
        var files = result.Root.Children.Where(node => !node.IsDirectory).ToArray();

        Assert.Equal(2, files.Length);
        Assert.Single(files, file => file.IsHardLinkDuplicate);
        Assert.Equal(1, result.Diagnostics.DuplicateHardLinks);
        Assert.Equal(files.Max(file => file.AllocatedSize), result.Root.AllocatedSize);
        Assert.Equal(32_768, result.Root.LogicalSize);
    }

    [Fact]
    public async Task WindowsAllocationComesFromHandleMetadata()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var fixture = new TemporaryDirectory();
        await File.WriteAllBytesAsync(Path.Combine(fixture.Path, "one-byte.bin"), [0x2A]);

        var result = await new DiskScanner().ScanAsync(fixture.Path, new ScanOptions(ShowHiddenFiles: true));
        var file = Assert.Single(result.Root.Children);

        Assert.Equal(1, file.LogicalSize);
        Assert.True(file.AllocatedSize >= file.LogicalSize);
        Assert.Equal(0, result.Diagnostics.ApproximateAllocatedSizes);
    }

    [Fact]
    public async Task WindowsJunctionsAreNotFollowedByDefault()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var fixture = new TemporaryDirectory();
        var target = Directory.CreateDirectory(Path.Combine(fixture.Path, "target"));
        await File.WriteAllBytesAsync(Path.Combine(target.FullName, "inside.bin"), new byte[1024]);
        var junction = Path.Combine(fixture.Path, "junction");
        using var process = Process.Start(new ProcessStartInfo
        {
            FileName = "cmd.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            ArgumentList = { "/d", "/c", "mklink", "/J", junction, target.FullName }
        });
        Assert.NotNull(process);
        await process.WaitForExitAsync();
        Assert.Equal(0, process.ExitCode);

        var result = await new DiskScanner().ScanAsync(fixture.Path, new ScanOptions(ShowHiddenFiles: true));
        var junctionNode = result.Root.Children.Single(node => node.DisplayName == "junction");

        Assert.Equal(FileNodeKind.SymbolicLink, junctionNode.Kind);
        Assert.True(junctionNode.IsSymbolicLink);
        Assert.Empty(junctionNode.Children);
        Assert.True(result.Diagnostics.SymbolicLinks >= 1);
    }

    [Fact]
    public async Task WindowsJunctionCannotBypassRootLinkPolicy()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var fixture = new TemporaryDirectory();
        var target = Directory.CreateDirectory(Path.Combine(fixture.Path, "target"));
        var junction = Path.Combine(fixture.Path, "junction");
        using var process = Process.Start(new ProcessStartInfo
        {
            FileName = "cmd.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            ArgumentList = { "/d", "/c", "mklink", "/J", junction, target.FullName }
        });
        Assert.NotNull(process);
        await process.WaitForExitAsync();
        Assert.Equal(0, process.ExitCode);

        var error = await Assert.ThrowsAsync<DiskScanException>(() => new DiskScanner().ScanAsync(junction));

        Assert.Contains("Enable Follow links", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task WindowsHiddenAttributeControlsEnumeration()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var fixture = new TemporaryDirectory();
        var hiddenPath = Path.Combine(fixture.Path, "hidden.bin");
        await File.WriteAllBytesAsync(hiddenPath, new byte[64]);
        File.SetAttributes(hiddenPath, File.GetAttributes(hiddenPath) | FileAttributes.Hidden);

        var hiddenExcluded = await new DiskScanner().ScanAsync(fixture.Path);
        var hiddenIncluded = await new DiskScanner().ScanAsync(fixture.Path, new ScanOptions(ShowHiddenFiles: true));

        Assert.DoesNotContain(hiddenExcluded.Root.Children, node => node.DisplayName == "hidden.bin");
        Assert.Equal(1, hiddenExcluded.Diagnostics.HiddenItemsExcluded);
        Assert.Contains(hiddenIncluded.Root.Children, node => node.DisplayName == "hidden.bin");
        Assert.Equal(0, hiddenIncluded.Diagnostics.HiddenItemsExcluded);
    }

    [LibraryImport("kernel32.dll", EntryPoint = "CreateHardLinkW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CreateHardLinkW(string fileName, string existingFileName, IntPtr securityAttributes);
}

internal sealed class TemporaryDirectory : IDisposable
{
    public TemporaryDirectory()
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"DiskInventoryZedTests-{Guid.NewGuid():N}");
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
