namespace DiskInventoryZed.Windows;

public partial class App : System.Windows.Application
{
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
                catch
                {
                    Shutdown(1);
                }
            };
        }

        window.Show();
    }
}
