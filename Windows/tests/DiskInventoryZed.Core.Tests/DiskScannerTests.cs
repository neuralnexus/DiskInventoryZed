using System.Runtime.InteropServices;
using System.Diagnostics;
using DiskInventoryZed.Core.Analysis;
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

    [WindowsFact]
    public async Task WindowsHardLinksAreCountedOnceOnDisk()
    {
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

    [WindowsFact]
    public async Task WindowsAllocationComesFromHandleMetadata()
    {
        using var fixture = new TemporaryDirectory();
        await File.WriteAllBytesAsync(Path.Combine(fixture.Path, "one-byte.bin"), [0x2A]);

        var result = await new DiskScanner().ScanAsync(fixture.Path, new ScanOptions(ShowHiddenFiles: true));
        var file = Assert.Single(result.Root.Children);

        Assert.Equal(1, file.LogicalSize);
        Assert.True(file.AllocatedSize >= file.LogicalSize);
        Assert.Equal(0, result.Diagnostics.ApproximateAllocatedSizes);
    }

    [WindowsFact]
    public async Task WindowsJunctionsAreNotFollowedByDefault()
    {
        using var fixture = new TemporaryDirectory();
        var target = Directory.CreateDirectory(Path.Combine(fixture.Path, "target"));
        await File.WriteAllBytesAsync(Path.Combine(target.FullName, "inside.bin"), new byte[1024]);
        var junction = Path.Combine(fixture.Path, "junction");
        await CreateJunctionAsync(junction, target.FullName);

        var result = await new DiskScanner().ScanAsync(fixture.Path, new ScanOptions(ShowHiddenFiles: true));
        var junctionNode = result.Root.Children.Single(node => node.DisplayName == "junction");

        Assert.Equal(FileNodeKind.SymbolicLink, junctionNode.Kind);
        Assert.True(junctionNode.IsSymbolicLink);
        Assert.Empty(junctionNode.Children);
        Assert.True(result.Diagnostics.SymbolicLinks >= 1);
    }

    [WindowsFact]
    public async Task WindowsJunctionCannotBypassRootLinkPolicy()
    {
        using var fixture = new TemporaryDirectory();
        var target = Directory.CreateDirectory(Path.Combine(fixture.Path, "target"));
        var junction = Path.Combine(fixture.Path, "junction");
        await CreateJunctionAsync(junction, target.FullName);

        var error = await Assert.ThrowsAsync<DiskScanException>(() => new DiskScanner().ScanAsync(junction));

        Assert.Contains("Enable Follow links", error.Message, StringComparison.Ordinal);
    }

    [WindowsFact]
    public async Task WindowsHiddenAttributeControlsEnumeration()
    {
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

    [WindowsFact]
    public async Task WindowsHiddenDirectoryExcludesItsDescendantsAsOneEncounteredEntry()
    {
        using var fixture = new TemporaryDirectory();
        var hidden = Directory.CreateDirectory(Path.Combine(fixture.Path, "hidden"));
        await File.WriteAllBytesAsync(Path.Combine(hidden.FullName, "inside.bin"), [1]);
        File.SetAttributes(hidden.FullName, File.GetAttributes(hidden.FullName) | FileAttributes.Hidden);

        var result = await new DiskScanner().ScanAsync(fixture.Path);

        Assert.DoesNotContain(result.Root.Children, node => node.DisplayName == "hidden");
        Assert.Equal(1, result.Diagnostics.HiddenItemsExcluded);
        Assert.Equal(0, result.TotalFiles);
    }

    [WindowsFact]
    public async Task WindowsFollowedJunctionCycleIsVisitedOnlyOnce()
    {
        using var fixture = new TemporaryDirectory();
        var target = Directory.CreateDirectory(Path.Combine(fixture.Path, "target"));
        await File.WriteAllBytesAsync(Path.Combine(target.FullName, "inside.bin"), [1]);
        var backLink = Path.Combine(target.FullName, "back-to-root");
        await CreateJunctionAsync(backLink, fixture.Path);

        var result = await new DiskScanner().ScanAsync(
            fixture.Path,
            new ScanOptions(ShowHiddenFiles: true, FollowReparsePoints: true));
        var targetNode = result.Root.Children.Single(node => node.DisplayName == "target");
        var cycleNode = targetNode.Children.Single(node => node.DisplayName == "back-to-root");

        Assert.Equal(FileNodeKind.SymbolicLink, cycleNode.Kind);
        Assert.Empty(cycleNode.Children);
        Assert.Equal(1, result.Diagnostics.RevisitedDirectories);
        Assert.NotNull(targetNode.FindById(Path.Combine(target.FullName, "inside.bin")));
    }

    [WindowsFact]
    public void WindowsDuplicateReadHandlePreventsPathReplacement()
    {
        using var fixture = new TemporaryDirectory();
        var path = Path.Combine(fixture.Path, "open.bin");
        var replacement = Path.Combine(fixture.Path, "renamed.bin");
        File.WriteAllBytes(path, [1, 2, 3]);

        using var stream = DuplicateVerifier.OpenRead(path);

        Assert.True(stream.IsAsync);
        Assert.Throws<IOException>(() => File.Move(path, replacement));
        Assert.True(File.Exists(path));
        Assert.False(File.Exists(replacement));
    }

    [WindowsFact]
    public void WindowsDirectoryGuardBlocksRenameAndReleasesItOnDispose()
    {
        using var fixture = new TemporaryDirectory();
        var path = Directory.CreateDirectory(Path.Combine(fixture.Path, "guarded")).FullName;
        var moved = Path.Combine(fixture.Path, "moved");
        var identity = WindowsFileMetadata.Read(path, true, false, 0, false).Identity;
        Assert.NotNull(identity);

        using (WindowsFileMetadata.OpenDirectoryGuard(path, false, identity))
        {
            Assert.Throws<IOException>(() => Directory.Move(path, moved));
        }

        Directory.Move(path, moved);
        Assert.True(Directory.Exists(moved));
    }

    [WindowsFact]
    public async Task WindowsDirectoryGuardRejectsAChangedJunctionIdentityAndReleasesHandles()
    {
        using var fixture = new TemporaryDirectory();
        var expectedPath = Directory.CreateDirectory(Path.Combine(fixture.Path, "expected-target")).FullName;
        var actualPath = Directory.CreateDirectory(Path.Combine(fixture.Path, "actual-target")).FullName;
        var movedActual = Path.Combine(fixture.Path, "moved-actual");
        var junction = Path.Combine(fixture.Path, "junction");
        await CreateJunctionAsync(junction, actualPath);
        var expectedIdentity = WindowsFileMetadata.Read(expectedPath, true, false, 0, false).Identity;
        Assert.NotNull(expectedIdentity);

        Assert.Throws<IOException>(() =>
            WindowsFileMetadata.OpenDirectoryGuard(junction, true, expectedIdentity));

        Directory.Delete(junction);
        Directory.Move(actualPath, movedActual);
        Assert.True(Directory.Exists(movedActual));
    }

    [WindowsFact]
    public async Task WindowsDirectoryGuardRetainsFollowedJunctionEntryAndTarget()
    {
        using var fixture = new TemporaryDirectory();
        var target = Directory.CreateDirectory(Path.Combine(fixture.Path, "target"));
        var movedTarget = Path.Combine(fixture.Path, "moved-target");
        var junction = Path.Combine(fixture.Path, "junction");
        await CreateJunctionAsync(junction, target.FullName);
        var metadata = WindowsFileMetadata.Read(junction, true, true, 0, true);
        Assert.NotNull(metadata.Identity);

        using (WindowsFileMetadata.OpenDirectoryGuard(junction, true, metadata.Identity))
        {
            Assert.Throws<IOException>(() => Directory.Delete(junction));
            Assert.Throws<IOException>(() => Directory.Move(target.FullName, movedTarget));
        }

        Directory.Delete(junction);
        Directory.Move(target.FullName, movedTarget);
        Assert.True(Directory.Exists(movedTarget));
    }

    [WindowsFact]
    public async Task WindowsUnfollowedJunctionMetadataNeverReadsTheTargetIdentity()
    {
        using var fixture = new TemporaryDirectory();
        var target = Directory.CreateDirectory(Path.Combine(fixture.Path, "target"));
        var junction = Path.Combine(fixture.Path, "junction");
        await CreateJunctionAsync(junction, target.FullName);

        var unfollowed = WindowsFileMetadata.Read(junction, true, true, 0, false);
        var followed = WindowsFileMetadata.Read(junction, true, true, 0, true);

        Assert.Equal(ReparsePointClassification.NameSurrogate, unfollowed.ReparsePointClassification);
        Assert.Null(unfollowed.Identity);
        Assert.Equal(0, unfollowed.LogicalSize);
        Assert.NotNull(followed.Identity);
    }

    [WindowsFact]
    public void WindowsDuplicateReadRejectsAReplacementSymlink()
    {
        using var fixture = new TemporaryDirectory();
        var target = Path.Combine(fixture.Path, "target.bin");
        var link = Path.Combine(fixture.Path, "replacement.bin");
        File.WriteAllBytes(target, [1, 2, 3]);
        File.CreateSymbolicLink(link, target);

        Assert.Throws<IOException>(() => DuplicateVerifier.OpenRead(link));
    }

    [WindowsFact]
    public void WindowsMetadataUsesTheHandleWhenTheAttributeHintIsStale()
    {
        using var fixture = new TemporaryDirectory();
        var target = Path.Combine(fixture.Path, "target.bin");
        var link = Path.Combine(fixture.Path, "changed-after-attributes.bin");
        File.WriteAllBytes(target, new byte[4096]);
        File.CreateSymbolicLink(link, target);

        var metadata = WindowsFileMetadata.Read(
            link,
            isDirectory: false,
            isReparsePoint: false,
            logicalSize: 4096,
            followReparsePoints: false);

        Assert.Equal(ReparsePointClassification.NameSurrogate, metadata.ReparsePointClassification);
        Assert.Equal(0, metadata.LogicalSize);
        Assert.Null(metadata.Identity);
    }

    private static async Task CreateJunctionAsync(string junction, string target)
    {
        using var process = Process.Start(new ProcessStartInfo
        {
            FileName = "cmd.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            ArgumentList = { "/d", "/c", "mklink", "/J", junction, target }
        });
        Assert.NotNull(process);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        try
        {
            await process.WaitForExitAsync(timeout.Token);
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
                // The process exited after the timeout was observed.
            }

            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
            throw new TimeoutException("Creating the test junction did not finish within 10 seconds.");
        }
        Assert.Equal(0, process.ExitCode);
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
