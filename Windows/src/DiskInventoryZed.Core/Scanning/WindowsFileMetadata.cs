using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace DiskInventoryZed.Core.Scanning;

internal readonly record struct FileIdentity(ulong VolumeSerialNumber, Guid FileId);

internal enum ReparsePointClassification
{
    NotReparsePoint,
    NameSurrogate,
    Other,
    Unknown
}

internal readonly record struct FileMetadata(
    long AllocatedSize,
    FileIdentity? Identity,
    uint HardLinkCount,
    bool AllocatedSizeIsApproximate,
    ReparsePointClassification ReparsePointClassification);

internal static partial class WindowsFileMetadata
{
    private const uint FileReadAttributes = 0x0080;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint FileShareDelete = 0x00000004;
    private const uint OpenExisting = 3;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint IoReparseTagNameSurrogate = 0x20000000;
    private const int FileAttributeTagInfoClass = 9;
    private const int FileIdInfoClass = 18;

    public static unsafe FileMetadata Read(
        string path,
        bool isDirectory,
        bool isReparsePoint,
        long logicalSize)
    {
        if (!OperatingSystem.IsWindows())
        {
            return new FileMetadata(
                logicalSize,
                null,
                1,
                true,
                isReparsePoint
                    ? ReparsePointClassification.NameSurrogate
                    : ReparsePointClassification.NotReparsePoint);
        }

        var nativePath = ToExtendedPath(path);
        var allocatedSize = TryGetAllocatedSize(nativePath, out var measuredSize)
            ? measuredSize
            : logicalSize;
        var reparseClassification = isReparsePoint
            ? ReadReparsePointClassification(nativePath, isDirectory)
            : ReparsePointClassification.NotReparsePoint;

        using var handle = CreateFileW(
            nativePath,
            FileReadAttributes,
            FileShareRead | FileShareWrite | FileShareDelete,
            IntPtr.Zero,
            OpenExisting,
            isDirectory ? FileFlagBackupSemantics : 0,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            return new FileMetadata(allocatedSize, null, 1, measuredSize < 0, reparseClassification);
        }

        FileIdentity? identity = null;
        if (GetFileIdInformationByHandle(
                handle,
                FileIdInfoClass,
                out var idInformation,
                (uint)sizeof(FileIdInfo)) &&
            idInformation.VolumeSerialNumber != 0 &&
            idInformation.FileId != Guid.Empty)
        {
            identity = new FileIdentity(idInformation.VolumeSerialNumber, idInformation.FileId);
        }

        var hardLinkCount = GetFileInformationByHandle(handle, out var information)
            ? information.NumberOfLinks
            : 1;
        return new FileMetadata(
            allocatedSize,
            identity,
            hardLinkCount,
            measuredSize < 0,
            reparseClassification);
    }

    private static unsafe ReparsePointClassification ReadReparsePointClassification(
        string path,
        bool isDirectory)
    {
        using var handle = CreateFileW(
            path,
            0,
            FileShareRead | FileShareWrite | FileShareDelete,
            IntPtr.Zero,
            OpenExisting,
            FileFlagOpenReparsePoint | (isDirectory ? FileFlagBackupSemantics : 0),
            IntPtr.Zero);
        if (handle.IsInvalid ||
            !GetFileAttributeTagInformationByHandle(
                handle,
                FileAttributeTagInfoClass,
                out var tagInformation,
                (uint)sizeof(FileAttributeTagInfo)))
        {
            return ReparsePointClassification.Unknown;
        }

        return (tagInformation.ReparseTag & IoReparseTagNameSurrogate) != 0
            ? ReparsePointClassification.NameSurrogate
            : ReparsePointClassification.Other;
    }

    private static bool TryGetAllocatedSize(string path, out long allocatedSize)
    {
        Marshal.SetLastPInvokeError(0);
        var low = GetCompressedFileSizeW(path, out var high);
        var error = Marshal.GetLastPInvokeError();
        if (low == uint.MaxValue && error != 0)
        {
            allocatedSize = -1;
            return false;
        }

        allocatedSize = checked((long)(((ulong)high << 32) | low));
        return true;
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

    [LibraryImport("kernel32.dll", EntryPoint = "CreateFileW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    private static partial SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetFileInformationByHandle(
        SafeFileHandle file,
        out ByHandleFileInformation information);

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

    [LibraryImport("kernel32.dll", EntryPoint = "GetCompressedFileSizeW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    private static partial uint GetCompressedFileSizeW(string fileName, out uint fileSizeHigh);

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
    private struct FileAttributeTagInfo
    {
        public uint FileAttributes;
        public uint ReparseTag;
    }
}
