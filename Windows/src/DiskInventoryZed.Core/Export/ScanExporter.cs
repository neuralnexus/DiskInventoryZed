using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using DiskInventoryZed.Core.Models;
using DiskInventoryZed.Core.Scanning;

namespace DiskInventoryZed.Core.Export;

public static partial class ScanExporter
{
    private const uint MoveFileWriteThrough = 0x00000008;
    private const int ErrorUnableToMoveReplacement2 = 1177;

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
        cancellationToken.ThrowIfCancellationRequested();
        Directory.CreateDirectory(directory);
        var operationId = Guid.NewGuid().ToString("N");
        var temporaryPath = Path.Combine(directory, $".diz-{operationId}.tmp");
        if (OperatingSystem.IsWindows())
        {
            var backupPath = Path.Combine(directory, $".diz-{operationId}.bak");
            var securityTemplatePath = Path.Combine(directory, $".diz-{operationId}.acl");
            await WriteAtomicallyWindowsAsync(
                temporaryPath,
                backupPath,
                securityTemplatePath,
                fullPath,
                write,
                cancellationToken,
                beforeCommit);
            return;
        }

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
            File.Move(temporaryPath, fullPath, overwrite: true);
        }
        catch
        {
            TryDelete(temporaryPath);
            throw;
        }
    }

    [SupportedOSPlatform("windows")]
    private static async Task WriteAtomicallyWindowsAsync(
        string temporaryPath,
        string backupPath,
        string securityTemplatePath,
        string destinationPath,
        Func<FileStream, Task> write,
        CancellationToken cancellationToken,
        Func<CancellationToken, Task>? beforeCommit)
    {
        using var identity = WindowsIdentity.GetCurrent();
        var caller = identity.User
            ?? throw new IOException("The current Windows token does not have a user identity.");
        var temporarySecurity = CreatePrivateFileSecurity(caller);
        var originalDestination = TryGetFileSnapshot(destinationPath, FileShare.ReadWrite | FileShare.Delete);
        var defaultSecurity = originalDestination is null
            ? CaptureDefaultFileSecurity(securityTemplatePath)
            : null;
        var defaultOwner = defaultSecurity is null
            ? caller
            : GetRequiredOwner(defaultSecurity);
        var defaultGroup = defaultSecurity is null
            ? caller
            : GetRequiredGroup(defaultSecurity);

        try
        {
            FileIdentity stagedIdentity;
            await using (var stream = new FileInfo(temporaryPath).Create(
                FileMode.CreateNew,
                FileSystemRights.FullControl,
                FileShare.None,
                64 * 1024,
                FileOptions.Asynchronous | FileOptions.SequentialScan | FileOptions.WriteThrough,
                temporarySecurity))
            {
                VerifyPrivateFileSecurity(stream, caller);
                stagedIdentity = ReadFileVersion(stream).Identity;
                await write(stream);
                await stream.FlushAsync(cancellationToken);
                stream.Flush(flushToDisk: true);
            }

            FileVersion completedVersion;
            using (var completedStream = new FileStream(
                temporaryPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read))
            {
                VerifyPrivateFileSecurity(completedStream, caller);
                completedVersion = ReadFileVersion(completedStream);
                if (completedVersion.Identity != stagedIdentity)
                {
                    throw new IOException("The export staging file identity changed while it was written.");
                }
            }

            if (beforeCommit is not null)
            {
                await beforeCommit(cancellationToken);
            }
            cancellationToken.ThrowIfCancellationRequested();

            using (var completedStream = new FileStream(
                temporaryPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read))
            {
                VerifyPrivateFileSecurity(completedStream, caller);
                if (ReadFileVersion(completedStream) != completedVersion)
                {
                    throw new IOException("The export staging file changed before commit.");
                }

                if (originalDestination is null)
                {
                    SetFileIdentity(temporaryPath, defaultOwner, defaultGroup);
                }
                else
                {
                    using var destinationStream = new FileStream(
                        destinationPath,
                        FileMode.Open,
                        FileAccess.Read,
                        FileShare.Read);
                    var currentDestination = ReadFileSnapshot(destinationStream);
                    if (currentDestination != originalDestination.Value)
                    {
                        throw new IOException(
                            "The export destination changed while the export was written.");
                    }

                    SetFileIdentity(
                        temporaryPath,
                        originalDestination.Value.Owner,
                        originalDestination.Value.Group);
                }

                cancellationToken.ThrowIfCancellationRequested();
            }

            if (originalDestination is null)
            {
                CommitNewWindowsFile(temporaryPath, destinationPath);
                TryApplyDefaultFileSecurity(destinationPath, defaultSecurity!);
                return;
            }

            // ReplaceFileW has no handle form; the final rename assumes the caller controls the parent folder.
            CommitExistingWindowsFile(temporaryPath, destinationPath, backupPath);
        }
        catch
        {
            TryDelete(temporaryPath);
            throw;
        }
    }

    [SupportedOSPlatform("windows")]
    private static FileSecurity CreatePrivateFileSecurity(SecurityIdentifier caller)
    {
        var security = new FileSecurity();
        security.SetOwner(caller);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            caller,
            FileSystemRights.FullControl,
            InheritanceFlags.None,
            PropagationFlags.None,
            AccessControlType.Allow));
        return security;
    }

    [SupportedOSPlatform("windows")]
    private static void VerifyPrivateFileSecurity(FileStream stream, SecurityIdentifier caller)
    {
        var security = stream.GetAccessControl();
        var descriptor = new RawSecurityDescriptor(
            security.GetSecurityDescriptorBinaryForm(),
            0);
        var access = descriptor.DiscretionaryAcl;
        var isPrivate =
            descriptor.ControlFlags.HasFlag(ControlFlags.DiscretionaryAclProtected) &&
            descriptor.Owner is not null &&
            caller.Equals(descriptor.Owner) &&
            access is { Count: 1 } &&
            access[0] is CommonAce
            {
                AceFlags: AceFlags.None,
                AceQualifier: AceQualifier.AccessAllowed,
                IsCallback: false,
                AccessMask: (int)FileSystemRights.FullControl
            } rule &&
            caller.Equals(rule.SecurityIdentifier);
        if (!isPrivate)
        {
            throw new IOException(
                "The destination filesystem did not enforce a private export staging file.");
        }
    }

    [SupportedOSPlatform("windows")]
    private static DestinationSnapshot? TryGetFileSnapshot(string path, FileShare share)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, share);
            return ReadFileSnapshot(stream);
        }
        catch (FileNotFoundException)
        {
            return null;
        }
        catch (DirectoryNotFoundException)
        {
            return null;
        }
        catch (UnauthorizedAccessException error)
        {
            throw new IOException(
                "The export destination is not an accessible regular file.",
                error);
        }
    }

    [SupportedOSPlatform("windows")]
    private static DestinationSnapshot ReadFileSnapshot(FileStream stream)
    {
        var security = stream.GetAccessControl();
        var owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier
            ?? throw new IOException("The export destination does not have a retrievable owner.");
        var group = security.GetGroup(typeof(SecurityIdentifier)) as SecurityIdentifier
            ?? throw new IOException("The export destination does not have a retrievable group.");
        var descriptor = security.GetSecurityDescriptorSddlForm(
            AccessControlSections.Owner |
            AccessControlSections.Group |
            AccessControlSections.Access);
        return new DestinationSnapshot(owner, group, descriptor, ReadFileVersion(stream));
    }

    [SupportedOSPlatform("windows")]
    private static FileVersion ReadFileVersion(FileStream stream)
    {
        if (!WindowsFileMetadata.TryReadVersion(stream.SafeFileHandle, out var version))
        {
            throw new IOException("The file identity could not be validated for atomic export.");
        }

        return version;
    }

    [SupportedOSPlatform("windows")]
    private static byte[] CaptureDefaultFileSecurity(string path)
    {
        using var stream = new FileStream(
            path,
            FileMode.CreateNew,
            FileAccess.ReadWrite,
            FileShare.None,
            1,
            FileOptions.DeleteOnClose);
        return stream.GetAccessControl().GetSecurityDescriptorBinaryForm();
    }

    [SupportedOSPlatform("windows")]
    private static SecurityIdentifier GetRequiredOwner(byte[] securityDescriptor)
    {
        var descriptor = new RawSecurityDescriptor(securityDescriptor, 0);
        return descriptor.Owner
            ?? throw new IOException("The default export security descriptor has no owner.");
    }

    [SupportedOSPlatform("windows")]
    private static SecurityIdentifier GetRequiredGroup(byte[] securityDescriptor)
    {
        var descriptor = new RawSecurityDescriptor(securityDescriptor, 0);
        return descriptor.Group
            ?? throw new IOException("The default export security descriptor has no primary group.");
    }

    [SupportedOSPlatform("windows")]
    private static void SetFileIdentity(
        string path,
        SecurityIdentifier destinationOwner,
        SecurityIdentifier destinationGroup)
    {
        try
        {
            var security = new FileSecurity();
            security.SetOwner(destinationOwner);
            security.SetGroup(destinationGroup);
            new FileInfo(path).SetAccessControl(security);
            var appliedSecurity = new FileInfo(path).GetAccessControl(
                AccessControlSections.Owner | AccessControlSections.Group);
            var appliedOwner = appliedSecurity.GetOwner(typeof(SecurityIdentifier));
            var appliedGroup = appliedSecurity.GetGroup(typeof(SecurityIdentifier));
            if (!destinationOwner.Equals(appliedOwner) ||
                !destinationGroup.Equals(appliedGroup))
            {
                throw new IOException("The export staging owner or group could not be preserved.");
            }
        }
        catch (Exception error) when (error is UnauthorizedAccessException
            or InvalidOperationException
            or NotSupportedException
            or System.Security.SecurityException)
        {
            throw new IOException(
                "The export destination owner or group cannot be preserved.",
                error);
        }
    }

    [SupportedOSPlatform("windows")]
    private static void CommitNewWindowsFile(string temporaryPath, string destinationPath)
    {
        if (!MoveFileExW(
                ToExtendedPath(temporaryPath),
                ToExtendedPath(destinationPath),
                MoveFileWriteThrough))
        {
            throw WindowsIOException(
                "The completed export could not be installed at the new destination.",
                Marshal.GetLastPInvokeError());
        }
    }

    [SupportedOSPlatform("windows")]
    private static void CommitExistingWindowsFile(
        string temporaryPath,
        string destinationPath,
        string backupPath)
    {
        if (ReplaceFileW(
                ToExtendedPath(destinationPath),
                ToExtendedPath(temporaryPath),
                ToExtendedPath(backupPath),
                0,
                0,
                0))
        {
            TryDelete(backupPath);
            return;
        }

        var replaceError = Marshal.GetLastPInvokeError();
        if (replaceError == ErrorUnableToMoveReplacement2)
        {
            if (MoveFileExW(
                    ToExtendedPath(backupPath),
                    ToExtendedPath(destinationPath),
                    MoveFileWriteThrough))
            {
                throw WindowsIOException(
                    "The export replacement failed; the previous destination was restored.",
                    replaceError);
            }

            var restoreError = Marshal.GetLastPInvokeError();
            throw new IOException(
                $"The export replacement and automatic recovery failed. " +
                $"The previous destination remains at '{backupPath}'.",
                new AggregateException(
                    new Win32Exception(replaceError),
                    new Win32Exception(restoreError)));
        }

        throw WindowsIOException(
            "The completed export could not replace the destination.",
            replaceError);
    }

    [SupportedOSPlatform("windows")]
    private static void TryApplyDefaultFileSecurity(string path, byte[] securityDescriptor)
    {
        try
        {
            var file = new FileInfo(path);
            var security = new FileSecurity();
            security.SetSecurityDescriptorBinaryForm(
                securityDescriptor,
                AccessControlSections.Owner |
                AccessControlSections.Group |
                AccessControlSections.Access);
            file.SetAccessControl(security);
        }
        catch
        {
            // Installation already committed; retain the safer private ACL on failure.
        }
    }

    private static IOException WindowsIOException(string message, int error) =>
        new(message, new Win32Exception(error));

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
            return;
        }
        catch (UnauthorizedAccessException)
        {
            // ReplaceFileW backups can retain the old destination's read-only attribute.
        }
        catch
        {
            return;
        }

        try
        {
            var attributes = File.GetAttributes(path) & ~FileAttributes.ReadOnly;
            File.SetAttributes(path, attributes == 0 ? FileAttributes.Normal : attributes);
            File.Delete(path);
        }
        catch
        {
            // Preserve the operation result; a complete recovery artifact may remain.
        }
    }

    [LibraryImport("kernel32.dll", EntryPoint = "ReplaceFileW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ReplaceFileW(
        string replacedFileName,
        string replacementFileName,
        string backupFileName,
        uint replaceFlags,
        nint exclude,
        nint reserved);

    [LibraryImport("kernel32.dll", EntryPoint = "MoveFileExW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool MoveFileExW(string existingFileName, string newFileName, uint flags);

    private readonly record struct DestinationSnapshot(
        SecurityIdentifier Owner,
        SecurityIdentifier Group,
        string SecurityDescriptor,
        FileVersion Version);
}
