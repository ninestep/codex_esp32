using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace CodexRemote.WindowsApp;

public sealed class AppModel : INotifyPropertyChanged
{
    private string connectionStatus = "正在搜索 Codex Remote…";
    private string speechStatus = "等待语音输入";
    private string batteryText = "电量未知";
    private bool loggedIn;
    public event PropertyChangedEventHandler? PropertyChanged;
    public string ConnectionStatus { get => connectionStatus; set => Set(ref connectionStatus, value); }
    public string SpeechStatus { get => speechStatus; set => Set(ref speechStatus, value); }
    public string BatteryText { get => batteryText; set => Set(ref batteryText, value); }
    public bool LoggedIn { get => loggedIn; set => Set(ref loggedIn, value); }
    public string LoginStatus => LoggedIn ? "已登录豆包" : "未登录豆包";
    public string LoginActionText => LoggedIn ? "退出登录" : "登录豆包";
    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null) { if (EqualityComparer<T>.Default.Equals(field, value)) return; field = value; PropertyChanged?.Invoke(this, new(name)); if (name == nameof(LoggedIn)) { PropertyChanged?.Invoke(this, new(nameof(LoginStatus))); PropertyChanged?.Invoke(this, new(nameof(LoginActionText))); } }
}
