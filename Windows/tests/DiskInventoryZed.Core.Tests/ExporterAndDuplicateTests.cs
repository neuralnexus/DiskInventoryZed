using System.Text.Json;
using DiskInventoryZed.Core.Analysis;
using DiskInventoryZed.Core.Export;
using DiskInventoryZed.Core.Models;
using DiskInventoryZed.Core.Scanning;

namespace DiskInventoryZed.Core.Tests;

public sealed class ExporterAndDuplicateTests
{
    [Fact]
    public async Task JsonExportKeepsSchemaThreeAndPortableIsoDates()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "snapshot.json");
        var modified = new DateTimeOffset(2026, 7, 31, 20, 33, 0, TimeSpan.Zero).AddTicks(1234);
        var file = new FileNode(
            Path.Combine(fixture.Path, "quoted,\"file.bin"),
            "quoted,\"file.bin",
            FileNodeKind.File,
            10,
            16,
            modificationDate: modified);
        var root = new FileNode(fixture.Path, "fixture", FileNodeKind.Directory, 10, 16, [file]);
        var diagnostics = ScanDiagnostics.Empty with { ApproximateAllocatedSizes = 1 };

        await ScanExporter.ExportJsonAsync(root, diagnostics, destination);

        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(destination));
        var jsonRoot = document.RootElement;
        Assert.Equal(3, jsonRoot.GetProperty("schemaVersion").GetInt32());
        Assert.Matches("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$", jsonRoot.GetProperty("exportedAt").GetString()!);
        Assert.Equal(1, jsonRoot.GetProperty("diagnostics").GetProperty("approximateAllocatedSizes").GetInt32());
        Assert.Equal("2026-07-31T20:33:00Z", jsonRoot.GetProperty("entries")[1].GetProperty("modificationDate").GetString());
    }

    [Fact]
    public async Task CsvExportEscapesNamesAndIncludesBothSizes()
    {
        using var fixture = new TemporaryDirectory();
        var destination = Path.Combine(fixture.Path, "inventory.csv");
        var file = new FileNode(Path.Combine(fixture.Path, "a,\"b.bin"), "a,\"b.bin", FileNodeKind.File, 10, 16);
        var root = new FileNode(fixture.Path, "fixture", FileNodeKind.Directory, 10, 16, [file]);

        await ScanExporter.ExportCsvAsync(root, destination);
        var csv = await File.ReadAllTextAsync(destination);

        Assert.Contains("allocated_bytes,logical_bytes", csv);
        Assert.Contains("\"a,\"\"b.bin\"", csv);
        Assert.Contains(",16,10,", csv);
    }

    [Fact]
    public async Task DuplicateVerifierRejectsSameSizeDifferentContent()
    {
        using var fixture = new TemporaryDirectory();
        var firstPath = Path.Combine(fixture.Path, "first.bin");
        var secondPath = Path.Combine(fixture.Path, "second.bin");
        await File.WriteAllBytesAsync(firstPath, Enumerable.Repeat((byte)0xAA, 4096).ToArray());
        await File.WriteAllBytesAsync(secondPath, Enumerable.Repeat((byte)0xBB, 4096).ToArray());
        var first = NodeFor(firstPath);
        var second = NodeFor(secondPath);

        var result = await DuplicateVerifier.VerifyAsync([new DuplicateCandidate(4096, [first, second])]);

        Assert.Empty(result.Groups);
    }

    [Fact]
    public async Task DuplicateVerifierFindsRenamedExactCopies()
    {
        using var fixture = new TemporaryDirectory();
        var firstPath = Path.Combine(fixture.Path, "first.bin");
        var secondPath = Path.Combine(fixture.Path, "renamed.bin");
        var content = Enumerable.Range(0, 8192).Select(index => (byte)(index % 251)).ToArray();
        await File.WriteAllBytesAsync(firstPath, content);
        await File.WriteAllBytesAsync(secondPath, content);
        var first = NodeFor(firstPath);
        var second = NodeFor(secondPath);

        var result = await DuplicateVerifier.VerifyAsync([new DuplicateCandidate(content.Length, [first, second])]);

        var group = Assert.Single(result.Groups);
        Assert.Equal(2, group.Files.Count);
        Assert.Equal(64, group.Digest.Length);
    }

    private static FileNode NodeFor(string path)
    {
        var info = new FileInfo(path);
        return new FileNode(path, info.Name, FileNodeKind.File, info.Length, info.Length, modificationDate: info.LastWriteTimeUtc);
    }
}
