using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using DiskInventoryZed.Core.Analysis;
using DiskInventoryZed.Core.Export;
using DiskInventoryZed.Core.Models;
using DiskInventoryZed.Windows.Controls;
using DiskInventoryZed.Windows.Services;
using DiskInventoryZed.Windows.ViewModels;
using Microsoft.Win32;

namespace DiskInventoryZed.Windows;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;
    private bool _isShellActionRunning;
    private bool _isClosing;

    internal Task StartupTask { get; private set; } = Task.CompletedTask;
    internal bool SuppressStartupErrors { get; set; }

    public MainWindow() : this(new MainViewModel())
    {
    }

    internal MainWindow(MainViewModel viewModel)
    {
        _viewModel = viewModel;
        InitializeComponent();
        DataContext = _viewModel;
        _viewModel.ErrorRaised += ViewModel_ErrorRaised;
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        StartupTask = _viewModel.RefreshDrivesAsync();
        try
        {
            await StartupTask;
        }
        catch (Exception error)
        {
            if (!SuppressStartupErrors && !_isClosing)
            {
                ViewModel_ErrorRaised(this, $"Drive discovery failed: {error.Message}");
            }
        }
    }

    private void Window_Closed(object? sender, EventArgs e)
    {
        _isClosing = true;
        _viewModel.ErrorRaised -= ViewModel_ErrorRaised;
        _viewModel.Dispose();
    }

    private void ViewModel_ErrorRaised(object? sender, string message)
    {
        _ = Dispatcher.InvokeAsync(() =>
        {
            if (!_isClosing)
            {
                MessageBox.Show(
                    this,
                    message,
                    "Disk Inventory Zed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
        });
    }

    private async void ScanPath_Click(object sender, RoutedEventArgs e) =>
        await _viewModel.ScanAsync(_viewModel.PathText);

    private async void PathBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            e.Handled = true;
            await _viewModel.ScanAsync(_viewModel.PathText);
        }
    }

    private async void ChooseFolder_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog
        {
            Title = "Choose a local folder, mapped drive, or network share to scan",
            Multiselect = false
        };
        if (dialog.ShowDialog(this) == true)
        {
            await _viewModel.ScanAsync(dialog.FolderName);
        }
    }

    private async void Location_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: LocationItem location })
        {
            await _viewModel.ScanAsync(location.Path);
        }
    }

    private void Back_Click(object sender, RoutedEventArgs e) => _viewModel.NavigateBack();
    private void Forward_Click(object sender, RoutedEventArgs e) => _viewModel.NavigateForward();
    private void Up_Click(object sender, RoutedEventArgs e) => _viewModel.NavigateUp();
    private void Root_Click(object sender, RoutedEventArgs e) => _viewModel.NavigateToRoot();

    private void Breadcrumb_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: FileNode node })
        {
            _viewModel.NavigateTo(node);
        }
    }

    private void FolderTree_SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
    {
        if (e.NewValue is FileNode node && !node.Equals(_viewModel.CurrentNode))
        {
            _viewModel.NavigateTo(node);
        }
    }

    private void Visualization_NodeSelected(object? sender, FileNodeEventArgs e) =>
        _viewModel.SelectedNode = e.Node;

    private void Visualization_NodeInvoked(object? sender, FileNodeEventArgs e) =>
        _viewModel.NavigateTo(e.Node);

    private void FileGrid_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (FindVisualParent<DataGridRow>(e.OriginalSource as DependencyObject) is not { DataContext: FileNode node })
        {
            return;
        }

        ActivateFileGridNode(node);
    }

    private void FileGrid_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter &&
            Keyboard.Modifiers == ModifierKeys.None &&
            FindVisualParent<DataGridRow>(e.OriginalSource as DependencyObject) is { DataContext: FileNode node })
        {
            e.Handled = ActivateFileGridNode(node);
        }
    }

    private bool ActivateFileGridNode(FileNode node)
    {
        if (!_viewModel.TryGetActiveNode(node, out var activeNode))
        {
            return false;
        }

        if (activeNode.IsDirectory)
        {
            _viewModel.NavigateTo(activeNode);
        }
        else
        {
            _viewModel.SelectedNode = activeNode;
            RunShellAction(WindowsShellService.Open);
        }
        return true;
    }

    private void FileGrid_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (FindVisualParent<DataGridRow>(e.OriginalSource as DependencyObject) is { } row)
        {
            row.IsSelected = true;
            row.Focus();
        }
    }

    private void FileGrid_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        var openedFromKeyboard = e.CursorLeft < 0 && e.CursorTop < 0;
        if ((!openedFromKeyboard &&
             FindVisualParent<DataGridRow>(Mouse.DirectlyOver as DependencyObject) is null) ||
            FileGrid.SelectedItem is not FileNode selectedNode ||
            !_viewModel.TryGetActiveNode(selectedNode, out _))
        {
            e.Handled = true;
        }
    }

    private void ExtensionList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        _viewModel.SelectedExtension = (ExtensionList.SelectedItem as ExtensionStat)?.Extension;
    }

    private void ClearTypeFilter_Click(object sender, RoutedEventArgs e)
    {
        ExtensionList.SelectedItem = null;
        _viewModel.SelectedExtension = null;
    }

    private void InsightList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (InsightNodeFrom(e.OriginalSource as DependencyObject) is { } node)
        {
            _viewModel.Focus(node);
        }
    }

    private void InsightList_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter &&
            Keyboard.Modifiers == ModifierKeys.None &&
            InsightNodeFrom(e.OriginalSource as DependencyObject) is { } node)
        {
            _viewModel.Focus(node);
            e.Handled = true;
        }
    }

    internal static FileNode? InsightNodeFrom(DependencyObject? source) =>
        FindVisualParent<ListBoxItem>(source)?.DataContext as FileNode;

    private async void VerifyDuplicates_Click(object sender, RoutedEventArgs e) =>
        await _viewModel.VerifyDuplicatesAsync();

    private void CancelVerification_Click(object sender, RoutedEventArgs e) =>
        _viewModel.CancelDuplicateVerification();

    private async void Rescan_Click(object sender, RoutedEventArgs e) =>
        await _viewModel.RescanAsync();

    private void CancelScan_Click(object sender, RoutedEventArgs e) => _viewModel.CancelScan();

    private async void ExportJson_Click(object sender, RoutedEventArgs e)
    {
        if (!_viewModel.CanUseSnapshot ||
            _viewModel.RootNode is not { } root ||
            _viewModel.ScanResult is not { } result)
        {
            return;
        }

        var dialog = new SaveFileDialog
        {
            Title = "Export scan snapshot",
            Filter = "JSON snapshot (*.json)|*.json",
            FileName = "DiskInventoryScan.json",
            AddExtension = true,
            DefaultExt = ".json"
        };
        if (dialog.ShowDialog(this) != true)
        {
            return;
        }

        try
        {
            Mouse.OverrideCursor = Cursors.Wait;
            await Task.Run(() => ScanExporter.ExportJsonAsync(root, result.Diagnostics, dialog.FileName, result.Options));
        }
        catch (Exception error)
        {
            ShowError($"The snapshot could not be exported: {error.Message}");
        }
        finally
        {
            Mouse.OverrideCursor = null;
        }
    }

    private async void ExportCsv_Click(object sender, RoutedEventArgs e)
    {
        if (!_viewModel.CanUseSnapshot || _viewModel.RootNode is not { } root)
        {
            return;
        }

        var dialog = new SaveFileDialog
        {
            Title = "Export file inventory",
            Filter = "CSV inventory (*.csv)|*.csv",
            FileName = "DiskInventoryScan.csv",
            AddExtension = true,
            DefaultExt = ".csv"
        };
        if (dialog.ShowDialog(this) != true)
        {
            return;
        }

        try
        {
            Mouse.OverrideCursor = Cursors.Wait;
            await Task.Run(() => ScanExporter.ExportCsvAsync(root, dialog.FileName));
        }
        catch (Exception error)
        {
            ShowError($"The CSV inventory could not be exported: {error.Message}");
        }
        finally
        {
            Mouse.OverrideCursor = null;
        }
    }

    private void OpenSelected_Click(object sender, RoutedEventArgs e) => RunShellAction(WindowsShellService.Open);
    private async void RevealSelected_Click(object sender, RoutedEventArgs e) =>
        await RunShellActionAsync(WindowsShellService.RevealAsync);
    private void OpenContaining_Click(object sender, RoutedEventArgs e) => RunShellAction(WindowsShellService.OpenContainingFolder);

    private void CopyPath_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel.TryGetActiveNode(_viewModel.InspectedNode, out var node))
        {
            try
            {
                Clipboard.SetText(node.FullPath);
            }
            catch (Exception error)
            {
                ShowError($"The path could not be copied: {error.Message}");
            }
        }
    }

    private void RunShellAction(Action<FileNode> action)
    {
        if (!_viewModel.TryGetActiveNode(_viewModel.InspectedNode, out var node))
        {
            return;
        }

        try
        {
            action(node);
        }
        catch (Exception error)
        {
            ShowError(error.Message);
        }
    }

    private async Task RunShellActionAsync(Func<FileNode, Task> action)
    {
        if (_isShellActionRunning || !_viewModel.TryGetActiveNode(_viewModel.InspectedNode, out var node))
        {
            return;
        }

        try
        {
            _isShellActionRunning = true;
            await action(node);
        }
        catch (Exception error)
        {
            ShowError(error.Message);
        }
        finally
        {
            _isShellActionRunning = false;
        }
    }

    private async void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
        {
            if (e.Key is Key.D1 or Key.NumPad1)
            {
                VisualizationTabs.SelectedIndex = 0;
                e.Handled = true;
                return;
            }

            if (e.Key is Key.D2 or Key.NumPad2)
            {
                VisualizationTabs.SelectedIndex = 1;
                e.Handled = true;
                return;
            }

            if (e.Key is Key.D3 or Key.NumPad3)
            {
                VisualizationTabs.SelectedIndex = 2;
                e.Handled = true;
                return;
            }
        }

        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt) && e.Key == Key.Left)
        {
            _viewModel.NavigateBack();
            e.Handled = true;
        }
        else if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt) && e.Key == Key.Right)
        {
            _viewModel.NavigateForward();
            e.Handled = true;
        }
        else if (e.Key == Key.F5)
        {
            await _viewModel.RescanAsync();
            e.Handled = true;
        }
        else if (e.Key == Key.Escape && _viewModel.IsScanning)
        {
            _viewModel.CancelScan();
            e.Handled = true;
        }
        else if (e.OriginalSource is not TextBox && e.Key == Key.Back)
        {
            _viewModel.NavigateUp();
            e.Handled = true;
        }
    }

    private void ShowError(string message) => MessageBox.Show(
        this,
        message,
        "Disk Inventory Zed",
        MessageBoxButton.OK,
        MessageBoxImage.Error);

    private static T? FindVisualParent<T>(DependencyObject? child) where T : DependencyObject
    {
        while (child is not null)
        {
            if (child is T match)
            {
                return match;
            }

            child = VisualTreeHelper.GetParent(child);
        }

        return null;
    }
}
