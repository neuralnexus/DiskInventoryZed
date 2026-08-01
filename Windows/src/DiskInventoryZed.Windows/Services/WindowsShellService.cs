using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using DiskInventoryZed.Core.Models;

namespace DiskInventoryZed.Windows.Services;

public static class WindowsShellService
{
    public static void Open(FileNode node)
    {
        Process.Start(new ProcessStartInfo(node.FullPath) { UseShellExecute = true });
    }

    public static Task RevealAsync(FileNode node)
    {
        var completion = new TaskCompletionSource<object?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            var comInitialized = false;
            try
            {
                var initializationResult = CoInitializeEx(IntPtr.Zero, CoinitApartmentThreaded);
                Marshal.ThrowExceptionForHR(initializationResult);
                comInitialized = true;
                RevealCore(node);
                completion.SetResult(null);
            }
            catch (Exception error)
            {
                completion.SetException(error);
            }
            finally
            {
                if (comInitialized)
                {
                    CoUninitialize();
                }
            }
        })
        {
            IsBackground = true,
            Name = "Disk Inventory Zed Explorer reveal"
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return completion.Task;
    }

    private static void RevealCore(FileNode node)
    {
        if (Path.GetPathRoot(node.FullPath)?.Equals(node.FullPath, StringComparison.OrdinalIgnoreCase) == true)
        {
            Open(node);
            return;
        }

        var itemIdList = IntPtr.Zero;
        var parentIdList = IntPtr.Zero;

        try
        {
            var parseResult = SHParseDisplayName(node.FullPath, IntPtr.Zero, out itemIdList, 0, out _);
            Marshal.ThrowExceptionForHR(parseResult);
            parentIdList = ILClone(itemIdList);
            if (parentIdList == IntPtr.Zero)
            {
                throw new IOException("File Explorer could not resolve the selected item.");
            }

            var childId = ILFindLastID(itemIdList);
            if (childId == IntPtr.Zero || !ILRemoveLastID(parentIdList))
            {
                throw new IOException("File Explorer could not resolve the selected item's parent folder.");
            }

            Marshal.ThrowExceptionForHR(SHOpenFolderAndSelectItems(parentIdList, 1, [childId], 0));
        }
        finally
        {
            if (parentIdList != IntPtr.Zero)
            {
                ILFree(parentIdList);
            }
            if (itemIdList != IntPtr.Zero)
            {
                ILFree(itemIdList);
            }
        }
    }

    public static void OpenContainingFolder(FileNode node)
    {
        var folder = Path.GetDirectoryName(node.FullPath);
        if (!string.IsNullOrWhiteSpace(folder))
        {
            Process.Start(new ProcessStartInfo(folder) { UseShellExecute = true });
        }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHParseDisplayName(
        string name,
        IntPtr bindContext,
        out IntPtr itemIdList,
        uint attributesIn,
        out uint attributesOut);

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHOpenFolderAndSelectItems(
        IntPtr folderIdList,
        uint itemCount,
        [MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] IntPtr[] childIdLists,
        uint flags);

    [DllImport("shell32.dll")]
    private static extern IntPtr ILClone(IntPtr itemIdList);

    [DllImport("shell32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ILRemoveLastID(IntPtr itemIdList);

    [DllImport("shell32.dll")]
    private static extern IntPtr ILFindLastID(IntPtr itemIdList);

    [DllImport("shell32.dll")]
    private static extern void ILFree(IntPtr itemIdList);

    private const uint CoinitApartmentThreaded = 0x2;

    [DllImport("ole32.dll")]
    private static extern int CoInitializeEx(IntPtr reserved, uint coInit);

    [DllImport("ole32.dll")]
    private static extern void CoUninitialize();
}
