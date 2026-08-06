using System.Runtime.InteropServices;
using System.ComponentModel;
using System.Runtime.Versioning;
using Microsoft.Win32.SafeHandles;

namespace DiskInventoryZed.Core.Scanning;

internal readonly record struct FileIdentity(ulong VolumeSerialNumber, Guid FileId);
internal readonly record struct FileVersion(
    FileIdentity Identity,
    long ChangeTime,
    long LastWriteTime,
    long Length);

internal enum ReparsePointClassification
{
    NotReparsePoint,
    NameSurrogate,
    Other,
    Unknown,
    Unavailable
}

internal readonly record struct FileMetadata(
    long LogicalSize,
    long AllocatedSize,
    FileIdentity? Identity,
    uint HardLinkCount,
    bool AllocatedSizeIsApproximate,
    DateTimeOffset? CreationDate,
    DateTimeOffset? ModificationDate,
    ReparsePointClassification ReparsePointClassification,
    bool MetadataUnavailable);

internal static partial class WindowsFileMetadata
{
    private const uint FileReadAttributes = 0x0080;
    private const uint FileReadData = 0x0001;
    private const uint FileListDirectory = FileReadData;
    private const uint GenericRead = 0x80000000;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint OpenExisting = 3;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint FileFlagOpenNoRecall = 0x00100000;
    private const uint FileFlagSequentialScan = 0x08000000;
    private const uint FileFlagOverlapped = 0x40000000;
    private const uint FileAttributeDirectory = 0x00000010;
    private const uint FileAttributeReparsePoint = 0x00000400;
    private const uint FileAttributeOffline = 0x00001000;
    private const uint FileAttributeRecallOnDataAccess = 0x00400000;
    private const uint CfPlaceholderStatePartial = 0x00000010;
    private const uint CfPlaceholderStatePartiallyOnDisk = 0x00000020;
    private const uint CfPlaceholderStateInvalid = 0xffffffff;
    private const uint IoReparseTagNameSurrogate = 0x20000000;
    private const int FileBasicInfoClass = 0;
    private const int FileStandardInfoClass = 1;
    private const int FileAttributeTagInfoClass = 9;
    private const int FileIdInfoClass = 18;

    public static unsafe FileMetadata Read(
        string path,
        bool isDirectory,
        bool isReparsePoint,
        long logicalSize,
        bool followReparsePoints)
    {
        if (!OperatingSystem.IsWindows())
        {
            return new FileMetadata(
                logicalSize,
                logicalSize,
                null,
                1,
                true,
                null,
                null,
                isReparsePoint
                    ? ReparsePointClassification.NameSurrogate
                    : ReparsePointClassification.NotReparsePoint,
                false);
        }

        var nativePath = ToExtendedPath(path);
        using var entryHandle = CreateFileW(
            nativePath,
            FileReadAttributes,
            FileShareRead | FileShareWrite,
            IntPtr.Zero,
            OpenExisting,
            FileFlagOpenReparsePoint | (isDirectory ? FileFlagBackupSemantics : 0),
            IntPtr.Zero);
        if (entryHandle.IsInvalid ||
            !GetFileAttributeTagInformationByHandle(
                entryHandle,
                FileAttributeTagInfoClass,
                out var tagInformation,
                (uint)sizeof(FileAttributeTagInfo)))
        {
            return UnavailableEntry(isReparsePoint);
        }

        var actualIsDirectory = (tagInformation.FileAttributes & FileAttributeDirectory) != 0;
        var reparseClassification = (tagInformation.FileAttributes & FileAttributeReparsePoint) == 0
            ? ReparsePointClassification.NotReparsePoint
            : (tagInformation.ReparseTag & IoReparseTagNameSurrogate) != 0
                ? ReparsePointClassification.NameSurrogate
                : ReparsePointClassification.Other;
        if (reparseClassification == ReparsePointClassification.NameSurrogate && !followReparsePoints)
        {
            return new FileMetadata(
                0,
                0,
                null,
                1,
                false,
                null,
                null,
                reparseClassification,
                false);
        }

        SafeFileHandle? targetHandle = null;
        try
        {
            var metadataHandle = entryHandle;
            if (reparseClassification == ReparsePointClassification.NameSurrogate)
            {
                targetHandle = CreateFileW(
                    nativePath,
                    FileReadAttributes,
                    FileShareRead | FileShareWrite,
                    IntPtr.Zero,
                    OpenExisting,
                    actualIsDirectory ? FileFlagBackupSemantics : 0,
                    IntPtr.Zero);
                if (targetHandle.IsInvalid)
                {
                    return new FileMetadata(
                        0,
                        0,
                        null,
                        1,
                        false,
                        null,
                        null,
                        reparseClassification,
                        true);
                }
                metadataHandle = targetHandle;
            }

            var hasStandardInfo = GetFileStandardInformationByHandle(
                metadataHandle,
                FileStandardInfoClass,
                out var standardInformation,
                (uint)sizeof(FileStandardInfo));
            var hasLegacyInformation = GetFileInformationByHandle(
                metadataHandle,
                out var legacyInformation);
            var legacyLogicalSize = hasLegacyInformation && !actualIsDirectory
                ? (long)Math.Min(
                    (ulong)long.MaxValue,
                    ((ulong)legacyInformation.FileSizeHigh << 32) | legacyInformation.FileSizeLow)
                : logicalSize;
            var measuredLogicalSize = hasStandardInfo && !actualIsDirectory
                ? Math.Max(0, standardInformation.EndOfFile)
                : legacyLogicalSize;
            var measuredAllocatedSize = hasStandardInfo && !actualIsDirectory
                ? Math.Max(0, standardInformation.AllocationSize)
                : actualIsDirectory ? 0 : legacyLogicalSize;

            DateTimeOffset? creationDate = null;
            DateTimeOffset? modificationDate = null;
            if (GetFileBasicInformationByHandle(
                    metadataHandle,
                    FileBasicInfoClass,
                    out var basicInformation,
                    (uint)sizeof(FileBasicInfo)))
            {
                creationDate = FromFileTime(basicInformation.CreationTime);
                modificationDate = FromFileTime(basicInformation.LastWriteTime);
            }

            FileIdentity? identity = TryReadIdentity(metadataHandle, out var measuredIdentity)
                ? measuredIdentity
                : null;
            var hardLinkCount = hasStandardInfo
                ? standardInformation.NumberOfLinks
                : hasLegacyInformation
                    ? legacyInformation.NumberOfLinks
                    : 1;
            return new FileMetadata(
                measuredLogicalSize,
                measuredAllocatedSize,
                identity,
                hardLinkCount,
                !hasStandardInfo,
                creationDate,
                modificationDate,
                reparseClassification,
                false);
        }
        finally
        {
            targetHandle?.Dispose();
        }
    }

    internal static unsafe FileStream OpenLocallyAvailableRead(string path, int bufferSize)
    {
        var nativePath = ToExtendedPath(path);
        using var entryHandle = CreateFileW(
            nativePath,
            FileReadAttributes,
            FileShareRead,
            IntPtr.Zero,
            OpenExisting,
            FileFlagOpenReparsePoint | FileFlagOpenNoRecall,
            IntPtr.Zero);
        if (entryHandle.IsInvalid)
        {
            throw NativeIOException("The file entry could not be locked for safe verification.");
        }
        if (!GetFileAttributeTagInformationByHandle(
                entryHandle,
                FileAttributeTagInfoClass,
                out var entryTagInformation,
                (uint)sizeof(FileAttributeTagInfo)))
        {
            throw new IOException("Only stable, locally available regular file entries can be verified.");
        }

        var entryPlaceholderState = CfGetPlaceholderStateFromAttributeTag(
            entryTagInformation.FileAttributes,
            entryTagInformation.ReparseTag);
        if ((entryTagInformation.ReparseTag & IoReparseTagNameSurrogate) != 0 ||
            !IsLocallyAvailableRegularFile(entryTagInformation.FileAttributes, entryPlaceholderState) ||
            !TryReadIdentity(entryHandle, out var entryIdentity))
        {
            throw new IOException("Only stable, locally available regular file entries can be verified.");
        }

        var handle = CreateFileW(
            nativePath,
            GenericRead,
            FileShareRead,
            IntPtr.Zero,
            OpenExisting,
            FileFlagOpenNoRecall | FileFlagSequentialScan | FileFlagOverlapped,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastPInvokeError();
            handle.Dispose();
            throw NativeIOException("The file could not be inspected without recalling remote content.", error);
        }

        try
        {
            if (!GetFileAttributeTagInformationByHandle(
                    handle,
                    FileAttributeTagInfoClass,
                    out var tagInformation,
                    (uint)sizeof(FileAttributeTagInfo)))
            {
                throw NativeIOException("The file availability could not be inspected.");
            }

            var placeholderState = CfGetPlaceholderStateFromAttributeTag(
                tagInformation.FileAttributes,
                tagInformation.ReparseTag);
            if ((tagInformation.ReparseTag & IoReparseTagNameSurrogate) != 0 ||
                !IsLocallyAvailableRegularFile(tagInformation.FileAttributes, placeholderState) ||
                !TryReadIdentity(handle, out var openedIdentity) ||
                openedIdentity != entryIdentity)
            {
                throw new IOException("Only locally available regular files can be verified.");
            }

            return new FileStream(handle, FileAccess.Read, bufferSize, isAsync: true);
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    internal static bool IsLocallyAvailableRegularFile(uint attributes, uint placeholderState)
    {
        var unavailableAttributes = FileAttributeDirectory | FileAttributeOffline | FileAttributeRecallOnDataAccess;
        var unavailablePlaceholderStates = CfPlaceholderStatePartial | CfPlaceholderStatePartiallyOnDisk;
        return (attributes & unavailableAttributes) == 0 &&
               placeholderState != CfPlaceholderStateInvalid &&
               (placeholderState & unavailablePlaceholderStates) == 0;
    }

    internal static FileMetadata UnavailableEntry(bool isReparsePoint) => new(
        0,
        0,
        null,
        1,
        false,
        null,
        null,
        isReparsePoint
            ? ReparsePointClassification.Unknown
            : ReparsePointClassification.Unavailable,
        true);

    internal static unsafe IDisposable OpenDirectoryGuard(
        string path,
        bool followReparsePoints,
        FileIdentity? expectedIdentity)
    {
        var entryHandle = CreateFileW(
            ToExtendedPath(path),
            FileListDirectory | FileReadAttributes,
            // Write sharing would permit in-place reparse mutation after validation.
            FileShareRead,
            IntPtr.Zero,
            OpenExisting,
            FileFlagBackupSemantics | FileFlagOpenReparsePoint,
            IntPtr.Zero);
        if (entryHandle.IsInvalid)
        {
            var error = Marshal.GetLastPInvokeError();
            entryHandle.Dispose();
            throw NativeIOException("The directory changed or could not be locked for safe enumeration.", error);
        }

        SafeFileHandle? targetHandle = null;
        try
        {
            if (!GetFileAttributeTagInformationByHandle(
                    entryHandle,
                    FileAttributeTagInfoClass,
                    out var tagInformation,
                    (uint)sizeof(FileAttributeTagInfo)))
            {
                throw NativeIOException("The directory type could not be revalidated before enumeration.");
            }
            if (!followReparsePoints && (tagInformation.ReparseTag & IoReparseTagNameSurrogate) != 0)
            {
                throw new IOException("The directory became a link or junction before it could be scanned safely.");
            }
            if ((tagInformation.FileAttributes & FileAttributeReparsePoint) != 0)
            {
                targetHandle = CreateFileW(
                    ToExtendedPath(path),
                    FileListDirectory | FileReadAttributes,
                    FileShareRead,
                    IntPtr.Zero,
                    OpenExisting,
                    FileFlagBackupSemantics,
                    IntPtr.Zero);
                if (targetHandle.IsInvalid)
                {
                    var error = Marshal.GetLastPInvokeError();
                    throw NativeIOException("The directory target changed or could not be locked for safe enumeration.", error);
                }
            }

            var identityHandle = targetHandle ?? entryHandle;
            if (expectedIdentity is { } expected &&
                (!GetFileIdInformationByHandle(
                    identityHandle,
                    FileIdInfoClass,
                    out var actual,
                    (uint)sizeof(FileIdInfo)) ||
                 actual.VolumeSerialNumber != expected.VolumeSerialNumber ||
                 actual.FileId != expected.FileId))
            {
                throw new IOException("The directory identity changed before it could be scanned safely.");
            }

            return new DirectoryGuard(entryHandle, targetHandle);
        }
        catch
        {
            targetHandle?.Dispose();
            entryHandle.Dispose();
            throw;
        }
    }

    private static DateTimeOffset? FromFileTime(long value)
    {
        if (value <= 0)
        {
            return null;
        }

        try
        {
            return new DateTimeOffset(DateTime.FromFileTimeUtc(value), TimeSpan.Zero);
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    [SupportedOSPlatform("windows")]
    internal static unsafe bool TryReadVersion(SafeFileHandle handle, out FileVersion version)
    {
        if (TryReadIdentity(handle, out var identity) &&
            GetFileBasicInformationByHandle(
                handle,
                FileBasicInfoClass,
                out var basicInformation,
                (uint)sizeof(FileBasicInfo)) &&
            GetFileStandardInformationByHandle(
                handle,
                FileStandardInfoClass,
                out var standardInformation,
                (uint)sizeof(FileStandardInfo)))
        {
            version = new FileVersion(
                identity,
                basicInformation.ChangeTime,
                basicInformation.LastWriteTime,
                standardInformation.EndOfFile);
            return true;
        }

        version = default;
        return false;
    }

    private static unsafe bool TryReadIdentity(SafeFileHandle handle, out FileIdentity identity)
    {
        if (GetFileIdInformationByHandle(
                handle,
                FileIdInfoClass,
                out var information,
                (uint)sizeof(FileIdInfo)) &&
            information.VolumeSerialNumber != 0 &&
            information.FileId != Guid.Empty)
        {
            identity = new FileIdentity(information.VolumeSerialNumber, information.FileId);
            return true;
        }

        identity = default;
        return false;
    }

    private static string ToExtendedPath(string path)
    {
        if (path.StartsWith("\\\\?\\", StringComparison.Ordinal) ||
            path.StartsWith("\\\\.\\", StringComparison.Ordinal))
        {
            return path;
        }

        var fullPath = Path.GetFullPath(path);
        return fullPath.StartsWith("\\\\", StringComparison.Ordinal)
            ? "\\\\?\\UNC\\" + fullPath[2..]
            : "\\\\?\\" + fullPath;
    }

    private static IOException NativeIOException(string message, int? error = null) =>
        new(message, new Win32Exception(error ?? Marshal.GetLastPInvokeError()));

    [LibraryImport("kernel32.dll", EntryPoint = "CreateFileW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    private static partial SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [LibraryImport("cldapi.dll")]
    private static partial uint CfGetPlaceholderStateFromAttributeTag(uint fileAttributes, uint reparseTag);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetFileInformationByHandle(
        SafeFileHandle file,
        out ByHandleFileInformation information);

    [LibraryImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetFileStandardInformationByHandle(
        SafeFileHandle file,
        int informationClass,
        out FileStandardInfo information,
        uint bufferSize);

    [LibraryImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetFileBasicInformationByHandle(
        SafeFileHandle file,
        int informationClass,
        out FileBasicInfo information,
        uint bufferSize);

    [LibraryImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetFileIdInformationByHandle(
        SafeFileHandle file,
        int informationClass,
        out FileIdInfo information,
        uint bufferSize);

    [LibraryImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetFileAttributeTagInformationByHandle(
        SafeFileHandle file,
        int informationClass,
        out FileAttributeTagInfo information,
        uint bufferSize);

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileIdInfo
    {
        public ulong VolumeSerialNumber;
        public Guid FileId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileStandardInfo
    {
        public long AllocationSize;
        public long EndOfFile;
        public uint NumberOfLinks;
        public byte DeletePending;
        public byte Directory;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileBasicInfo
    {
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public long ChangeTime;
        public uint FileAttributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileAttributeTagInfo
    {
        public uint FileAttributes;
        public uint ReparseTag;
    }

    private sealed class DirectoryGuard(SafeFileHandle entryHandle, SafeFileHandle? targetHandle) : IDisposable
    {
        public void Dispose()
        {
            targetHandle?.Dispose();
            entryHandle.Dispose();
        }
    }
}
