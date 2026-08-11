using System.Windows;

namespace CodexRemote.WindowsApp;

public partial class SpeechOverlay : Window
{
    public SpeechOverlay() { InitializeComponent(); }
    public void SetState(string text, bool active) { Status.Text = text; Activity.Visibility = active ? Visibility.Visible : Visibility.Collapsed; if (active) Show(); else Hide(); }
}
