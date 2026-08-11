using System.Windows;

namespace CodexRemote.WindowsApp;

public partial class App : Application
{
    private SettingsWindow? settings;
    private SpeechOverlay? overlay;
    private TrayIconService? tray;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        overlay = new SpeechOverlay();
        settings = new SettingsWindow(overlay);
        tray = new TrayIconService(ShowSettings, ExitApplication);
        settings.Show();
    }

    private void ShowSettings() => Dispatcher.Invoke(() =>
    {
        if (settings is null) return;
        settings.Show();
        settings.WindowState = WindowState.Normal;
        settings.Activate();
    });

    private void ExitApplication() => Dispatcher.Invoke(() =>
    {
        tray?.Dispose();
        tray = null;
        overlay?.Close();
        settings?.CloseForExit();
        Shutdown();
    });
}
