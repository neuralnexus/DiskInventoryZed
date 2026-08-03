using System.Globalization;
using System.Text;
using DiskInventoryZed.Core.Export;
using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Core.Tests;

public sealed class ScanExporterAtomicityTests
{
    [Fact]
    public async Task SuccessfulExportReplacesAnExistingDestination()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");
        await File.WriteAllTextAsync(destination, "old-content");

        await ScanExporter.ExportCsvAsync(Tree(), destination);

        var content = await File.ReadAllTextAsync(destination);
        Assert.StartsWith("path,parent_path", content, StringComparison.Ordinal);
        Assert.DoesNotContain("old-content", content, StringComparison.Ordinal);
        Assert.Empty(TemporaryExports(fixture.Path, destination));
    }

    [Fact]
    public async Task CancelledExportPreservesExistingDestinationAndRemovesTemporaryFile()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");
        await File.WriteAllTextAsync(destination, "preserve-me");
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            ScanExporter.ExportCsvAsync(Tree(), destination, cancellation.Token));

        Assert.Equal("preserve-me", await File.ReadAllTextAsync(destination));
        Assert.Empty(TemporaryExports(fixture.Path, destination));
    }

    [Fact]
    public async Task CancellationAtCommitBoundaryPreservesExistingDestination()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");
        await File.WriteAllTextAsync(destination, "preserve-me");
        using var cancellation = new CancellationTokenSource();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ScanExporter.WriteAtomicallyAsync(
            destination,
            async stream => await stream.WriteAsync("replacement"u8.ToArray()),
            cancellation.Token,
            _ =>
            {
                cancellation.Cancel();
                return Task.CompletedTask;
            }));

        Assert.Equal("preserve-me", await File.ReadAllTextAsync(destination));
        Assert.Empty(TemporaryExports(fixture.Path, destination));
    }

    [Fact]
    public async Task CommitFailureLeavesNoTemporaryFile()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Directory.CreateDirectory(Path.Combine(fixture.Path, "destination.csv"));

        await Assert.ThrowsAnyAsync<IOException>(() =>
            ScanExporter.ExportCsvAsync(Tree(), destination.FullName));

        Assert.True(Directory.Exists(destination.FullName));
        Assert.Empty(TemporaryExports(fixture.Path, destination.FullName));
    }

    [Fact]
    public async Task LongDestinationNameDoesNotLengthenTemporaryComponent()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, new string('a', 240) + ".csv");

        await ScanExporter.ExportCsvAsync(Tree(), destination);

        Assert.True(File.Exists(destination));
        Assert.Empty(TemporaryExports(fixture.Path, destination));
    }

    [WindowsFact]
    public async Task ExtendedLengthDestinationCommitsSuccessfully()
    {
        using var fixture = new TemporaryDirectory();
        var directory = fixture.Path;
        while (directory.Length < 280)
        {
            directory = Directory.CreateDirectory(Path.Combine(directory, new string('d', 40))).FullName;
        }
        var destination = Path.Combine(directory, "inventory.csv");

        await ScanExporter.ExportCsvAsync(Tree(), destination);

        Assert.True(File.Exists(destination));
        Assert.Empty(TemporaryExports(directory, destination));
    }

    [WindowsFact]
    public async Task LockedExistingDestinationSurvivesReplaceFailure()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");
        await File.WriteAllTextAsync(destination, "preserve-me");
        await using (var locked = new FileStream(destination, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            await Assert.ThrowsAnyAsync<IOException>(() => ScanExporter.ExportCsvAsync(Tree(), destination));
        }

        Assert.Equal("preserve-me", await File.ReadAllTextAsync(destination));
        Assert.Empty(TemporaryExports(fixture.Path, destination));
    }

    [Fact]
    public async Task CsvIsUtf8WithoutBomAndCultureInvariant()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");
        var previousCulture = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("fr-FR");
            await ScanExporter.ExportCsvAsync(Tree(), destination);
        }
        finally
        {
            CultureInfo.CurrentCulture = previousCulture;
        }

        var bytes = await File.ReadAllBytesAsync(destination);
        Assert.False(bytes.AsSpan().StartsWith(Encoding.UTF8.Preamble));
        Assert.Contains(",4096,1234,", Encoding.UTF8.GetString(bytes), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("\tplain.txt")]
    [InlineData("\rplain.txt")]
    [InlineData("\nplain.txt")]
    [InlineData("\uFEFFplain.txt")]
    [InlineData("  \tplain.txt")]
    public async Task CsvNeutralizesHazardousControlPrefixes(string name)
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");
        var file = new FileNode(Path.Combine(fixture.Path, name), name, FileNodeKind.File, 1, 1);
        var root = new FileNode(fixture.Path, "fixture", FileNodeKind.Directory, 1, 1, [file]);

        await ScanExporter.ExportCsvAsync(root, destination);

        Assert.Contains($"\"'{name.Replace("\"", "\"\"")}\"", await File.ReadAllTextAsync(destination));
    }

    private static IReadOnlyList<string> TemporaryExports(string directory, string destination) =>
        Directory.GetFiles(directory, ".diz-*.tmp");

    private static FileNode Tree()
    {
        var file = new FileNode("C:\\fixture\\file.bin", "file.bin", FileNodeKind.File, 1234, 4096);
        return new FileNode("C:\\fixture", "fixture", FileNodeKind.Directory, 1234, 4096, [file]);
    }
}
