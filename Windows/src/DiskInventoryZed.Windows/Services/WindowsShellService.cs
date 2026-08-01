using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using DiskInventoryZed.Core.Models;
using Microsoft.Win32.SafeHandles;

namespace DiskInventoryZed.Windows.Services;

public static class WindowsShellService
{
    public static void Open(FileNode node)
    {
        Process.Start(new ProcessStartInfo(node.FullPath) { UseShellExecute = true });
    }

    public static void Reveal(FileNode node)
    {
        if (Path.GetPathRoot(node.FullPath)?.Equals(node.FullPath, StringComparison.OrdinalIgnoreCase) == true)
        {
            Process.Start(new ProcessStartInfo(node.FullPath) { UseShellExecute = true });
            return;
        }

        Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            Arguments = $"/select,\"{node.FullPath}\"",
            UseShellExecute = true
        });
    }

    public static void OpenContainingFolder(FileNode node)
    {
        var folder = Path.GetDirectoryName(node.FullPath);
        if (!string.IsNullOrWhiteSpace(folder))
        {
            Process.Start(new ProcessStartInfo(folder) { UseShellExecute = true });
        }
    }

    public static bool CanMoveToRecycleBin(FileNode node, FileNode scanRoot, out string reason)
    {
        var path = Path.GetFullPath(node.FullPath);
        var rootPath = Path.GetFullPath(scanRoot.FullPath);
        if (path.Equals(rootPath, StringComparison.OrdinalIgnoreCase))
        {
            reason = "The root of the current scan cannot be moved to the Recycle Bin.";
            return false;
        }

        var volumeRoot = Path.GetPathRoot(path);
        if (string.IsNullOrWhiteSpace(volumeRoot) || path.TrimEnd('\\').Equals(volumeRoot.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
        {
            reason = "A drive or share root cannot be moved to the Recycle Bin.";
            return false;
        }

        if (IsNetworkPath(path, volumeRoot))
        {
            reason = "Windows cannot reliably recycle items on network shares. Disk Inventory Zed will never fall back to permanent deletion.";
            return false;
        }

        var scannedPath = scanRoot.PathTo(node.Id);
        if (scannedPath is null)
        {
            reason = "The selected item is no longer part of the active scan.";
            return false;
        }

        if (scannedPath.Take(Math.Max(0, scannedPath.Count - 1)).Any(ancestor => ancestor.IsSymbolicLink))
        {
            reason = "This item was reached through a followed link or junction. Rescan that location directly before recycling anything inside it.";
            return false;
        }

        if (!File.Exists(path) && !Directory.Exists(path))
        {
            reason = "The item no longer exists. Rescan the location to refresh the view.";
            return false;
        }

        var resolvedPath = TryGetFinalPath(path, node.IsDirectory);
        if (resolvedPath is null)
        {
            reason = "The item could not be resolved safely. Disk Inventory Zed will not recycle it.";
            return false;
        }

        var resolvedRoot = Path.GetPathRoot(resolvedPath);
        if (string.IsNullOrWhiteSpace(resolvedRoot) || IsNetworkPath(resolvedPath, resolvedRoot))
        {
            reason = "The resolved item is on a network share. Disk Inventory Zed will not risk a permanent network deletion.";
            return false;
        }

        var protectedTrees = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData)
        }.Where(value => !string.IsNullOrWhiteSpace(value));
        if (protectedTrees.Any(protectedPath => IsSameOrChild(resolvedPath, TryGetFinalPath(protectedPath, true) ?? protectedPath)))
        {
            reason = "Disk Inventory Zed will not recycle files from a protected Windows system tree.";
            return false;
        }

        var exactProtectedPaths = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Path.GetDirectoryName(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile))
        }.Where(value => !string.IsNullOrWhiteSpace(value));
        if (exactProtectedPaths.Any(protectedPath => resolvedPath.Equals(
                TryGetFinalPath(protectedPath!, true) ?? Path.GetFullPath(protectedPath!),
                StringComparison.OrdinalIgnoreCase)))
        {
            reason = "This protected user-profile location cannot be moved to the Recycle Bin.";
            return false;
        }

        reason = string.Empty;
        return true;
    }

    public static Task MoveToRecycleBinAsync(FileNode node, FileNode scanRoot, IntPtr ownerWindow)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                if (!CanMoveToRecycleBin(node, scanRoot, out var reason))
                {
                    throw new InvalidOperationException(reason);
                }

                MoveToRecycleBinCore(node.FullPath, ownerWindow);
                completion.SetResult();
            }
            catch (Exception error)
            {
                completion.SetException(error);
            }
        })
        {
            IsBackground = true,
            Name = "Disk Inventory Zed Recycle Bin"
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return completion.Task;
    }

    private static void MoveToRecycleBinCore(string path, IntPtr ownerWindow)
    {
        IShellItem? item = null;
        object? operationObject = null;
        try
        {
            var shellItemId = typeof(IShellItem).GUID;
            Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(path, IntPtr.Zero, ref shellItemId, out item));
            operationObject = new FileOperationComObject();
            var operation = (IFileOperation)operationObject;
            const uint allowUndo = 0x00000040;
            const uint noConfirmation = 0x00000010;
            const uint recycleOnDelete = 0x00080000;
            const uint earlyFailure = 0x00100000;
            Marshal.ThrowExceptionForHR(operation.SetOwnerWindow(ownerWindow));
            Marshal.ThrowExceptionForHR(operation.SetOperationFlags(allowUndo | noConfirmation | recycleOnDelete | earlyFailure));
            Marshal.ThrowExceptionForHR(operation.DeleteItem(item, IntPtr.Zero));
            Marshal.ThrowExceptionForHR(operation.PerformOperations());
            Marshal.ThrowExceptionForHR(operation.GetAnyOperationsAborted(out var aborted));
            if (aborted)
            {
                throw new OperationCanceledException("The Recycle Bin operation was cancelled.");
            }
        }
        finally
        {
            if (item is not null && Marshal.IsComObject(item))
            {
                Marshal.FinalReleaseComObject(item);
            }

            if (operationObject is not null && Marshal.IsComObject(operationObject))
            {
                Marshal.FinalReleaseComObject(operationObject);
            }
        }
    }

    private static bool IsNetworkPath(string path, string volumeRoot)
    {
        if (path.StartsWith("\\\\", StringComparison.Ordinal))
        {
            return true;
        }

        try
        {
            return new DriveInfo(volumeRoot).DriveType == DriveType.Network;
        }
        catch
        {
            return true;
        }
    }

    private static bool IsSameOrChild(string path, string possibleParent)
    {
        var parent = Path.GetFullPath(possibleParent).TrimEnd('\\');
        return path.Equals(parent, StringComparison.OrdinalIgnoreCase) ||
               path.StartsWith(parent + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private static string? TryGetFinalPath(string path, bool isDirectory)
    {
        const uint shareRead = 0x00000001;
        const uint shareWrite = 0x00000002;
        const uint shareDelete = 0x00000004;
        const uint openExisting = 3;
        const uint backupSemantics = 0x02000000;
        using var handle = CreateFileW(
            path,
            0,
            shareRead | shareWrite | shareDelete,
            IntPtr.Zero,
            openExisting,
            isDirectory ? backupSemantics : 0,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            return null;
        }

        var buffer = new StringBuilder(1024);
        var length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
        if (length == 0)
        {
            return null;
        }

        if (length >= buffer.Capacity)
        {
            buffer.EnsureCapacity((int)length + 1);
            length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0 || length >= buffer.Capacity)
            {
                return null;
            }
        }

        var finalPath = buffer.ToString();
        if (finalPath.StartsWith("\\\\?\\UNC\\", StringComparison.OrdinalIgnoreCase))
        {
            return "\\\\" + finalPath[8..];
        }

        return finalPath.StartsWith("\\\\?\\", StringComparison.OrdinalIgnoreCase) ? finalPath[4..] : finalPath;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(
        SafeFileHandle file,
        StringBuilder filePath,
        uint filePathLength,
        uint flags);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHCreateItemFromParsingName(
        string path,
        IntPtr bindContext,
        ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out IShellItem shellItem);

    [ComImport]
    [Guid("3AD05575-8857-4850-9277-11B85BDB8E09")]
    [ClassInterface(ClassInterfaceType.None)]
    private sealed class FileOperationComObject
    {
    }

    [ComImport]
    [Guid("947AAB5F-0A5C-4C13-B4D6-4BF7836FC9F8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOperation
    {
        [PreserveSig] int Advise(IntPtr progressSink, out uint cookie);
        [PreserveSig] int Unadvise(uint cookie);
        [PreserveSig] int SetOperationFlags(uint operationFlags);
        [PreserveSig] int SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string message);
        [PreserveSig] int SetProgressDialog([MarshalAs(UnmanagedType.IUnknown)] object progressDialog);
        [PreserveSig] int SetProperties([MarshalAs(UnmanagedType.IUnknown)] object propertyChanges);
        [PreserveSig] int SetOwnerWindow(IntPtr ownerWindow);
        [PreserveSig] int ApplyPropertiesToItem(IShellItem item);
        [PreserveSig] int ApplyPropertiesToItems([MarshalAs(UnmanagedType.IUnknown)] object items);
        [PreserveSig] int RenameItem(IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string newName, IntPtr progressSink);
        [PreserveSig] int RenameItems([MarshalAs(UnmanagedType.IUnknown)] object items, [MarshalAs(UnmanagedType.LPWStr)] string newName);
        [PreserveSig] int MoveItem(IShellItem item, IShellItem destinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string newName, IntPtr progressSink);
        [PreserveSig] int MoveItems([MarshalAs(UnmanagedType.IUnknown)] object items, IShellItem destinationFolder);
        [PreserveSig] int CopyItem(IShellItem item, IShellItem destinationFolder, [MarshalAs(UnmanagedType.LPWStr)] string copyName, IntPtr progressSink);
        [PreserveSig] int CopyItems([MarshalAs(UnmanagedType.IUnknown)] object items, IShellItem destinationFolder);
        [PreserveSig] int DeleteItem(IShellItem item, IntPtr progressSink);
        [PreserveSig] int DeleteItems([MarshalAs(UnmanagedType.IUnknown)] object items);
        [PreserveSig] int NewItem(IShellItem destinationFolder, uint fileAttributes, [MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.LPWStr)] string templateName, IntPtr progressSink);
        [PreserveSig] int PerformOperations();
        [PreserveSig] int GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool aborted);
    }

    [ComImport]
    [Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr bindContext, ref Guid handlerId, ref Guid interfaceId, out IntPtr result);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint displayNameType, out IntPtr name);
        void GetAttributes(uint attributeMask, out uint attributes);
        void Compare(IShellItem other, uint hint, out int order);
    }
}
