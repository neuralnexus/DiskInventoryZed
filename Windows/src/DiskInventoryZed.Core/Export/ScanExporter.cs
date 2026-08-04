using System.Text;
using System.Text.Json;
using System.Globalization;
using System.ComponentModel;
using System.Runtime.InteropServices;
using DiskInventoryZed.Core.Models;
using DiskInventoryZed.Core.Scanning;

namespace DiskInventoryZed.Core.Export;

public static partial class ScanExporter
{
    private const uint MoveFileReplaceExisting = 0x00000001;
    private const uint MoveFileWriteThrough = 0x00000008;

    public static async Task ExportJsonAsync(
        FileNode root,
        ScanDiagnostics diagnostics,
        string destinationPath,
        ScanOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        await WriteAtomicallyAsync(destinationPath, async stream =>
        {
            using var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = false });
            writer.WriteStartObject();
            writer.WriteNumber("schemaVersion", 3);
            writer.WriteString("exportedAt", JsonDate(DateTimeOffset.UtcNow));
            writer.WriteString("rootPath", root.FullPath);
            WriteDiagnostics(writer, diagnostics);
            WriteOptions(writer, options);
            writer.WriteStartArray("entries");

            var stack = new Stack<(FileNode Node, string? ParentPath)>();
            stack.Push((root, null));
            while (stack.TryPop(out var item))
            {
                cancellationToken.ThrowIfCancellationRequested();
                WriteEntry(writer, item.Node, item.ParentPath);
                for (var index = item.Node.Children.Count - 1; index >= 0; index--)
                {
                    stack.Push((item.Node.Children[index], item.Node.FullPath));
                }
            }

            writer.WriteEndArray();
            writer.WriteEndObject();
            await writer.FlushAsync(cancellationToken);
        }, cancellationToken);
    }

    public static async Task ExportCsvAsync(
        FileNode root,
        string destinationPath,
        CancellationToken cancellationToken = default)
    {
        await WriteAtomicallyAsync(destinationPath, async stream =>
        {
            await using var writer = new StreamWriter(stream, new UTF8Encoding(false), 64 * 1024, leaveOpen: true);
            await writer.WriteLineAsync("path,parent_path,name,kind,is_package,is_symbolic_link,allocated_bytes,logical_bytes,child_count,total_file_count,total_directory_count,created_at,modified_at,hard_link_duplicate,hard_link_identity_unavailable,issue,is_unreadable");
            var stack = new Stack<(FileNode Node, string? ParentPath)>();
            stack.Push((root, null));
            while (stack.TryPop(out var item))
            {
                cancellationToken.ThrowIfCancellationRequested();
                var node = item.Node;
                var fields = new[]
                {
                    Csv(node.FullPath),
                    Csv(item.ParentPath ?? string.Empty),
                    Csv(node.DisplayName),
                    Csv(KindName(node.Kind)),
                    node.IsPackage ? "true" : "false",
                    node.IsSymbolicLink ? "true" : "false",
                    node.AllocatedSize.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    node.LogicalSize.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    node.Children.Count.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    node.TotalFileCount.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    node.TotalDirectoryCount.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    Csv(node.CreationDate?.ToString("O") ?? string.Empty),
                    Csv(node.ModificationDate?.ToString("O") ?? string.Empty),
                    node.IsHardLinkDuplicate ? "true" : "false",
                    node.HasUnverifiedHardLinks ? "true" : "false",
                    Csv(node.Issue ?? string.Empty),
                    node.IsUnreadable ? "true" : "false"
                };
                await writer.WriteLineAsync(string.Join(',', fields).AsMemory(), cancellationToken);
                for (var index = node.Children.Count - 1; index >= 0; index--)
                {
                    stack.Push((node.Children[index], node.FullPath));
                }
            }

            await writer.FlushAsync(cancellationToken);
        }, cancellationToken);
    }

    private static void WriteDiagnostics(Utf8JsonWriter writer, ScanDiagnostics diagnostics)
    {
        writer.WriteStartObject("diagnostics");
        writer.WriteNumber("unreadableItems", diagnostics.UnreadableItems);
        writer.WriteNumber("skippedDirectories", diagnostics.SkippedDirectories);
        writer.WriteNumber("hiddenItemsExcluded", diagnostics.HiddenItemsExcluded);
        writer.WriteNumber("symbolicLinks", diagnostics.SymbolicLinks);
        writer.WriteNumber("packages", diagnostics.Packages);
        writer.WriteNumber("duplicateHardLinks", diagnostics.DuplicateHardLinks);
        writer.WriteNumber("unverifiedHardLinks", diagnostics.UnverifiedHardLinks);
        writer.WriteNumber("revisitedDirectories", diagnostics.RevisitedDirectories);
        writer.WriteNumber("approximateAllocatedSizes", diagnostics.ApproximateAllocatedSizes);
        writer.WriteNumber("metadataUnavailableItems", diagnostics.MetadataUnavailableItems);
        writer.WriteStartArray("firstUnreadablePaths");
        foreach (var path in diagnostics.FirstUnreadablePaths)
        {
            writer.WriteStringValue(path);
        }

        writer.WriteEndArray();
        writer.WriteEndObject();
    }

    private static void WriteOptions(Utf8JsonWriter writer, ScanOptions? options)
    {
        if (options is null)
        {
            return;
        }

        writer.WriteStartObject("scanOptions");
        writer.WriteBoolean("skipDeveloperFolders", options.SkipDeveloperFolders);
        writer.WriteBoolean("showHiddenFiles", options.ShowHiddenFiles);
        writer.WriteBoolean("followReparsePoints", options.FollowReparsePoints);
        writer.WriteNumber("maximumEntries", options.MaximumEntries);
        writer.WriteEndObject();
    }

    private static void WriteEntry(Utf8JsonWriter writer, FileNode node, string? parentPath)
    {
        writer.WriteStartObject();
        writer.WriteString("path", node.FullPath);
        if (parentPath is null)
        {
            writer.WriteNull("parentPath");
        }
        else
        {
            writer.WriteString("parentPath", parentPath);
        }

        writer.WriteString("name", node.DisplayName);
        writer.WriteString("kind", KindName(node.Kind));
        writer.WriteBoolean("isPackage", node.IsPackage);
        writer.WriteBoolean("isSymbolicLink", node.IsSymbolicLink);
        writer.WriteNumber("allocatedSize", node.AllocatedSize);
        writer.WriteNumber("logicalSize", node.LogicalSize);
        writer.WriteNumber("childCount", node.Children.Count);
        writer.WriteNumber("totalFileCount", node.TotalFileCount);
        writer.WriteNumber("totalDirectoryCount", node.TotalDirectoryCount);
        if (node.CreationDate is { } creationDate)
        {
            writer.WriteString("creationDate", JsonDate(creationDate));
        }

        if (node.ModificationDate is { } modificationDate)
        {
            writer.WriteString("modificationDate", JsonDate(modificationDate));
        }

        writer.WriteBoolean("isHardLinkDuplicate", node.IsHardLinkDuplicate);
        writer.WriteBoolean("hardLinkIdentityUnavailable", node.HasUnverifiedHardLinks);
        writer.WriteBoolean("isUnreadable", node.IsUnreadable);
        if (node.Issue is not null)
        {
            writer.WriteString("issue", node.Issue);
        }

        writer.WriteEndObject();
    }

    private static string KindName(FileNodeKind kind) => kind switch
    {
        FileNodeKind.File => "file",
        FileNodeKind.Directory => "directory",
        FileNodeKind.Package => "package",
        FileNodeKind.SymbolicLink => "symbolicLink",
        _ => "file"
    };

    private static string Csv(string value)
    {
        var hasHazardousLeadingControl = value
            .TakeWhile(character => char.IsWhiteSpace(character) || character == '\uFEFF')
            .Any(character => character is '\t' or '\r' or '\n' or '\uFEFF');
        var firstMeaningful = value.FirstOrDefault(character =>
            !char.IsWhiteSpace(character) && character != '\uFEFF');
        if (hasHazardousLeadingControl || firstMeaningful is '=' or '+' or '-' or '@')
        {
            value = "'" + value;
        }

        return $"\"{value.Replace("\"", "\"\"")}\"";
    }

    private static string JsonDate(DateTimeOffset value) =>
        value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    internal static async Task WriteAtomicallyAsync(
        string destinationPath,
        Func<FileStream, Task> write,
        CancellationToken cancellationToken,
        Func<CancellationToken, Task>? beforeCommit = null)
    {
        var fullPath = Path.GetFullPath(destinationPath);
        var directory = Path.GetDirectoryName(fullPath)
            ?? throw new IOException("The export destination does not have a parent folder.");
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(directory, $".diz-{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                64 * 1024,
                FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                await write(stream);
                await stream.FlushAsync(cancellationToken);
                stream.Flush(flushToDisk: true);
            }

            if (beforeCommit is not null)
            {
                await beforeCommit(cancellationToken);
            }
            cancellationToken.ThrowIfCancellationRequested();
            CommitTemporaryFile(temporaryPath, fullPath);
        }
        catch
        {
            TryDelete(temporaryPath);
            throw;
        }
    }

    private static void CommitTemporaryFile(string temporaryPath, string destinationPath)
    {
        if (!OperatingSystem.IsWindows())
        {
            File.Move(temporaryPath, destinationPath, overwrite: true);
            return;
        }

        if (!MoveFileExW(
                ToExtendedPath(temporaryPath),
                ToExtendedPath(destinationPath),
                MoveFileReplaceExisting | MoveFileWriteThrough))
        {
            throw new IOException(
                "The completed export could not replace the destination.",
                new Win32Exception(Marshal.GetLastPInvokeError()));
        }
    }

    private static string ToExtendedPath(string path)
    {
        if (path.StartsWith("\\\\?\\", StringComparison.Ordinal) ||
            path.StartsWith("\\\\.\\", StringComparison.Ordinal))
        {
            return path;
        }

        return path.StartsWith("\\\\", StringComparison.Ordinal)
            ? "\\\\?\\UNC\\" + path[2..]
            : "\\\\?\\" + path;
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch
        {
            // Preserve the operation failure; a complete recovery artifact may remain.
        }
    }

    [LibraryImport("kernel32.dll", EntryPoint = "MoveFileExW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool MoveFileExW(string existingFileName, string newFileName, uint flags);
}
