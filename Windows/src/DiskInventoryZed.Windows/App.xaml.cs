using System.Windows.Threading;
using DiskInventoryZed.Windows.Services;

namespace DiskInventoryZed.Windows;

public partial class App : System.Windows.Application
{
    private readonly AppDiagnostics _diagnostics = new();

    public App()
    {
        _diagnostics.StartSession();
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += OnUnhandledException;
        TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;
        Exit += OnExit;
    }

    internal static void RecordDiagnostic(string eventCode, Exception? error = null) =>
        (Current as App)?._diagnostics.Record(eventCode, error);

    protected override void OnStartup(System.Windows.StartupEventArgs e)
    {
        base.OnStartup(e);
        var window = new MainWindow();
        MainWindow = window;
        var smokeTest = e.Args.Contains("--smoke-test", StringComparer.Ordinal);
        window.SuppressStartupErrors = smokeTest;
        if (smokeTest)
        {
            window.Loaded += async (_, _) =>
            {
                try
                {
                    await window.StartupTask;
                    _ = window.Dispatcher.BeginInvoke(
                        System.Windows.Threading.DispatcherPriority.ApplicationIdle,
                        new Action(window.Close));
                }
                catch (Exception error)
                {
                    _diagnostics.Record("startup-smoke-failed", error);
                    Shutdown(1);
                }
            };
        }

        window.Show();
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e) =>
        _diagnostics.Record("dispatcher-unhandled-exception", e.Exception);

    private void OnUnhandledException(object? sender, UnhandledExceptionEventArgs e) =>
        _diagnostics.Record("process-unhandled-exception", e.ExceptionObject as Exception);

    private void OnUnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        _diagnostics.Record("unobserved-task-exception", e.Exception.GetBaseException());
        e.SetObserved();
    }

    private void OnExit(object sender, System.Windows.ExitEventArgs e)
    {
        _diagnostics.MarkCleanShutdown();
        DispatcherUnhandledException -= OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException -= OnUnhandledException;
        TaskScheduler.UnobservedTaskException -= OnUnobservedTaskException;
        Exit -= OnExit;
    }
}
